---@class ViredEntry
---@field name string Filename
---@field path string Full path
---@field type "file"|"directory"|"link"|"unknown"
---@field size number Size in bytes
---@field mtime number Modification time (unix timestamp)
---@field mode number File mode/permissions
---@field link_target? string Symlink target if type is "link"

local M = {}

local uv = vim.loop or vim.uv
local utils = require("vired.utils")

---Get file/directory information
---@param path string
---@return ViredEntry|nil, string|nil
function M.stat(path)
  local stat = uv.fs_lstat(path)
  if not stat then
    return nil, "Cannot stat: " .. path
  end

  local entry = {
    name = utils.basename(path),
    path = path,
    type = stat.type or "unknown",
    size = stat.size or 0,
    mtime = stat.mtime and stat.mtime.sec or 0,
    mode = stat.mode or 0,
  }

  -- Resolve symlink target
  if stat.type == "link" then
    local target = uv.fs_readlink(path)
    entry.link_target = target
  end

  return entry, nil
end

---Read directory contents
---@param path string Directory path
---@param show_hidden? boolean Include hidden files (default: false)
---@return ViredEntry[], string|nil
function M.readdir(path, show_hidden)
  path = utils.normalize(path)

  local handle, err = uv.fs_scandir(path)
  if not handle then
    return {}, "Cannot read directory: " .. (err or path)
  end

  local entries = {}

  while true do
    local name, type = uv.fs_scandir_next(handle)
    if not name then
      break
    end

    -- Skip hidden files unless requested
    if show_hidden or name:sub(1, 1) ~= "." then
      local entry_path = utils.join(path, name)
      local entry, stat_err = M.stat(entry_path)

      if entry then
        -- fs_scandir_next returns type, use it if stat failed to determine
        if entry.type == "unknown" and type then
          entry.type = type
        end
        table.insert(entries, entry)
      end
    end
  end

  -- Sort: directories first, then alphabetically
  table.sort(entries, function(a, b)
    if a.type == "directory" and b.type ~= "directory" then
      return true
    elseif a.type ~= "directory" and b.type == "directory" then
      return false
    else
      return a.name:lower() < b.name:lower()
    end
  end)

  return entries, nil
end

---Check if path exists
---@param path string
---@return boolean
function M.exists(path)
  return uv.fs_stat(path) ~= nil
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

---Create directory (with parents if needed)
---@param path string
---@param mode? number Permissions (default: 755)
---@return boolean, string|nil
function M.mkdir(path, mode)
  mode = mode or 493 -- 0755

  -- Check if already exists
  if M.exists(path) then
    if M.is_dir(path) then
      return true, nil
    else
      return false, "Path exists and is not a directory: " .. path
    end
  end

  -- Create parent directories first
  local parent = utils.parent(path)
  if parent ~= "/" and parent ~= path and not M.exists(parent) then
    local ok, err = M.mkdir(parent, mode)
    if not ok then
      return false, err
    end
  end

  -- Create the directory
  local ok, err = uv.fs_mkdir(path, mode)
  if not ok then
    return false, "Failed to create directory: " .. (err or path)
  end

  return true, nil
end

---Create an empty file
---@param path string
---@param mode? number Permissions (default: 644)
---@return boolean, string|nil
function M.touch(path, mode)
  mode = mode or 420 -- 0644

  if M.exists(path) then
    -- Update mtime
    local now = os.time()
    local ok, err = uv.fs_utime(path, now, now)
    if not ok then
      return false, "Failed to update mtime: " .. (err or path)
    end
    return true, nil
  end

  -- Ensure parent directory exists
  local parent = utils.parent(path)
  if not M.exists(parent) then
    local ok, err = M.mkdir(parent)
    if not ok then
      return false, err
    end
  end

  -- Create empty file
  local fd, err = uv.fs_open(path, "w", mode)
  if not fd then
    return false, "Failed to create file: " .. (err or path)
  end
  uv.fs_close(fd)

  return true, nil
