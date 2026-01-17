---@class DiredEditOperation
---@field type "rename"|"delete"|"create"
---@field source string|nil Original path (for rename/delete)
---@field dest string|nil New path (for rename/create)

---@class DiredEditSnapshot
---@field entries table<number, DiredEntry> Line number -> original entry
---@field path string Directory path
---@field name_positions table<number, number> Line number -> column where name starts

local M = {}

local utils = require("dired.utils")
local fs = require("dired.fs")
local config = require("dired.config")
local git = require("dired.git")

---@type table<number, DiredEditSnapshot> Buffer -> snapshot
local snapshots = {}

---@type table<number, boolean> Buffer -> is in edit mode
local edit_mode = {}

---@type table<number, number> Buffer -> autocmd ID for TextChanged
local change_autocmds = {}

---@type table<number, number> Buffer -> timer for debounced highlights
local highlight_timers = {}

local HEADER_LINES = 1
local EDIT_NS = vim.api.nvim_create_namespace("dired_edit")
local HIGHLIGHT_DEBOUNCE_MS = 100 -- Debounce highlight updates for performance

-- ============================================================================
-- Line Parsing
-- ============================================================================

---Calculate where the name starts based on column configuration
---@param columns string[]
---@return number name_start_col (0-indexed)
local function calculate_name_start(columns)
  local col = 0

  -- Mark indicator (1 char + 1 space)
  col = col + 2

  -- Git status (1 char + 1 space)
  col = col + 2

  -- Each column adds its width + 1 space
  for _, column in ipairs(columns) do
    if column == "icon" then
      -- Icon is variable width but typically 1-2 chars + 1 space
      -- We'll use 2 + 1 = 3 as estimate, but actual parsing adjusts
      col = col + 3
    elseif column == "permissions" then
      -- drwxr-xr-x = 10 chars + 1 space
      col = col + 11
    elseif column == "size" then
      -- Right-aligned 6 chars + 1 space
      col = col + 7
    elseif column == "mtime" then
      -- YYYY-MM-DD = 10 chars + 1 space
      col = col + 11
    end
  end

  return col
end

