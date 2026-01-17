---@class GitFileStatus
---@field index string Status in index (staged): M, A, D, R, C, U, ?, !
---@field worktree string Status in worktree: M, D, U, ?
---@field path string Path relative to repo root

local M = {}

local utils = require("vired.utils")
local config = require("vired.config")

---@type table<string, table<string, GitFileStatus>> Cache by repo root
local status_cache = {}

---@type table<string, number> Last update time by repo root
local cache_timestamps = {}

local CACHE_TTL_MS = 5000 -- 5 seconds

-- ============================================================================
-- Repository Detection
-- ============================================================================

---Find git repository root from a path
---@param path string
---@return string|nil repo_root
function M.find_repo_root(path)
  path = utils.absolute(path)

  -- Walk up directory tree looking for .git
  local current = path
  while current and current ~= "/" do
    local git_dir = utils.join(current, ".git")
    if utils.exists(git_dir) then
      return current
    end
    current = utils.parent(current)
  end

  -- Check root
  if utils.exists("/.git") then
    return "/"
  end

  return nil
end

---Check if path is inside a git repository
---@param path string
---@return boolean
function M.is_git_repo(path)
  return M.find_repo_root(path) ~= nil
end

-- ============================================================================
-- Status Parsing
-- ============================================================================

---Parse git status --porcelain output
---@param output string Raw output from git status --porcelain
---@param repo_root string Repository root for building full paths
---@return table<string, GitFileStatus> status_map Path to status mapping
function M.parse_porcelain(output, repo_root)
  local status_map = {}

  for line in output:gmatch("[^\r\n]+") do
    if #line >= 3 then
      local index_status = line:sub(1, 1)
      local worktree_status = line:sub(2, 2)
      local file_path = line:sub(4)

      -- Handle renamed files (format: "R  old -> new")
      -- Use plain string matching (4th param = true) because "-" is a pattern metacharacter
      local arrow_pos = file_path:find(" -> ", 1, true)
      if arrow_pos then
        file_path = file_path:sub(arrow_pos + 4)
      end

      -- Handle quoted paths (for special characters)
      if file_path:sub(1, 1) == '"' and file_path:sub(-1) == '"' then
        file_path = file_path:sub(2, -2)
        -- Unescape common sequences
        file_path = file_path:gsub("\\n", "\n")
        file_path = file_path:gsub("\\t", "\t")
        file_path = file_path:gsub('\\"', '"')
        file_path = file_path:gsub("\\\\", "\\")
      end

      local full_path = utils.join(repo_root, file_path)

      status_map[full_path] = {
        index = index_status,
        worktree = worktree_status,
        path = file_path,
      }

      -- Also store status for parent directories (for directory indicators)
      local parent = utils.parent(full_path)
      while parent and parent ~= repo_root and parent ~= "/" do
        if not status_map[parent] then
          status_map[parent] = {
            index = "D", -- Directory contains changes
            worktree = "D",
            path = utils.relative(parent, repo_root),
          }
        end
        parent = utils.parent(parent)
      end
    end
  end

  return status_map
end

---Get display character for git status
---@param status GitFileStatus|nil
---@return string char, string highlight_group
function M.get_status_display(status)
  if not status then
    return " ", "Normal"
  end

  local index = status.index
  local worktree = status.worktree

  -- Conflict
  if index == "U" or worktree == "U" then
    return "C", "ViredGitConflict"
  end

  -- Staged changes (index has modifications)
  if index == "M" or index == "A" or index == "D" or index == "R" or index == "C" then
    return index, "ViredGitStaged"
  end

  -- Worktree changes (unstaged modifications)
  if worktree == "M" or worktree == "D" then
    return worktree, "ViredGitModified"
  end

  -- Untracked
  if index == "?" and worktree == "?" then
    return "?", "ViredGitUntracked"
  end

  -- Ignored
  if index == "!" and worktree == "!" then
    return "!", "ViredGitIgnored"
  end

  -- Directory with changes
  if index == "D" and worktree == "D" and status.path then
    return "*", "ViredGitModified"
  end

  return " ", "Normal"
end

-- ============================================================================
-- Async Status Fetching
-- ============================================================================

