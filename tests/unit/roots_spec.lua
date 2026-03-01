local roots = require("code-shape.roots")
local util = require("code-shape.util")

describe("roots", function()
  before_each(function()
    roots.clear()
  end)

  describe("register_uri", function()
    it("returns nil for non-file URIs", function()
      assert.is_nil(roots.register_uri("https://example.com"))
    end)

    it("returns nil for nil input", function()
      assert.is_nil(roots.register_uri(nil))
    end)

    it("returns git root for a file URI in a git repo", function()
      -- Use the current repo as test fixture
      local cwd = vim.fn.getcwd()
      local git_root = util.find_git_root(cwd)
      if not git_root then
        pending("not in a git repo")
        return
      end

      local test_uri = vim.uri_from_fname(cwd .. "/lua/code-shape/init.lua")
      local result = roots.register_uri(test_uri)
      assert.are.equal(git_root, result)
    end)
  end)

  describe("get_roots", function()
    it("returns empty table initially", function()
      local result = roots.get_roots()
      assert.are.same({}, result)
    end)

    it("returns registered roots sorted", function()
      -- Stub find_git_root to return known values
      local original = util.find_git_root
      local call_count = 0
      util.find_git_root = function()
        call_count = call_count + 1
        if call_count == 1 then
          return "/repo_b"
        else
          return "/repo_a"
        end
      end

      roots.register_uri("file:///repo_b/src/main.lua")
      roots.register_uri("file:///repo_a/src/main.lua")

      local result = roots.get_roots()
      assert.are.same({ "/repo_a", "/repo_b" }, result)

      util.find_git_root = original
    end)

    it("does not duplicate roots", function()
      local original = util.find_git_root
      util.find_git_root = function()
        return "/repo_a"
      end

      roots.register_uri("file:///repo_a/src/a.lua")
      roots.register_uri("file:///repo_a/src/b.lua")

      local result = roots.get_roots()
      assert.are.same({ "/repo_a" }, result)

      util.find_git_root = original
    end)
  end)

  describe("root_for_uri", function()
    it("returns nil for non-file URI", function()
      assert.is_nil(roots.root_for_uri("https://example.com"))
    end)

    it("returns git root for file URI", function()
      local cwd = vim.fn.getcwd()
      local git_root = util.find_git_root(cwd)
      if not git_root then
        pending("not in a git repo")
        return
      end

      local test_uri = vim.uri_from_fname(cwd .. "/lua/code-shape/init.lua")
      local result = roots.root_for_uri(test_uri)
      assert.are.equal(git_root, result)
    end)
  end)

  describe("clear", function()
    it("removes all tracked roots", function()
      local original = util.find_git_root
      util.find_git_root = function()
        return "/repo_a"
      end

      roots.register_uri("file:///repo_a/src/main.lua")
      assert.are.same({ "/repo_a" }, roots.get_roots())

      roots.clear()
      assert.are.same({}, roots.get_roots())

      util.find_git_root = original
    end)
  end)
end)