---Parse the name from a rendered line
---This is tricky because the name is at the end, after variable-width columns
---We use the known structure: name is everything after the last fixed column
---@param line string The rendered line
---@param columns string[] Column configuration
---@return string|nil name, string|nil type ("directory"|"file"|"link")
function M.parse_line_name(line, columns)
  if not line or line == "" then
    return nil, nil
  end

  -- Skip header-like lines (start with spaces followed by /)
  if line:match("^%s+/") then
    return nil, nil
  end

  -- Skip empty or whitespace-only lines
  if line:match("^%s*$") then
    return nil, nil
  end

  local name_part = nil

  -- Strategy 1: If mtime is in columns, find YYYY-MM-DD pattern
  if vim.tbl_contains(columns, "mtime") then
    local _, date_finish = line:find("%d%d%d%d%-%d%d%-%d%d")
    if date_finish then
      name_part = line:sub(date_finish + 2) -- +2 for space after date
    end
  end

  -- Strategy 2: If size is in columns but not mtime, find size pattern
  if not name_part and vim.tbl_contains(columns, "size") then
    -- Size format: right-aligned, like "  1.2K" or "    -" or " 123B"
    -- Look for patterns after permissions if present
    if vim.tbl_contains(columns, "permissions") then
      -- Find permissions pattern (10 chars like drwxr-xr-x or -rw-r--r--)
      local _, perm_end = line:find("[d%-l][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-][rwx%-]")
      if perm_end then
        -- After permissions comes size (6 chars) then name
        local after_perm = line:sub(perm_end + 1)
        -- Skip whitespace and size column
        local _, size_end = after_perm:find("^%s*[%d%.%-]+[BKMGTP]?%s*")
        if size_end then
          name_part = after_perm:sub(size_end + 1)
        else
          -- Try simpler: skip next word
          name_part = after_perm:match("^%s*%S+%s+(.+)$")
        end
      end
    end
  end

  -- Strategy 3: Fallback - take content after known column widths
  if not name_part then
    local start_col = calculate_name_start(columns)
    if start_col < #line then
      name_part = line:sub(start_col + 1)
    end
  end

  -- Strategy 4: Ultimate fallback - split and reconstruct
  if not name_part or name_part == "" then
    local parts = {}
    for part in line:gmatch("%S+") do
      table.insert(parts, part)
    end
    -- Skip known column parts (mark, git, icon, etc) and take the rest
    -- This is imprecise but better than nothing
    if #parts > 4 then
      -- Assume at least 4 parts are columns, rest is name
      local name_parts = {}
      for i = 5, #parts do
        table.insert(name_parts, parts[i])
      end
      name_part = table.concat(name_parts, " ")
    elseif #parts > 0 then
      name_part = parts[#parts]
    end
  end

  if not name_part or name_part == "" then
    return nil, nil
  end

  -- Clean up leading/trailing whitespace
  name_part = name_part:match("^%s*(.-)%s*$")

  if not name_part or name_part == "" then
    return nil, nil
  end

  -- Determine entry type and extract name
  local name = name_part
  local entry_type = "file"

  -- Check if directory (ends with /)
  if name:sub(-1) == "/" then
    name = name:sub(1, -2)
    entry_type = "directory"
  -- Check if symlink (contains " -> ")
  elseif name:find(" -> ", 1, true) then
    local arrow_pos = name:find(" -> ", 1, true)
    name = name:sub(1, arrow_pos - 1)
    entry_type = "link"
  end

  -- Handle edge cases
  if name == "" then
    return nil, nil
  end

  return name, entry_type
end

---Parse a line more robustly by matching against known entry
---@param line string The edited line
---@param original_entry DiredEntry The original entry for this line
---@param columns string[] Column configuration
---@return string|nil new_name The parsed name (nil if line deleted)
function M.parse_line_with_context(line, original_entry, columns)
  if not line or line == "" or line:match("^%s*$") then
    return nil -- Line was deleted
  end

  local name, _ = M.parse_line_name(line, columns)
  return name
end

-- ============================================================================
-- Snapshot Management
-- ============================================================================

---Create a snapshot of the current buffer state before editing
---@param bufnr number Buffer number
---@param buf_data table DiredBuffer data
function M.create_snapshot(bufnr, buf_data)
  local columns = config.get().columns

  local snapshot = {
    entries = {},
    path = buf_data.path,
    name_positions = {},
  }

  for i, entry in ipairs(buf_data.entries) do
    local line_num = HEADER_LINES + i -- 1-indexed line number
    snapshot.entries[line_num] = vim.deepcopy(entry)
    snapshot.name_positions[line_num] = calculate_name_start(columns)
  end

  snapshots[bufnr] = snapshot
end

---Get snapshot for a buffer
---@param bufnr number
---@return DiredEditSnapshot|nil
function M.get_snapshot(bufnr)
  return snapshots[bufnr]
end

---Clear snapshot for a buffer
---@param bufnr number
function M.clear_snapshot(bufnr)
  snapshots[bufnr] = nil
end

-- ============================================================================
-- Real-time Highlighting
-- ============================================================================

---Update highlights to show pending changes in real-time
---@param bufnr number
function M.update_highlights(bufnr)
  local snapshot = snapshots[bufnr]
  if not snapshot then
    return
  end

  -- Clear existing edit highlights
  vim.api.nvim_buf_clear_namespace(bufnr, EDIT_NS, 0, -1)

  local columns = config.get().columns or {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local current_line_count = #lines

  -- Update header to show edit mode
  if current_line_count > 0 then
    local header = lines[1]
    if header and not header:find("%[EDIT%]") then
      -- Add visual indicator in header (we can't modify, just highlight)
    end
    vim.api.nvim_buf_add_highlight(bufnr, EDIT_NS, "DiredEditMode", 0, 0, -1)
  end

  -- Check each line for changes
  for line_num = HEADER_LINES + 1, current_line_count do
    local line = lines[line_num]
    local original_entry = snapshot.entries[line_num]

    if original_entry then
      local new_name = M.parse_line_with_context(line, original_entry, columns)

      if new_name == nil or (line and line:match("^%s*$")) then
        -- Line was deleted/emptied - show as deleted
        vim.api.nvim_buf_add_highlight(bufnr, EDIT_NS, "DiredEditDeleted", line_num - 1, 0, -1)
      elseif new_name ~= original_entry.name then
        -- Name changed - show as modified
        vim.api.nvim_buf_add_highlight(bufnr, EDIT_NS, "DiredEditChanged", line_num - 1, 0, -1)
      end
    elseif line and not line:match("^%s*$") then
      -- New line with content
      vim.api.nvim_buf_add_highlight(bufnr, EDIT_NS, "DiredEditNew", line_num - 1, 0, -1)
    end
  end

  -- Check for lines that were at the end but are now gone
  for line_num, _ in pairs(snapshot.entries) do
    if line_num > current_line_count then
      -- This line was deleted (can't highlight non-existent line, but tracked in diff)
    end
  end
end

---Get a summary of current changes for status line or message
---@param bufnr number
---@return table {renamed: number, deleted: number, created: number}
function M.get_change_summary(bufnr)
  local operations = M.calculate_diff(bufnr)
  local summary = { renamed = 0, deleted = 0, created = 0 }

  for _, op in ipairs(operations) do
    if op.type == "rename" then
      summary.renamed = summary.renamed + 1
    elseif op.type == "delete" then
      summary.deleted = summary.deleted + 1
    elseif op.type == "create" then
      summary.created = summary.created + 1
    end
  end

  return summary
end

-- ============================================================================
-- Diff Calculation
-- ============================================================================

---Calculate operations needed based on buffer changes
---@param bufnr number Buffer number
---@return DiredEditOperation[] operations
function M.calculate_diff(bufnr)
  local snapshot = snapshots[bufnr]
  if not snapshot then
    return {}
  end

  local columns = config.get().columns
  local operations = {}

  -- Get current buffer lines
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local current_line_count = #lines

  -- Track which original entries we've seen
  local seen_originals = {}

  -- Process each line
  for line_num = HEADER_LINES + 1, current_line_count do
    local line = lines[line_num]
    local original_entry = snapshot.entries[line_num]

    if original_entry then
      -- This line had an original entry
      local new_name = M.parse_line_with_context(line, original_entry, columns)

      if new_name == nil then
        -- Line was deleted or emptied - this is a delete operation
        table.insert(operations, {
          type = "delete",
          source = original_entry.path,
          dest = nil,
        })
      elseif new_name ~= original_entry.name then
        -- Name changed - this is a rename operation
        local new_path = utils.join(snapshot.path, new_name)
        table.insert(operations, {
          type = "rename",
          source = original_entry.path,
          dest = new_path,
        })
      end
      -- else: name unchanged, no operation needed

      seen_originals[line_num] = true
    else
      -- This is a new line (line_num > original count or inserted)
      local new_name, entry_type = M.parse_line_name(line, columns)
      if new_name and new_name ~= "" then
        local new_path = utils.join(snapshot.path, new_name)
        table.insert(operations, {
          type = "create",
          source = nil,
          dest = new_path,
        })
      end
    end
  end

  -- Check for deleted lines (original entries not in current buffer)
  for line_num, entry in pairs(snapshot.entries) do
    if not seen_originals[line_num] and line_num > current_line_count then
      -- This entry's line was deleted
      table.insert(operations, {
        type = "delete",
        source = entry.path,
        dest = nil,
      })
    end
  end

  return operations
end

-- ============================================================================
-- Edit Mode Management
-- ============================================================================

---Check if buffer is in edit mode
---@param bufnr number
---@return boolean
function M.is_editing(bufnr)
  return edit_mode[bufnr] == true
end

---Enter edit mode for a buffer
---@param bufnr number
---@param buf_data table DiredBuffer data
function M.enter_edit_mode(bufnr, buf_data)
  if edit_mode[bufnr] then
    return -- Already in edit mode
  end

  -- Create snapshot
  M.create_snapshot(bufnr, buf_data)

  -- Clear marks to avoid confusion
  buf_data.marks = {}

  -- Enable editing
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].buftype = "acwrite" -- Allow :write to trigger autocmd

  edit_mode[bufnr] = true

  -- Set up autocmd for saving
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      M.apply_changes(bufnr)
    end,
  })

  -- Set up real-time highlighting on text changes (debounced for performance)
  local autocmd_id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    callback = function()
      -- Cancel previous timer if exists
      if highlight_timers[bufnr] then
        vim.fn.timer_stop(highlight_timers[bufnr])
      end
      -- Schedule debounced highlight update
      highlight_timers[bufnr] = vim.fn.timer_start(HIGHLIGHT_DEBOUNCE_MS, function()
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(bufnr) and edit_mode[bufnr] then
            M.update_highlights(bufnr)
          end
        end)
      end)
    end,
  })
  change_autocmds[bufnr] = autocmd_id

  -- Initial highlight update (immediate)
  M.update_highlights(bufnr)

  vim.notify("dired: Edit mode enabled. :w to apply, :e! to cancel. Changes highlighted in real-time.", vim.log.levels.INFO)
