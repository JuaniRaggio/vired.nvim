---Project management for vired (Projectile-like functionality)
---Automatically detects project roots and allows bookmarking projects

local M = {}

local utils = require("vired.utils")
local fs = require("vired.fs")
local config = require("vired.config")

---@class ViredProject
---@field path string Absolute path to project root
---@field name string Project name (usually directory name)
---@field added_at number Timestamp when added
---@field last_accessed number Timestamp of last access

---@type ViredProject[]
local projects = {}

---@type boolean Whether projects have been loaded from disk
local loaded = false

---@type string Path to the projects file
local projects_file = nil

-- ============================================================================
-- Project Detection
-- ============================================================================

---Default project markers (files/directories that indicate a project root)
local DEFAULT_MARKERS = {
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
  "requirements.txt",
  ".project",
  ".projectile",
  "vired-project",
}

---Get configured project markers
---@return string[]
local function get_markers()
  local cfg = config.get()
  if cfg.projects and cfg.projects.markers then
    return cfg.projects.markers
  end
  return DEFAULT_MARKERS
end

---Check if a directory contains any project marker
---@param dir string Directory to check
---@return string|nil marker The marker found, or nil
local function find_marker_in_dir(dir)
  local markers = get_markers()
  for _, marker in ipairs(markers) do
    local path = utils.join(dir, marker)
    if fs.exists(path) then
      return marker
    end
  end
  return nil
end

---Find project root starting from a directory
---@param start_dir string Starting directory
---@return string|nil root Project root path, or nil if not found
---@return string|nil marker The marker that identified the project
function M.find_root(start_dir)
  local dir = start_dir
  local home = vim.fn.expand("~")

  while dir and dir ~= "/" and dir ~= home do
    local marker = find_marker_in_dir(dir)
    if marker then
      return dir, marker
    end
    local parent = utils.parent(dir)
    if parent == dir then
      break
    end
    dir = parent
  end

  return nil, nil
end

---Get project name from path
---@param path string Project path
---@return string name
local function get_project_name(path)
  return utils.basename(path) or path
end

-- ============================================================================
-- Persistence
-- ============================================================================

---Get the path to the projects file
---@return string
local function get_projects_file()
  if projects_file then
    return projects_file
  end
  local data_dir = vim.fn.stdpath("data")
  projects_file = utils.join(data_dir, "vired_projects.json")
  return projects_file
end

---Load projects from disk
local function load_projects()
  if loaded then
    return
  end

  local file_path = get_projects_file()
  if not fs.exists(file_path) then
    loaded = true
    return
  end

  local file = io.open(file_path, "r")
  if not file then
    loaded = true
    return
  end

  local content = file:read("*all")
  file:close()

  if not content or content == "" then
    loaded = true
    return
  end

  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    projects = data
  end

  loaded = true
end

---Save projects to disk
local function save_projects()
  local file_path = get_projects_file()

  -- Ensure directory exists
  local dir = utils.parent(file_path)
  if dir and not fs.exists(dir) then
    fs.mkdir(dir)
  end

  local ok, json = pcall(vim.json.encode, projects)
  if not ok then
    vim.notify("vired: Failed to encode projects", vim.log.levels.ERROR)
    return
  end

  local file = io.open(file_path, "w")
  if not file then
    vim.notify("vired: Failed to write projects file", vim.log.levels.ERROR)
    return
  end

  file:write(json)
  file:close()
end

-- ============================================================================
-- Project Management
-- ============================================================================

---Check if a project is already bookmarked
---@param path string Project path
---@return boolean
function M.is_bookmarked(path)
  load_projects()
  local normalized = utils.normalize(path)
  for _, project in ipairs(projects) do
    if utils.normalize(project.path) == normalized then
      return true
    end
  end
  return false
end

---Add a project to bookmarks
---@param path string Project path
---@param name? string Optional custom name
---@return boolean success
function M.add(path, name)
  load_projects()

  local normalized = utils.normalize(path)

  -- Check if already exists
  if M.is_bookmarked(normalized) then
    return false
  end

  local project = {
    path = normalized,
    name = name or get_project_name(normalized),
    added_at = os.time(),
    last_accessed = os.time(),
  }

  table.insert(projects, project)
  save_projects()

  return true
