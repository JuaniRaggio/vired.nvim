---@class PathPickerOpts
---@field prompt? string Prompt text
---@field default? string Default path value
---@field cwd? string Working directory for relative paths
---@field on_select fun(path: string) Callback when path is selected
---@field on_cancel? fun() Callback when cancelled
---@field create_if_missing? boolean Offer to create non-existent paths

---@class PathPickerSource
---@field name string Source identifier
---@field icon string Icon to display
---@field get_items fun(input: string, cwd: string): string[] Function to get items

local M = {}

local fs = require("dired.fs")
local utils = require("dired.utils")
local config = require("dired.config")

---@type number|nil Current picker buffer
local picker_buf = nil
---@type number|nil Current picker window
local picker_win = nil
---@type number|nil Results buffer
local results_buf = nil
---@type number|nil Results window
local results_win = nil
---@type number|nil Preview buffer (directory contents)
local preview_buf = nil
---@type number|nil Preview window
local preview_win = nil

---@type PathPickerOpts|nil Current picker options
local picker_opts = nil
---@type table[] Current completion results {str, score, positions, source}
local results = {}
---@type number Selected result index (1-based)
local selected_idx = 1
---@type string|nil Last input for detecting backspace at boundary
local last_input = nil

-- ============================================================================
-- Sources
-- ============================================================================

---@type table<string, PathPickerSource>
local sources = {}

---Register a source
---@param name string
---@param source PathPickerSource
function M.register_source(name, source)
  sources[name] = source
end

---Filesystem source - directories in current path
sources.filesystem = {
  name = "filesystem",
  icon = "",
  get_items = function(input, cwd)
    local items = {}

    -- Expand and normalize input
    local path = utils.expand(input)
    if not utils.is_absolute(path) then
      path = utils.join(cwd, path)
    end

    local dir, prefix
    if input:sub(-1) == "/" then
      dir = path
      prefix = ""
    else
      dir = utils.parent(path)
      prefix = utils.basename(path)
    end

    if not fs.exists(dir) then
      return items
    end

    local entries, _ = fs.readdir(dir, config.get().path_picker.show_hidden)
    if not entries then
      return items
    end

    for _, entry in ipairs(entries) do
      local item_path = utils.join(dir, entry.name)
      if entry.type == "directory" then
        item_path = item_path .. "/"
      end
      table.insert(items, item_path)
    end

    return items
  end,
}

---Recent directories source - from oldfiles
sources.recent = {
  name = "recent",
  icon = "",
  get_items = function(input, cwd)
    local items = {}
    local seen = {}

    -- Get directories from oldfiles
    local oldfiles = vim.v.oldfiles or {}
    for _, file in ipairs(oldfiles) do
      local dir = utils.parent(file)
      if dir and not seen[dir] and fs.is_dir(dir) then
        seen[dir] = true
        table.insert(items, dir .. "/")
        if #items >= 50 then
          break
        end
      end
    end

    return items
  end,
}

---Buffers source - directories of open buffers
sources.buffers = {
  name = "buffers",
  icon = "",
  get_items = function(input, cwd)
    local items = {}
    local seen = {}

    local bufs = vim.api.nvim_list_bufs()
    for _, buf in ipairs(bufs) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name and name ~= "" then
          local dir = utils.parent(name)
          if dir and not seen[dir] and fs.is_dir(dir) then
            seen[dir] = true
            table.insert(items, dir .. "/")
          end
        end
      end
    end

    return items
  end,
}

---Bookmarks/Projects source - bookmarked project directories
sources.bookmarks = {
  name = "bookmarks",
  icon = "",
  get_items = function(input, cwd)
    local ok, projects = pcall(require, "dired.projects")
    if not ok then
      return {}
    end

    local items = {}
    local project_paths = projects.list_paths("recent")

    for _, path in ipairs(project_paths) do
      -- Add trailing slash to indicate directory
      if path:sub(-1) ~= "/" then
        path = path .. "/"
      end
      table.insert(items, path)
    end

    return items
  end,
}

-- ============================================================================
-- Fuzzy Matching Integration
-- ============================================================================

