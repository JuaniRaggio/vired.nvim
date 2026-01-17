---@class ViredWatcher
---@field handle userdata|nil uv_fs_event_t handle
---@field path string Directory being watched
---@field timer userdata|nil Debounce timer
---@field pending_refresh boolean Has pending refresh after debounce

local M = {}

local config = require("vired.config")

---@type table<number, ViredWatcher>
local watchers = {}

---Check if watcher is enabled in config
---@return boolean
local function is_enabled()
  local cfg = config.get()
  return cfg.watcher and cfg.watcher.enabled
end

---Get debounce time from config
---@return number
local function get_debounce_ms()
  local cfg = config.get()
  return (cfg.watcher and cfg.watcher.debounce_ms) or 200
end

---Check if buffer is currently visible in any window
---@param bufnr number
---@return boolean
local function is_buffer_visible(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return true
    end
  end
  return false
end

---Start watching a directory for changes
---@param bufnr number Buffer number to associate with watcher
---@param path string Directory path to watch
function M.start(bufnr, path)
  if not is_enabled() then
    return
  end

  -- Stop existing watcher if any
  M.stop(bufnr)

  local handle = vim.loop.new_fs_event()
  if not handle then
    return
  end

  local watcher = {
    handle = handle,
    path = path,
    timer = nil,
    pending_refresh = false,
  }

  watchers[bufnr] = watcher

  -- Start watching
  local ok, err = handle:start(path, {}, function(err_watch, filename, events)
    if err_watch then
      return
    end

    -- Skip if buffer no longer valid
    if not vim.api.nvim_buf_is_valid(bufnr) then
      M.stop(bufnr)
      return
    end

    local w = watchers[bufnr]
    if not w then
      return
    end

    -- Debounce: cancel existing timer and start new one
    if w.timer then
      w.timer:stop()
      w.timer:close()
      w.timer = nil
    end

    w.pending_refresh = true

    w.timer = vim.loop.new_timer()
    if w.timer then
      w.timer:start(get_debounce_ms(), 0, function()
        vim.schedule(function()
          M._do_refresh(bufnr)
        end)
      end)
    end
  end)

  if not ok then
    M.stop(bufnr)
  end
end

---Stop watching for a buffer
---@param bufnr number
function M.stop(bufnr)
  local watcher = watchers[bufnr]
  if not watcher then
    return
  end

  -- Stop and close timer
  if watcher.timer then
    if not watcher.timer:is_closing() then
      watcher.timer:stop()
      watcher.timer:close()
    end
    watcher.timer = nil
  end

  -- Stop and close handle
  if watcher.handle then
    if not watcher.handle:is_closing() then
      watcher.handle:stop()
      watcher.handle:close()
    end
    watcher.handle = nil
  end

  watchers[bufnr] = nil
end

---Update watcher path when navigating to a new directory
---@param bufnr number
---@param path string New directory path
function M.update(bufnr, path)
  if not is_enabled() then
    return
  end

  -- Just restart with new path
  M.start(bufnr, path)
end

---Check if a buffer has an active watcher
---@param bufnr number
---@return boolean
function M.is_watching(bufnr)
  local watcher = watchers[bufnr]
  return watcher ~= nil and watcher.handle ~= nil
end

---Stop all watchers (for cleanup)
function M.stop_all()
  for bufnr, _ in pairs(watchers) do
    M.stop(bufnr)
  end
end

---Internal: perform the actual refresh
---@param bufnr number
function M._do_refresh(bufnr)
  local watcher = watchers[bufnr]
  if not watcher then
    return
  end

  watcher.pending_refresh = false

  -- Stop and close timer
  if watcher.timer then
    if not watcher.timer:is_closing() then
      watcher.timer:stop()
      watcher.timer:close()
    end
    watcher.timer = nil
  end

  -- Check if buffer is still valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    M.stop(bufnr)
    return
  end

  -- Check if directory still exists
  local fs = require("vired.fs")
  if not fs.is_dir(watcher.path) then
    -- Directory was deleted - navigate to parent
    vim.notify("vired: Directory deleted externally, navigating to parent", vim.log.levels.WARN)
    local utils = require("vired.utils")
    local parent = utils.parent(watcher.path)
    local buffer = require("vired.buffer")
    if buffer.buffers[bufnr] then
      buffer.navigate(bufnr, parent)
    end
    return
  end

  -- Only refresh if buffer is visible (performance optimization)
  if is_buffer_visible(bufnr) then
    local buffer = require("vired.buffer")
    buffer.refresh(bufnr)
  else
    -- Mark as pending for when buffer becomes visible
    watcher.pending_refresh = true
  end
end

---Check if buffer has pending refresh (for BufEnter handler)
---@param bufnr number
---@return boolean
function M.has_pending_refresh(bufnr)
  local watcher = watchers[bufnr]
  return watcher ~= nil and watcher.pending_refresh
end

---Clear pending refresh flag
---@param bufnr number
function M.clear_pending_refresh(bufnr)
  local watcher = watchers[bufnr]
  if watcher then
    watcher.pending_refresh = false
  end
end

return M
