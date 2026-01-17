---Jump list for directory navigation history
---Similar to Vim's jumplist but for directories

local M = {}

---@class ViredJumpList
---@field stack string[] Stack of visited directory paths
---@field position number Current position in stack (1-based, points to current dir)

---@type table<number, ViredJumpList> Per-buffer jump lists
local jumplists = {}

---@type number Maximum history size
local MAX_HISTORY = 100

---Get or create jumplist for a buffer
---@param bufnr number
---@return ViredJumpList
local function get_jumplist(bufnr)
  if not jumplists[bufnr] then
    jumplists[bufnr] = {
      stack = {},
      position = 0,
    }
  end
  return jumplists[bufnr]
end

---Push a new directory to the jumplist
---@param bufnr number Buffer number
---@param path string Directory path
function M.push(bufnr, path)
  local jl = get_jumplist(bufnr)

  -- Don't push if it's the same as current position
  if jl.position > 0 and jl.stack[jl.position] == path then
    return
  end

  -- If we're not at the end of the stack, truncate forward history
  if jl.position < #jl.stack then
    for i = #jl.stack, jl.position + 1, -1 do
      table.remove(jl.stack, i)
    end
  end

  -- Add new path
  table.insert(jl.stack, path)
  jl.position = #jl.stack

  -- Trim if exceeds max history
  if #jl.stack > MAX_HISTORY then
    table.remove(jl.stack, 1)
    jl.position = jl.position - 1
  end
end

---Check if we can go back in history
---@param bufnr number
---@return boolean
function M.can_go_back(bufnr)
  local jl = get_jumplist(bufnr)
  return jl.position > 1
end

---Check if we can go forward in history
---@param bufnr number
---@return boolean
function M.can_go_forward(bufnr)
  local jl = get_jumplist(bufnr)
  return jl.position < #jl.stack
end

---Go back in history
---@param bufnr number
---@return string|nil path The previous directory path, or nil if can't go back
function M.back(bufnr)
  local jl = get_jumplist(bufnr)

  if not M.can_go_back(bufnr) then
    return nil
  end

  jl.position = jl.position - 1
  return jl.stack[jl.position]
end

---Go forward in history
---@param bufnr number
---@return string|nil path The next directory path, or nil if can't go forward
function M.forward(bufnr)
  local jl = get_jumplist(bufnr)

  if not M.can_go_forward(bufnr) then
    return nil
  end

  jl.position = jl.position + 1
  return jl.stack[jl.position]
end

---Get current position info
---@param bufnr number
---@return number position Current position
---@return number total Total items in stack
function M.get_position(bufnr)
  local jl = get_jumplist(bufnr)
  return jl.position, #jl.stack
end

---Get the full history stack (for debugging or display)
---@param bufnr number
---@return string[] stack
---@return number position
function M.get_stack(bufnr)
  local jl = get_jumplist(bufnr)
  return vim.deepcopy(jl.stack), jl.position
end

---Clear jumplist for a buffer
---@param bufnr number
function M.clear(bufnr)
  jumplists[bufnr] = nil
end

---Clear all jumplists
function M.clear_all()
  jumplists = {}
end

return M
