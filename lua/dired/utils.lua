local M = {}

local uv = vim.loop or vim.uv

---Get the path separator for current OS
---@return string
function M.sep()
  if jit and jit.os == "Windows" then
    return "\\"
  end
  return "/"
end

---Normalize path separators
---@param path string
---@return string
function M.normalize(path)
  if not path then
    return ""
  end
  -- Convert backslashes to forward slashes
  path = path:gsub("\\", "/")
  -- Remove trailing slash (except for root)
  if #path > 1 and path:sub(-1) == "/" then
    path = path:sub(1, -2)
  end
  return path
end

---Join path segments
---@param ... string
---@return string
function M.join(...)
  local parts = { ... }
  local result = {}
  for _, part in ipairs(parts) do
    if part and part ~= "" then
      part = M.normalize(part)
      if #result == 0 or part:sub(1, 1) == "/" then
        result = { part }
      else
        table.insert(result, part)
      end
    end
  end
  return table.concat(result, "/")
end

---Get parent directory
---@param path string
---@return string
function M.parent(path)
  path = M.normalize(path)
  if path == "/" then
    return "/"
  end
  local parent = path:match("(.+)/[^/]+$")
  return parent or "/"
end

---Get basename (filename with extension)
---@param path string
---@return string
function M.basename(path)
  path = M.normalize(path)
  return path:match("[^/]+$") or path
end

---Get dirname
---@param path string
---@return string
function M.dirname(path)
  return M.parent(path)
end

---Get file extension (without dot)
---@param path string
---@return string|nil
function M.extension(path)
  local basename = M.basename(path)
  return basename:match("%.([^%.]+)$")
end

---Get filename without extension
---@param path string
---@return string
function M.stem(path)
  local basename = M.basename(path)
  local stem = basename:match("(.+)%.[^%.]+$")
  return stem or basename
end

---Check if path is absolute
---@param path string
---@return boolean
function M.is_absolute(path)
  if not path or path == "" then
    return false
  end
  -- Unix absolute path
  if path:sub(1, 1) == "/" then
    return true
  end
  -- Windows absolute path (C:\, D:\, etc)
  if path:match("^%a:[\\/]") then
    return true
  end
  return false
end

---Expand ~ to home directory
---@param path string
---@return string
function M.expand(path)
  if path:sub(1, 1) == "~" then
    local home = uv.os_homedir() or os.getenv("HOME") or ""
    return home .. path:sub(2)
  end
  return path
end

---Make path absolute
---@param path string
---@param base? string Base directory (defaults to cwd)
---@return string
function M.absolute(path, base)
  path = M.expand(path)
  if M.is_absolute(path) then
    return M.normalize(path)
  end
  base = base or uv.cwd() or ""
  return M.normalize(M.join(base, path))
end

