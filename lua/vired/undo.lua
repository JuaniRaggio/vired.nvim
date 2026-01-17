---Undo/Redo system for file operations
---Tracks all file operations and allows reversing them

local M = {}

local utils = require("vired.utils")
local fs = require("vired.fs")
local config = require("vired.config")

-- ============================================================================
-- Types
-- ============================================================================

---@alias UndoOperationType "rename"|"delete"|"copy"|"mkdir"|"touch"

---@class UndoOperation
---@field type UndoOperationType
---@field timestamp number
---@field data table Operation-specific data

---@class UndoRenameData
---@field old_path string
---@field new_path string

---@class UndoDeleteData
---@field path string Original path
---@field trash_path string Path in trash
---@field was_dir boolean Whether it was a directory

---@class UndoCopyData
---@field source string Source path (still exists)
---@field dest string Destination path (created by copy)

---@class UndoMkdirData
---@field path string Created directory path

---@class UndoTouchData
---@field path string Created file path

-- ============================================================================
-- State
-- ============================================================================

---@type UndoOperation[]
local undo_stack = {}

---@type UndoOperation[]
local redo_stack = {}

---@type number Maximum operations to keep in history
local MAX_HISTORY = 100

---@type string|nil Trash directory path
local trash_dir = nil

-- ============================================================================
-- Trash Management
-- ============================================================================

---Get or create the trash directory
---@return string
local function get_trash_dir()
  if trash_dir and fs.exists(trash_dir) then
    return trash_dir
  end

  -- Use XDG trash or fallback to data directory
  local xdg_data = vim.env.XDG_DATA_HOME or (vim.env.HOME .. "/.local/share")
  trash_dir = utils.join(xdg_data, "vired-trash")

  if not fs.exists(trash_dir) then
    fs.mkdir(trash_dir)
  end

  return trash_dir
end

---Generate a unique trash path for a file
---@param original_path string
---@return string
local function get_trash_path(original_path)
  local trash = get_trash_dir()
  local basename = utils.basename(original_path)
  local timestamp = os.time()

  -- Create a unique name: basename.timestamp.random
  local unique_name = string.format("%s.%d.%d", basename, timestamp, math.random(10000, 99999))
  return utils.join(trash, unique_name)
end

---Move file/directory to trash
---@param path string
---@return boolean success
---@return string|nil trash_path
---@return string|nil error
local function move_to_trash(path)
  if not fs.exists(path) then
    return false, nil, "Path does not exist: " .. path
  end

  local trash_path = get_trash_path(path)
  local ok, err = fs.rename(path, trash_path)

  if ok then
    return true, trash_path, nil
  else
    return false, nil, err
  end
end

---Restore file/directory from trash
---@param trash_path string
---@param original_path string
---@return boolean success
---@return string|nil error
local function restore_from_trash(trash_path, original_path)
  if not fs.exists(trash_path) then
    return false, "Trash file no longer exists: " .. trash_path
  end

  -- Ensure parent directory exists
  local parent = utils.parent(original_path)
  if parent and not fs.exists(parent) then
    fs.mkdir(parent)
  end

  -- Check if original path is now occupied
  if fs.exists(original_path) then
    return false, "Cannot restore: path already exists: " .. original_path
  end

  return fs.rename(trash_path, original_path)
end

-- ============================================================================
-- Operation Recording
-- ============================================================================

---Push an operation onto the undo stack
---@param op UndoOperation
local function push_undo(op)
  table.insert(undo_stack, op)

  -- Trim history if too large
  while #undo_stack > MAX_HISTORY do
    table.remove(undo_stack, 1)
  end

  -- Clear redo stack when new operation is recorded
  redo_stack = {}
end

---Record a rename operation
---@param old_path string
---@param new_path string
function M.record_rename(old_path, new_path)
  push_undo({
    type = "rename",
    timestamp = os.time(),
    data = {
      old_path = old_path,
      new_path = new_path,
    },
  })
end

---Record a delete operation (moves to trash)
---@param path string
---@param trash_path string
---@param was_dir boolean
function M.record_delete(path, trash_path, was_dir)
  push_undo({
    type = "delete",
    timestamp = os.time(),
    data = {
      path = path,
      trash_path = trash_path,
      was_dir = was_dir,
    },
  })
