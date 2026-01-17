---@mod vired Vired - A file manager for Neovim
---@brief [[
---vired.nvim is a file manager that replicates the Emacs dired + ivy/vertico
---experience: file operations with interactive fuzzy completion for paths,
---where moving/renaming/copying files is as fluid as code autocompletion.
---@brief ]]

local M = {}

local config = require("vired.config")

---@type boolean
M._initialized = false

---Setup vired with user configuration
---@param opts? ViredConfig User configuration
function M.setup(opts)
  if M._initialized then
    return
  end

  config.setup(opts)

  -- Initialize highlights
  require("vired.highlights").setup()

  -- Initialize projects
  require("vired.projects").setup()

  -- Initialize undo system
  require("vired.undo").setup()

  M._setup_commands()
  M._setup_autocommands()

  M._initialized = true
end

---Setup user commands
function M._setup_commands()
  vim.api.nvim_create_user_command("Vired", function(cmd_opts)
    local path = cmd_opts.args
    if path == "" then
      -- No argument: check config for default behavior
      local cfg = config.get()
      if cfg.use_picker_by_default then
        M.pick_and_open()
      else
        M.open(nil)
      end
    else
      M.open(path)
    end
  end, {
    nargs = "?",
    complete = "dir",
    desc = "Open vired file manager",
  })

  vim.api.nvim_create_user_command("ViredOpen", function()
    M.pick_and_open()
  end, {
    desc = "Open vired with interactive directory picker",
  })
end

---Setup autocommands
function M._setup_autocommands()
  local group = vim.api.nvim_create_augroup("Vired", { clear = true })

  -- Handle directory buffers (like oil.nvim)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "*",
    callback = function(args)
      local bufname = vim.api.nvim_buf_get_name(args.buf)
      if bufname ~= "" and vim.fn.isdirectory(bufname) == 1 then
        -- Delete the directory buffer and open vired instead
        vim.schedule(function()
          local path = bufname
          vim.api.nvim_buf_delete(args.buf, { force = true })
          M.open(path)
        end)
      end
    end,
  })
end

---Open vired buffer for a directory
---@param path? string Directory path (defaults to cwd)
function M.open(path)
  local utils = require("vired.utils")
  local buffer = require("vired.buffer")
  local projects = require("vired.projects")

  path = path or vim.loop.cwd()
  path = utils.absolute(path)

  if not utils.is_dir(path) then
    vim.notify("vired: not a directory: " .. path, vim.log.levels.ERROR)
    return
  end

  -- Ensure we're in normal mode (important when coming from picker)
  vim.cmd("stopinsert")

  -- Create buffer and show it
  local bufnr = buffer.create(path)
  vim.api.nvim_set_current_buf(bufnr)

  -- Position cursor on first entry
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  -- Check if this is a new project and prompt to add
  projects.check_and_prompt(path)
end

---Open path picker for selecting a destination
---@param opts? table Options for path picker
---@field prompt? string Prompt text
---@field default? string Default path
---@field on_select? function Callback when path is selected
---@field create_if_missing? boolean Offer to create non-existent paths
function M.pick_path(opts)
  local picker = require("vired.picker")
  opts = opts or {}
  opts.cwd = opts.cwd or vim.loop.cwd()
  opts.on_select = opts.on_select or function() end
  picker.open(opts)
end

---Open interactive directory picker, then open vired in selected directory
---This provides a Vertico-like experience for directory navigation
function M.pick_and_open()
  local picker = require("vired.picker")
  local cwd = vim.loop.cwd()

  picker.open({
    prompt = "Open directory: ",
    default = cwd .. "/",
    cwd = cwd,
    create_if_missing = true,
    on_select = function(path)
      -- Backends open vired for directories directly
      -- but if somehow we get here with a file, open its parent
      local fs = require("vired.fs")
      if fs.is_file(path) then
        local utils = require("vired.utils")
        path = utils.parent(path)
      end
      if path then
        M.open(path)
      end
    end,
  })
end

---Move file(s) to destination
---@param source string|string[] Source path(s)
---@param dest string Destination path
function M.move(source, dest)
  local fs = require("vired.fs")
  local sources = type(source) == "table" and source or { source }

  for _, src in ipairs(sources) do
    local ok, err = fs.rename(src, dest)
    if not ok then
      vim.notify("vired: " .. err, vim.log.levels.ERROR)
      return false
    end
  end
  return true
end

---Copy file(s) to destination
---@param source string|string[] Source path(s)
---@param dest string Destination path
function M.copy(source, dest)
  local fs = require("vired.fs")
  local sources = type(source) == "table" and source or { source }

  for _, src in ipairs(sources) do
    local ok, err = fs.copy(src, dest)
    if not ok then
      vim.notify("vired: " .. err, vim.log.levels.ERROR)
      return false
    end
  end
  return true
end

---Delete file(s)
---@param path string|string[] Path(s) to delete
function M.delete(path)
  local fs = require("vired.fs")
  local paths = type(path) == "table" and path or { path }

  for _, p in ipairs(paths) do
    local ok, err
    if fs.is_dir(p) then
      ok, err = fs.delete_recursive(p)
    else
      ok, err = fs.delete(p)
    end
    if not ok then
      vim.notify("vired: " .. err, vim.log.levels.ERROR)
      return false
    end
  end
  return true
end

---Create directory
---@param path string Directory path to create
function M.mkdir(path)
  local fs = require("vired.fs")
  local ok, err = fs.mkdir(path)
  if not ok then
    vim.notify("vired: " .. err, vim.log.levels.ERROR)
    return false
  end
  return true
end

---Mark a file in the current vired buffer
---@param path string Path to mark
function M.mark(path)
  local buffer = require("vired.buffer")
  local bufnr = vim.api.nvim_get_current_buf()
  local buf_data = buffer.buffers[bufnr]

  if buf_data then
    buf_data.marks[path] = true
    buffer.render(bufnr)
  end
end

---Unmark a file in the current vired buffer
---@param path string Path to unmark
function M.unmark(path)
  local buffer = require("vired.buffer")
  local bufnr = vim.api.nvim_get_current_buf()
  local buf_data = buffer.buffers[bufnr]

  if buf_data then
    buf_data.marks[path] = nil
    buffer.render(bufnr)
  end
end

---Get all marked files in the current vired buffer
---@return string[] List of marked paths
function M.get_marked()
  local buffer = require("vired.buffer")
  local bufnr = vim.api.nvim_get_current_buf()
  local buf_data = buffer.buffers[bufnr]

  if not buf_data then
    return {}
  end

  local marked = {}
  for path, _ in pairs(buf_data.marks) do
    table.insert(marked, path)
  end
  return marked
end

---Clear all marks in the current vired buffer
function M.clear_marks()
  local buffer = require("vired.buffer")
  local bufnr = vim.api.nvim_get_current_buf()
  buffer.unmark_all(bufnr)
end

return M
