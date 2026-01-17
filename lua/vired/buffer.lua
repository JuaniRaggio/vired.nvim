local M = {}

local fs = require("vired.fs")
local utils = require("vired.utils")
local config = require("vired.config")
local highlights = require("vired.highlights")
local git = require("vired.git")
local undo = require("vired.undo")
local watcher = require("vired.watcher")

---@class ViredBuffer
---@field bufnr number Buffer number
---@field path string Current directory path
---@field entries ViredEntry[] Directory entries
---@field show_hidden boolean Show hidden files
---@field marks table<string, boolean> Marked files (path -> true)
---@field git_root string|nil Git repository root (nil if not in repo)
---@field git_status table<string, GitFileStatus>|nil Git status map

---@type table<number, ViredBuffer>
M.buffers = {}

local FILETYPE = "vired"
local HEADER_LINES = 1 -- Number of header lines before entries

---Create or get vired buffer for path
---@param path string Directory path
---@return number bufnr
function M.create(path)
  path = utils.absolute(path)

  -- Check if buffer already exists for this path
  for bufnr, buf_data in pairs(M.buffers) do
    if buf_data.path == path and vim.api.nvim_buf_is_valid(bufnr) then
      return bufnr
    end
  end

  -- Create new buffer
  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_name(bufnr, "vired://" .. path)

  -- Buffer options
  vim.bo[bufnr].filetype = FILETYPE
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false

  -- Detect git repository
  local git_root = git.find_repo_root(path)

  -- Store buffer data
  M.buffers[bufnr] = {
    bufnr = bufnr,
    path = path,
    entries = {},
    show_hidden = config.get().path_picker.show_hidden,
    marks = {},
    git_root = git_root,
    git_status = nil,
  }

  -- Setup keymaps
  M.setup_keymaps(bufnr)

  -- Load and render
  M.refresh(bufnr)

  -- Start file watcher for auto-refresh
  watcher.start(bufnr, path)

  -- Cleanup on buffer delete
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      watcher.stop(bufnr)
      M.buffers[bufnr] = nil
    end,
  })

  -- Handle pending refreshes when buffer becomes visible again
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = bufnr,
    callback = function()
      if watcher.has_pending_refresh(bufnr) then
        watcher.clear_pending_refresh(bufnr)
        M.refresh(bufnr)
      end
    end,
  })

  return bufnr
end

---Setup keymaps for vired buffer
---@param bufnr number
function M.setup_keymaps(bufnr)
  local opts = { buffer = bufnr, noremap = true, silent = true }
  local keymaps = config.get().keymaps

  local action_handlers = {
    ["actions.select"] = function()
      M.action_select(bufnr)
    end,
    ["actions.parent"] = function()
      M.action_parent(bufnr)
    end,
    ["actions.close"] = function()
      M.action_close(bufnr)
    end,
    ["actions.refresh"] = function()
      M.refresh(bufnr)
    end,
    ["actions.toggle_hidden"] = function()
      M.toggle_hidden(bufnr)
    end,
    ["actions.toggle_mark"] = function()
      M.toggle_mark(bufnr)
    end,
    ["actions.unmark"] = function()
      M.unmark_current(bufnr)
    end,
    ["actions.unmark_all"] = function()
      M.unmark_all(bufnr)
    end,
    ["actions.move"] = function()
      M.action_move(bufnr)
    end,
    ["actions.copy"] = function()
      M.action_copy(bufnr)
    end,
    ["actions.delete"] = function()
      M.action_delete(bufnr)
    end,
    ["actions.mkdir"] = function()
      M.action_mkdir(bufnr)
    end,
    ["actions.touch"] = function()
      M.action_touch(bufnr)
    end,
    ["actions.preview"] = function()
      M.action_preview(bufnr)
    end,
    ["actions.edit"] = function()
      M.action_edit(bufnr)
    end,
    ["actions.edit_cancel"] = function()
      M.action_edit_cancel(bufnr)
    end,
    ["actions.undo"] = function()
      M.action_undo(bufnr)
    end,
    ["actions.redo"] = function()
      M.action_redo(bufnr)
    end,
    ["actions.help"] = function()
      M.action_help(bufnr)
    end,
    ["actions.toggle_watch"] = function()
      M.action_toggle_watch(bufnr)
    end,
  }

  for key, action in pairs(keymaps) do
    local handler = action_handlers[action]
    if handler then
      vim.keymap.set("n", key, handler, opts)
    end
  end