end

---Remove a project from bookmarks
---@param path string Project path
---@return boolean success
function M.remove(path)
  load_projects()

  local normalized = utils.normalize(path)
  for i, project in ipairs(projects) do
    if utils.normalize(project.path) == normalized then
      table.remove(projects, i)
      save_projects()
      return true
    end
  end

  return false
end

---Update last accessed time for a project
---@param path string Project path
function M.touch(path)
  load_projects()

  local normalized = utils.normalize(path)
  for _, project in ipairs(projects) do
    if utils.normalize(project.path) == normalized then
      project.last_accessed = os.time()
      save_projects()
      return
    end
  end
end

---Get all bookmarked projects
---@param sort_by? "name"|"recent"|"added" Sort order (default: "recent")
---@return ViredProject[]
function M.list(sort_by)
  load_projects()

  local result = vim.deepcopy(projects)
  sort_by = sort_by or "recent"

  if sort_by == "name" then
    table.sort(result, function(a, b)
      return a.name:lower() < b.name:lower()
    end)
  elseif sort_by == "recent" then
    table.sort(result, function(a, b)
      return (a.last_accessed or 0) > (b.last_accessed or 0)
    end)
  elseif sort_by == "added" then
    table.sort(result, function(a, b)
      return (a.added_at or 0) > (b.added_at or 0)
    end)
  end

  return result
end

---Get project paths as strings
---@param sort_by? "name"|"recent"|"added"
---@return string[]
function M.list_paths(sort_by)
  local project_list = M.list(sort_by)
  local paths = {}
  for _, project in ipairs(project_list) do
    if fs.exists(project.path) then
      table.insert(paths, project.path)
    end
  end
  return paths
end

-- ============================================================================
-- Auto-detection and Prompting
-- ============================================================================

---@type table<string, boolean> Projects we've already prompted about this session
local prompted_this_session = {}

---Prompt user to add current project to bookmarks
---@param project_root string
---@param marker string
local function prompt_add_project(project_root, marker)
  local project_name = get_project_name(project_root)

  utils.select({
    prompt = string.format("Add '%s' to bookmarked projects? (detected by %s)", project_name, marker),
    items = {
      {
        key = "y",
        label = "Yes",
        callback = function()
          if M.add(project_root) then
            vim.notify(string.format("vired: Added '%s' to projects", project_name), vim.log.levels.INFO)
          end
        end,
      },
      {
        key = "n",
        label = "No",
        callback = function() end,
      },
      {
        key = "x",
        label = "Never ask for this project",
        callback = function()
          add_to_ignored(project_root)
        end,
      },
    },
    default_key = "y",
  })
end

---@type string[] Projects to never prompt about
local ignored_projects = {}
local ignored_loaded = false

---Get path to ignored projects file
---@return string
local function get_ignored_file()
  local data_dir = vim.fn.stdpath("data")
  return utils.join(data_dir, "vired_projects_ignored.json")
end

---Load ignored projects
local function load_ignored()
  if ignored_loaded then
    return
  end

  local file_path = get_ignored_file()
  if not fs.exists(file_path) then
    ignored_loaded = true
    return
  end

  local file = io.open(file_path, "r")
  if not file then
    ignored_loaded = true
    return
  end

  local content = file:read("*all")
  file:close()

  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    ignored_projects = data
  end

  ignored_loaded = true
end

---Save ignored projects
local function save_ignored()
  local file_path = get_ignored_file()
  local dir = utils.parent(file_path)
  if dir and not fs.exists(dir) then
    fs.mkdir(dir)
  end

  local ok, json = pcall(vim.json.encode, ignored_projects)
  if not ok then
    return
  end

  local file = io.open(file_path, "w")
  if file then
    file:write(json)
    file:close()
  end
end

