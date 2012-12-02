# Live Assets

## Gotchas

### Precompile

- Ordering of load paths matters. Precompile will use the first matching file found.
- You must use the same filename in your templates as you specify in precompile
  or you will find your assets are not compiled.
  - E.g. If using `environment.precompile ['app.js']` then use
  `!=js('app.js')` instead of `!=js('app')`

  - TODO: If no extension provided for `js()` arg, append `.js`.
    - `precompile` must always use extensions otherwise there is no way to tell whether you want to compile `app.js` or `app.css`.
