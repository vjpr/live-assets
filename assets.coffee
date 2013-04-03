_         = require 'underscore'
Mincer    = require 'mincer'
path      = require 'path'
fs        = require 'fs'
UglifyJS  = require 'uglify-js'
Csso      = require 'csso'

class Assets

  constructor: (@opts = {}) ->

    # Process options.
    _.defaults @opts,
      logger: console
      mincerLogger: console
      root: process.cwd()
      digest: false
      expandTags: true
      usePrecompiledAssets: false
      # The directory which is searched for uploaded precompiled assets.
      # If the assets are not found here then we precompile assets on server.
      remoteAssetsDir: ''
      helpers: {} # Helper methods for templates.
      minify: false
      # Where assets are served from in production.
      assetServePath: 'http://localhost:3000/assets'
      # The path where Mincer serves assets from in development.
      localServePath: '/assets'
      files: null
      # If a helper tag causes an error, how should we display it?
      inPageErrorFormat: 'html' # Options: popup | html | none
      # If a helper tag causes an error, should we display a message
      # for the developer or the production user?
      inPageErrorVerbosity: 'dev' # Options dev | prod
      # Once we run `useInMemoryCachedAssets` we cannot modify the environment.
      # This callback runs just after we create the Mincer environment.
      afterEnvironmentCreated: ->
      # Fired when assets have been precompiled when we are precompiling and also
      # when the environment is ready if we are not precompiling.
      # This is useful during testing.
      afterAssetsReady: ->
    @expandTags = @opts.expandTags
    @digest = @opts.digest

    # Whether we are using uploaded assets. This is determined only after
    # running useUploadedAssets() which may fail and fallback to cached assets.
    @usingUploadedAssets = false

    # Configure logging.
    Mincer.logger.use @opts.mincerLogger
    @logger = @opts.logger

    # TODO: I think we can get rid of this because it was fixed upstream.
    #Mincer.unregisterPostProcessor 'application/javascript', Mincer.SafetyColons

    # This is the mincer environment.
    @env = new Mincer.Environment @opts.root

    # Allow user to modify the environment before we make our modifications.
    @opts.afterEnvironmentCreated.apply @

    @setupPaths()
    @setupHelpers()
    @setMinifyBuilds @opts.minify

    # Precompiled Assets
    # ------------------
    # If we are running remotely we use uploaded assets
    # Also, when running staging locally we use precompiled assets.
    # TODO: This should really be a flag somewhere.
    if @opts.usePrecompiledAssets
      @useUploadedAssets @opts.afterAssetsReady
    else
      @opts.afterAssetsReady()

  # Serve in-memory cached assets and use their digests.
  useInMemoryCachedAssets: (cb) =>
    unless @opts.files?
      return new Error 'Specify `files` as an option to allow precompiling.'
    # Cache all compiled assets.
    @env = @env.index
    # Ensure assets have been precompiled
    start = new Date()
    @logger.debug "Precompile assets: started"
    @env.precompile @opts.files, (err, data) =>
      return cb err if err
      duration = (new Date() - start) / 1000
      @logger.debug "Precompile assets: finished in #{duration}s"
      # Serve precompiled assets from Mincer server
      @logger.info "Now serving server-compiled in-memory cached assets"
      # Index#findAssets caches assets on first use
      cb()

  # Use digests from uploaded `manifest.json` file.
  useUploadedAssets: (assetsReady) =>
    if fs.existsSync path.join @opts.remoteAssetsDir, 'manifest.json'
      @logger.info "Now serving uploaded assets from " + @opts.remoteAssetsDir
      @usingUploadedAssets = true
      @manifest = new Mincer.Manifest @env, @opts.remoteAssetsDir
      assetsReady()
    else
      @logger.warn "Could not find manifest.json. Reverting to cached."
      @usingUploadedAssets = false
      @useInMemoryCachedAssets (err) =>
        return @logger.error err if err
        assetsReady()

  # Precompile assets for development. Required because templating is
  # not asynchronous which prevents expanded tags until asset is compiled.
  #
  # IMPORTANT: You must handle the callback otherwise you will receive a
  # popup box on your webpage informing you that a file is not compiled,
  # but not letting you know what prevented it from compiling.
  precompileForDevelopment: (cb) =>
    unless @opts.files?
      return new Error 'Specify `files` as an option to allow precompiling.'
    start = new Date()
    @logger.info "Precompile: started"
    @env.precompile @opts.files, (err, data) =>
      if err
        @logger.error "Precompile: #{'failed'.red}"
        return cb err
      duration = (new Date() - start) / 1000
      @logger.info "Precompile: finished in #{duration}s"
      cb()

  # This could be monkey-patched as findAsset() potentially. Although this would
  # need to return an `Asset` object which is tricky and error-prone.
  #@env.findAsset = (logicalPath) ->
  getDigestPathFromManifest: (logicalPath) =>
    digestPath = @manifest.assets[logicalPath]
    if digestPath?
      return digestPath
    else
      msg = "Could not find precompiled file for: " + logicalPath
      msg += "\nPlease make sure you have uploaded the assets to " + @opts.remoteAssetsDir
      msg += "\nAlso make sure the asset is set to be precompiled."
      throw new Error msg

  getEnvironment: => @env

  getMincer: => Mincer

  setupPaths: =>
    unless @opts.paths?.length
      throw new Error "You must provide at least one source path."
    @env.appendPath p for p in @opts.paths

  # Minification
  # ------------

  setMinifyBuilds: (bool) =>
    if bool
      @setupCompressors()
    else
      @env.jsCompressor = null
      @env.cssCompressor = null

  # Enable compression when minifying builds.
  setupCompressors: =>
    @env.jsCompressor = (context, data, callback) ->
      try
        ast = UglifyJS.parser.parse(data)
        ast = UglifyJS.uglify.ast_mangle(ast)
        ast = UglifyJS.uglify.ast_squeeze(ast)
        callback null, UglifyJS.uglify.gen_code(ast)
      catch err
        callback err
    @env.cssCompressor = (context, data, callback) ->
      try
        callback null, Csso.justDoIt(data)
      catch err
        callback err

  # ---

  _shouldAppendDigest: (asset) =>
    @digest and (asset.contentType isnt 'text/html')

  assetPathAsync: (pathname, cb) =>
    asset = @env.findAsset(pathname)
    if not asset.isCompiled
      asset.compile (err, result) ->
        return cb err if err
        if asset
          # We don't return digests for html pages and when compiling extension
          if @_shouldAppendDigest asset
            cb null, asset.digestPath
          else
            cb null, asset.logicalPath
        else
          cb null, @_handleLogicalPathNotFoundError pathname

  # TODO: Try and move to assetPathAsync in the future.
  # This function is very broken, we don't actually use digests for most assets
  # so things seem like they work.
  assetPathSync: (pathname, cb) =>
    asset = @env.findAsset(pathname)
    if not asset.isCompiled
      asset.compile (err, result) ->
        throw err if err
        # TODO: There is no guarantee that we get the correct digest
        #   because of async compile. Seems to work so far but its very
        #   bad. Need to use async .ejs templating engine.
        #   Possibly use dependOnAsset at top of file.
        #   Template needs to be rendered asynchronously.
    if asset
      # We don't return digests for html pages and when compiling extension
      if @_shouldAppendDigest asset
        return asset.digestPath
      else
        return asset.logicalPath
    else
      return @_handleLogicalPathNotFoundError pathname

  # Make locals accessible to dynamic templates
  locals: =>
    (req, res, next) =>
      _.extend res.locals, @getHelpers()
      next()

  # Serve assets over HTTP
  middleware: (app) =>
    unless @server?
      @server = Mincer.createServer @env
    app.use @locals()
    app.use @opts.localServePath, @server

  # Helpers
  # -------

  setupHelpers: =>
    # These helpers are accessible in templates as methods
    @env.registerHelper @getHelpers()

  getHelpers: =>
    _.extend @opts.helpers,
      js: @clientHelper().js
      css: @clientHelper().css
      asset: @clientHelper().asset
      stylusAssetPath: (pathname) =>
        "url(#{@assetPathSync pathname})"
      stylusAssetPathAsync: (pathname, cb) =>
        @assetPathAsync pathname, (err, result) ->
          return cb err if err
          cb null, "url(#{result})"
      assetPath: @assetPathSync
      assetPathAsync: @assetPathAsync
      mincerEnv: => @env

  # If a callback is passed in, we run an async version.
  clientHelper: =>

    # Returns string of line separated html tags from an array of paths.
    # Paths are adjusted based upon environment.
    # tmpl - An Underscore function for generating the tag which takes a local named `path`.
    # mimetype - Used for messaging purposes only. Doesn't need to be mime.
    # opts -
    #   pathsOnly - If true, return an array of paths.
    #   TODO: array - If true, return an array of tags.
    processPaths = (paths, logicalPath, mimetype, tmpl, opts = {}) =>
      paths = @_prefixPathWithServePath paths
      if tmpl then tmpl = _.template tmpl
      if opts.pathsOnly
        return ( p for p in paths )
      else
        return (tmpl(path: p) for p in paths).join('\n')

    getPaths = (logicalPath, mimetype, tmpl, opts, cb) =>
      if cb?
        @_findAssetPaths logicalPath, @expandTags, (err, paths) =>
          return cb err if err
          return cb @_handleLogicalPathNotFoundError(logicalPath, mimetype, paths, opts) if not paths or paths instanceof Error
          cb null, processPaths paths, logicalPath, mimetype, tmpl, opts
      else
        paths = @_findAssetPathsSync logicalPath, @expandTags
        return @_handleLogicalPathNotFoundError(logicalPath, mimetype, paths, opts) if not paths or paths instanceof Error
        processPaths paths, logicalPath, mimetype, tmpl, opts

    js: (logicalPath, cb) =>
      mimetype = 'application/javascript'
      tmpl = "<script type='application/javascript' src='<%= path %>'></script>"
      return getPaths logicalPath, mimetype, tmpl, {}, cb

    css: (logicalPath, cb) =>
      mimetype = 'text/css'
      tmpl = "<link rel='stylesheet' type='text/css' href='<%= path %>'></link>"
      return getPaths logicalPath, mimetype, tmpl, {}, cb

    # Get path to a single asset.
    asset: (logicalPath, cb) =>
      mimetype = 'Asset'
      if cb?
        getPaths logicalPath, mimetype, null, {pathsOnly: true}, (err, paths) =>
          return cb err if err
          cb null, paths[0]
      else
        ret = getPaths logicalPath, mimetype, null, {pathsOnly: true}
        ret[0]

  compile: (files, dest, servePath, cb) =>
    manifest = new Mincer.Manifest @env, dest
    manifest.compile files, (err, data) ->
      return cb err if err
      cb err, data

  # PRIVATE
  # -------

  # Take a logical path and return the path to itself and optionally,
  # its dependencies.

  _findAssetPaths: (logicalPath, includeDependencies = false, cb) =>
    return cb(null, [@getDigestPathFromManifest(logicalPath)]) if @usingUploadedAssets
    asset = @env.findAsset(logicalPath)
    return cb(new Error "Asset '#{logicalPath}' not found") if not asset
    # Precompile asset.
    if not asset.isCompiled
      asset.compile (err, data) =>
        return cb(new Error "Could not compile asset #{logicalPath}") if err
        cb null, @_processAssetPaths logicalPath, asset, includeDependencies
    else
      cb null, @_processAssetPaths logicalPath, asset, includeDependencies

  _findAssetPathsSync: (logicalPath, includeDependencies = false) =>
    return [@getDigestPathFromManifest(logicalPath)] if @usingUploadedAssets
    asset = @env.findAsset(logicalPath)
    return null if not asset
    # Precompile asset.
    if not asset.isCompiled
      msg = "#{logicalPath} is not compiled.\n" +
        "You must precompile your assets before rendering a webpage.\n" +
        "1. There may have been an error during precompilation. Check your logs.\n" +
        "2. You may not be handling the callback from method `precompileForDevelopment` and precompilation is failing silently. You should handle this callback.\n" +
        "3. You are not precompiling your assets before rendering your templates. Use the method `precompileForDevelopment` before rendering a view.\n" +
        "4. If you do not want to precompile before each request you must use the async version of this method with an async templating library (which are hard to find)."
      return new Error msg
    else
      @_processAssetPaths logicalPath, asset, includeDependencies

  # STATIC!
  _processAssetPaths: (logicalPath, asset, includeDependencies) ->
    paths = []

    # The problem is that the asset dependencies are not known until
    # compile. Since compile is async and templating is sync, we have
    # to wait until assets are compiled before serving templates.
    # TODO: Get asset dependencies synchronously.

    if includeDependencies and not asset.isCompiled
      @logger.warn "#{logicalPath} is not compiled yet"

    # Use this line if you want to serve the unexpanded tag in the meantime.
    #if includeDependencies and asset.isCompiled
    if includeDependencies
      for dep in asset.toArray()
        paths.push dep.logicalPath + '?body=1'
    else
      if @_shouldAppendDigest asset
        paths.push asset.digestPath
      else
        # TODO: Non-digest paths currently not supported
        paths.push asset.logicalPath
    paths

  _prefixPathWithServePath: (paths) =>
    (@opts.assetServePath + p for p in paths)

  _handleLogicalPathNotFoundError: (logicalPath, fileType = 'The', err) ->

    if err instanceof Error
      return err if @opts.pathsOnly
      # Replace new lines with literal new lines.
      err = err.toString().replace /(\r\n|\n|\r)/gm, '\\n\\n'
      msg = "#{fileType} file #{logicalPath} caused error: \\n\\n#{err}"

      return if @opts.inPageErrorFormat is 'none'
      if @opts.inPageErrorFormat is 'html'

        htmlMsg = if @opts.inPageErrorVerbosity is 'dev'
          "<pre style='margin: 20px'>#{msg}</p><hr>"
        else
          msg = "There was a problem loading file <strong>#{logicalPath}</strong>."
          "<pre style='margin: 20px'>#{msg}</div><hr>"

        return """
        <script src="https://ajax.googleapis.com/ajax/libs/jquery/1.8.3/jquery.min.js"></script>
        <script type='application/javascript'>
          $(document).ready(function () {
            if (!$('#live-assets-error').length) {
              $('body').html("<div id='live-assets-error'><h2 style='margin: 20px'>An error occurred while loading this page. Please check back shortly.</h1></div>")
            }
            el = $('#live-assets-error').append("#{htmlMsg}");
          });
        </script>
        """
      else
        # TODO: Might deprecate this error format in the future because it is annoying.
        return "<script type='application/javascript'>alert('#{msg}')</script>"

    else

      # This will help us notify that given logicalPath is not found
      # without "breaking" view renderer
      # TODO: Escape logicalPath - see mincer issue
      msg = "#{fileType} file #{JSON.stringify(logicalPath)} not found."
      return err if @opts.pathsOnly
      return "<script type='application/javascript'>alert('#{msg}')</script>"

module.exports = Assets