end

---Clean up edit mode resources
---@param bufnr number
local function cleanup_edit_mode(bufnr)
  -- Clear highlight namespace
  vim.api.nvim_buf_clear_namespace(bufnr, EDIT_NS, 0, -1)

  -- Remove TextChanged autocmd
  if change_autocmds[bufnr] then
    pcall(vim.api.nvim_del_autocmd, change_autocmds[bufnr])
    change_autocmds[bufnr] = nil
  end

  -- Cancel any pending highlight timer
  if highlight_timers[bufnr] then
    vim.fn.timer_stop(highlight_timers[bufnr])
    highlight_timers[bufnr] = nil
  end

  -- Clear snapshot
  M.clear_snapshot(bufnr)

  -- Reset buffer options
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].buftype = "nofile"

  edit_mode[bufnr] = nil
end

---Exit edit mode without applying changes
---@param bufnr number
---@param buf_data table DiredBuffer data
function M.cancel_edit_mode(bufnr, buf_data)
  if not edit_mode[bufnr] then
    return
  end

  cleanup_edit_mode(bufnr)

  -- Re-render to restore original state
  local buffer = require("dired.buffer")
  buffer.refresh(bufnr)

  vim.notify("dired: Edit cancelled", vim.log.levels.INFO)
end

-- ============================================================================
-- Operation Execution
-- ============================================================================

