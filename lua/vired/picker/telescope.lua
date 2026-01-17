---Telescope backend for vired path picker
local M = {}

local utils = require("vired.utils")
local fs = require("vired.fs")
local config = require("vired.config")

---Check if telescope is available
---@return boolean
function M.is_available()
  local ok = pcall(require, "telescope")
  return ok
end

---Open telescope picker for directory selection
---@param opts table
---  - prompt: string
---  - default: string (starting path)
---  - cwd: string
---  - on_select: function(path)
---  - on_cancel: function()|nil
---  - create_if_missing: boolean
function M.open(opts)
  local telescope = require("telescope")
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

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
  ---@return table[]
  local function get_entries(dir)
    local entries = {}

    -- Add parent directory option
    local parent = utils.parent(dir:sub(1, -2))
    if parent and parent ~= dir:sub(1, -2) then
      table.insert(entries, {
        display = "..",
        path = parent .. "/",
        is_dir = true,
        ordinal = "..",
      })
    end

    local dir_entries, _ = fs.readdir(dir, cfg.path_picker.show_hidden)
    if dir_entries then
      for _, entry in ipairs(dir_entries) do
        local path = entry.path
        local display = entry.name
        local is_dir = entry.type == "directory"

        if is_dir then
          path = path .. "/"
          display = display .. "/"
        end

        table.insert(entries, {
          display = display,
          path = path,
          is_dir = is_dir,
          ordinal = display,
          type = entry.type,
        })
      end
    end

    return entries
  end

  ---Create a previewer for directory contents
  local dir_previewer = previewers.new_buffer_previewer({
    title = "Preview",
    define_preview = function(self, entry, status)
      local path = entry.path
      if not path then
        return
      end

      local lines = {}

      if entry.is_dir then
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
        -- Show file info/preview
        local stat = vim.loop.fs_stat(path)
        if stat then
          table.insert(lines, "File: " .. utils.basename(path))
          table.insert(lines, "Size: " .. utils.format_size(stat.size))
          table.insert(lines, "Modified: " .. utils.format_time(stat.mtime.sec))
          table.insert(lines, "")

          -- Try to show file content preview
          if stat.size < 50000 then -- Only for small files
            local file = io.open(path, "r")
            if file then
              local content = file:read("*all")
              file:close()
              if content then
                table.insert(lines, "--- Content ---")
                for line in content:gmatch("[^\n]+") do
                  table.insert(lines, line)
                  if #lines > 50 then
                    table.insert(lines, "...")
                    break
                  end
                end
              end
            end
          end
        end
      end

      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
    end,
  })

  local function make_picker(dir)
    local entries = get_entries(dir)

    return pickers.new({}, {
      prompt_title = opts.prompt or "Select Path",
      results_title = dir,
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.display,
            ordinal = entry.ordinal,
            path = entry.path,
            is_dir = entry.is_dir,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = dir_previewer,
      attach_mappings = function(prompt_bufnr, map)
        -- Enter: select file or navigate into directory
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          if not selection then
            -- No selection, use the prompt text as path
            local prompt = action_state.get_current_line()
            if prompt and prompt ~= "" then
              local path = prompt
              if not utils.is_absolute(path) then
                path = utils.join(dir, path)
              end
              actions.close(prompt_bufnr)
              if fs.is_dir(path) then
                local vired = require("vired")
                vired.open(path)
              elseif opts.on_select then
                opts.on_select(path)
              end
            end
            return
          end

          if selection.is_dir then
            -- Navigate into directory or open vired
            actions.close(prompt_bufnr)
            if selection.value.display == ".." then
              -- Go to parent, reopen picker
              make_picker(selection.path):find()
            else
              -- Open vired in this directory
              local vired = require("vired")
              vired.open(selection.path)
            end
          else
            -- Select file
            actions.close(prompt_bufnr)
            if opts.on_select then
              opts.on_select(selection.path)
            end
          end
        end)

        -- Tab: navigate into directory (stay in picker)
        map("i", "<Tab>", function()
          local selection = action_state.get_selected_entry()
          if selection and selection.is_dir then
            actions.close(prompt_bufnr)
            make_picker(selection.path):find()
          end
        end)

        map("n", "<Tab>", function()
          local selection = action_state.get_selected_entry()
          if selection and selection.is_dir then
            actions.close(prompt_bufnr)
            make_picker(selection.path):find()
          end
        end)

        -- Backspace at beginning: go to parent
        map("i", "<BS>", function()
          local prompt = action_state.get_current_line()
          if prompt == "" or prompt == nil then
            local parent = utils.parent(dir:sub(1, -2))
            if parent then
              actions.close(prompt_bufnr)
              make_picker(parent .. "/"):find()
            end
          else
            -- Normal backspace
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "n", false)
          end
        end)

        -- Escape: cancel
        map("i", "<Esc>", function()
          actions.close(prompt_bufnr)
          if opts.on_cancel then
            opts.on_cancel()
          end
        end)

        return true
      end,
    })
  end

  make_picker(current_dir):find()
end

return M