end

---Delete file or empty directory
---@param path string
---@return boolean, string|nil
function M.delete(path)
  if not M.exists(path) then
    return true, nil -- Already doesn't exist
  end

  local stat = uv.fs_lstat(path)
  if not stat then
    return false, "Cannot stat: " .. path
  end

  if stat.type == "directory" then
    local ok, err = uv.fs_rmdir(path)
    if not ok then
      return false, "Failed to delete directory: " .. (err or path)
    end
  else
    local ok, err = uv.fs_unlink(path)
    if not ok then
      return false, "Failed to delete file: " .. (err or path)
    end
  end

  return true, nil
end

---Delete directory recursively
---@param path string
---@return boolean, string|nil
function M.delete_recursive(path)
  if not M.exists(path) then
    return true, nil
  end

  local stat = uv.fs_lstat(path)
  if not stat then
    return false, "Cannot stat: " .. path
  end

  if stat.type ~= "directory" then
    return M.delete(path)
  end

  -- Delete contents first
  local entries, err = M.readdir(path, true)
  if err then
    return false, err
  end

  for _, entry in ipairs(entries) do
    local ok, del_err = M.delete_recursive(entry.path)
    if not ok then
      return false, del_err
    end
  end

  -- Now delete the empty directory
  return M.delete(path)
end

---Rename/move file or directory
---@param src string Source path
---@param dest string Destination path
---@return boolean, string|nil
function M.rename(src, dest)
  if not M.exists(src) then
    return false, "Source does not exist: " .. src
  end

  -- Ensure destination parent exists
  local dest_parent = utils.parent(dest)
  if not M.exists(dest_parent) then
    local ok, err = M.mkdir(dest_parent)
    if not ok then
      return false, err
    end
  end

  local ok, err = uv.fs_rename(src, dest)
  if not ok then
    return false, "Failed to rename: " .. (err or src)
  end

  return true, nil
end

---Copy file
---@param src string Source path
---@param dest string Destination path
---@return boolean, string|nil
function M.copy_file(src, dest)
  if not M.exists(src) then
    return false, "Source does not exist: " .. src
  end

  if not M.is_file(src) then
    return false, "Source is not a file: " .. src
  end

  -- Ensure destination parent exists
  local dest_parent = utils.parent(dest)
  if not M.exists(dest_parent) then
    local ok, err = M.mkdir(dest_parent)
    if not ok then
      return false, err
    end
  end

  local ok, err = uv.fs_copyfile(src, dest)
  if not ok then
    return false, "Failed to copy: " .. (err or src)
  end

  return true, nil
end

---Copy directory recursively
---@param src string Source path
---@param dest string Destination path
---@return boolean, string|nil
function M.copy_dir(src, dest)
  if not M.exists(src) then
    return false, "Source does not exist: " .. src
  end

  if not M.is_dir(src) then
    return false, "Source is not a directory: " .. src
  end

  -- Create destination directory
  local ok, err = M.mkdir(dest)
  if not ok then
    return false, err
  end

  -- Copy contents
  local entries, read_err = M.readdir(src, true)
  if read_err then
    return false, read_err
  end

  for _, entry in ipairs(entries) do
    local dest_path = utils.join(dest, entry.name)

    if entry.type == "directory" then
      local copy_ok, copy_err = M.copy_dir(entry.path, dest_path)
      if not copy_ok then
        return false, copy_err
      end
    else
      local copy_ok, copy_err = M.copy_file(entry.path, dest_path)
      if not copy_ok then
        return false, copy_err
      end
    end
  end

  return true, nil
end

---Copy file or directory
---@param src string Source path
---@param dest string Destination path
---@return boolean, string|nil
function M.copy(src, dest)
  if M.is_dir(src) then
    return M.copy_dir(src, dest)
  else
    return M.copy_file(src, dest)
  end
end

return M