---Apply all pending changes to the filesystem
---@param bufnr number
function M.apply_changes(bufnr)
  local buffer = require("dired.buffer")
  local buf_data = buffer.buffers[bufnr]

  if not buf_data then
    vim.notify("dired: Invalid buffer", vim.log.levels.ERROR)
    return
  end

  local operations = M.calculate_diff(bufnr)

  if #operations == 0 then
    vim.notify("dired: No changes to apply", vim.log.levels.INFO)
    M.exit_edit_mode(bufnr, buf_data)
    return
  end

  -- Show confirmation
  local summary = M.format_operations_summary(operations)
  vim.ui.select({ "Apply", "Cancel" }, {
    prompt = "Apply changes?\n" .. summary,
  }, function(choice)
    if choice == "Apply" then
      M.execute_operations(bufnr, buf_data, operations)
    else
      vim.notify("dired: Changes not applied", vim.log.levels.INFO)
    end
  end)
end

---Format operations for display
---@param operations DiredEditOperation[]
---@return string
function M.format_operations_summary(operations)
  local lines = {}

  for _, op in ipairs(operations) do
    if op.type == "rename" then
      local src_name = utils.basename(op.source)
      local dest_name = utils.basename(op.dest)
      table.insert(lines, string.format("  Rename: %s -> %s", src_name, dest_name))
    elseif op.type == "delete" then
      local name = utils.basename(op.source)
      table.insert(lines, string.format("  Delete: %s", name))
    elseif op.type == "create" then
      local name = utils.basename(op.dest)
      table.insert(lines, string.format("  Create: %s", name))
    end
  end

  return table.concat(lines, "\n")
end

