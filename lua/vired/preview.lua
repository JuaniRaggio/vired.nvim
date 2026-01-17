local M = {}

local fs = require("vired.fs")
local utils = require("vired.utils")
local config = require("vired.config")

---@type number|nil Preview buffer
local preview_buf = nil
---@type number|nil Preview window
local preview_win = nil
---@type string|nil Currently previewed path
local current_path = nil

-- Default preview config
local DEFAULT_PREVIEW_CONFIG = {
  max_lines = 100,
  max_file_size = 1024 * 1024, -- 1MB
  border = "rounded",
  width = 0.5,
  height = 0.7,
}

-- ============================================================================
-- File Type Detection
-- ============================================================================

---Check if file is binary by reading first bytes
---@param path string
---@return boolean
local function is_binary(path)
  local fd = vim.loop.fs_open(path, "r", 438)
  if not fd then
    return false
  end

  local data = vim.loop.fs_read(fd, 512, 0)
  vim.loop.fs_close(fd)

  if not data then
    return false
  end

  -- Check for null bytes (common in binary files)
  if data:find("\0") then
    return true
  end

  -- Check for high ratio of non-printable characters
  local non_printable = 0
  for i = 1, #data do
    local byte = data:byte(i)
    if byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
      non_printable = non_printable + 1
    end
  end

  return non_printable / #data > 0.3
end

---Get file type info using `file` command
---@param path string
---@return string
local function get_file_info(path)
  local result = vim.fn.system({ "file", "-b", path })
  return vim.trim(result)
end

-- ============================================================================
-- Preview Content Generation
-- ============================================================================

---Generate preview for a text file
---@param path string
---@param max_lines number
---@return string[] lines, string filetype
local function preview_text_file(path, max_lines)
  local lines = {}

  -- Read file
  local fd = vim.loop.fs_open(path, "r", 438)
  if not fd then
    return { "Error: Cannot read file" }, "text"
  end

  local stat = vim.loop.fs_fstat(fd)
  if not stat then
    vim.loop.fs_close(fd)
    return { "Error: Cannot stat file" }, "text"
  end

  -- Read content
  local content = vim.loop.fs_read(fd, stat.size, 0)
  vim.loop.fs_close(fd)

  if not content then
    return { "Error: Cannot read content" }, "text"
  end

  -- Split into lines
  local line_count = 0
  for line in content:gmatch("[^\r\n]*") do
    if line_count >= max_lines then
      table.insert(lines, "")
      table.insert(lines, string.format("... (%d more lines)", stat.size))
      break
    end
    -- Truncate very long lines
    if #line > 500 then
      line = line:sub(1, 500) .. " ..."
    end
    table.insert(lines, line)
    line_count = line_count + 1
  end

  -- Detect filetype
  local filetype = vim.filetype.match({ filename = path }) or "text"

  return lines, filetype
end

---Generate preview for a directory
---@param path string
---@return string[] lines
local function preview_directory(path)
  local lines = {}

  local entries, err = fs.readdir(path, true)
  if err then
    return { "Error: " .. err }
  end

  table.insert(lines, string.format("Directory: %d items", #entries))
  table.insert(lines, "")

  for i, entry in ipairs(entries) do
    if i > 50 then
      table.insert(lines, string.format("... and %d more", #entries - 50))
      break
    end

    local prefix = entry.type == "directory" and "/" or ""
    local size_str = entry.type == "directory" and "" or string.format(" (%s)", utils.format_size(entry.size))
    table.insert(lines, string.format("  %s%s%s", entry.name, prefix, size_str))
  end

  return lines
end

---Generate preview for a binary file
---@param path string
---@return string[] lines
local function preview_binary(path)
  local lines = {}

  local stat = vim.loop.fs_stat(path)
  if not stat then
    return { "Error: Cannot stat file" }
  end

  table.insert(lines, "Binary file")
  table.insert(lines, "")
  table.insert(lines, string.format("Size: %s", utils.format_size(stat.size)))
  table.insert(lines, string.format("Modified: %s", utils.format_time(stat.mtime.sec)))
  table.insert(lines, "")

  -- File type info
  local file_info = get_file_info(path)
  table.insert(lines, "Type: " .. file_info)

  return lines
end

-- ============================================================================
-- Window Management
-- ============================================================================

---Create preview window
---@param lines string[]
---@param filetype string|nil
---@param title string
local function create_preview_window(lines, filetype, title)
  local cfg = config.get()
  local preview_cfg = vim.tbl_extend("force", DEFAULT_PREVIEW_CONFIG, cfg.float or {})

  -- Calculate dimensions
  local width = math.floor(vim.o.columns * preview_cfg.width)
  local height = math.floor(vim.o.lines * preview_cfg.height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create buffer
  preview_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.bo[preview_buf].swapfile = false

  -- Set content
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)

  -- Apply filetype for syntax highlighting
  if filetype and filetype ~= "text" then
    vim.bo[preview_buf].filetype = filetype
  end

  -- Make buffer read-only
  vim.bo[preview_buf].modifiable = false

  -- Create window
  preview_win = vim.api.nvim_open_win(preview_buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = preview_cfg.border,
    title = " " .. title .. " ",
    title_pos = "center",
  })

  -- Window options
  vim.wo[preview_win].wrap = false
  vim.wo[preview_win].number = true
  vim.wo[preview_win].relativenumber = false
  vim.wo[preview_win].cursorline = true
end

-- ============================================================================
-- Public API
-- ============================================================================

---Check if preview is currently open
---@return boolean
function M.is_open()
  return preview_win ~= nil and vim.api.nvim_win_is_valid(preview_win)
end

---Close the preview window
function M.close()
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_close(preview_win, true)
  end
  if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
    vim.api.nvim_buf_delete(preview_buf, { force = true })
  end

  preview_win = nil
  preview_buf = nil
  current_path = nil
end

---Open preview for a path
---@param path string
function M.open(path)
  -- Close existing preview
  M.close()

  path = utils.absolute(path)
  current_path = path

  local stat = vim.loop.fs_stat(path)
  if not stat then
    create_preview_window({ "Error: Path not found" }, nil, "Preview")
    return
  end

  local cfg = config.get()
  local preview_cfg = vim.tbl_extend("force", DEFAULT_PREVIEW_CONFIG, cfg.float or {})
  local title = utils.basename(path)
  local lines, filetype

  if stat.type == "directory" then
    -- Directory preview
    lines = preview_directory(path)
    filetype = nil
    title = title .. "/"
  elseif stat.size > preview_cfg.max_file_size then
    -- File too large
    lines = {
      "File too large to preview",
      "",
      string.format("Size: %s", utils.format_size(stat.size)),
      string.format("Max preview size: %s", utils.format_size(preview_cfg.max_file_size)),
    }
    filetype = nil
  elseif is_binary(path) then
    -- Binary file
    lines = preview_binary(path)
    filetype = nil
  else
    -- Text file
    lines, filetype = preview_text_file(path, preview_cfg.max_lines)
  end

  create_preview_window(lines, filetype, title)
end

---Toggle preview for a path
---@param path string
function M.toggle(path)
  path = utils.absolute(path)

  if M.is_open() then
    if current_path == path then
      -- Same path, close preview
      M.close()
    else
      -- Different path, update preview
      M.open(path)
    end
  else
    M.open(path)
  end
end

---Update preview if open (for cursor following)
---@param path string
function M.update(path)
  if M.is_open() and current_path ~= path then
    M.open(path)
  end
end

return M
