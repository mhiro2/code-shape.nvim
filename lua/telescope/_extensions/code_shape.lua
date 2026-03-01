return require("telescope").register_extension({
  exports = {
    code_shape = require("code-shape.picker.telescope").defs,
    defs = require("code-shape.picker.telescope").defs,
    hotspots = require("code-shape.picker.telescope").hotspots,
    calls = require("code-shape.picker.telescope").calls,
  },
})
