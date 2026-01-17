local watcher = require("vired.watcher")
local config = require("vired.config")

-- Helper to create temp directory for tests
local function create_temp_dir()
  local tmp = os.tmpname()
  os.remove(tmp)
  vim.fn.mkdir(tmp, "p")
  return tmp
end

-- Helper to cleanup
local function cleanup(path)
  if vim.fn.isdirectory(path) == 1 then
    vim.fn.delete(path, "rf")
  elseif vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
end

-- Helper to create a scratch buffer
local function create_test_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  return bufnr
end

describe("vired.watcher", function()
  local temp_dir
  local test_bufnr

  before_each(function()
    temp_dir = create_temp_dir()
    test_bufnr = create_test_buffer()
    -- Ensure watcher is enabled in config
    config.setup({ watcher = { enabled = true, debounce_ms = 50 } })
  end)

  after_each(function()
    watcher.stop_all()
    if vim.api.nvim_buf_is_valid(test_bufnr) then
      vim.api.nvim_buf_delete(test_bufnr, { force = true })
    end
    cleanup(temp_dir)
  end)

  describe("start", function()
    it("should start watching a directory", function()
      watcher.start(test_bufnr, temp_dir)
      assert.is_true(watcher.is_watching(test_bufnr))
    end)

    it("should not watch when disabled in config", function()
      config.setup({ watcher = { enabled = false } })
      watcher.start(test_bufnr, temp_dir)
      assert.is_false(watcher.is_watching(test_bufnr))
    end)
  end)

  describe("stop", function()
    it("should stop watching a buffer", function()
      watcher.start(test_bufnr, temp_dir)
      assert.is_true(watcher.is_watching(test_bufnr))

      watcher.stop(test_bufnr)
      assert.is_false(watcher.is_watching(test_bufnr))
    end)

    it("should handle stopping non-existent watcher gracefully", function()
      -- Should not error
      watcher.stop(999999)
      assert.is_false(watcher.is_watching(999999))
    end)
  end)

  describe("update", function()
    it("should update watcher to new path", function()
      watcher.start(test_bufnr, temp_dir)
      assert.is_true(watcher.is_watching(test_bufnr))

      local new_dir = create_temp_dir()
      watcher.update(test_bufnr, new_dir)
      assert.is_true(watcher.is_watching(test_bufnr))

      cleanup(new_dir)
    end)
  end)

  describe("is_watching", function()
    it("should return false for non-watched buffer", function()
      assert.is_false(watcher.is_watching(test_bufnr))
    end)

    it("should return true for watched buffer", function()
      watcher.start(test_bufnr, temp_dir)
      assert.is_true(watcher.is_watching(test_bufnr))
    end)
  end)

  describe("stop_all", function()
    it("should stop all watchers", function()
      local bufnr1 = create_test_buffer()
      local bufnr2 = create_test_buffer()
      local dir1 = create_temp_dir()
      local dir2 = create_temp_dir()

      watcher.start(bufnr1, dir1)
      watcher.start(bufnr2, dir2)

      assert.is_true(watcher.is_watching(bufnr1))
      assert.is_true(watcher.is_watching(bufnr2))

      watcher.stop_all()

      assert.is_false(watcher.is_watching(bufnr1))
      assert.is_false(watcher.is_watching(bufnr2))

      vim.api.nvim_buf_delete(bufnr1, { force = true })
      vim.api.nvim_buf_delete(bufnr2, { force = true })
      cleanup(dir1)
      cleanup(dir2)
    end)
  end)

  describe("pending_refresh", function()
    it("should track pending refresh state", function()
      watcher.start(test_bufnr, temp_dir)

      -- Initially no pending refresh
      assert.is_false(watcher.has_pending_refresh(test_bufnr))
    end)

    it("should clear pending refresh", function()
      watcher.start(test_bufnr, temp_dir)
      watcher.clear_pending_refresh(test_bufnr)
      assert.is_false(watcher.has_pending_refresh(test_bufnr))
    end)

    it("should return false for non-watched buffer", function()
      assert.is_false(watcher.has_pending_refresh(999999))
    end)
  end)

  describe("config integration", function()
    it("should use custom debounce_ms from config", function()
      config.setup({ watcher = { enabled = true, debounce_ms = 500 } })
      watcher.start(test_bufnr, temp_dir)
      assert.is_true(watcher.is_watching(test_bufnr))
    end)

    it("should respect enabled=false", function()
      config.setup({ watcher = { enabled = false, debounce_ms = 200 } })
      watcher.start(test_bufnr, temp_dir)
      assert.is_false(watcher.is_watching(test_bufnr))
    end)
  end)
end)