---Get completions from all enabled sources with fuzzy matching
---@param input string Current input
---@param cwd string Working directory
---@return table[] results {str, score, positions, source}
local function get_completions(input, cwd)
  local cfg = config.get()
  local enabled_sources = cfg.path_picker.sources or { "filesystem" }
  local all_items = {}

  -- Gather items from all sources
  for _, source_name in ipairs(enabled_sources) do
    local source = sources[source_name]
    if source then
      local items = source.get_items(input, cwd)
      for _, item in ipairs(items) do
        table.insert(all_items, { path = item, source = source_name })
      end
    end
  end

  -- Extract search pattern from input
  local pattern = ""
  if input:sub(-1) ~= "/" then
    pattern = utils.basename(input)
  end

  -- If no pattern, return filesystem items sorted
  if pattern == "" then
    local completions = {}
    for _, item in ipairs(all_items) do
      if item.source == "filesystem" then
        table.insert(completions, {
          str = item.path,
          score = 0,
          positions = {},
          source = item.source,
        })
      end
    end
    -- Sort directories first, then alphabetically
    table.sort(completions, function(a, b)
      local a_is_dir = a.str:sub(-1) == "/"
      local b_is_dir = b.str:sub(-1) == "/"
      if a_is_dir and not b_is_dir then
        return true
      elseif not a_is_dir and b_is_dir then
        return false
      end
      return a.str < b.str
    end)
    return completions
  end

  -- Apply fuzzy matching
  local completions = {}
  for _, item in ipairs(all_items) do
    -- Match against basename for filesystem, full path for others
    local match_str = item.source == "filesystem" and utils.basename(item.path) or item.path
    local score, positions = utils.fuzzy_match(pattern, match_str)

    if score then
      -- Boost score for filesystem source (prioritize current directory)
      if item.source == "filesystem" then
        score = score + 10
      end

      table.insert(completions, {
        str = item.path,
        score = score,
        positions = positions,
        source = item.source,
      })
    end
  end

  -- Sort by score descending
  table.sort(completions, function(a, b)
    return a.score > b.score
  end)

  -- Limit results
  local limit = 20
  if #completions > limit then
    local limited = {}
    for i = 1, limit do
      limited[i] = completions[i]
    end
    return limited
  end

  return completions
end

-- ============================================================================
-- Directory Preview
-- ============================================================================

