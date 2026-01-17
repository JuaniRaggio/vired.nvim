---fzf-lua backend for dired path picker
local M = {}

local utils = require("dired.utils")
local fs = require("dired.fs")
local config = require("dired.config")

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

  ---Generate preview for an entry
  ---@param dir string Current directory
  ---@return function
  local function make_previewer(dir)
    return function(items)
      if not items or #items == 0 then
        return {}
      end

      local item = items[1]
      -- Strip ANSI codes
      item = fzf.utils.strip_ansi_coloring(item)

      local path
      if item == "../" or item == ".." then
        path = utils.parent(dir:sub(1, -2))
      else
        -- Remove trailing /
        local name = item:gsub("/$", "")
        path = utils.join(dir, name)
      end

      if not path or not fs.exists(path) then
        return { "(path not found)" }
      end

      local lines = {}

      if fs.is_dir(path) then
        -- Show directory contents
        local preview_entries, _ = fs.readdir(path, cfg.path_picker.show_hidden)
        if preview_entries and #preview_entries > 0 then
          for i, e in ipairs(preview_entries) do
            if i > 30 then
              table.insert(lines, string.format("... and %d more", #preview_entries - 30))
              break
            end
            local icon = e.type == "directory" and "" or ""
            local name = e.name
            if e.type == "directory" then
              name = name .. "/"
            end
            table.insert(lines, string.format(" %s %s", icon, name))
          end
        else
          table.insert(lines, "  (empty directory)")
        end
      else
        -- Show file info
        local stat = vim.loop.fs_stat(path)
        if stat then
          table.insert(lines, "File: " .. utils.basename(path))
          table.insert(lines, "Size: " .. utils.format_size(stat.size))
          table.insert(lines, "Modified: " .. utils.format_time(stat.mtime.sec))
        end
      end

      return lines
    end
  end

  local function open_picker(dir)
    local entries = get_entries(dir)

    fzf.fzf_exec(entries, {
      prompt = (opts.prompt or "Path") .. " " .. dir .. " > ",
      previewer = {
        _ctor = function()
          return {
            parse_entry = function(_, entry)
              return entry
            end,
            preview = make_previewer(dir),
          }
        end,
      },
      fzf_opts = {
        ["--preview-window"] = "right:50%",
        ["--ansi"] = "",
      },
      actions = {
        ["default"] = function(selected)
          if not selected or #selected == 0 then
            return
          end

          local item = fzf.utils.strip_ansi_coloring(selected[1])

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

          if fs.is_dir(path) then
            -- Open dired
            local dired = require("dired")
            dired.open(path)
          else
            -- File selected
            if opts.on_select then
              opts.on_select(path)
            end
          end
        end,
        ["tab"] = function(selected)
          if not selected or #selected == 0 then
            return
          end

          local item = fzf.utils.strip_ansi_coloring(selected[1])

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