---Show a visual diff preview in a floating window
---@param bufnr number
---@return number|nil preview_bufnr, number|nil preview_win
function M.show_diff_preview(bufnr)
  local operations = M.calculate_diff(bufnr)

  if #operations == 0 then
    vim.notify("dired: No changes to preview", vim.log.levels.INFO)
    return nil, nil
  end

  -- Build preview content
  local lines = {
    "Pending Changes:",
    string.rep("-", 40),
    "",
  }

  local hl_lines = {} -- {line_num, hl_group}

  for _, op in ipairs(operations) do
    local line_num = #lines + 1

    if op.type == "rename" then
      local src_name = utils.basename(op.source)
      local dest_name = utils.basename(op.dest)
      table.insert(lines, string.format("  [RENAME] %s", src_name))
      table.insert(hl_lines, { line_num - 1, "DiredEditChanged" })
      table.insert(lines, string.format("        -> %s", dest_name))
      table.insert(hl_lines, { #lines - 1, "DiredEditNew" })
    elseif op.type == "delete" then
      local name = utils.basename(op.source)
      table.insert(lines, string.format("  [DELETE] %s", name))
      table.insert(hl_lines, { line_num - 1, "DiredEditDeleted" })
    elseif op.type == "create" then
      local name = utils.basename(op.dest)
      table.insert(lines, string.format("  [CREATE] %s", name))
      table.insert(hl_lines, { line_num - 1, "DiredEditNew" })
    end
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("-", 40))
  table.insert(lines, string.format("Total: %d operation(s)", #operations))
  table.insert(lines, "")
  table.insert(lines, "Press :w to apply, :e! to cancel")

  -- Calculate window size
  local max_width = 0
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, #line)
  end
  local width = math.min(max_width + 4, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.6))

  -- Create preview buffer
  local preview_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.bo[preview_buf].swapfile = false

  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
  vim.bo[preview_buf].modifiable = false

  -- Apply highlights
  local preview_ns = vim.api.nvim_create_namespace("dired_preview")
  for _, hl in ipairs(hl_lines) do
    vim.api.nvim_buf_add_highlight(preview_buf, preview_ns, hl[2], hl[1], 0, -1)
  end

  -- Create floating window
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local preview_win = vim.api.nvim_open_win(preview_buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Diff Preview ",
    title_pos = "center",
  })

  -- Auto-close after delay or on any key
  vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_close(preview_win, true)
    end
  end, 5000)

  return preview_buf, preview_win
end

---Validate an operation before executing
---@param op DiredEditOperation
---@return boolean valid, string|nil error
local function validate_operation(op)
  if op.type == "rename" then
    -- Check source exists
    if not utils.exists(op.source) then
      return false, string.format("Source does not exist: %s", utils.basename(op.source))
    end
    -- Check destination doesn't exist (unless overwriting)
    if utils.exists(op.dest) then
      return false, string.format("Destination already exists: %s", utils.basename(op.dest))
    end
    -- Check destination directory exists
    local dest_parent = utils.parent(op.dest)
    if not utils.exists(dest_parent) then
      return false, string.format("Destination directory does not exist: %s", dest_parent)
    end
    -- Check for invalid characters in new name
    local new_name = utils.basename(op.dest)
    if new_name:match("[/\0]") then
      return false, string.format("Invalid characters in filename: %s", new_name)
    end

  elseif op.type == "delete" then
    -- Check source exists
    if not utils.exists(op.source) then
      return false, string.format("File does not exist: %s", utils.basename(op.source))
    end

  elseif op.type == "create" then
    -- Check destination doesn't exist
    if utils.exists(op.dest) then
      return false, string.format("File already exists: %s", utils.basename(op.dest))
    end
    -- Check parent directory exists
    local dest_parent = utils.parent(op.dest)
    if not utils.exists(dest_parent) then
      return false, string.format("Parent directory does not exist: %s", dest_parent)
    end
    -- Check for invalid characters
    local new_name = utils.basename(op.dest)
    if new_name:match("[/\0]") then
      return false, string.format("Invalid characters in filename: %s", new_name)
    end
  end

  return true, nil
end

