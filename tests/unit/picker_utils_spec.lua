local picker_utils = require("code-shape.picker.utils")

describe("picker.utils", function()
  local original_rpc

  before_each(function()
    original_rpc = package.loaded["code-shape.rpc"]
  end)

  after_each(function()
    package.loaded["code-shape.rpc"] = original_rpc
  end)

  describe("item_location", function()
    it("extracts filepath and 1-based line number", function()
      local item = {
        uri = "file:///tmp/test.lua",
        range = { start = { line = 9, character = 4 }, ["end"] = { line = 9, character = 20 } },
        name = "foo",
        kind = 12,
      }

      local path, lnum = picker_utils.item_location(item)

      assert.are.equal("/tmp/test.lua", path)
      assert.are.equal(10, lnum)
    end)

    it("handles missing range gracefully", function()
      local item = {
        uri = "file:///tmp/test.lua",
        range = nil,
        name = "foo",
        kind = 12,
      }

      local path, lnum = picker_utils.item_location(item)

      assert.are.equal("/tmp/test.lua", path)
      assert.are.equal(1, lnum)
    end)

    it("keeps non-file URI as-is", function()
      local item = {
        uri = "jdt://workspace/Foo",
        range = { start = { line = 1, character = 0 } },
      }

      local path, lnum = picker_utils.item_location(item)

      assert.are.equal("jdt://workspace/Foo", path)
      assert.are.equal(2, lnum)
    end)
  end)

  describe("format_entry", function()
    it("formats a search result item", function()
      local item = {
        uri = "file:///tmp/project/src/main.lua",
        range = { start = { line = 41, character = 0 }, ["end"] = { line = 41, character = 10 } },
        name = "setup",
        kind = 12,
        container_name = "M",
      }

      local display = picker_utils.format_entry(item)

      assert.is_string(display)
      assert.truthy(display:find("Function"))
      assert.truthy(display:find("setup"))
      assert.truthy(display:find("%[M%]"))
      assert.truthy(display:find(":42"))
    end)

    it("omits container if empty", function()
      local item = {
        uri = "file:///tmp/test.lua",
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
        name = "foo",
        kind = 12,
        container_name = nil,
      }

      local display = picker_utils.format_entry(item)

      assert.is_nil(display:find("%["))
    end)
  end)

  describe("format_hotspot", function()
    it("formats a hotspot item", function()
      local item = {
        path = "file:///tmp/project/src/main.lua",
        score = 0.85,
      }

      local display = picker_utils.format_hotspot(item)

      assert.is_string(display)
      assert.truthy(display:find("0.85"))
    end)
  end)

  describe("search_params", function()
    it("builds search params from config", function()
      local config = { search = { limit = 50 }, metrics = { complexity_cap = 80 } }

      local params = picker_utils.search_params("test", config)

      assert.are.equal("test", params.q)
      assert.are.equal(50, params.limit)
      assert.are.equal(80, params.complexity_cap)
      assert.is_nil(params.filters)
    end)

    it("includes kind filter when provided", function()
      local config = { search = { limit = 50 }, metrics = { complexity_cap = 50 } }

      local params = picker_utils.search_params("test", config, { 6, 12 })

      assert.are.same({ kinds = { 6, 12 } }, params.filters)
    end)
  end)

  describe("search_symbols", function()
    it("returns results via coroutine yield", function()
      package.loaded["code-shape.rpc"] = {
        request = function(_, _, cb)
          cb(nil, {
            symbols = {
              {
                symbol_id = "s1",
                name = "my_fn",
                kind = 12,
                container_name = "M",
                uri = "file:///tmp/test.lua",
                range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } },
                score = 1,
              },
            },
          })
        end,
      }

      -- Run inside a coroutine (as all real callers do)
      local result
      local co = coroutine.create(function()
        result = picker_utils.search_symbols("my_fn", { search = { limit = 20 }, metrics = { complexity_cap = 50 } })
      end)
      coroutine.resume(co)

      assert.are.equal(1, #result)
      assert.are.equal("my_fn", result[1].name)
    end)

    it("returns empty for empty query", function()
      local result
      local co = coroutine.create(function()
        result = picker_utils.search_symbols("", { search = { limit = 20 }, metrics = { complexity_cap = 50 } })
      end)
      coroutine.resume(co)

      assert.are.same({}, result)
    end)

    it("returns empty when not in coroutine context", function()
      local symbols =
        picker_utils.search_symbols("my_fn", { search = { limit = 20 }, metrics = { complexity_cap = 50 } })
      assert.are.same({}, symbols)
    end)
  end)
end)
