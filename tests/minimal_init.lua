-- Minimal init.lua for testing with plenary.nvim
-- This file is used by `make test`

-- Set up runtimepath
local root = vim.fn.fnamemodify(vim.uv.cwd(), ":p")

-- Add plugin directory
vim.opt.runtimepath:append(root)

-- Add plenary if available
local plenary_path = os.getenv("PLENARY_PATH") or root .. "/deps/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 1 then
  vim.opt.runtimepath:append(plenary_path)
end

-- Basic settings for testing
vim.opt.swapfile = false
vim.opt.undofile = false
vim.opt.shadafile = "NONE"
vim.opt.hidden = true

-- Load code-shape module (for testing)
-- Note: Tests should mock RPC calls to Rust core
