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
  -- Try to use nvim-web-devicons first for directories too
  local ok, devicons = pcall(require, "nvim-web-devicons")

  if type == "directory" then
    if ok and devicons.get_icon then
      -- Try to get folder icon from devicons
      local icon = devicons.get_icon("folder", nil, { default = false })
      if icon then
        return icon, "ViredDirectory"
      end
    end
    -- Fallback folder icon (nerd font)
    return "\u{f07b}", "ViredDirectory"
  end

  if ok then
    local icon, hl = devicons.get_icon(name, nil, { default = true })
    return icon or "\u{f15b}", hl
  end

  -- Fallback icons
  if type == "link" then
    return "\u{f0c1}", "ViredSymlink"
  end

  local ext = name:match("%.([^%.]+)$")
  local icon_map = {
    lua = "\u{e620}",
    py = "\u{e73c}",
    js = "\u{e74e}",
    ts = "\u{e628}",
    rs = "\u{e7a8}",
    go = "\u{e626}",
    c = "\u{e61e}",
    cpp = "\u{e61d}",
    h = "\u{e61e}",
    md = "\u{e73e}",
    json = "\u{e60b}",
    yaml = "\u{e60b}",
    yml = "\u{e60b}",
    toml = "\u{e60b}",
    sh = "\u{e795}",
    bash = "\u{e795}",
    zsh = "\u{e795}",
    vim = "\u{e62b}",
    git = "\u{e702}",
    txt = "\u{f15c}",
  }

  return icon_map[ext] or "\u{f15b}", "ViredFile"
end

return M
