---Path picker with multiple backend support
---Supports: telescope, fzf-lua, and built-in lua picker

local M = {}

local config = require("vired.config")

---@type table<string, table> Backend modules cache
local backends = {}

---Get a backend module
---@param name string
---@return table|nil
local function get_backend(name)
  if backends[name] then
    return backends[name]
  end

  local ok, backend
  if name == "telescope" then
    ok, backend = pcall(require, "vired.picker.telescope")
  elseif name == "fzf" or name == "fzf-lua" then
    ok, backend = pcall(require, "vired.picker.fzf")
  elseif name == "lua" or name == "builtin" then
    ok, backend = pcall(require, "vired.path_picker")
  end

  if ok and backend then
    backends[name] = backend
    return backend
  end

  return nil
end

---Check if a backend is available
---@param name string
---@return boolean
function M.is_backend_available(name)
  local backend = get_backend(name)
  if not backend then
    return false
  end

  if backend.is_available then
    return backend.is_available()
  end

  return true
end

---Get the best available backend based on config
---@return table backend
---@return string name
function M.get_backend()
  local cfg = config.get()
  local preferred = cfg.path_picker.backend

  -- Try preferred backend first
  if preferred and preferred ~= "auto" then
    local backend = get_backend(preferred)
    if backend and M.is_backend_available(preferred) then
      return backend, preferred
    end
    vim.notify(
      string.format("vired: Backend '%s' not available, falling back to auto", preferred),
      vim.log.levels.WARN
    )
  end

  -- Auto-detect: try telescope, then fzf-lua, then builtin
  local order = { "telescope", "fzf", "lua" }
  for _, name in ipairs(order) do
    local backend = get_backend(name)
    if backend and M.is_backend_available(name) then
      return backend, name
    end
  end

  -- Fallback to builtin (should always work)
  return require("vired.path_picker"), "lua"
end

---Open path picker with the configured backend
---@param opts table
---  - prompt: string
---  - default: string
---  - cwd: string
---  - on_select: function(path)
---  - on_cancel: function()|nil
---  - create_if_missing: boolean
function M.open(opts)
  local backend, name = M.get_backend()
  backend.open(opts)
end

---Get list of available backends
---@return string[]
function M.list_available()
  local available = {}
  for _, name in ipairs({ "telescope", "fzf", "lua" }) do
    if M.is_backend_available(name) then
      table.insert(available, name)
    end
  end
  return available
end

return M