---Execute filesystem operations
---@param bufnr number
---@param buf_data table
---@param operations DiredEditOperation[]
function M.execute_operations(bufnr, buf_data, operations)
  local errors = {}
  local warnings = {}
  local successful = 0
  local lsp = require("dired.lsp")
  local cfg = config.get() or {}

  -- Validate all operations first
  for _, op in ipairs(operations) do
    local valid, err = validate_operation(op)
    if not valid then
      table.insert(warnings, err)
    end
  end

  -- Show warnings if any
  if #warnings > 0 then
    vim.notify("dired: Validation warnings:\n" .. table.concat(warnings, "\n"), vim.log.levels.WARN)
  end

  for _, op in ipairs(operations) do
    local ok, err
    local op_name = utils.basename(op.source or op.dest or "unknown")

    if op.type == "rename" then
      -- Skip if source doesn't exist anymore (might have been renamed already)
      if not utils.exists(op.source) then
        table.insert(errors, string.format("Rename skipped (source gone): %s", op_name))
        goto continue
      end

      -- Try LSP rename first if enabled
      if cfg.lsp and cfg.lsp.enabled then
        lsp.will_rename_files(op.source, op.dest, function(lsp_ok)
          -- Continue with filesystem rename regardless of LSP result
        end)
      end

      -- Use git mv if in git repo and configured
      if buf_data.git_root and cfg.git and cfg.git.use_git_mv then
        ok, err = M.git_mv(op.source, op.dest)
        if not ok then
          err = string.format("git mv failed for '%s': %s", op_name, err or "unknown")
        end
      else
        ok, err = fs.rename(op.source, op.dest)
        if not ok then
          err = string.format("Rename failed for '%s': %s", op_name, err or "permission denied or invalid path")
        end
      end

      -- Notify LSP after rename
      if ok and cfg.lsp and cfg.lsp.enabled then
        lsp.did_rename_files(op.source, op.dest)
      end

    elseif op.type == "delete" then
      -- Skip if already deleted
      if not utils.exists(op.source) then
        table.insert(warnings, string.format("Already deleted: %s", op_name))
        goto continue
      end

      -- Check if it's a directory
      local stat = vim.loop.fs_stat(op.source)
      local is_dir = stat and stat.type == "directory"

      -- Use git rm if in git repo and configured
      if buf_data.git_root and cfg.git and cfg.git.use_git_rm then
        ok, err = M.git_rm(op.source)
        if not ok then
          err = string.format("git rm failed for '%s': %s", op_name, err or "unknown")
        end
      else
        if is_dir then
          ok, err = fs.delete_recursive(op.source)
        else
          ok, err = fs.delete(op.source)
        end
        if not ok then
          err = string.format("Delete failed for '%s': %s", op_name, err or "permission denied")
        end
      end

      -- Notify LSP after delete
      if ok and cfg.lsp and cfg.lsp.enabled then
        lsp.did_delete_files(op.source)
      end

    elseif op.type == "create" then
      -- Skip if already exists
      if utils.exists(op.dest) then
        table.insert(warnings, string.format("Already exists: %s", utils.basename(op.dest)))
        goto continue
      end

      -- Create as file by default, directory if ends with /
      if op.dest:sub(-1) == "/" then
        ok, err = fs.mkdir(op.dest:sub(1, -2))
        if not ok then
          err = string.format("Create directory failed for '%s': %s", utils.basename(op.dest), err or "permission denied")
        end
      else
        ok, err = fs.touch(op.dest)
        if not ok then
          err = string.format("Create file failed for '%s': %s", utils.basename(op.dest), err or "permission denied")
        end
      end

      -- Notify LSP after create
      if ok and cfg.lsp and cfg.lsp.enabled then
        lsp.did_create_files(op.dest)
      end
    end

    if ok then
      successful = successful + 1
    elseif err then
      table.insert(errors, err)
    end

    ::continue::
  end

  -- Exit edit mode
  M.exit_edit_mode(bufnr, buf_data)

  -- Report results
  if #errors > 0 then
    vim.notify(
      string.format("dired: %d of %d operations failed:\n%s", #errors, #operations, table.concat(errors, "\n")),
      vim.log.levels.ERROR
    )
  elseif successful > 0 then
    vim.notify(string.format("dired: Successfully applied %d operation(s)", successful), vim.log.levels.INFO)
  else
    vim.notify("dired: No operations were applied", vim.log.levels.WARN)
  end
end

---Exit edit mode after applying changes
---@param bufnr number
---@param buf_data table
function M.exit_edit_mode(bufnr, buf_data)
  cleanup_edit_mode(bufnr)

  -- Refresh buffer
  local buffer = require("dired.buffer")
  buffer.refresh(bufnr)
end

-- ============================================================================
-- Git Operations (sync wrappers for edit mode)
-- ============================================================================

---Synchronous git mv
---@param src string
---@param dest string
---@return boolean ok, string|nil err
function M.git_mv(src, dest)
  local repo_root = git.find_repo_root(src)
  if not repo_root then
    return fs.rename(src, dest) -- Fallback to regular rename
  end

  local result = vim.fn.system({ "git", "-C", repo_root, "mv", src, dest })
  if vim.v.shell_error ~= 0 then
    return false, "git mv failed: " .. result
  end

  git.invalidate_cache(repo_root)
  return true, nil
end

---Synchronous git rm
---@param path string
---@return boolean ok, string|nil err
function M.git_rm(path)
  local repo_root = git.find_repo_root(path)
  if not repo_root then
    return fs.delete(path) -- Fallback to regular delete
  end

  local result = vim.fn.system({ "git", "-C", repo_root, "rm", "-f", path })
  if vim.v.shell_error ~= 0 then
    return false, "git rm failed: " .. result
  end

  git.invalidate_cache(repo_root)
  return true, nil
end

return M
