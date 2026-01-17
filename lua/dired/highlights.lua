local M = {}

---Define highlight groups for dired
function M.setup()
  local highlights = {
    -- File types
    DiredDirectory = { link = "Directory" },
    DiredFile = { link = "Normal" },
    DiredSymlink = { link = "Constant" },
    DiredBrokenLink = { fg = "#ff6b6b", bold = true },
    DiredExecutable = { fg = "#98c379", bold = true },

    -- Columns
    DiredSize = { link = "Number" },
    DiredDate = { link = "Comment" },
    DiredPermissions = { link = "Comment" },
    DiredOwner = { link = "Identifier" },

    -- Marks
    DiredMarked = { fg = "#e5c07b", bold = true },
    DiredMarkedFile = { bg = "#3e4451" },

    -- Git status
    DiredGitModified = { fg = "#e5c07b" },
    DiredGitStaged = { fg = "#98c379" },
    DiredGitUntracked = { fg = "#abb2bf" },
    DiredGitIgnored = { fg = "#5c6370" },
    DiredGitConflict = { fg = "#e06c75" },

    -- UI elements
    DiredHeader = { fg = "#61afef", bold = true },
    DiredFooter = { link = "Comment" },
    DiredCursor = { link = "CursorLine" },

    -- Path picker
    DiredPickerPrompt = { fg = "#61afef", bold = true },
    DiredPickerMatch = { fg = "#e5c07b", bold = true },
    DiredPickerSelection = { bg = "#3e4451" },
    DiredPickerCreate = { fg = "#98c379", italic = true },
    DiredPickerBorder = { link = "FloatBorder" },
  }

  for name, opts in pairs(highlights) do
    -- Only set if not already defined by user
    local existing = vim.api.nvim_get_hl(0, { name = name })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
end

---Get icon for file type (uses nvim-web-devicons if available)
---@param name string Filename
---@param type string "file"|"directory"|"link"
---@return string icon, string|nil highlight_group
function M.get_icon(name, type)
  if type == "directory" then
    return "", "DiredDirectory"
  end

  -- Try to use nvim-web-devicons
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok then
    local icon, hl = devicons.get_icon(name, nil, { default = true })
    return icon or "", hl
  end

  -- Fallback icons
  if type == "link" then
    return "", "DiredSymlink"
  end

  local ext = name:match("%.([^%.]+)$")
  local icon_map = {
    lua = "",
    py = "",
    js = "",
    ts = "",
    rs = "",
    go = "",
    c = "",
    cpp = "",
    h = "",
    md = "",
    json = "",
    yaml = "",
    yml = "",
    toml = "",
    sh = "",
    bash = "",
    zsh = "",
    vim = "",
    git = "",
    txt = "",
  }

  return icon_map[ext] or "", "DiredFile"
end

return M
