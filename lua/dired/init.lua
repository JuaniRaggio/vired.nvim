---@mod dired Dired - A file manager for Neovim
---@brief [[
---dired.nvim is a file manager that replicates the dired + ivy/vertico
---experience from Emacs: file operations with interactive fuzzy completion
---for paths, where moving/renaming/copying files is as fluid as code
---autocompletion.
---@brief ]]

local M = {}

local config = require("dired.config")

---@type boolean
M._initialized = false

---Setup dired with user configuration
---@param opts? DiredConfig User configuration
function M.setup(opts)
  if M._initialized then
    return
  end

  config.setup(opts)

  -- Initialize highlights
  require("dired.highlights").setup()

  M._setup_commands()
  M._setup_autocommands()

  M._initialized = true
end

---Setup user commands
function M._setup_commands()
  vim.api.nvim_create_user_command("Dired", function(cmd_opts)
    local path = cmd_opts.args
    if path == "" then
      path = nil
    end
    M.open(path)
  end, {
    nargs = "?",
    complete = "dir",
    desc = "Open dired file manager",
  })
end

---Setup autocommands
function M._setup_autocommands()
  local group = vim.api.nvim_create_augroup("Dired", { clear = true })

  -- Handle directory buffers (like oil.nvim)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "*",
    callback = function(args)
      local bufname = vim.api.nvim_buf_get_name(args.buf)
      if bufname ~= "" and vim.fn.isdirectory(bufname) == 1 then
        -- Delete the directory buffer and open dired instead
        vim.schedule(function()
          local path = bufname
          vim.api.nvim_buf_delete(args.buf, { force = true })
          M.open(path)
        end)
      end
    end,
  })
end

---Open dired buffer for a directory
---@param path? string Directory path (defaults to cwd)
function M.open(path)
  local utils = require("dired.utils")

  path = path or vim.loop.cwd()
  path = utils.absolute(path)

  if not utils.is_dir(path) then
    vim.notify("dired: not a directory: " .. path, vim.log.levels.ERROR)
    return
  end

  -- Create buffer and show it
  local bufnr = buffer.create(path)
  vim.api.nvim_set_current_buf(bufnr)

  -- Position cursor on first entry
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
end

---Open path picker for selecting a destination
---@param opts? table Options for path picker
---@field prompt? string Prompt text
---@field default? string Default path
---@field on_select? function Callback when path is selected
---@field create_if_missing? boolean Offer to create non-existent paths
function M.pick_path(opts)
  -- TODO: Implement in Phase 2
  vim.notify("dired: path picker not implemented yet", vim.log.levels.INFO)
end

---Move file(s) to destination
---@param source string|string[] Source path(s)
---@param dest string Destination path
function M.move(source, dest)
  -- TODO: Implement in Phase 3
  vim.notify("dired: move not implemented yet", vim.log.levels.INFO)
end

---Copy file(s) to destination
---@param source string|string[] Source path(s)
---@param dest string Destination path
function M.copy(source, dest)
  -- TODO: Implement in Phase 3
  vim.notify("dired: copy not implemented yet", vim.log.levels.INFO)
end

---Delete file(s)
---@param path string|string[] Path(s) to delete
function M.delete(path)
  -- TODO: Implement in Phase 3
  vim.notify("dired: delete not implemented yet", vim.log.levels.INFO)
end

---Create directory
---@param path string Directory path to create
function M.mkdir(path)
  -- TODO: Implement in Phase 3
  vim.notify("dired: mkdir not implemented yet", vim.log.levels.INFO)
end

---Mark a file
---@param path string Path to mark
function M.mark(path)
  -- TODO: Implement in Phase 3
  vim.notify("dired: mark not implemented yet", vim.log.levels.INFO)
end

---Unmark a file
---@param path string Path to unmark
function M.unmark(path)
  -- TODO: Implement in Phase 3
  vim.notify("dired: unmark not implemented yet", vim.log.levels.INFO)
end

---Get all marked files
---@return string[] List of marked paths
function M.get_marked()
  -- TODO: Implement in Phase 3
  return {}
end

---Clear all marks
function M.clear_marks()
  -- TODO: Implement in Phase 3
  vim.notify("dired: clear_marks not implemented yet", vim.log.levels.INFO)
end

return M