end

---Record a copy operation
---@param source string
---@param dest string
function M.record_copy(source, dest)
  push_undo({
    type = "copy",
    timestamp = os.time(),
    data = {
      source = source,
      dest = dest,
    },
  })
end

---Record a mkdir operation
---@param path string
function M.record_mkdir(path)
  push_undo({
    type = "mkdir",
    timestamp = os.time(),
    data = {
      path = path,
    },
  })
end

---Record a touch (create file) operation
---@param path string
function M.record_touch(path)
  push_undo({
    type = "touch",
    timestamp = os.time(),
    data = {
      path = path,
    },
  })
end

-- ============================================================================
-- Undo/Redo Execution
-- ============================================================================

---Undo a rename operation
---@param data UndoRenameData
---@return boolean success
---@return string|nil error
local function undo_rename(data)
  -- Rename back: new_path -> old_path
  if not fs.exists(data.new_path) then
    return false, "Cannot undo rename: file no longer at " .. data.new_path
  end

  return fs.rename(data.new_path, data.old_path)
end

---Redo a rename operation
---@param data UndoRenameData
---@return boolean success
---@return string|nil error
local function redo_rename(data)
  if not fs.exists(data.old_path) then
    return false, "Cannot redo rename: file no longer at " .. data.old_path
  end

  return fs.rename(data.old_path, data.new_path)
end

---Undo a delete operation (restore from trash)
---@param data UndoDeleteData
---@return boolean success
---@return string|nil error
local function undo_delete(data)
  return restore_from_trash(data.trash_path, data.path)
end

---Redo a delete operation (move back to trash)
---@param data UndoDeleteData
---@return boolean success
---@return string|nil error
local function redo_delete(data)
  if not fs.exists(data.path) then
    return false, "Cannot redo delete: file no longer exists"
  end

  local ok, new_trash_path, err = move_to_trash(data.path)
  if ok then
    -- Update the trash path for future undos
    data.trash_path = new_trash_path
  end
  return ok, err
end

---Undo a copy operation (delete the copy)
---@param data UndoCopyData
---@return boolean success
---@return string|nil error
local function undo_copy(data)
  if not fs.exists(data.dest) then
    return false, "Cannot undo copy: destination no longer exists"
  end

  -- Delete the copy (move to trash for safety)
  local ok, trash_path, err = move_to_trash(data.dest)
  if ok then
    -- Store trash path in case we need to redo
    data._trash_path = trash_path
  end
  return ok, err
end

---Redo a copy operation
---@param data UndoCopyData
---@return boolean success
---@return string|nil error
local function redo_copy(data)
  if not fs.exists(data.source) then
    return false, "Cannot redo copy: source no longer exists"
  end

  -- If we have a trashed copy, restore it instead of re-copying
  if data._trash_path and fs.exists(data._trash_path) then
    return restore_from_trash(data._trash_path, data.dest)
  end

  -- Otherwise, copy again
  return fs.copy(data.source, data.dest)
end

---Undo a mkdir operation (delete the directory)
---@param data UndoMkdirData
---@return boolean success
---@return string|nil error
local function undo_mkdir(data)
  if not fs.exists(data.path) then
    return true, nil -- Already gone
  end

  -- Check if directory is empty
  local entries = fs.readdir(data.path, true)
  if entries and #entries > 0 then
    return false, "Cannot undo mkdir: directory is not empty"
  end

  return fs.delete(data.path)
end

---Redo a mkdir operation
---@param data UndoMkdirData
---@return boolean success
---@return string|nil error
local function redo_mkdir(data)
  if fs.exists(data.path) then
    return true, nil -- Already exists
  end

  return fs.mkdir(data.path)
end

---Undo a touch operation (delete the file)
---@param data UndoTouchData
---@return boolean success
---@return string|nil error
local function undo_touch(data)
  if not fs.exists(data.path) then
    return true, nil -- Already gone
  end

  -- Check if file was modified (non-empty)
  local stat = vim.loop.fs_stat(data.path)
  if stat and stat.size > 0 then
    -- Move to trash instead of deleting
    local ok, trash_path, err = move_to_trash(data.path)
    if ok then
      data._trash_path = trash_path
    end
    return ok, err
  end

  return fs.delete(data.path)