---Add project to ignored list
---@param path string
function add_to_ignored(path)
  load_ignored()
  local normalized = utils.normalize(path)
  for _, ignored in ipairs(ignored_projects) do
    if ignored == normalized then
      return
    end
  end
  table.insert(ignored_projects, normalized)
  save_ignored()
end

---Check if project is ignored
---@param path string
---@return boolean
local function is_ignored(path)
  load_ignored()
  local normalized = utils.normalize(path)
  for _, ignored in ipairs(ignored_projects) do
    if ignored == normalized then
      return true
    end
  end
  return false
end

---Check directory and prompt to add if it's a new project
---@param dir string Directory being opened
function M.check_and_prompt(dir)
  local cfg = config.get()

  -- Check if auto-prompt is enabled
  if not cfg.projects or not cfg.projects.auto_prompt then
    return
  end

  local project_root, marker = M.find_root(dir)
  if not project_root then
    return
  end

  -- Already bookmarked?
  if M.is_bookmarked(project_root) then
    -- Update last accessed time
    M.touch(project_root)
    return
  end

  -- Already prompted this session?
  if prompted_this_session[project_root] then
    return
  end

  -- In ignored list?
  if is_ignored(project_root) then
    return
  end

  -- Mark as prompted
  prompted_this_session[project_root] = true

  -- Prompt after a short delay to not interrupt
  vim.defer_fn(function()
    prompt_add_project(project_root, marker)
  end, 100)
end

-- ============================================================================
-- Commands and UI
-- ============================================================================

-- ============================================================================
-- Project Picker UI (Floating Window)
-- ============================================================================

---@type number|nil Current picker buffer
local picker_buf = nil
---@type number|nil Current picker window
local picker_win = nil
---@type number|nil Results buffer
local results_buf = nil
---@type number|nil Results window
local results_win = nil
---@class FilteredProject
---@field project ViredProject
---@field score number
---@field positions number[]

---@type FilteredProject[] Current filtered projects with match info
local filtered_projects = {}
---@type number Selected index (1-based)
local selected_idx = 1

---Close project picker
local function close_picker()
  if picker_win and vim.api.nvim_win_is_valid(picker_win) then
    vim.api.nvim_win_close(picker_win, true)
  end
  if results_win and vim.api.nvim_win_is_valid(results_win) then
    vim.api.nvim_win_close(results_win, true)
  end
  if picker_buf and vim.api.nvim_buf_is_valid(picker_buf) then
    vim.api.nvim_buf_delete(picker_buf, { force = true })
  end
  if results_buf and vim.api.nvim_buf_is_valid(results_buf) then
    vim.api.nvim_buf_delete(results_buf, { force = true })
  end
  picker_buf = nil
  picker_win = nil
  results_buf = nil
  results_win = nil
  filtered_projects = {}
  selected_idx = 1
end

---Render results in the results buffer
local function render_results()
  if not results_buf or not vim.api.nvim_buf_is_valid(results_buf) then
    return
  end

  local lines = {}
  local highlights = {}

  for i, item in ipairs(filtered_projects) do
    local prefix = i == selected_idx and "> " or "  "
    local line = string.format("%s%s", prefix, item.project.name)
    table.insert(lines, line)

    -- Highlight for directory (project name)
    table.insert(highlights, {
      line = i - 1,
      col = #prefix,
      end_col = #line,
      hl = "ViredDirectory",
      priority = 10,
    })

    -- Highlight matched characters if matching name
    if item.positions and #item.positions > 0 and item.match_field == "name" then
      for _, pos in ipairs(item.positions) do
        local col = #prefix + pos - 1
        table.insert(highlights, {
          line = i - 1,
          col = col,
          end_col = col + 1,
          hl = "ViredPickerMatch",
          priority = 20,
        })
      end
    end

    -- Selection background (lowest priority)
    if i == selected_idx then
      table.insert(highlights, {
        line = i - 1,
        col = 0,
        end_col = #line,
        hl = "ViredPickerSelection",
        priority = 5,
      })
    end
  end

  if #lines == 0 then
    lines = { "  No projects found" }
  end

  vim.bo[results_buf].modifiable = true
  vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
  vim.bo[results_buf].modifiable = false

  -- Apply highlights using extmarks
  local ns = vim.api.nvim_create_namespace("vired_project_picker")
  vim.api.nvim_buf_clear_namespace(results_buf, ns, 0, -1)

  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_set_extmark, results_buf, ns, hl.line, hl.col, {
      end_col = hl.end_col,
      hl_group = hl.hl,
      priority = hl.priority or 10,
    })
  end

  -- Show path in virtual text for selected item
  if selected_idx >= 1 and selected_idx <= #filtered_projects then
    local item = filtered_projects[selected_idx]
    vim.api.nvim_buf_set_extmark(results_buf, ns, selected_idx - 1, 0, {
      virt_text = { { "  " .. item.project.path, "Comment" } },
      virt_text_pos = "eol",
    })
  end
