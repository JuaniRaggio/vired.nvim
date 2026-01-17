local M = {}

---Define highlight groups for vired
function M.setup()
  local highlights = {
    -- File types
    ViredDirectory = { link = "Directory" },
    ViredFile = { link = "Normal" },
    ViredSymlink = { link = "Constant" },
    ViredBrokenLink = { fg = "#ff6b6b", bold = true },
    ViredExecutable = { fg = "#98c379", bold = true },

    -- Columns
    ViredSize = { link = "Number" },
    ViredDate = { link = "Comment" },
    ViredPermissions = { link = "Comment" },
    ViredOwner = { link = "Identifier" },

    -- Marks
    ViredMarked = { fg = "#e5c07b", bold = true },
    ViredMarkedFile = { bg = "#3e4451" },

    -- Git status
    ViredGitModified = { fg = "#e5c07b" },
    ViredGitStaged = { fg = "#98c379" },
    ViredGitUntracked = { fg = "#abb2bf" },
    ViredGitIgnored = { fg = "#5c6370" },
    ViredGitConflict = { fg = "#e06c75" },

    -- UI elements
    ViredHeader = { fg = "#61afef", bold = true },
    ViredFooter = { link = "Comment" },
    ViredCursor = { link = "CursorLine" },

    -- Path picker
    ViredPickerPrompt = { fg = "#61afef", bold = true },
    ViredPickerMatch = { fg = "#e5c07b", bold = true },
    ViredPickerSelection = { bg = "#3e4451" },
    ViredPickerCreate = { fg = "#98c379", italic = true },
    ViredPickerBorder = { link = "FloatBorder" },

    -- Edit mode (wdired)
    ViredEditChanged = { fg = "#e5c07b", bg = "#3e4451" },
    ViredEditDeleted = { fg = "#e06c75", strikethrough = true },
    ViredEditNew = { fg = "#98c379", italic = true },
    ViredEditMode = { fg = "#c678dd", bold = true },
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
    return "", "ViredDirectory"
  end

  -- Try to use nvim-web-devicons
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok then
    local icon, hl = devicons.get_icon(name, nil, { default = true })
    return icon or "", hl
  end

  -- Fallback icons
  if type == "link" then
    return "", "ViredSymlink"
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

  return icon_map[ext] or "", "ViredFile"
end

return M
