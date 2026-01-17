---@class DiredPathPickerConfig
---@field backend "fzf"|"lua"|"telescope"
---@field sources string[]
---@field create_directories boolean
---@field show_hidden boolean

---@class DiredLspConfig
---@field enabled boolean
---@field timeout_ms number

---@class DiredGitConfig
---@field auto_add boolean
---@field use_git_mv boolean
---@field use_git_rm boolean

---@class DiredFloatConfig
---@field border string
---@field width number
---@field height number

---@class DiredPreviewConfig
---@field max_lines number
---@field max_file_size number
---@field auto_preview boolean

---@class DiredBufferEditConfig
---@field enabled boolean
---@field confirm_changes boolean

---@class DiredConfig
---@field columns string[]
---@field path_picker DiredPathPickerConfig
---@field delete_to_trash boolean
---@field confirm_delete boolean
---@field skip_confirm_single boolean
---@field lsp DiredLspConfig
---@field git DiredGitConfig
---@field preview DiredPreviewConfig
---@field buffer_editing DiredBufferEditConfig
---@field float DiredFloatConfig
---@field keymaps table<string, string>

local M = {}

---@type DiredConfig
M.defaults = {
  -- Columnas a mostrar en el buffer
  columns = { "icon", "permissions", "size", "mtime" },

  -- Path picker configuration
  path_picker = {
    backend = "lua", -- "fzf" | "lua" | "telescope"
    sources = { "filesystem", "recent", "bookmarks", "buffers" },
    create_directories = true,
    show_hidden = false,
  },

  -- Comportamiento
  delete_to_trash = true,
  confirm_delete = true,
  skip_confirm_single = true,

  -- LSP integration
  lsp = {
    enabled = true,
    timeout_ms = 3000,
  },

  -- Git integration
  git = {
    auto_add = false,
    use_git_mv = true,
    use_git_rm = true,
  },

  -- Preview settings
  preview = {
    max_lines = 100,
    max_file_size = 1024 * 1024, -- 1MB
    auto_preview = false,
  },

  -- Buffer editing (wdired-like mode)
  buffer_editing = {
    enabled = true,
    confirm_changes = true,
  },

  -- UI floating windows
  float = {
    border = "rounded",
    width = 0.8,
    height = 0.8,
  },

  -- Keymaps (buffer-local en dired buffer)
  keymaps = {
    ["R"] = "actions.move",
    ["C"] = "actions.copy",
    ["D"] = "actions.delete",
    ["+"] = "actions.mkdir",
    ["%"] = "actions.touch",
    ["m"] = "actions.toggle_mark",
    ["u"] = "actions.unmark",
    ["U"] = "actions.unmark_all",
    ["g."] = "actions.toggle_hidden",
    ["-"] = "actions.parent",
    ["<CR>"] = "actions.select",
    ["<Tab>"] = "actions.preview",
    ["q"] = "actions.close",
    ["gr"] = "actions.refresh",
    ["i"] = "actions.edit", -- Enter wdired-like edit mode
  },
}

---@type DiredConfig
M.options = {}

---Merge user config with defaults
---@param user_config? DiredConfig
---@return DiredConfig
function M.setup(user_config)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, user_config or {})
  return M.options
end

---Get current config
---@return DiredConfig
function M.get()
  return M.options
end

return M
