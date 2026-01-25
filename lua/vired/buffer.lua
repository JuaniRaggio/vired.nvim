local M = {}

local fs = require("vired.fs")
local utils = require("vired.utils")
local config = require("vired.config")
local highlights = require("vired.highlights")
local git = require("vired.git")
local undo = require("vired.undo")
local watcher = require("vired.watcher")
local jumplist = require("vired.jumplist")

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

  -- Add to jumplist
  jumplist.push(bufnr, path)

  -- Start file watcher for auto-refresh
  watcher.start(bufnr, path)

  -- Cleanup on buffer delete
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      watcher.stop(bufnr)
      jumplist.clear(bufnr)
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
    ["actions.jump_back"] = function()
      M.action_jump_back(bufnr)
    end,
    ["actions.jump_forward"] = function()
      M.action_jump_forward(bufnr)
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

---Open directory or file(s)
---@param bufnr number
function M.action_select(bufnr)
  local buf_data = M.buffers[bufnr]
  if not buf_data then
    return
  end

  -- Check if there are marked entries
  local marked = {}
  for _, entry in ipairs(buf_data.entries) do
    if buf_data.marks[entry.path] then
      table.insert(marked, entry)
    end
  end

  -- If multiple files are marked, open them all as buffers
  if #marked > 1 then
    local files_to_open = {}
    for _, entry in ipairs(marked) do
      if entry.type ~= "directory" then
        table.insert(files_to_open, entry.path)
      end
    end

    if #files_to_open > 0 then
      -- Open first file in current window
      vim.cmd.edit(files_to_open[1])
      -- Open rest as hidden buffers
      for i = 2, #files_to_open do
        vim.cmd("badd " .. vim.fn.fnameescape(files_to_open[i]))
      end
      -- Clear marks
      buf_data.marks = {}
      vim.notify(string.format("vired: Opened %d files", #files_to_open), vim.log.levels.INFO)
      return
    end
  end

  -- Single entry (marked or at cursor)
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
---@param skip_jumplist? boolean If true, don't add to jumplist (used for back/forward)
function M.navigate(bufnr, path, skip_jumplist)
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

  -- Add to jumplist (unless navigating through history)
  if not skip_jumplist then
    jumplist.push(bufnr, path)
  end

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
      local dest_is_dir = fs.is_dir(dest)

      for _, entry in ipairs(entries) do
        local target = dest
        -- If dest is a directory, append filename to move into it
        if dest_is_dir then
          target = utils.join(dest, entry.name)
        end

        local ok, err = undo.rename_with_undo(entry.path, target)
        if not ok then
          vim.notify("vired: " .. err, vim.log.levels.ERROR)
        else
          vim.notify(string.format("vired: Moved %s -> %s", entry.name, target), vim.log.levels.INFO)
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
      local dest_is_dir = fs.is_dir(dest)

      for _, entry in ipairs(entries) do
        local target = dest
        -- If dest is a directory, append filename to copy into it
        if dest_is_dir then
          target = utils.join(dest, entry.name)
        end

        local ok, err = undo.copy_with_undo(entry.path, target)
        if not ok then
          vim.notify("vired: " .. err, vim.log.levels.ERROR)
        else
          vim.notify(string.format("vired: Copied %s -> %s", entry.name, target), vim.log.levels.INFO)
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

---Show help popup with all keybindings (multi-column layout)
---@param bufnr number
function M.action_help(bufnr)
  local cfg = config.get()
  local keymaps = cfg.keymaps

  -- Build reverse map: action -> key
  local action_to_key = {}
  for key, action in pairs(keymaps) do
    action_to_key[action] = key
  end

  -- Helper to format key binding
  local function fmt_key(action, desc)
    local key = action_to_key[action]
    if not key then return nil end
    local key_disp = key
    if #key_disp < 6 then
      key_disp = key_disp .. string.rep(" ", 6 - #key_disp)
    end
    return key_disp .. " " .. desc
  end

  -- Define columns (each column is a category with items)
  local col1 = { -- Navigation
    title = "Navigation",
    items = {
      fmt_key("actions.select", "Open"),
      fmt_key("actions.parent", "Parent"),
      fmt_key("actions.close", "Close"),
      fmt_key("actions.refresh", "Refresh"),
      fmt_key("actions.jump_back", "Back"),
      fmt_key("actions.jump_forward", "Forward"),
    },
  }

  local col2 = { -- Files
    title = "Files",
    items = {
      fmt_key("actions.move", "Move/Rename"),
      fmt_key("actions.copy", "Copy"),
      fmt_key("actions.delete", "Delete"),
      fmt_key("actions.mkdir", "New dir"),
      fmt_key("actions.touch", "New file"),
      fmt_key("actions.undo", "Undo"),
      fmt_key("actions.redo", "Redo"),
    },
  }

  local col3 = { -- View
    title = "View",
    items = {
      fmt_key("actions.toggle_hidden", "Hidden"),
      fmt_key("actions.preview", "Preview"),
      fmt_key("actions.toggle_watch", "Watch"),
      fmt_key("actions.help", "Help"),
    },
  }

  local col4 = { -- Marks
    title = "Marks",
    items = {
      fmt_key("actions.toggle_mark", "Toggle"),
      fmt_key("actions.unmark", "Unmark"),
      fmt_key("actions.unmark_all", "Clear all"),
    },
  }

  local col5 = { -- Edit
    title = "Edit Mode",
    items = {
      fmt_key("actions.edit", "Enter edit"),
      ":w     Apply changes",
      ":e!    Cancel",
    },
  }

  -- Filter nil items
  local function filter_items(col)
    local filtered = {}
    for _, item in ipairs(col.items) do
      if item then table.insert(filtered, item) end
    end
    col.items = filtered
    return col
  end

  col1 = filter_items(col1)
  col2 = filter_items(col2)
  col3 = filter_items(col3)
  col4 = filter_items(col4)
  col5 = filter_items(col5)

  -- Calculate column width (fixed for alignment)
  local col_width = 20
  local gap = 2

  -- Build lines by combining columns horizontally
  local function pad(str, width)
    if not str then str = "" end
    if #str < width then
      return str .. string.rep(" ", width - #str)
    end
    return str:sub(1, width)
  end

  -- Get max rows needed
  local max_rows = math.max(
    #col1.items + 1,
    #col2.items + 1,
    #col3.items + 1,
    #col4.items + 1,
    #col5.items + 1
  )

  local lines = {}
  local highlights = {} -- {line, start_col, end_col, hl_group}

  -- Row 0: Column titles
  local title_line = pad(col1.title, col_width)
    .. string.rep(" ", gap)
    .. pad(col2.title, col_width)
    .. string.rep(" ", gap)
    .. pad(col3.title, col_width)
    .. string.rep(" ", gap)
    .. pad(col4.title, col_width)
    .. string.rep(" ", gap)
    .. pad(col5.title, col_width)
  table.insert(lines, title_line)

  -- Add title highlights
  local offset = 0
  for i, col in ipairs({ col1, col2, col3, col4, col5 }) do
    table.insert(highlights, { 0, offset, offset + #col.title, "Statement" })
    offset = offset + col_width + gap
  end

  -- Separator
  local total_width = (col_width * 5) + (gap * 4)
  table.insert(lines, string.rep("-", total_width))

  -- Content rows
  for row = 1, max_rows do
    local line = pad(col1.items[row], col_width)
      .. string.rep(" ", gap)
      .. pad(col2.items[row], col_width)
      .. string.rep(" ", gap)
      .. pad(col3.items[row], col_width)
      .. string.rep(" ", gap)
      .. pad(col4.items[row], col_width)
      .. string.rep(" ", gap)
      .. pad(col5.items[row], col_width)
    table.insert(lines, line)

    -- Highlight keys in each column
    local line_idx = #lines - 1
    offset = 0
    for _, col in ipairs({ col1, col2, col3, col4, col5 }) do
      if col.items[row] then
        -- Highlight first 6 chars (the key)
        table.insert(highlights, { line_idx, offset, offset + 6, "Special" })
      end
      offset = offset + col_width + gap
    end
  end

  -- Blank line
  table.insert(lines, "")

  -- Commands section (2 columns)
  table.insert(lines, "Commands")
  table.insert(highlights, { #lines - 1, 0, 8, "Statement" })
  table.insert(lines, string.rep("-", total_width))

  local commands = {
    { ":Vired [path]", "Open vired" },
    { ":ViredOpen", "Path picker" },
    { ":ViredProjects", "Project picker" },
    { ":ViredProjectAdd", "Bookmark project" },
    { ":ViredProjectRemove", "Remove bookmark" },
    { ":ViredUndo", "Undo operation" },
    { ":ViredRedo", "Redo operation" },
  }

  local cmd_col_width = math.floor((total_width - gap) / 2)
  for i = 1, math.ceil(#commands / 2) do
    local left_cmd = commands[i]
    local right_cmd = commands[i + math.ceil(#commands / 2)]

    local left_str = ""
    local right_str = ""

    if left_cmd then
      left_str = pad(left_cmd[1], 20) .. " " .. left_cmd[2]
    end
    if right_cmd then
      right_str = pad(right_cmd[1], 20) .. " " .. right_cmd[2]
    end

    local line = pad(left_str, cmd_col_width) .. string.rep(" ", gap) .. right_str
    table.insert(lines, line)

    -- Highlight command names
    local line_idx = #lines - 1
    if left_cmd then
      table.insert(highlights, { line_idx, 0, #left_cmd[1], "Function" })
    end
    if right_cmd then
      table.insert(highlights, { line_idx, cmd_col_width + gap, cmd_col_width + gap + #right_cmd[1], "Function" })
    end
  end

  -- Footer
  table.insert(lines, "")
  table.insert(lines, string.rep("-", total_width))
  table.insert(lines, "Press q/Esc to close | <M-e> enters full vim edit mode")
  table.insert(highlights, { #lines - 1, 6, 7, "Special" })
  table.insert(highlights, { #lines - 1, 8, 11, "Special" })
  table.insert(highlights, { #lines - 1, 24, 29, "Special" })

  -- Calculate window size
  local width = total_width + 4
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
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(float_bufnr, ns, hl[4], hl[1], hl[2], hl[3])
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

---Go back in directory history
---@param bufnr number
function M.action_jump_back(bufnr)
  if not jumplist.can_go_back(bufnr) then
    vim.notify("vired: Already at oldest directory", vim.log.levels.INFO)
    return
  end

  local path = jumplist.back(bufnr)
  if path then
    M.navigate(bufnr, path, true) -- skip_jumplist = true
  end
end

---Go forward in directory history
---@param bufnr number
function M.action_jump_forward(bufnr)
  if not jumplist.can_go_forward(bufnr) then
    vim.notify("vired: Already at newest directory", vim.log.levels.INFO)
    return
  end

  local path = jumplist.forward(bufnr)
  if path then
    M.navigate(bufnr, path, true) -- skip_jumplist = true
  end
end

return M