end

---Redo a touch operation
---@param data UndoTouchData
---@return boolean success
---@return string|nil error
local function redo_touch(data)
  if fs.exists(data.path) then
    return true, nil -- Already exists
  end

  -- If we have a trashed file, restore it
  if data._trash_path and fs.exists(data._trash_path) then
    return restore_from_trash(data._trash_path, data.path)
  end

  return fs.touch(data.path)
end

-- ============================================================================
-- Public API
-- ============================================================================

---Check if undo is available
---@return boolean
function M.can_undo()
  return #undo_stack > 0
end

---Check if redo is available
---@return boolean
function M.can_redo()
  return #redo_stack > 0
end

---Get description of the operation that would be undone
---@return string|nil
function M.peek_undo()
  if #undo_stack == 0 then
    return nil
  end

  local op = undo_stack[#undo_stack]
  return M.describe_operation(op)
end

---Get description of the operation that would be redone
---@return string|nil
function M.peek_redo()
  if #redo_stack == 0 then
    return nil
  end

  local op = redo_stack[#redo_stack]
  return M.describe_operation(op)
end

---Describe an operation for display
---@param op UndoOperation
---@return string
function M.describe_operation(op)
  if op.type == "rename" then
    return string.format("Rename: %s -> %s",
      utils.basename(op.data.old_path),
      utils.basename(op.data.new_path))
  elseif op.type == "delete" then
    return string.format("Delete: %s", utils.basename(op.data.path))
  elseif op.type == "copy" then
    return string.format("Copy: %s -> %s",
      utils.basename(op.data.source),
      utils.basename(op.data.dest))
  elseif op.type == "mkdir" then
    return string.format("Create directory: %s", utils.basename(op.data.path))
  elseif op.type == "touch" then
    return string.format("Create file: %s", utils.basename(op.data.path))
  else
    return "Unknown operation"
  end
end

---Undo the last operation
---@return boolean success
---@return string|nil error
function M.undo()
  if #undo_stack == 0 then
    return false, "Nothing to undo"
  end

  local op = table.remove(undo_stack)
  local ok, err

  if op.type == "rename" then
    ok, err = undo_rename(op.data)
  elseif op.type == "delete" then
    ok, err = undo_delete(op.data)
  elseif op.type == "copy" then
    ok, err = undo_copy(op.data)
  elseif op.type == "mkdir" then
    ok, err = undo_mkdir(op.data)
  elseif op.type == "touch" then
    ok, err = undo_touch(op.data)
  else
    return false, "Unknown operation type: " .. tostring(op.type)
  end

  if ok then
    -- Push to redo stack
    table.insert(redo_stack, op)
    return true, nil
  else
    -- Put back on undo stack since it failed
    table.insert(undo_stack, op)
    return false, err
  end
end

---Redo the last undone operation
---@return boolean success
---@return string|nil error
function M.redo()
  if #redo_stack == 0 then
    return false, "Nothing to redo"
  end

  local op = table.remove(redo_stack)
  local ok, err

  if op.type == "rename" then
    ok, err = redo_rename(op.data)
  elseif op.type == "delete" then
    ok, err = redo_delete(op.data)
  elseif op.type == "copy" then
    ok, err = redo_copy(op.data)
  elseif op.type == "mkdir" then
    ok, err = redo_mkdir(op.data)
  elseif op.type == "touch" then
    ok, err = redo_touch(op.data)
  else
    return false, "Unknown operation type: " .. tostring(op.type)
  end

  if ok then
    -- Push back to undo stack
    table.insert(undo_stack, op)
    return true, nil
  else
    -- Put back on redo stack since it failed
    table.insert(redo_stack, op)
    return false, err
  end
end

---Get undo history for display
---@param limit? number Maximum items to return (default 10)
---@return table[] List of {description, timestamp}
function M.get_history(limit)
  limit = limit or 10
  local history = {}

  for i = #undo_stack, math.max(1, #undo_stack - limit + 1), -1 do
    local op = undo_stack[i]
    table.insert(history, {
      description = M.describe_operation(op),
      timestamp = op.timestamp,
      index = i,
    })
  end

  return history
end

---Clear undo/redo history
function M.clear_history()
  undo_stack = {}
  redo_stack = {}
end

---Get undo stack size
---@return number
function M.get_undo_count()
  return #undo_stack
end

---Get redo stack size
---@return number
function M.get_redo_count()
  return #redo_stack
end

-- ============================================================================
-- Wrapped Operations (for external use)
-- ============================================================================

---Delete with undo support (moves to trash)
---@param path string
---@return boolean success
---@return string|nil error
function M.delete_with_undo(path)
  local was_dir = fs.is_dir(path)
  local ok, trash_path, err = move_to_trash(path)

  if ok then
    M.record_delete(path, trash_path, was_dir)
    return true, nil
  else
    return false, err
  end
end

---Rename with undo support
---@param old_path string
---@param new_path string
---@return boolean success
---@return string|nil error
function M.rename_with_undo(old_path, new_path)
  local ok, err = fs.rename(old_path, new_path)

  if ok then
    M.record_rename(old_path, new_path)
    return true, nil
  else
    return false, err
  end
end

---Copy with undo support
---@param source string
---@param dest string
---@return boolean success
---@return string|nil error
function M.copy_with_undo(source, dest)
  local ok, err = fs.copy(source, dest)

  if ok then
    M.record_copy(source, dest)
    return true, nil
  else
    return false, err
  end
end

---Mkdir with undo support
---@param path string
---@return boolean success
---@return string|nil error
function M.mkdir_with_undo(path)
  local ok, err = fs.mkdir(path)

  if ok then
    M.record_mkdir(path)
    return true, nil
  else
    return false, err
  end
end

---Touch with undo support
---@param path string
---@return boolean success
---@return string|nil error
function M.touch_with_undo(path)
  local ok, err = fs.touch(path)

  if ok then
    M.record_touch(path)
    return true, nil
  else
    return false, err
  end
end

-- ============================================================================
-- Commands
-- ============================================================================

---Setup undo commands
function M.setup()
  vim.api.nvim_create_user_command("ViredUndo", function()
    if not M.can_undo() then
      vim.notify("vired: Nothing to undo", vim.log.levels.INFO)
      return
    end

    local desc = M.peek_undo()
    local ok, err = M.undo()

    if ok then
      vim.notify("vired: Undone: " .. desc, vim.log.levels.INFO)
      -- Refresh any open vired buffers
      M._refresh_vired_buffers()
    else
      vim.notify("vired: Undo failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
    end
  end, { desc = "Undo last vired file operation" })

  vim.api.nvim_create_user_command("ViredRedo", function()
    if not M.can_redo() then
      vim.notify("vired: Nothing to redo", vim.log.levels.INFO)
      return
    end

    local desc = M.peek_redo()
    local ok, err = M.redo()

    if ok then
      vim.notify("vired: Redone: " .. desc, vim.log.levels.INFO)
      M._refresh_vired_buffers()
    else
      vim.notify("vired: Redo failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
    end
  end, { desc = "Redo last undone vired operation" })

  vim.api.nvim_create_user_command("ViredUndoHistory", function()
    local history = M.get_history(20)

    if #history == 0 then
      vim.notify("vired: No undo history", vim.log.levels.INFO)
      return
    end

    local lines = { "Undo History (most recent first):", "" }
    for i, item in ipairs(history) do
      local time = os.date("%H:%M:%S", item.timestamp)
      table.insert(lines, string.format("%d. [%s] %s", i, time, item.description))
    end

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "Show vired undo history" })
end

---Refresh any open vired buffers
function M._refresh_vired_buffers()
  local buffer = require("vired.buffer")
  for bufnr, _ in pairs(buffer.buffers or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      buffer.render(bufnr)
    end
  end
end

-- ============================================================================
-- Testing helpers
-- ============================================================================

---Clear all state (for testing)
function M._clear()
  undo_stack = {}
  redo_stack = {}
end

---Set custom trash directory (for testing)
---@param path string
function M._set_trash_dir(path)
  trash_dir = path
end

---Get current trash directory
---@return string
function M._get_trash_dir()
  return get_trash_dir()
end

return M