end

---Refresh buffer contents
---@param bufnr number
function M.refresh(bufnr)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  -- Read directory
  local entries, err = fs.readdir(buf_data.path, buf_data.show_hidden)
  if err then
    vim.notify("vired: " .. err, vim.log.levels.ERROR)
    return
  end

  buf_data.entries = entries

  -- Load git status asynchronously if in a git repo
  if buf_data.git_root then
    git.invalidate_cache(buf_data.git_root)
    git.get_status_async(buf_data.git_root, function(status_map, git_err)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      buf_data.git_status = status_map
      -- Re-render with git status
      M.render(bufnr)
    end)
  end

  -- Render buffer (may re-render after git status loads)
  M.render(bufnr)
end

---Render buffer contents
---@param bufnr number
function M.render(bufnr)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  local lines = {}
  local hl_marks = {}
  local cfg = config.get()

  -- Header line
  local header = "  " .. buf_data.path
  if buf_data.show_hidden then
    header = header .. " [hidden]"
  end
  if buf_data.git_root then
    header = header .. " [git]"
  end
  table.insert(lines, header)
  table.insert(hl_marks, { line = 0, col = 0, end_col = #header, hl = "ViredHeader" })

  -- Render each entry
  for i, entry in ipairs(buf_data.entries) do
    local file_git_status = buf_data.git_status and buf_data.git_status[entry.path]
    local line, entry_hls = M.render_entry(entry, buf_data.marks[entry.path], cfg.columns, file_git_status)
    table.insert(lines, line)

    -- Adjust highlight line numbers (offset by header)
    local line_idx = i -- 0-indexed line = i (since header is line 0)
    for _, hl in ipairs(entry_hls) do
      hl.line = line_idx
      table.insert(hl_marks, hl)
    end
  end

  -- Set buffer contents
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("vired")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for _, hl in ipairs(hl_marks) do
    vim.api.nvim_buf_add_highlight(bufnr, ns, hl.hl, hl.line, hl.col, hl.end_col)
  end
end

---Render a single entry line
---@param entry ViredEntry
---@param is_marked boolean
---@param columns string[]
---@param git_status GitFileStatus|nil
---@return string line, table[] highlights
function M.render_entry(entry, is_marked, columns, git_status)
  local parts = {}
  local hls = {}
  local col = 0

  -- Mark indicator
  local mark_char = is_marked and "*" or " "
  table.insert(parts, mark_char)
  if is_marked then
    table.insert(hls, { col = col, end_col = col + 1, hl = "ViredMarked" })
  end
  col = col + 2 -- mark + space

  -- Git status indicator
  local git_char, git_hl = git.get_status_display(git_status)
  table.insert(parts, git_char)
  if git_char ~= " " then
    table.insert(hls, { col = col, end_col = col + 1, hl = git_hl })
  end
  col = col + 2 -- git status + space

  -- Build columns
  for _, column in ipairs(columns) do
    if column == "icon" then
      local icon, icon_hl = highlights.get_icon(entry.name, entry.type)
      table.insert(parts, icon)
      table.insert(hls, { col = col, end_col = col + #icon, hl = icon_hl })
      col = col + #icon + 1

    elseif column == "permissions" then
      local perms = utils.format_permissions(entry.mode, entry.type)
      table.insert(parts, perms)
      table.insert(hls, { col = col, end_col = col + #perms, hl = "ViredPermissions" })
      col = col + #perms + 1

    elseif column == "size" then
      local size_str
      if entry.type == "directory" then
        size_str = string.format("%6s", "-")
      else
        size_str = string.format("%6s", utils.format_size(entry.size))
      end
      table.insert(parts, size_str)
      table.insert(hls, { col = col, end_col = col + #size_str, hl = "ViredSize" })
      col = col + #size_str + 1

    elseif column == "mtime" then
      local time_str = utils.format_time(entry.mtime)
      table.insert(parts, time_str)
      table.insert(hls, { col = col, end_col = col + #time_str, hl = "ViredDate" })
      col = col + #time_str + 1
    end
  end

  -- Name (always last)
  local name = entry.name
  if entry.type == "directory" then
    name = name .. "/"
  elseif entry.type == "link" then
    name = name .. " -> " .. (entry.link_target or "?")
  end

  local name_hl = "ViredFile"
  if entry.type == "directory" then
    name_hl = "ViredDirectory"
  elseif entry.type == "link" then
    name_hl = "ViredSymlink"
  end

  table.insert(parts, name)
  table.insert(hls, { col = col, end_col = col + #name, hl = name_hl })

  -- Join with spaces
  local line = table.concat(parts, " ")

  -- If marked, add background highlight to entire line
  if is_marked then
    table.insert(hls, { col = 0, end_col = #line, hl = "ViredMarkedFile" })
  end

  return line, hls
end

---Get entry under cursor
---@param bufnr number
---@return ViredEntry|nil
function M.get_entry_at_cursor(bufnr)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] -- 1-indexed

  -- Account for header
  local entry_idx = line - HEADER_LINES
  if entry_idx < 1 or entry_idx > #buf_data.entries then
    return nil
  end

  return buf_data.entries[entry_idx]
end

---Open directory or file
---@param bufnr number
function M.action_select(bufnr)
  local entry = M.get_entry_at_cursor(bufnr)
  if not entry then
    return
  end

  if entry.type == "directory" then
    -- Navigate into directory
    M.navigate(bufnr, entry.path)
  else
    -- Open file
    vim.cmd.edit(entry.path)
  end
end

---Navigate to parent directory
---@param bufnr number
function M.action_parent(bufnr)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  local parent = utils.parent(buf_data.path)
  if parent ~= buf_data.path then
    M.navigate(bufnr, parent)
  end
end

---Navigate to a new directory
---@param bufnr number
---@param path string
function M.navigate(bufnr, path)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  path = utils.absolute(path)

  if not fs.is_dir(path) then
    vim.notify("vired: not a directory: " .. path, vim.log.levels.ERROR)
    return
  end

  -- Update buffer
  buf_data.path = path
  buf_data.marks = {} -- Clear marks on navigation
  buf_data.git_root = git.find_repo_root(path)
  buf_data.git_status = nil

  -- Update buffer name
  vim.api.nvim_buf_set_name(bufnr, "vired://" .. path)

  -- Update watcher to new path
  watcher.update(bufnr, path)

  -- Refresh
  M.refresh(bufnr)

  -- Move cursor to first entry
  vim.api.nvim_win_set_cursor(0, { HEADER_LINES + 1, 0 })
end

---Close vired buffer
---@param bufnr number
function M.action_close(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

---Toggle hidden files
---@param bufnr number
function M.toggle_hidden(bufnr)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  buf_data.show_hidden = not buf_data.show_hidden
  M.refresh(bufnr)
end

---Toggle mark on current entry
---@param bufnr number
function M.toggle_mark(bufnr)
  local buf_data = M.buffers[bufnr]
  local entry = M.get_entry_at_cursor(bufnr)
  if not buf_data or not entry then
    return
  end

  if buf_data.marks[entry.path] then
    buf_data.marks[entry.path] = nil
  else
    buf_data.marks[entry.path] = true
  end

  M.render(bufnr)

  -- Move to next line
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if cursor[1] < line_count then
    vim.api.nvim_win_set_cursor(0, { cursor[1] + 1, cursor[2] })
  end
end

---Unmark current entry
---@param bufnr number
function M.unmark_current(bufnr)
  local buf_data = M.buffers[bufnr]
  local entry = M.get_entry_at_cursor(bufnr)
  if not buf_data or not entry then
    return
  end

  buf_data.marks[entry.path] = nil
  M.render(bufnr)
end

---Clear all marks
---@param bufnr number
function M.unmark_all(bufnr)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  buf_data.marks = {}
  M.render(bufnr)
end

---Get marked entries (or current entry if none marked)
---@param bufnr number
---@return ViredEntry[]
function M.get_marked_or_current(bufnr)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return {}
  end

  local marked = {}
  for _, entry in ipairs(buf_data.entries) do
    if buf_data.marks[entry.path] then
      table.insert(marked, entry)
    end
  end

  -- If nothing marked, use current entry
  if #marked == 0 then
    local current = M.get_entry_at_cursor(bufnr)
    if current then
      return { current }
    end
  end

  return marked
end

---Move/rename files with path picker
function M.action_move(bufnr)
  local entries = M.get_marked_or_current(bufnr)
  if #entries == 0 then
    return
  end

  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  local picker = require("vired.picker")
  local prompt, default

  if #entries == 1 then
    -- Single file: rename mode
    prompt = "Rename: "
    default = entries[1].path
  else
    -- Multiple files: move to directory
    prompt = "Move " .. #entries .. " files to: "
    default = buf_data.path .. "/"
  end

  picker.open({
    prompt = prompt,
    default = default,
    cwd = buf_data.path,
    on_select = function(dest)
      for _, entry in ipairs(entries) do
        local target = dest
        -- If dest is a directory and multiple files, append filename
        if #entries > 1 or (fs.is_dir(dest) and dest:sub(-1) == "/") then
          target = utils.join(dest, entry.name)
        end

        local ok, err = undo.rename_with_undo(entry.path, target)
        if not ok then
          vim.notify("vired: " .. err, vim.log.levels.ERROR)
        end
      end
      -- Clear marks and refresh
      buf_data.marks = {}
      M.refresh(bufnr)
    end,
  })
end

---Copy files with path picker
function M.action_copy(bufnr)
  local entries = M.get_marked_or_current(bufnr)
  if #entries == 0 then
    return
  end

  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  local picker = require("vired.picker")
  local prompt, default

  if #entries == 1 then
    prompt = "Copy to: "
    default = entries[1].path
  else
    prompt = "Copy " .. #entries .. " files to: "
    default = buf_data.path .. "/"
  end

  picker.open({
    prompt = prompt,
    default = default,
    cwd = buf_data.path,
    on_select = function(dest)
      for _, entry in ipairs(entries) do
        local target = dest
        -- If dest is a directory and multiple files, append filename
        if #entries > 1 or (fs.is_dir(dest) and dest:sub(-1) == "/") then
          target = utils.join(dest, entry.name)
        end

        local ok, err = undo.copy_with_undo(entry.path, target)
        if not ok then
          vim.notify("vired: " .. err, vim.log.levels.ERROR)
        end
      end
      M.refresh(bufnr)
    end,
  })
end

function M.action_delete(bufnr)
  local entries = M.get_marked_or_current(bufnr)
  if #entries == 0 then
    return
  end

  local buf_data = M.buffers[bufnr]

  local names = {}
  for _, entry in ipairs(entries) do
    table.insert(names, entry.name)
  end

  local confirm_msg = "Delete " .. #entries .. " file(s)? [" .. table.concat(names, ", ") .. "] (moved to trash)"
  utils.confirm({
    prompt = confirm_msg,
    on_yes = function()
      for _, entry in ipairs(entries) do
        local ok, err = undo.delete_with_undo(entry.path)
        if not ok then
          vim.notify("vired: " .. err, vim.log.levels.ERROR)
        end
      end
      -- Clear marks and refresh
      if buf_data then
        buf_data.marks = {}
      end
      M.refresh(bufnr)
    end,
  })
end

function M.action_mkdir(bufnr)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  vim.ui.input({ prompt = "Create directory: ", default = buf_data.path .. "/" }, function(input)
    if input and input ~= "" then
      local ok, err = undo.mkdir_with_undo(input)
      if ok then
        M.refresh(bufnr)
      else
        vim.notify("vired: " .. err, vim.log.levels.ERROR)
      end
    end
  end)
end

function M.action_touch(bufnr)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  vim.ui.input({ prompt = "Create file: ", default = buf_data.path .. "/" }, function(input)
    if input and input ~= "" then
      local ok, err = undo.touch_with_undo(input)
      if ok then
        M.refresh(bufnr)
      else
        vim.notify("vired: " .. err, vim.log.levels.ERROR)
      end
    end
  end)
end

function M.action_preview(bufnr)
  local preview = require("vired.preview")
  local entry = M.get_entry_at_cursor(bufnr)

  if entry then
    preview.toggle(entry.path)
  end
end

---Enter edit mode to rename files by editing buffer
---@param bufnr number
function M.action_edit(bufnr)
  local edit = require("vired.edit")
  local buf_data = M.buffers[bufnr]

  if not buf_data then
    return
  end

  if edit.is_editing(bufnr) then
    vim.notify("vired: Already in edit mode. :w to apply, :e! to cancel", vim.log.levels.WARN)
    return
  end

  edit.enter_edit_mode(bufnr, buf_data)
end

---Cancel edit mode and restore original buffer
---@param bufnr number
function M.action_edit_cancel(bufnr)
  local edit = require("vired.edit")
  local buf_data = M.buffers[bufnr]

  if not buf_data then
    return
  end

  if not edit.is_editing(bufnr) then
    return
  end

  edit.cancel_edit_mode(bufnr, buf_data)
end

---Undo last file operation
---@param bufnr number
function M.action_undo(bufnr)
  if not undo.can_undo() then
    vim.notify("vired: Nothing to undo", vim.log.levels.INFO)
    return
  end

  local desc = undo.peek_undo()
  local ok, err = undo.undo()

  if ok then
    vim.notify("vired: Undone: " .. desc, vim.log.levels.INFO)
    M.refresh(bufnr)
  else
    vim.notify("vired: Undo failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
  end
end

---Redo last undone operation
---@param bufnr number
function M.action_redo(bufnr)
  if not undo.can_redo() then
    vim.notify("vired: Nothing to redo", vim.log.levels.INFO)
    return
  end

  local desc = undo.peek_redo()
  local ok, err = undo.redo()

  if ok then
    vim.notify("vired: Redone: " .. desc, vim.log.levels.INFO)
    M.refresh(bufnr)
  else
    vim.notify("vired: Redo failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
  end
end

---Show help popup with all keybindings
---@param bufnr number
function M.action_help(bufnr)
  local cfg = config.get()
  local keymaps = cfg.keymaps

  -- Action descriptions
  local action_descriptions = {
    ["actions.select"] = "Open file/directory",
    ["actions.parent"] = "Go to parent directory",
    ["actions.close"] = "Close vired buffer",
    ["actions.refresh"] = "Refresh directory listing",
    ["actions.toggle_hidden"] = "Toggle hidden files",
    ["actions.toggle_mark"] = "Toggle mark on file",
    ["actions.unmark"] = "Unmark current file",
    ["actions.unmark_all"] = "Unmark all files",
    ["actions.move"] = "Move/rename file(s)",
    ["actions.copy"] = "Copy file(s)",
    ["actions.delete"] = "Delete file(s) (to trash)",
    ["actions.mkdir"] = "Create directory",
    ["actions.touch"] = "Create file",
    ["actions.preview"] = "Preview file",
    ["actions.edit"] = "Enter edit mode (wdired)",
    ["actions.edit_cancel"] = "Cancel edit mode",
    ["actions.undo"] = "Undo last operation",
    ["actions.redo"] = "Redo last operation",
    ["actions.help"] = "Show this help",
    ["actions.toggle_watch"] = "Toggle auto-refresh",
  }

  -- Build help lines
  local lines = {
    "Vired Keybindings",
    string.rep("-", 40),
    "",
  }

  -- Sort keymaps by action for consistent display
  local sorted_keys = {}
  for key, _ in pairs(keymaps) do
    table.insert(sorted_keys, key)
  end
  table.sort(sorted_keys)

  -- Group by category
  local categories = {
    { name = "Navigation", actions = { "actions.select", "actions.parent", "actions.close", "actions.refresh" } },
    { name = "Marking", actions = { "actions.toggle_mark", "actions.unmark", "actions.unmark_all" } },
    { name = "File Operations", actions = { "actions.move", "actions.copy", "actions.delete", "actions.mkdir", "actions.touch" } },
    { name = "View", actions = { "actions.toggle_hidden", "actions.preview", "actions.toggle_watch" } },
    { name = "Edit Mode", actions = { "actions.edit", "actions.edit_cancel" } },
    { name = "Undo/Redo", actions = { "actions.undo", "actions.redo" } },
    { name = "Help", actions = { "actions.help" } },
  }

  -- Build reverse map: action -> key
  local action_to_key = {}
  for key, action in pairs(keymaps) do
    action_to_key[action] = key
  end

  for _, category in ipairs(categories) do
    local has_items = false
    for _, action in ipairs(category.actions) do
      if action_to_key[action] then
        has_items = true
        break
      end
    end

    if has_items then
      table.insert(lines, category.name .. ":")
      for _, action in ipairs(category.actions) do
        local key = action_to_key[action]
        if key then
          local desc = action_descriptions[action] or action
          -- Format key nicely
          local key_display = key
          if #key_display < 8 then
            key_display = key_display .. string.rep(" ", 8 - #key_display)
          end
          table.insert(lines, "  " .. key_display .. "  " .. desc)
        end
      end
      table.insert(lines, "")
    end
  end

  table.insert(lines, string.rep("-", 40))
  table.insert(lines, "Press q, ? or <Esc> to close")

  -- Calculate window size
  local max_width = 0
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, #line)
  end
  local width = max_width + 4
  local height = #lines

  -- Create floating window
  local float_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_bufnr, 0, -1, false, lines)
  vim.bo[float_bufnr].modifiable = false
  vim.bo[float_bufnr].buftype = "nofile"
  vim.bo[float_bufnr].bufhidden = "wipe"

  -- Center the window
  local ui = vim.api.nvim_list_uis()[1]
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  local win_opts = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = cfg.float.border,
    title = " Vired Help ",
    title_pos = "center",
  }

  local win = vim.api.nvim_open_win(float_bufnr, true, win_opts)

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("vired_help")
  -- Title
  vim.api.nvim_buf_add_highlight(float_bufnr, ns, "Title", 0, 0, -1)
  -- Category headers
  for i, line in ipairs(lines) do
    if line:match("^%w.*:$") then
      vim.api.nvim_buf_add_highlight(float_bufnr, ns, "Statement", i - 1, 0, -1)
    elseif line:match("^  %S") then
      -- Key highlight
      vim.api.nvim_buf_add_highlight(float_bufnr, ns, "Special", i - 1, 2, 12)
    end
  end

  -- Close keymaps
  local close_keys = { "q", "?", "<Esc>" }
  for _, key in ipairs(close_keys) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = float_bufnr, noremap = true, silent = true })
  end
end

---Toggle file watcher for auto-refresh
---@param bufnr number
function M.action_toggle_watch(bufnr)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  watcher.toggle(bufnr, buf_data.path)
end

return M
