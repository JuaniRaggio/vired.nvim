---fzf-lua backend for vired path picker
local M = {}

local utils = require("vired.utils")
local fs = require("vired.fs")
local config = require("vired.config")

---Check if fzf-lua is available
---@return boolean
function M.is_available()
  local ok = pcall(require, "fzf-lua")
  return ok
end

---Open fzf-lua picker for directory selection
---@param opts table
---  - prompt: string
---  - default: string (starting path)
---  - cwd: string
---  - on_select: function(path)
---  - on_cancel: function()|nil
---  - create_if_missing: boolean
function M.open(opts)
  local fzf = require("fzf-lua")

  local current_dir = opts.default or opts.cwd or vim.loop.cwd()
  -- Remove trailing filename if present, keep only directory
  if not fs.is_dir(current_dir) then
    current_dir = utils.parent(current_dir) or vim.loop.cwd()
  end
  -- Ensure trailing slash
  if current_dir:sub(-1) ~= "/" then
    current_dir = current_dir .. "/"
  end

  local cfg = config.get()

  ---Get entries for a directory
  ---@param dir string
  ---@return string[]
  local function get_entries(dir)
    local entries = {}

    -- Add "." entry to open vired in current directory
    table.insert(entries, fzf.utils.ansi_codes.green(".") .. "  [Open vired here]")

    -- Add parent directory option
    local parent = utils.parent(dir:sub(1, -2))
    if parent and parent ~= dir:sub(1, -2) then
      table.insert(entries, fzf.utils.ansi_codes.blue("..") .. "/")
    end

    local dir_entries, _ = fs.readdir(dir, cfg.path_picker.show_hidden)
    if dir_entries then
      for _, entry in ipairs(dir_entries) do
        local display = entry.name
        local is_dir = entry.type == "directory"

        if is_dir then
          display = fzf.utils.ansi_codes.blue(display) .. "/"
        elseif entry.type == "link" then
          display = fzf.utils.ansi_codes.cyan(display)
        end

        table.insert(entries, display)
      end
    end

    return entries
  end

  local function open_picker(dir)
    local entries = get_entries(dir)

    fzf.fzf_exec(entries, {
      prompt = (opts.prompt or "Path") .. " " .. dir .. " > ",
      previewer = false, -- Disable previewer to avoid API compatibility issues
      fzf_opts = {
        ["--ansi"] = "",
      },
      actions = {
        ["default"] = function(selected)
          if not selected or #selected == 0 then
            return
          end

          local item = fzf.utils.strip_ansi_coloring(selected[1])

          -- Handle "." entry
          if item:match("^%.%s+%[") or item == "." then
            if opts.on_select then
              opts.on_select(dir:gsub("/$", ""))
            else
              local vired = require("vired")
              vired.open(dir:gsub("/$", ""))
            end
            return
          end

          local path
          if item == "../" or item == ".." then
            path = utils.parent(dir:sub(1, -2))
            if path then
              path = path .. "/"
            end
          else
            local name = item:gsub("/$", "")
            path = utils.join(dir, name)
            if fs.is_dir(path) then
              path = path .. "/"
            end
          end

          if not path then
            return
          end

          local clean_path = path:gsub("/$", "")
          if opts.on_select then
            -- Has callback (move/copy) - call it
            opts.on_select(clean_path)
          elseif fs.is_dir(path) then
            -- No callback, directory - open vired
            local vired = require("vired")
            vired.open(clean_path)
          else
            -- No callback, file - open it
            vim.cmd("edit " .. vim.fn.fnameescape(path))
          end
        end,
        ["tab"] = function(selected)
          if not selected or #selected == 0 then
            return
          end

          local item = fzf.utils.strip_ansi_coloring(selected[1])

          -- Skip "." entry for tab navigation
          if item:match("^%.%s+%[") or item == "." then
            return
          end

          local path
          if item == "../" or item == ".." then
            path = utils.parent(dir:sub(1, -2))
            if path then
              path = path .. "/"
            end
          else
            local name = item:gsub("/$", "")
            path = utils.join(dir, name)
            if fs.is_dir(path) then
              path = path .. "/"
            end
          end

          if path and fs.is_dir(path) then
            -- Change working directory
            vim.cmd.cd(path:gsub("/$", ""))
            -- Navigate into directory
            vim.schedule(function()
              open_picker(path)
            end)
          end
        end,
        ["esc"] = function()
          if opts.on_cancel then
            opts.on_cancel()
          end
        end,
      },
    })
  end

  open_picker(current_dir)
end

return M
