local projects = require("dired.projects")
local config = require("dired.config")

describe("dired.projects", function()
  local temp_dir
  local test_projects_file

  before_each(function()
    -- Setup config
    config.setup()

    -- Clear projects state
    projects._clear()

    -- Create temp directory for test projects file
    temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    test_projects_file = temp_dir .. "/test_projects.json"
    projects._set_projects_file(test_projects_file)
  end)

  after_each(function()
    -- Cleanup
    if temp_dir then
      vim.fn.delete(temp_dir, "rf")
    end
  end)

  describe("find_root", function()
    it("should find git repository root", function()
      -- Use the actual dired.nvim repo
      local cwd = vim.fn.getcwd()
      local root, marker = projects.find_root(cwd)

      assert.is_not_nil(root)
      assert.equals(".git", marker)
    end)

    it("should return nil for non-project directory", function()
      local root, marker = projects.find_root("/tmp")

      assert.is_nil(root)
      assert.is_nil(marker)
    end)

    it("should find project from subdirectory", function()
      local cwd = vim.fn.getcwd()
      local subdir = cwd .. "/lua/dired"
      local root, marker = projects.find_root(subdir)

      assert.equals(cwd, root)
      assert.equals(".git", marker)
    end)
  end)

  describe("add and remove", function()
    it("should add a project", function()
      local path = "/test/project"
      local result = projects.add(path)

      assert.is_true(result)
      assert.is_true(projects.is_bookmarked(path))
    end)

    it("should not add duplicate project", function()
      local path = "/test/project"
      projects.add(path)
      local result = projects.add(path)

      assert.is_false(result)
    end)

    it("should remove a project", function()
      local path = "/test/project"
      projects.add(path)

      local result = projects.remove(path)

      assert.is_true(result)
      assert.is_false(projects.is_bookmarked(path))
    end)

    it("should return false when removing non-existent project", function()
      local result = projects.remove("/non/existent")

      assert.is_false(result)
    end)

    it("should add project with custom name", function()
      local path = "/test/project"
      projects.add(path, "My Custom Project")

      local project_list = projects.list()
      assert.equals(1, #project_list)
      assert.equals("My Custom Project", project_list[1].name)
    end)
  end)

  describe("list", function()
    it("should return empty list when no projects", function()
      local result = projects.list()

      assert.equals(0, #result)
    end)

    it("should list all added projects", function()
      projects.add("/project/one")
      projects.add("/project/two")
      projects.add("/project/three")

      local result = projects.list()

      assert.equals(3, #result)
    end)

    it("should sort by name", function()
      projects.add("/project/zebra")
      projects.add("/project/alpha")
      projects.add("/project/beta")

      local result = projects.list("name")

      assert.equals("alpha", result[1].name)
      assert.equals("beta", result[2].name)
      assert.equals("zebra", result[3].name)
    end)

    it("should sort by recent access", function()
      projects.add("/project/one")
      projects.add("/project/two")
      projects.add("/project/three")

      -- Touch the middle one to make it most recent
      projects.touch("/project/one")

      local result = projects.list("recent")

      assert.equals("one", result[1].name)
    end)
  end)

  describe("list_paths", function()
    it("should return paths as strings", function()
      -- Use actual existing directories
      local cwd = vim.fn.getcwd()
      projects.add(cwd)

      local paths = projects.list_paths()

      assert.equals(1, #paths)
      assert.equals(cwd, paths[1])
    end)

    it("should filter out non-existent paths", function()
      projects.add("/non/existent/path")

      local paths = projects.list_paths()

      assert.equals(0, #paths)
    end)
  end)

  describe("is_bookmarked", function()
    it("should return true for bookmarked project", function()
      projects.add("/test/project")

      assert.is_true(projects.is_bookmarked("/test/project"))
    end)

    it("should return false for non-bookmarked project", function()
      assert.is_false(projects.is_bookmarked("/test/project"))
    end)

    it("should normalize paths when checking", function()
      projects.add("/test/project/")

      assert.is_true(projects.is_bookmarked("/test/project"))
    end)
  end)

  describe("touch", function()
    it("should update last_accessed time", function()
      projects.add("/test/project")
      local before = projects.list()[1].last_accessed

      -- Wait a bit to ensure time difference
      vim.wait(10)
      projects.touch("/test/project")

      local after = projects.list()[1].last_accessed
      assert.is_true(after >= before)
    end)

    it("should not error for non-existent project", function()
      -- Should not throw
      projects.touch("/non/existent")
    end)
  end)

  describe("persistence", function()
    it("should persist projects to file", function()
      projects.add("/test/project")

      -- Check file exists
      assert.equals(1, vim.fn.filereadable(test_projects_file))
    end)

    it("should load projects from file on next access", function()
      projects.add("/test/project")

      -- Clear and reload
      projects._clear()
      projects._set_projects_file(test_projects_file)

      assert.is_true(projects.is_bookmarked("/test/project"))
    end)
  end)
end)