---Render preview of a directory's contents
---@param dir_path string Directory to preview
local function render_preview(dir_path)
  if not preview_buf or not vim.api.nvim_buf_is_valid(preview_buf) then
    return
  end

  local lines = {}
  local highlights = {}

  if not dir_path or dir_path == "" then
    lines = { "  (no directory selected)" }
  elseif not fs.exists(dir_path) then
    lines = { "  (directory does not exist)" }
  elseif not fs.is_dir(dir_path) then
    -- It's a file, show file info
    local stat = vim.loop.fs_stat(dir_path)
    if stat then
      lines = {
        "  File: " .. utils.basename(dir_path),
        "  Size: " .. utils.format_size(stat.size),
        "  Modified: " .. utils.format_time(stat.mtime.sec),
      }
    end
  else
    -- It's a directory, show contents
    local entries, _ = fs.readdir(dir_path, config.get().path_picker.show_hidden)
    if entries and #entries > 0 then
      for i, entry in ipairs(entries) do
        if i > 20 then
          table.insert(lines, string.format("  ... and %d more", #entries - 20))
          break
        end

        local icon = ""
        local name = entry.name
        local hl_group = "DiredFile"

        if entry.type == "directory" then
          icon = ""
          name = name .. "/"
          hl_group = "DiredDirectory"
        elseif entry.type == "link" then
          icon = ""
          hl_group = "DiredSymlink"
        end

        local line = string.format("  %s %s", icon, name)
        table.insert(lines, line)
        table.insert(highlights, { line = i - 1, hl = hl_group })
      end
    else
      lines = { "  (empty directory)" }
    end
  end

  vim.bo[preview_buf].modifiable = true
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
  vim.bo[preview_buf].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("dired_picker_preview")
  vim.api.nvim_buf_clear_namespace(preview_buf, ns, 0, -1)

  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, preview_buf, ns, hl.hl, hl.line, 0, -1)
  end
end

---Update preview based on current selection
local function update_preview()
  if not results or #results == 0 then
    render_preview(nil)
    return
  end

  if selected_idx <= #results then
    local selected = results[selected_idx]
    render_preview(selected.str)
  else
    -- "Create" option selected
    render_preview(nil)
  end
end

-- ============================================================================
-- UI Rendering
-- ============================================================================

---Get source icon
---@param source_name string
---@return string
local function get_source_icon(source_name)
  local source = sources[source_name]
  return source and source.icon or ""
end

---Render the results window
local function render_results()
  if not results_buf or not vim.api.nvim_buf_is_valid(results_buf) then
    return
  end

  local lines = {}
  local highlights = {}

  for i, result in ipairs(results) do
    local prefix = i == selected_idx and "> " or "  "
    local icon = get_source_icon(result.source)
    local line = prefix .. icon .. " " .. result.str

    table.insert(lines, line)

    -- Highlight matched characters
    if result.positions and #result.positions > 0 then
      local offset = #prefix + #icon + 1 -- account for prefix and icon
      -- Adjust positions for the basename display in the full path
      local basename_start = result.str:find(utils.basename(result.str:gsub("/$", "")), 1, true) or 1
      for _, pos in ipairs(result.positions) do
        local col = offset + basename_start + pos - 2
        table.insert(highlights, {
          line = i - 1,
          col = col,
          end_col = col + 1,
          hl = "DiredPickerMatch",
        })
      end
    end

    -- Highlight selected line
    if i == selected_idx then
      table.insert(highlights, {
        line = i - 1,
        col = 0,
        end_col = #line,
        hl = "DiredPickerSelection",
      })
    end
  end

  -- Add "create" option if path doesn't exist
  if picker_opts and picker_opts.create_if_missing then
    local input = vim.api.nvim_buf_get_lines(picker_buf, 0, 1, false)[1] or ""
    local path = utils.expand(input)
    if not utils.is_absolute(path) and picker_opts.cwd then
      path = utils.join(picker_opts.cwd, path)
    end

    if input ~= "" and not fs.exists(path) then
      local create_idx = #lines + 1
      local prefix = create_idx == selected_idx and "> " or "  "
      local create_line = prefix .. " [Create: " .. path .. "]"
      table.insert(lines, create_line)

      table.insert(highlights, {
        line = create_idx - 1,
        col = 0,
        end_col = #create_line,
        hl = "DiredPickerCreate",
      })

      if create_idx == selected_idx then
        table.insert(highlights, {
          line = create_idx - 1,
          col = 0,
          end_col = #create_line,
          hl = "DiredPickerSelection",
        })
      end
    end
  end

  if #lines == 0 then
    lines = { "  (no matches)" }
  end

  vim.bo[results_buf].modifiable = true
  vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
  vim.bo[results_buf].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("dired_picker")
  vim.api.nvim_buf_clear_namespace(results_buf, ns, 0, -1)

  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, results_buf, ns, hl.hl, hl.line, hl.col, hl.end_col)
  end

  -- Resize results window based on content
  local height = math.min(#lines, 15)
  if results_win and vim.api.nvim_win_is_valid(results_win) then
    vim.api.nvim_win_set_height(results_win, height)
  end
end

---Update completions based on current input
local function update_completions()
  if not picker_buf or not vim.api.nvim_buf_is_valid(picker_buf) then
    return
  end

  local input = vim.api.nvim_buf_get_lines(picker_buf, 0, 1, false)[1] or ""
  local cwd = picker_opts and picker_opts.cwd or vim.loop.cwd()

  results = get_completions(input, cwd)
  selected_idx = 1

  render_results()
  update_preview()
end

-- ============================================================================
-- Navigation
-- ============================================================================

---Get total number of selectable items (including create option)
---@return number
local function get_max_idx()
  local max_idx = #results

  if picker_opts and picker_opts.create_if_missing and picker_buf then
    local input = vim.api.nvim_buf_get_lines(picker_buf, 0, 1, false)[1] or ""
    local path = utils.expand(input)
    if not utils.is_absolute(path) and picker_opts.cwd then
      path = utils.join(picker_opts.cwd, path)
    end
    if input ~= "" and not fs.exists(path) then
      max_idx = max_idx + 1
    end
  end

  return max_idx
end

---Select next result
local function select_next()
  local max_idx = get_max_idx()
  if max_idx == 0 then
    return
  end

  if selected_idx < max_idx then
    selected_idx = selected_idx + 1
  else
    selected_idx = 1
  end
  render_results()
  update_preview()
end

---Select previous result
local function select_prev()
  local max_idx = get_max_idx()
  if max_idx == 0 then
    return
  end

  if selected_idx > 1 then
    selected_idx = selected_idx - 1
  else
    selected_idx = max_idx
  end
  render_results()
  update_preview()
end

---Complete with selected result (Tab behavior - complete directory by directory)
local function complete_selected()
  if not picker_buf or #results == 0 or selected_idx > #results then
    return
  end

  local selected = results[selected_idx]
  local path = selected.str

  -- If it's a directory, complete it and stay in picker to continue navigating
  if path:sub(-1) == "/" then
    vim.api.nvim_buf_set_lines(picker_buf, 0, 1, false, { path })
    -- Move cursor to end
    if picker_win and vim.api.nvim_win_is_valid(picker_win) then
      vim.api.nvim_win_set_cursor(picker_win, { 1, #path })
    end
    update_completions()
  else
    -- It's a file, complete it
    vim.api.nvim_buf_set_lines(picker_buf, 0, 1, false, { path })
    if picker_win and vim.api.nvim_win_is_valid(picker_win) then
      vim.api.nvim_win_set_cursor(picker_win, { 1, #path })
    end
    update_completions()
  end
end

---Go up one directory (like backspace at boundary in vertico)
local function go_up_directory()
  if not picker_buf then
    return
  end

  local input = vim.api.nvim_buf_get_lines(picker_buf, 0, 1, false)[1] or ""

  -- Remove trailing slash if present
  if input:sub(-1) == "/" then
    input = input:sub(1, -2)
  end

  -- Go to parent
  local parent = utils.parent(input)
  if parent and parent ~= input then
    parent = parent .. "/"
    vim.api.nvim_buf_set_lines(picker_buf, 0, 1, false, { parent })
    if picker_win and vim.api.nvim_win_is_valid(picker_win) then
      vim.api.nvim_win_set_cursor(picker_win, { 1, #parent })
    end
    update_completions()
  end
end

---Handle backspace with smart directory navigation
local function handle_backspace()
  if not picker_buf or not picker_win then
    return
  end

  local input = vim.api.nvim_buf_get_lines(picker_buf, 0, 1, false)[1] or ""
  local cursor = vim.api.nvim_win_get_cursor(picker_win)
  local col = cursor[2]

  -- If cursor is right after a slash or at the end of a path ending in slash,
  -- go up one directory instead of just deleting the slash
  if input:sub(-1) == "/" and col == #input then
    go_up_directory()
    return
  end

  -- Check if we're about to delete a slash (cursor is right after it)
  if col > 0 and input:sub(col, col) == "/" then
    go_up_directory()
    return
  end

  -- Normal backspace - let Neovim handle it
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "n", false)
end

---Confirm selection
local function confirm()
  if not picker_buf or not picker_opts then
    return
  end

  local input = vim.api.nvim_buf_get_lines(picker_buf, 0, 1, false)[1] or ""
  local path = utils.expand(input)
  if not utils.is_absolute(path) and picker_opts.cwd then
    path = utils.join(picker_opts.cwd, path)
  end

  -- Check if selecting "create" option
  local is_create = selected_idx > #results and picker_opts.create_if_missing and not fs.exists(path)

  if is_create then
    -- Confirm creation
    vim.ui.select({ "Yes", "No" }, { prompt = "Create " .. path .. "?" }, function(choice)
      if choice == "Yes" then
        local is_dir = path:sub(-1) == "/"
        local ok, err
        if is_dir then
          ok, err = fs.mkdir(path)
        else
          ok, err = fs.touch(path)
        end

        if ok then
          local on_select = picker_opts.on_select
          M.close()
          on_select(path)
        else
          vim.notify("dired: " .. err, vim.log.levels.ERROR)
        end
      end
    end)
  else
    -- Check if it's a directory - open dired instead of selecting
    if fs.is_dir(path) then
      M.close()
      -- Open dired in the selected directory
      local dired_ok, dired = pcall(require, "dired")
      if dired_ok and dired.open then
        dired.open(path)
      else
        -- Fallback: use netrw or just notify
        vim.cmd("edit " .. vim.fn.fnameescape(path))
      end
    else
      local on_select = picker_opts.on_select
      M.close()
      on_select(path)
    end
  end
end

---Cancel picker
local function cancel()
  local on_cancel = picker_opts and picker_opts.on_cancel
  M.close()
  if on_cancel then
    on_cancel()
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

---Close the picker
function M.close()
  if picker_win and vim.api.nvim_win_is_valid(picker_win) then
    vim.api.nvim_win_close(picker_win, true)
  end
  if results_win and vim.api.nvim_win_is_valid(results_win) then
    vim.api.nvim_win_close(results_win, true)
  end
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_close(preview_win, true)
  end
  if picker_buf and vim.api.nvim_buf_is_valid(picker_buf) then
    vim.api.nvim_buf_delete(picker_buf, { force = true })
  end
  if results_buf and vim.api.nvim_buf_is_valid(results_buf) then
    vim.api.nvim_buf_delete(results_buf, { force = true })
  end
  if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
    vim.api.nvim_buf_delete(preview_buf, { force = true })
  end

  picker_buf = nil
  picker_win = nil
  results_buf = nil
  results_win = nil
  preview_buf = nil
  preview_win = nil
  picker_opts = nil
  results = {}
  selected_idx = 1
  last_input = nil
end

---Open the path picker
---@param opts PathPickerOpts
function M.open(opts)
  -- Close existing picker if any
  M.close()

  picker_opts = opts
  picker_opts.cwd = opts.cwd or vim.loop.cwd()
  picker_opts.create_if_missing = opts.create_if_missing ~= false

  local cfg = config.get()

  -- Calculate window dimensions
  local width = math.floor(vim.o.columns * 0.6)
  local height = 1
  local results_height = 15
  local row = math.floor((vim.o.lines - height - results_height - 4) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create input buffer
  picker_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[picker_buf].buftype = "nofile"

  -- Set initial value
  local default = opts.default or opts.cwd .. "/"
  vim.api.nvim_buf_set_lines(picker_buf, 0, -1, false, { default })

  -- Create input window
  local prompt = opts.prompt or "Path: "
  picker_win = vim.api.nvim_open_win(picker_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = cfg.float.border,
    title = " " .. prompt .. " ",
    title_pos = "left",
  })

  -- Create results buffer
  results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[results_buf].buftype = "nofile"
  vim.bo[results_buf].modifiable = false

  -- Create results window (left side)
  local results_width = math.floor(width * 0.5)
  local preview_width = width - results_width - 1

  results_win = vim.api.nvim_open_win(results_buf, false, {
    relative = "editor",
    width = results_width,
    height = results_height,
    row = row + height + 2,
    col = col,
    style = "minimal",
    border = cfg.float.border,
  })

  -- Create preview buffer
  preview_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].modifiable = false

  -- Create preview window (right side)
  preview_win = vim.api.nvim_open_win(preview_buf, false, {
    relative = "editor",
    width = preview_width,
    height = results_height,
    row = row + height + 2,
    col = col + results_width + 1,
    style = "minimal",
    border = cfg.float.border,
    title = " Preview ",
    title_pos = "center",
  })

  -- Setup keymaps for insert mode
  local kopts = { buffer = picker_buf, noremap = true, silent = true }

  vim.keymap.set("i", "<CR>", confirm, kopts)
  vim.keymap.set("i", "<Esc>", cancel, kopts)
  vim.keymap.set("i", "<C-c>", cancel, kopts)
  vim.keymap.set("i", "<Tab>", complete_selected, kopts)
  vim.keymap.set("i", "<C-n>", select_next, kopts)
  vim.keymap.set("i", "<C-p>", select_prev, kopts)
  vim.keymap.set("i", "<Down>", select_next, kopts)
  vim.keymap.set("i", "<Up>", select_prev, kopts)
  vim.keymap.set("i", "<BS>", handle_backspace, kopts)

  -- Normal mode mappings
  vim.keymap.set("n", "<CR>", confirm, kopts)
  vim.keymap.set("n", "<Esc>", cancel, kopts)
  vim.keymap.set("n", "q", cancel, kopts)
  vim.keymap.set("n", "<Tab>", complete_selected, kopts)
  vim.keymap.set("n", "j", select_next, kopts)
  vim.keymap.set("n", "k", select_prev, kopts)

  -- Auto-update on text change with debounce
  local debounced_update = utils.debounce(update_completions, 50)
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = picker_buf,
    callback = debounced_update,
  })

  -- Close on buffer leave
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = picker_buf,
    once = true,
    callback = function()
      vim.schedule(cancel)
    end,
  })

  -- Enter insert mode and position cursor at end
  vim.cmd("startinsert!")
  vim.api.nvim_win_set_cursor(picker_win, { 1, #default })

  -- Initial completions
  update_completions()
end

---Get registered sources
---@return table<string, PathPickerSource>
function M.get_sources()
  return sources
end

return M