end

---Filter projects based on input with fuzzy matching
---@param input string
local function filter_projects(input)
  local project_list = M.list("recent")

  if input == "" then
    -- No filter, show all with no match positions
    filtered_projects = {}
    for _, project in ipairs(project_list) do
      table.insert(filtered_projects, {
        project = project,
        score = 0,
        positions = {},
      })
    end
  else
    filtered_projects = {}
    for _, project in ipairs(project_list) do
      -- Try matching against name first (higher priority)
      local score, positions = utils.fuzzy_match(input, project.name)
      if score then
        table.insert(filtered_projects, {
          project = project,
          score = score + 10, -- Bonus for name match
          positions = positions,
          match_field = "name",
        })
      else
        -- Try matching against path
        score, positions = utils.fuzzy_match(input, project.path)
        if score then
          table.insert(filtered_projects, {
            project = project,
            score = score,
            positions = positions,
            match_field = "path",
          })
        end
      end
    end

    -- Sort by score descending
    table.sort(filtered_projects, function(a, b)
      return a.score > b.score
    end)
  end

  -- Reset selection
  selected_idx = 1
  render_results()
end

---Select current project and open it
local function select_project()
  if selected_idx >= 1 and selected_idx <= #filtered_projects then
    local item = filtered_projects[selected_idx]
    close_picker()
    M.touch(item.project.path)
    local vired = require("vired")
    vired.open(item.project.path)
  end
end

