---@class PathPickerOpts
---@field prompt? string Prompt text
---@field default? string Default path value
---@field cwd? string Working directory for relative paths
---@field on_select fun(path: string) Callback when path is selected
---@field on_cancel? fun() Callback when cancelled
---@field create_if_missing? boolean Offer to create non-existent paths

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

---@type PathPickerOpts|nil Current picker options
local picker_opts = nil
---@type string[] Current completion results
local results = {}
---@type number Selected result index (1-based)
local selected_idx = 1

---Get completions for a path
---@param input string Current input
---@param cwd string Working directory
---@return string[] completions
local function get_completions(input, cwd)
  local completions = {}

  -- Expand and normalize input
  local path = utils.expand(input)
  if not utils.is_absolute(path) then
    path = utils.join(cwd, path)
  end

  local dir, prefix
  if input:sub(-1) == "/" then
    -- Input ends with /, list contents of that directory
    dir = path
    prefix = ""
  else
    -- Get parent directory and filter by prefix
    dir = utils.parent(path)
    prefix = utils.basename(path):lower()
  end

  if not fs.exists(dir) then
    return completions
  end

  -- Read directory contents
  local entries, err = fs.readdir(dir, config.get().path_picker.show_hidden)
  if err then
    return completions
  end

  for _, entry in ipairs(entries) do
    local name_lower = entry.name:lower()

    -- Filter by prefix (simple prefix matching for v1)
    if prefix == "" or name_lower:sub(1, #prefix) == prefix then
      local completion = utils.join(dir, entry.name)
      if entry.type == "directory" then
        completion = completion .. "/"
      end
      table.insert(completions, completion)
    end
  end

  return completions
end

---Render the results window
local function render_results()
  if not results_buf or not vim.api.nvim_buf_is_valid(results_buf) then
    return
  end

  local lines = {}
  local cfg = config.get()

  for i, result in ipairs(results) do
    local prefix = i == selected_idx and "> " or "  "
    table.insert(lines, prefix .. result)
  end

  -- Add "create" option if path doesn't exist
  if picker_opts and picker_opts.create_if_missing then
    local input = vim.api.nvim_buf_get_lines(picker_buf, 0, 1, false)[1] or ""
    local path = utils.expand(input)
    if not utils.is_absolute(path) and picker_opts.cwd then
      path = utils.join(picker_opts.cwd, path)
    end

    if input ~= "" and not fs.exists(path) then
      local create_line = "  [Create: " .. path .. "]"
      table.insert(lines, create_line)
      -- If no results and we have a create option, select it
      if #results == 0 then
        selected_idx = 1
        lines[1] = "> " .. lines[1]:sub(3)
      end
    end
  end

  if #lines == 0 then
    lines = { "  (no matches)" }
  end

  vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("dired_picker")
  vim.api.nvim_buf_clear_namespace(results_buf, ns, 0, -1)

  for i, line in ipairs(lines) do
    if line:sub(1, 1) == ">" then
      vim.api.nvim_buf_add_highlight(results_buf, ns, "DiredPickerSelection", i - 1, 0, -1)
    end
    if line:match("%[Create:") then
      vim.api.nvim_buf_add_highlight(results_buf, ns, "DiredPickerCreate", i - 1, 0, -1)
    end
  end

  -- Resize results window based on content
  local height = math.min(#lines, 10)
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
end

---Select next result
local function select_next()
  local max_idx = #results
  if picker_opts and picker_opts.create_if_missing then
    local input = vim.api.nvim_buf_get_lines(picker_buf, 0, 1, false)[1] or ""
    local path = utils.expand(input)
    if not utils.is_absolute(path) and picker_opts.cwd then
      path = utils.join(picker_opts.cwd, path)
    end
    if input ~= "" and not fs.exists(path) then
      max_idx = max_idx + 1 -- For "create" option
    end
  end

  if selected_idx < max_idx then
    selected_idx = selected_idx + 1
  else
    selected_idx = 1
  end
  render_results()
end

---Select previous result
local function select_prev()
  local max_idx = #results
  if picker_opts and picker_opts.create_if_missing then
    local input = vim.api.nvim_buf_get_lines(picker_buf, 0, 1, false)[1] or ""
    local path = utils.expand(input)
    if not utils.is_absolute(path) and picker_opts.cwd then
      path = utils.join(picker_opts.cwd, path)
    end
    if input ~= "" and not fs.exists(path) then
      max_idx = max_idx + 1
    end
  end

  if selected_idx > 1 then
    selected_idx = selected_idx - 1
  else
    selected_idx = max_idx
  end
  render_results()
end

---Complete with selected result
local function complete_selected()
  if not picker_buf or #results == 0 then
    return
  end

  if selected_idx <= #results then
    local selected = results[selected_idx]
    vim.api.nvim_buf_set_lines(picker_buf, 0, 1, false, { selected })
    -- Move cursor to end
    vim.api.nvim_win_set_cursor(picker_win, { 1, #selected })
    update_completions()
  end
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
        -- Determine if it's a file or directory
        local is_dir = path:sub(-1) == "/"
        local ok, err
        if is_dir then
          ok, err = fs.mkdir(path)
        else
          ok, err = fs.touch(path)
        end

        if ok then
          M.close()
          picker_opts.on_select(path)
        else
          vim.notify("dired: " .. err, vim.log.levels.ERROR)
        end
      end
    end)
  else
    M.close()
    picker_opts.on_select(path)
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

---Close the picker
function M.close()
  if picker_win and vim.api.nvim_win_is_valid(picker_win) then
    vim.api.nvim_win_close(picker_win, true)
  end
  if results_win and vim.api.nvim_win_is_valid(results_win) then
    vim.api.nvim_win_close(results_win, true)
  end
  if picker_buf and vim.api.nvim_buf_is_valid(picker_buf) then
    vim.api.nvim_buf_delete(picker_buf, { force = true })
  end
  if results_buf and vim.api.nvim_buf_is_valid(results_buf) then
    vim.api.nvim_buf_delete(results_buf, { force = true })
  end

  picker_buf = nil
  picker_win = nil
  results_buf = nil
  results_win = nil
  picker_opts = nil
  results = {}
  selected_idx = 1
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
  local results_height = 10
  local row = math.floor((vim.o.lines - height - results_height - 4) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create input buffer
  picker_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[picker_buf].buftype = "prompt"
  vim.fn.prompt_setprompt(picker_buf, "")

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

  -- Create results window
  results_win = vim.api.nvim_open_win(results_buf, false, {
    relative = "editor",
    width = width,
    height = results_height,
    row = row + height + 2,
    col = col,
    style = "minimal",
    border = cfg.float.border,
  })

  -- Setup keymaps
  local kopts = { buffer = picker_buf, noremap = true, silent = true }

  vim.keymap.set("i", "<CR>", confirm, kopts)
  vim.keymap.set("i", "<Esc>", cancel, kopts)
  vim.keymap.set("i", "<C-c>", cancel, kopts)
  vim.keymap.set("i", "<Tab>", complete_selected, kopts)
  vim.keymap.set("i", "<C-n>", select_next, kopts)
  vim.keymap.set("i", "<C-p>", select_prev, kopts)
  vim.keymap.set("i", "<Down>", select_next, kopts)
  vim.keymap.set("i", "<Up>", select_prev, kopts)

  -- Normal mode mappings
  vim.keymap.set("n", "<CR>", confirm, kopts)
  vim.keymap.set("n", "<Esc>", cancel, kopts)
  vim.keymap.set("n", "q", cancel, kopts)

  -- Auto-update on text change
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = picker_buf,
    callback = utils.debounce(update_completions, 50),
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

return M