---Check if path exists
---@param path string
---@return boolean
function M.exists(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil
end

---Check if path is a directory
---@param path string
---@return boolean
function M.is_dir(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---Check if path is a file
---@param path string
---@return boolean
function M.is_file(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

---Check if path is a symlink
---@param path string
---@return boolean
function M.is_symlink(path)
  local stat = uv.fs_lstat(path)
  return stat ~= nil and stat.type == "link"
end

---Get relative path from base
---@param path string
---@param base string
---@return string
function M.relative(path, base)
  path = M.normalize(path)
  base = M.normalize(base)

  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end

  if path:sub(1, #base) == base then
    return path:sub(#base + 1)
  end

  return path
end

---Format file size for display
---@param size number Size in bytes
---@return string
function M.format_size(size)
  if size < 1024 then
    return string.format("%dB", size)
  elseif size < 1024 * 1024 then
    return string.format("%.1fK", size / 1024)
  elseif size < 1024 * 1024 * 1024 then
    return string.format("%.1fM", size / (1024 * 1024))
  else
    return string.format("%.1fG", size / (1024 * 1024 * 1024))
  end
end

---Format timestamp for display
---@param timestamp number Unix timestamp
---@return string
function M.format_time(timestamp)
  return os.date("%Y-%m-%d %H:%M", timestamp)
end

---Format permissions for display (Unix style)
---@param mode number File mode from stat
---@param file_type string "file", "directory", "link"
---@return string
function M.format_permissions(mode, file_type)
  local type_char = "-"
  if file_type == "directory" then
    type_char = "d"
  elseif file_type == "link" then
    type_char = "l"
  end

  local function triplet(val)
    local r = (val % 8 >= 4) and "r" or "-"
    local w = (val % 4 >= 2) and "w" or "-"
    local x = (val % 2 >= 1) and "x" or "-"
    return r .. w .. x
  end

  local owner = math.floor(mode / 64) % 8
  local group = math.floor(mode / 8) % 8
  local other = mode % 8

  return type_char .. triplet(owner) .. triplet(group) .. triplet(other)
end

---Debounce a function
---@param fn function
---@param ms number Milliseconds to wait
---@return function
function M.debounce(fn, ms)
  local timer = nil
  return function(...)
    local args = { ... }
    if timer then
      timer:stop()
    end
    timer = uv.new_timer()
    timer:start(ms, 0, function()
      timer:stop()
      timer:close()
      timer = nil
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end
end

---Throttle a function
---@param fn function
---@param ms number Minimum milliseconds between calls
---@return function
function M.throttle(fn, ms)
  local last_call = 0
  local timer = nil
  return function(...)
    local args = { ... }
    local now = uv.now()
    local remaining = ms - (now - last_call)

    if remaining <= 0 then
      last_call = now
      fn(unpack(args))
    else
      if timer then
        timer:stop()
      end
      timer = uv.new_timer()
      timer:start(remaining, 0, function()
        timer:stop()
        timer:close()
        timer = nil
        last_call = uv.now()
        vim.schedule(function()
          fn(unpack(args))
        end)
      end)
    end
  end
end

---Schedule function to run on main loop
---@param fn function
function M.schedule(fn)
  vim.schedule(fn)
end

---Create async wrapper using coroutines
---@param fn function
---@return function
function M.async(fn)
  return function(...)
    local co = coroutine.create(fn)
    local function step(...)
      local ok, result = coroutine.resume(co, ...)
      if not ok then
        error(result)
      end
    end
    step(...)
  end
end

-- ============================================================================
-- Fuzzy Matching
-- ============================================================================

---@class FuzzyMatch
---@field str string The matched string
---@field score number Match score (higher is better)
---@field positions number[] 1-indexed positions of matched characters

---Calculate fuzzy match score between pattern and string
---Returns nil if no match, otherwise returns score and match positions
---@param pattern string The search pattern
---@param str string The string to match against
---@return number|nil score, number[]|nil positions
function M.fuzzy_match(pattern, str)
  if not pattern or pattern == "" then
    return 0, {}
  end

  if not str or str == "" then
    return nil, nil
  end

  local pattern_lower = pattern:lower()
  local str_lower = str:lower()
  local pattern_len = #pattern_lower
  local str_len = #str_lower

  -- Quick check: pattern must be shorter or equal to string
  if pattern_len > str_len then
    return nil, nil
  end

  local positions = {}
  local score = 0
  local pattern_idx = 1
  local prev_match_idx = 0
  local consecutive_bonus = 0

  for str_idx = 1, str_len do
    if pattern_idx > pattern_len then
      break
    end

    local pattern_char = pattern_lower:sub(pattern_idx, pattern_idx)
    local str_char = str_lower:sub(str_idx, str_idx)

    if pattern_char == str_char then
      table.insert(positions, str_idx)

      -- Base score for match
      local match_score = 1

      -- Bonus for consecutive matches
      if str_idx == prev_match_idx + 1 then
        consecutive_bonus = consecutive_bonus + 2
        match_score = match_score + consecutive_bonus
      else
        consecutive_bonus = 0
      end

      -- Bonus for match at start of string
      if str_idx == 1 then
        match_score = match_score + 10
      end

      -- Bonus for match after separator (/, -, _, .)
      if str_idx > 1 then
        local prev_char = str:sub(str_idx - 1, str_idx - 1)
        if prev_char == "/" or prev_char == "-" or prev_char == "_" or prev_char == "." or prev_char == " " then
          match_score = match_score + 8
        end
      end

      -- Bonus for uppercase match (camelCase)
      local original_char = str:sub(str_idx, str_idx)
      if original_char:match("%u") then
        match_score = match_score + 5
      end

      -- Penalty for late matches (prefer earlier matches)
      match_score = match_score - (str_idx / str_len) * 0.5

      score = score + match_score
      prev_match_idx = str_idx
      pattern_idx = pattern_idx + 1
    end
  end

  -- Check if all pattern characters were matched
  if pattern_idx <= pattern_len then
    return nil, nil
  end

  -- Bonus for shorter strings (exact-ish matches)
  local length_ratio = pattern_len / str_len
  score = score + length_ratio * 5

  return score, positions
end

---Filter and sort a list of strings by fuzzy match
---@param pattern string The search pattern
---@param items string[] List of strings to filter
---@param limit? number Maximum number of results (default: 50)
---@return FuzzyMatch[] matches Sorted by score descending
function M.fuzzy_filter(pattern, items, limit)
  limit = limit or 50
  local matches = {}

  for _, item in ipairs(items) do
    local score, positions = M.fuzzy_match(pattern, item)
    if score then
      table.insert(matches, {
        str = item,
        score = score,
        positions = positions,
      })
    end
  end

  -- Sort by score descending
  table.sort(matches, function(a, b)
    return a.score > b.score
  end)

  -- Limit results
  if #matches > limit then
    local limited = {}
    for i = 1, limit do
      limited[i] = matches[i]
    end
    return limited
  end

  return matches
end

---Simple prefix match (fallback for when fuzzy is overkill)
---@param prefix string The prefix to match
---@param str string The string to check
---@return boolean
function M.prefix_match(prefix, str)
  if not prefix or prefix == "" then
    return true
  end
  if not str then
    return false
  end
  return str:lower():sub(1, #prefix) == prefix:lower()
end

return M
