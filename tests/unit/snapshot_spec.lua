local snapshot = require("code-shape.snapshot")

describe("snapshot", function()
  local function make_config(overrides)
    local cfg = {
      snapshot = {
        enabled = true,
        load_on_start = true,
        save_on_exit = true,
        remote_cache = {
          enabled = false,
          dir = nil,
          load_on_start = true,
          save_on_exit = true,
        },
      },
      debug = false,
    }
    return vim.tbl_deep_extend("force", cfg, overrides or {})
  end

  it("load skips RPC when disabled", function()
    local called = false
    local rpc = {
      request = function()
        called = true
        error("should not be called")
      end,
    }
    local config = make_config({
      snapshot = {
        enabled = false,
      },
    })
    local callback_called = false

    snapshot.load(rpc, config, function(success, err)
      callback_called = true
      assert.is_false(success)
      assert.is_nil(err)
    end)

    assert.is_false(called)
    assert.is_true(callback_called)
  end)

  describe("get_path_for_root", function()
    it("returns deterministic path for a git root", function()
      local path1 = snapshot.get_path_for_root("/home/user/repo_a")
      local path2 = snapshot.get_path_for_root("/home/user/repo_a")
      assert.are.equal(path1, path2)
    end)

    it("returns different paths for different roots", function()
      local path_a = snapshot.get_path_for_root("/home/user/repo_a")
      local path_b = snapshot.get_path_for_root("/home/user/repo_b")
      assert.are_not.equal(path_a, path_b)
    end)

    it("includes basename in path for readability", function()
      local path = snapshot.get_path_for_root("/home/user/my-project")
      assert.is_true(path:find("my%-project") ~= nil)
    end)

    it("separates project and workspace directories", function()
      local path = snapshot.get_path_for_root("/home/user/repo")
      assert.is_true(path:find("code%-shape/.+/.-/index%.bin$") ~= nil)
    end)

    it("ends with index.bin", function()
      local path = snapshot.get_path_for_root("/home/user/repo")
      assert.is_true(path:find("index%.bin$") ~= nil)
    end)

    it("keeps shared project key and separate workspace key for worktree", function()
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

      local project_path = snapshot.get_path_for_root(project_root)
      local worktree_path = snapshot.get_path_for_root(worktree_root)
      local project_dir = project_path:match("code%-shape/(.-)/")
      local worktree_dir = worktree_path:match("code%-shape/(.-)/")
      local project_workspace_dir = project_path:match("code%-shape/.-/(.-)/index%.bin$")
      local worktree_workspace_dir = worktree_path:match("code%-shape/.-/(.-)/index%.bin$")

      assert.are.equal(project_dir, worktree_dir)
      assert.are_not.equal(project_workspace_dir, worktree_workspace_dir)

      vim.fn.delete(root, "rf")
    end)
  end)

  describe("get_remote_path_for_root", function()
    it("returns nil when remote cache is disabled", function()
      local config = make_config()
      assert.is_nil(snapshot.get_remote_path_for_root(config, "/repo"))
    end)

    it("uses configured remote cache directory", function()
      local config = make_config({
        snapshot = {
          remote_cache = {
            enabled = true,
            dir = "/remote/cache",
          },
        },
      })
      local path = snapshot.get_remote_path_for_root(config, "/repo")
      assert.is_true(path:find("^/remote/cache/", 1, false) ~= nil)
      assert.is_true(path:find("index%.bin$") ~= nil)
    end)
  end)

  describe("multi-root save/load", function()
    ---@param roots string[]
    ---@param fn fun()
    local function with_registered_roots(roots, fn)
      local roots_mod = require("code-shape.roots")
      local util = require("code-shape.util")
      roots_mod.clear()
      local original_find = util.find_git_root
      local idx = 1
      util.find_git_root = function()
        local current = roots[idx] or roots[#roots]
        idx = math.min(idx + 1, #roots)
        return current
      end

      for _, root in ipairs(roots) do
        roots_mod.register_uri(vim.uri_from_fname(vim.fs.joinpath(root, "main.lua")))
      end
      util.find_git_root = original_find

      fn()
      roots_mod.clear()
    end

    it("saves per-root snapshots", function()
      with_registered_roots({ "/repo_a", "/repo_b" }, function()
        local called_methods = {}
        local rpc = {
          request = function(method, _, cb)
            table.insert(called_methods, method)
            cb(nil, { success = true })
          end,
        }
        local callback_called = false

        snapshot.save(rpc, make_config(), function(success)
          callback_called = true
          assert.is_true(success)
        end)

        assert.is_true(callback_called)
        local save_count = 0
        for _, method in ipairs(called_methods) do
          if method == "index/saveSnapshotForRoot" then
            save_count = save_count + 1
          end
        end
        assert.are.equal(2, save_count)
      end)
    end)

    it("pulls remote snapshot before load", function()
      local temp_dir = vim.fn.tempname()
      local root_path = "/repo_remote_load"
      local original_stdpath = vim.fn.stdpath
      vim.fn.stdpath = function(kind)
        if kind == "cache" then
          return vim.fs.joinpath(temp_dir, "local-cache")
        end
        return original_stdpath(kind)
      end

      local config = make_config({
        snapshot = {
          remote_cache = {
            enabled = true,
            dir = temp_dir,
            load_on_start = true,
            save_on_exit = false,
          },
        },
      })

      local local_path = snapshot.get_path_for_root(root_path)
      local remote_path = snapshot.get_remote_path_for_root(config, root_path)
      vim.fn.mkdir(vim.fs.dirname(remote_path), "p")
      vim.fn.writefile({ "from-remote" }, remote_path)

      with_registered_roots({ root_path }, function()
        local loaded = false
        local rpc = {
          request = function(method, params, cb)
            if method == "index/snapshotExists" then
              assert.are.equal(local_path, params.path)
              cb(nil, { exists = true })
              return
            end
            if method == "index/loadSnapshotForRoot" then
              loaded = true
              cb(nil, { success = true, symbol_count = 1, uri_count = 1 })
              return
            end
            error("unexpected method: " .. method)
          end,
        }

        local callback_called = false
        snapshot.load(rpc, config, function(success, err)
          callback_called = true
          assert.is_true(success)
          assert.is_nil(err)
        end)

        assert.is_true(callback_called)
        assert.is_true(loaded)
        assert.is_true(vim.fn.filereadable(local_path) == 1)
      end)

      vim.fn.stdpath = original_stdpath
      vim.fn.delete(temp_dir, "rf")
    end)

    it("pushes local snapshot to remote cache after save", function()
      local temp_dir = vim.fn.tempname()
      local root_path = "/repo_remote_save"
      local original_stdpath = vim.fn.stdpath
      vim.fn.stdpath = function(kind)
        if kind == "cache" then
          return vim.fs.joinpath(temp_dir, "local-cache")
        end
        return original_stdpath(kind)
      end

      local config = make_config({
        snapshot = {
          remote_cache = {
            enabled = true,
            dir = temp_dir,
            load_on_start = false,
            save_on_exit = true,
          },
        },
      })

      local local_path = snapshot.get_path_for_root(root_path)
      local remote_path = snapshot.get_remote_path_for_root(config, root_path)

      with_registered_roots({ root_path }, function()
        local rpc = {
          request = function(method, params, cb)
            if method == "index/saveSnapshotForRoot" then
              vim.fn.mkdir(vim.fs.dirname(params.path), "p")
              vim.fn.writefile({ "local-snapshot" }, params.path)
              cb(nil, { success = true })
              return
            end
            error("unexpected method: " .. method)
          end,
        }

        local callback_called = false
        snapshot.save(rpc, config, function(success, err)
          callback_called = true
          assert.is_true(success)
          assert.is_nil(err)
        end)

        assert.is_true(callback_called)
        assert.is_true(vim.fn.filereadable(local_path) == 1)
        assert.is_true(vim.fn.filereadable(remote_path) == 1)
      end)

      vim.fn.stdpath = original_stdpath
      vim.fn.delete(temp_dir, "rf")
    end)

    it("returns error when remote cache parent directory cannot be created", function()
      local temp_dir = vim.fn.tempname()
      local blocker_path = vim.fs.joinpath(temp_dir, "remote-blocker")
      local root_path = "/repo_remote_save_error"
      local original_stdpath = vim.fn.stdpath
      vim.fn.stdpath = function(kind)
        if kind == "cache" then
          return vim.fs.joinpath(temp_dir, "local-cache")
        end
        return original_stdpath(kind)
      end

      vim.fn.mkdir(temp_dir, "p")
      vim.fn.writefile({ "blocking-file" }, blocker_path)

      local config = make_config({
        snapshot = {
          remote_cache = {
            enabled = true,
            dir = blocker_path,
            load_on_start = false,
            save_on_exit = true,
          },
        },
      })

      with_registered_roots({ root_path }, function()
        local rpc = {
          request = function(method, params, cb)
            if method == "index/saveSnapshotForRoot" then
              vim.fn.mkdir(vim.fs.dirname(params.path), "p")
              vim.fn.writefile({ "local-snapshot" }, params.path)
              cb(nil, { success = true })
              return
            end
            error("unexpected method: " .. method)
          end,
        }

        local callback_called = false
        snapshot.save(rpc, config, function(success, err)
          callback_called = true
          assert.is_true(success)
          assert.is_not_nil(err)
          assert.is_true(err:find("failed to push remote snapshot", 1, true) ~= nil)
          assert.is_true(err:find("failed to create directory", 1, true) ~= nil)
        end)

        assert.is_true(callback_called)
      end)

      vim.fn.stdpath = original_stdpath
      vim.fn.delete(temp_dir, "rf")
    end)
  end)
end)
