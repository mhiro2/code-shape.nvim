local util = require("code-shape.util")

describe("util", function()
  describe("tbl_deep_merge", function()
    it("merges nested tables", function()
      local base = { a = 1, b = { c = 2, d = 3 } }
      local extra = { b = { c = 10 } }

      local result = util.tbl_deep_merge(base, extra)

      assert.are.equal(1, result.a)
      assert.are.equal(10, result.b.c)
      assert.are.equal(3, result.b.d)
    end)

    it("handles nil extra", function()
      local base = { a = 1 }

      local result = util.tbl_deep_merge(base, nil)

      assert.are.equal(1, result.a)
    end)
  end)

  describe("path_join", function()
    it("joins path components", function()
      local result = util.path_join("a", "b", "c")
      assert.are.equal(vim.fs.joinpath("a", "b", "c"), result)
    end)
  end)

  describe("dirname", function()
    it("returns parent directory", function()
      assert.are.equal(vim.fs.dirname("/a/b/c.txt"), util.dirname("/a/b/c.txt"))
    end)

    it("handles empty string", function()
      assert.are.equal(".", util.dirname(""))
    end)

    it("handles nil", function()
      assert.are.equal(".", util.dirname(nil))
    end)
  end)

  describe("find_git_root", function()
    it("finds git root from nested directory and returns cached result", function()
      local root = vim.fn.tempname()
      local git_dir = vim.fs.joinpath(root, ".git")
      local nested = vim.fs.joinpath(root, "src", "lua")
      vim.fn.mkdir(git_dir, "p")
      vim.fn.mkdir(nested, "p")

      local found_first = util.find_git_root(nested)
      local found_second = util.find_git_root(nested)

      assert.are.equal(root, found_first)
      assert.are.equal(root, found_second)

      vim.fn.delete(root, "rf")
    end)

    it("returns nil when git root does not exist", function()
      local root = vim.fn.tempname()
      local nested = vim.fs.joinpath(root, "nested", "dir")
      vim.fn.mkdir(nested, "p")

      local found = util.find_git_root(nested)
      assert.is_nil(found)

      vim.fn.delete(root, "rf")
    end)

    it("supports git worktree where .git is a file", function()
      local root = vim.fn.tempname()
      local project_root = vim.fs.joinpath(root, "project")
      local worktree_root = vim.fs.joinpath(root, "project-feature")
      local git_common_dir = vim.fs.joinpath(project_root, ".git")
      local git_worktree_dir = vim.fs.joinpath(git_common_dir, "worktrees", "feature")
      local nested = vim.fs.joinpath(worktree_root, "src")

      vim.fn.mkdir(git_common_dir, "p")
      vim.fn.mkdir(git_worktree_dir, "p")
      vim.fn.mkdir(nested, "p")
      vim.fn.writefile({ "gitdir: " .. git_worktree_dir }, vim.fs.joinpath(worktree_root, ".git"))

      local found = util.find_git_root(nested)
      assert.are.equal(worktree_root, found)

      vim.fn.delete(root, "rf")
    end)
  end)

  describe("get_snapshot_scope", function()
    it("returns project/workspace separated keys for regular git root", function()
      local root = vim.fn.tempname()
      local git_dir = vim.fs.joinpath(root, ".git")
      vim.fn.mkdir(git_dir, "p")

      local scope = util.get_snapshot_scope(root)
      assert.are.equal(vim.fs.basename(root), scope.project_name)
      assert.are.equal(vim.fs.basename(root), scope.workspace_name)
      assert.is_true(scope.relative_dir:find(scope.project_name .. "-", 1, true) == 1)
      assert.is_true(scope.relative_dir:find("/" .. scope.workspace_name .. "-", 1, true) ~= nil)

      vim.fn.delete(root, "rf")
    end)

    it("uses shared project id and separate workspace id for worktrees", function()
      local root = vim.fn.tempname()
      local project_root = vim.fs.joinpath(root, "project")
      local worktree_root = vim.fs.joinpath(root, "project-feature")
      local git_common_dir = vim.fs.joinpath(project_root, ".git")
      local git_worktree_dir = vim.fs.joinpath(git_common_dir, "worktrees", "feature")

      vim.fn.mkdir(git_common_dir, "p")
      vim.fn.mkdir(git_worktree_dir, "p")
      vim.fn.mkdir(worktree_root, "p")
      vim.fn.writefile({ "gitdir: " .. git_worktree_dir }, vim.fs.joinpath(worktree_root, ".git"))
      vim.fn.writefile({ "../.." }, vim.fs.joinpath(git_worktree_dir, "commondir"))

      local project_scope = util.get_snapshot_scope(project_root)
      local worktree_scope = util.get_snapshot_scope(worktree_root)

      assert.are.equal(project_scope.project_hash, worktree_scope.project_hash)
      assert.are_not.equal(project_scope.workspace_hash, worktree_scope.workspace_hash)
      assert.are.equal(vim.fs.basename(project_root), worktree_scope.project_name)
      assert.are.equal(vim.fs.basename(worktree_root), worktree_scope.workspace_name)

      vim.fn.delete(root, "rf")
    end)
  end)

  describe("shorten_path", function()
    it("returns path relative to git root", function()
      local root = vim.fn.tempname()
      local git_dir = vim.fs.joinpath(root, ".git")
      local file_path = vim.fs.joinpath(root, "src", "main.lua")
      vim.fn.mkdir(git_dir, "p")
      vim.fn.mkdir(vim.fs.dirname(file_path), "p")
      vim.fn.writefile({ "return 42" }, file_path)

      assert.are.equal("src/main.lua", util.shorten_path(file_path))

      vim.fn.delete(root, "rf")
    end)
  end)

  describe("uri/path conversion", function()
    it("detects file URI", function()
      assert.is_true(util.is_file_uri("file:///tmp/test.lua"))
      assert.is_false(util.is_file_uri("https://example.com"))
      assert.is_false(util.is_file_uri(nil))
    end)

    it("converts file URI to path safely", function()
      assert.are.equal("/tmp/test.lua", util.file_uri_to_fname("file:///tmp/test.lua"))
      assert.is_nil(util.file_uri_to_fname("jdt://workspace/Foo"))
      assert.is_nil(util.file_uri_to_fname(nil))
    end)

    it("converts path to file URI safely", function()
      local path = "/tmp/code-shape-util.lua"
      local uri = util.fname_to_file_uri(path)
      assert.is_not_nil(uri)
      assert.are.equal(path, util.file_uri_to_fname(uri))
    end)

    it("falls back to original URI for display path", function()
      assert.are.equal("/tmp/test.lua", util.uri_display_path("file:///tmp/test.lua"))
      assert.are.equal("jdt://workspace/Foo", util.uri_display_path("jdt://workspace/Foo"))
      assert.are.equal("", util.uri_display_path(nil))
    end)
  end)

  describe("to_symbol_kind", function()
    it("returns number for number input", function()
      assert.are.equal(12, util.to_symbol_kind(12))
    end)

    it("converts string kind to number", function()
      assert.are.equal(12, util.to_symbol_kind("Function"))
      assert.are.equal(5, util.to_symbol_kind("Class"))
      assert.are.equal(6, util.to_symbol_kind("Method"))
    end)

    it("returns 0 for unknown kind", function()
      assert.are.equal(0, util.to_symbol_kind("Unknown"))
    end)
  end)

  describe("symbol_kind_name", function()
    it("returns name for known kind", function()
      assert.are.equal("Function", util.symbol_kind_name(12))
      assert.are.equal("Class", util.symbol_kind_name(5))
      assert.are.equal("Method", util.symbol_kind_name(6))
    end)

    it("returns Unknown for unknown kind", function()
      assert.are.equal("Unknown", util.symbol_kind_name(999))
    end)
  end)

  describe("generate_symbol_id", function()
    it("matches Rust stable symbol id format", function()
      local range = {
        start = { line = 1, character = 2 },
        ["end"] = { line = 3, character = 4 },
      }

      local symbol_id = util.generate_symbol_id("file:///a.lua", "myFunc", 12, range)
      assert.are.equal("e6dcfd67ab45e643c39441bbbaab6b9ea91fc959a4f47de587f73219aed91ab2", symbol_id)
    end)

    it("changes when symbol identity changes", function()
      local range = {
        start = { line = 1, character = 2 },
        ["end"] = { line = 3, character = 4 },
      }

      local id_a = util.generate_symbol_id("file:///a.lua", "myFunc", 12, range)
      local id_b = util.generate_symbol_id("file:///a.lua", "myFunc2", 12, range)

      assert.are_not.equal(id_a, id_b)
    end)
  end)
end)
