local picker = require("code-shape.picker")

describe("picker.init", function()
  describe("open", function()
    it("notifies error for unknown backend", function()
      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      -- Mock code-shape module
      package.loaded["code-shape"] = {
        ensure_setup = function() end,
        get_config = function()
          return { picker = nil, search = { limit = 50 }, metrics = { complexity_cap = 50 } }
        end,
      }

      picker.open("defs", { picker = "nonexistent" })

      vim.notify = orig_notify
      package.loaded["code-shape"] = nil

      assert.is_true(#notifications > 0)
      assert.truthy(notifications[1].msg:find("unknown picker backend"))
    end)
  end)
end)