---Open project picker
function M.pick_project()
  local project_list = M.list("recent")

  if #project_list == 0 then
    vim.notify("vired: No bookmarked projects. Open a project directory to add it.", vim.log.levels.INFO)
    return
  end

  -- Close any existing picker
  close_picker()

  local cfg = config.get()

  -- Calculate window dimensions
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.min(#project_list + 2, 15)
  local row = math.floor((vim.o.lines - height - 3) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create input buffer
  picker_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[picker_buf].buftype = "prompt"
  vim.bo[picker_buf].bufhidden = "wipe"

  -- Create results buffer
  results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[results_buf].buftype = "nofile"
  vim.bo[results_buf].bufhidden = "wipe"
  vim.bo[results_buf].modifiable = false

  -- Create input window
  picker_win = vim.api.nvim_open_win(picker_buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = row,
    col = col,
    style = "minimal",
    border = cfg.float.border,
    title = " Projects ",
    title_pos = "center",
  })

  -- Create results window
  results_win = vim.api.nvim_open_win(results_buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row + 3,
    col = col,
    style = "minimal",
    border = cfg.float.border,
  })

  -- Initialize with all projects (wrapped in expected structure)
  filtered_projects = {}
  for _, project in ipairs(project_list) do
    table.insert(filtered_projects, {
      project = project,
      score = 0,
      positions = {},
    })
  end
  render_results()

  -- Setup prompt
  vim.fn.prompt_setprompt(picker_buf, " Project: ")

  -- Handle input changes
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = picker_buf,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(picker_buf, 0, 1, false)
      local input = lines[1] or ""
      -- Remove prompt prefix
      input = input:gsub("^ Project: ", "")
      filter_projects(input)
    end,
  })

  -- Keymaps
  local opts = { buffer = picker_buf, noremap = true, silent = true }

  -- Close on escape
  vim.keymap.set({ "i", "n" }, "<Esc>", close_picker, opts)
  vim.keymap.set({ "i", "n" }, "<C-c>", close_picker, opts)

  -- Navigation
  vim.keymap.set("i", "<C-n>", function()
    if selected_idx < #filtered_projects then
      selected_idx = selected_idx + 1
      render_results()
    end
  end, opts)

  vim.keymap.set("i", "<C-p>", function()
    if selected_idx > 1 then
      selected_idx = selected_idx - 1
      render_results()
    end
  end, opts)

  vim.keymap.set("i", "<Down>", function()
    if selected_idx < #filtered_projects then
      selected_idx = selected_idx + 1
      render_results()
    end
  end, opts)

  vim.keymap.set("i", "<Up>", function()
    if selected_idx > 1 then
      selected_idx = selected_idx - 1
      render_results()
    end
  end, opts)

  -- Select
  vim.keymap.set("i", "<CR>", select_project, opts)
  vim.keymap.set("i", "<C-o>", select_project, opts)

  -- Delete project with <C-d>
  vim.keymap.set("i", "<C-d>", function()
    if selected_idx >= 1 and selected_idx <= #filtered_projects then
      local item = filtered_projects[selected_idx]
      M.remove(item.project.path)
      vim.notify(string.format("vired: Removed '%s'", item.project.name), vim.log.levels.INFO)
      -- Re-filter to update list
      local lines = vim.api.nvim_buf_get_lines(picker_buf, 0, 1, false)
      local input = (lines[1] or ""):gsub("^ Project: ", "")
      filter_projects(input)
    end
  end, opts)

  -- Start in insert mode
  vim.cmd("startinsert!")

  -- Close when buffer is wiped
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = picker_buf,
    callback = close_picker,
    once = true,
  })
end

---Add current directory as a project
function M.add_current()
  local cwd = vim.fn.getcwd()
  local project_root, marker = M.find_root(cwd)

  if project_root then
    if M.is_bookmarked(project_root) then
      vim.notify("vired: Project already bookmarked", vim.log.levels.INFO)
    else
      M.add(project_root)
      vim.notify(string.format("vired: Added '%s' to projects", get_project_name(project_root)), vim.log.levels.INFO)
    end
  else
    -- No project marker found, ask if user wants to add cwd anyway
    utils.confirm({
      prompt = "No project marker found. Add current directory as project?",
      on_yes = function()
        M.add(cwd)
        vim.notify(string.format("vired: Added '%s' to projects", get_project_name(cwd)), vim.log.levels.INFO)
      end,
    })
  end
end

---Remove a project interactively
function M.remove_project()
  local project_list = M.list("name")

  if #project_list == 0 then
    vim.notify("vired: No bookmarked projects", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, project in ipairs(project_list) do
    table.insert(items, {
      display = string.format("%s  %s", project.name, project.path),
      project = project,
    })
  end

  vim.ui.select(items, {
    prompt = "Remove project:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if choice then
      M.remove(choice.project.path)
      vim.notify(string.format("vired: Removed '%s' from projects", choice.project.name), vim.log.levels.INFO)
    end
  end)
end

-- ============================================================================
-- Initialization
-- ============================================================================

---Setup project management
function M.setup()
  -- Create user commands
  vim.api.nvim_create_user_command("ViredProjects", function()
    M.pick_project()
  end, { desc = "Open vired project picker" })

  vim.api.nvim_create_user_command("ViredProjectAdd", function()
    M.add_current()
  end, { desc = "Add current directory as a project" })

  vim.api.nvim_create_user_command("ViredProjectRemove", function()
    M.remove_project()
  end, { desc = "Remove a bookmarked project" })
end

---Clear all data (for testing)
function M._clear()
  projects = {}
  loaded = false
  ignored_projects = {}
  ignored_loaded = false
  prompted_this_session = {}
end

---Set projects file path (for testing)
---@param path string
function M._set_projects_file(path)
  projects_file = path
  loaded = false
end

return M