---Get git status for a repository (async)
---@param repo_root string Repository root path
---@param callback fun(status_map: table<string, GitFileStatus>|nil, err: string|nil)
function M.get_status_async(repo_root, callback)
  -- Check cache first
  local now = vim.loop.now()
  local cached = status_cache[repo_root]
  local cache_time = cache_timestamps[repo_root] or 0

  if cached and (now - cache_time) < CACHE_TTL_MS then
    vim.schedule(function()
      callback(cached, nil)
    end)
    return
  end

  -- Run git status asynchronously
  local cmd = {
    "git",
    "-C", repo_root,
    "status",
    "--porcelain=v1",
    "--ignored",
    "--untracked-files=all",
  }

  local output = {}
  local stderr_output = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_output, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          callback(nil, "git status failed: " .. table.concat(stderr_output, "\n"))
          return
        end

        local raw_output = table.concat(output, "\n")
        local status_map = M.parse_porcelain(raw_output, repo_root)

        -- Update cache
        status_cache[repo_root] = status_map
        cache_timestamps[repo_root] = vim.loop.now()

        callback(status_map, nil)
      end)
    end,
  })
end

---Get git status synchronously (blocking, use sparingly)
---@param repo_root string Repository root path
---@return table<string, GitFileStatus>|nil status_map, string|nil err
function M.get_status_sync(repo_root)
  -- Check cache first
  local now = vim.loop.now()
  local cached = status_cache[repo_root]
  local cache_time = cache_timestamps[repo_root] or 0

  if cached and (now - cache_time) < CACHE_TTL_MS then
    return cached, nil
  end

  local result = vim.fn.systemlist({
    "git", "-C", repo_root,
    "status", "--porcelain=v1", "--ignored", "--untracked-files=all"
  })

  if vim.v.shell_error ~= 0 then
    return nil, "git status failed"
  end

  local raw_output = table.concat(result, "\n")
  local status_map = M.parse_porcelain(raw_output, repo_root)

  -- Update cache
  status_cache[repo_root] = status_map
  cache_timestamps[repo_root] = vim.loop.now()

  return status_map, nil
end

---Invalidate cache for a repository
---@param repo_root string|nil Repository root (nil to clear all)
function M.invalidate_cache(repo_root)
  if repo_root then
    status_cache[repo_root] = nil
    cache_timestamps[repo_root] = nil
  else
    status_cache = {}
    cache_timestamps = {}
  end
end

---Get status for a specific file
---@param path string Full file path
---@param status_map table<string, GitFileStatus>|nil
---@return GitFileStatus|nil
function M.get_file_status(path, status_map)
  if not status_map then
    return nil
  end
  return status_map[path]
end

-- ============================================================================
-- Git Operations
-- ============================================================================

---Check if a file is tracked by git
---@param path string File path
---@param repo_root string Repository root
---@return boolean
function M.is_tracked(path, repo_root)
  local result = vim.fn.systemlist({
    "git", "-C", repo_root,
    "ls-files", "--error-unmatch", path
  })
  return vim.v.shell_error == 0
end

---Git mv (async)
---@param src string Source path
---@param dest string Destination path
---@param callback fun(ok: boolean, err: string|nil)
function M.mv(src, dest, callback)
  local repo_root = M.find_repo_root(src)
  if not repo_root then
    vim.schedule(function()
      callback(false, "Not a git repository")
    end)
    return
  end

  vim.fn.jobstart({ "git", "-C", repo_root, "mv", src, dest }, {
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code == 0 then
          M.invalidate_cache(repo_root)
          callback(true, nil)
        else
          callback(false, "git mv failed")
        end
      end)
    end,
  })
end

---Git rm (async)
---@param path string File path
---@param callback fun(ok: boolean, err: string|nil)
function M.rm(path, callback)
  local repo_root = M.find_repo_root(path)
  if not repo_root then
    vim.schedule(function()
      callback(false, "Not a git repository")
    end)
    return
  end

  vim.fn.jobstart({ "git", "-C", repo_root, "rm", "-f", path }, {
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code == 0 then
          M.invalidate_cache(repo_root)
          callback(true, nil)
        else
          callback(false, "git rm failed")
        end
      end)
    end,
  })
end

---Git add (async)
---@param path string File path
---@param callback fun(ok: boolean, err: string|nil)
function M.add(path, callback)
  local repo_root = M.find_repo_root(path)
  if not repo_root then
    vim.schedule(function()
      callback(false, "Not a git repository")
    end)
    return
  end

  vim.fn.jobstart({ "git", "-C", repo_root, "add", path }, {
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code == 0 then
          M.invalidate_cache(repo_root)
          callback(true, nil)
        else
          callback(false, "git add failed")
        end
      end)
    end,
  })
end

return M
