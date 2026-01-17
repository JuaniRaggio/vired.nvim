---@class ViredPathPickerConfig
---@field backend "auto"|"telescope"|"fzf"|"lua"
---@field sources string[]
---@field create_directories boolean
---@field show_hidden boolean

---@class ViredLspConfig
---@field enabled boolean
---@field timeout_ms number

---@class ViredGitConfig
---@field auto_add boolean
---@field use_git_mv boolean
---@field use_git_rm boolean

---@class ViredFloatConfig
---@field border string
---@field width number
---@field height number

---@class ViredPreviewConfig
---@field max_lines number
---@field max_file_size number
---@field auto_preview boolean

---@class ViredBufferEditConfig
---@field enabled boolean
---@field confirm_changes boolean

---@class ViredProjectsConfig
---@field auto_prompt boolean Prompt to add new projects automatically
---@field auto_cd boolean Change Neovim cwd when opening a project
---@field markers string[] Files/directories that indicate a project root
---@field sort_by "name"|"recent"|"added" Default sort order for projects

---@class ViredWatcherConfig
---@field enabled boolean Enable auto-refresh on filesystem changes
---@field debounce_ms number Debounce time in milliseconds

---@class ViredConfig
---@field columns string[]
---@field path_picker ViredPathPickerConfig
---@field delete_to_trash boolean
---@field confirm_delete boolean
---@field skip_confirm_single boolean
---@field use_picker_by_default boolean
---@field lsp ViredLspConfig
---@field git ViredGitConfig
---@field preview ViredPreviewConfig
---@field buffer_editing ViredBufferEditConfig
---@field projects ViredProjectsConfig
---@field watcher ViredWatcherConfig
---@field float ViredFloatConfig
---@field keymaps table<string, string>

local M = {}

---@type ViredConfig
M.defaults = {
  -- Columnas a mostrar en el buffer
  columns = { "icon", "permissions", "size", "mtime" },

  -- Path picker configuration
  path_picker = {
    backend = "auto", -- "auto" | "telescope" | "fzf" | "lua"
    sources = { "filesystem", "recent", "bookmarks", "buffers" },
    create_directories = true,
    show_hidden = false,
  },

  -- Comportamiento
  delete_to_trash = true,
  confirm_delete = true,
  skip_confirm_single = true,
  use_picker_by_default = false, -- If true, :Vired opens picker instead of cwd

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

  -- Projects (Projectile-like functionality)
  projects = {
    auto_prompt = true, -- Prompt to add new projects when detected
    auto_cd = true, -- Change Neovim cwd when opening a project
    markers = {
      ".git",
      ".hg",
      ".svn",
      "package.json",
      "Cargo.toml",
      "go.mod",
      "Makefile",
      "CMakeLists.txt",
      "pyproject.toml",
      "setup.py",
      ".project",
      ".projectile",
    },
    sort_by = "recent", -- "name" | "recent" | "added"
  },

  -- File watcher for auto-refresh
  watcher = {
    enabled = true,
    debounce_ms = 200,
  },

  -- UI floating windows
  float = {
    border = "rounded",
    width = 0.8,
    height = 0.8,
  },

  -- Keymaps (buffer-local en vired buffer)
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
    ["<C-z>"] = "actions.undo", -- Undo last file operation
    ["<C-y>"] = "actions.redo", -- Redo last undone operation
    ["?"] = "actions.help", -- Show help popup
    ["gw"] = "actions.toggle_watch", -- Toggle auto-refresh watcher
    ["<C-o>"] = "actions.jump_back", -- Go back in directory history
    ["<C-i>"] = "actions.jump_forward", -- Go forward in directory history
  },
}

---@type ViredConfig
M.options = {}

---Merge user config with defaults
---@param user_config? ViredConfig
---@return ViredConfig
function M.setup(user_config)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, user_config or {})
  return M.options
end

---Get current config
---@return ViredConfig
function M.get()
  return M.options
end

return M
