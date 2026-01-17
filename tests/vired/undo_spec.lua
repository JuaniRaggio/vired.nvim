local undo = require("vired.undo")
local fs = require("vired.fs")
local config = require("vired.config")

describe("vired.undo", function()
  local temp_dir
  local trash_dir

  before_each(function()
    -- Setup config
    config.setup()

    -- Clear undo state
    undo._clear()

    -- Create temp directories
    temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")

    trash_dir = temp_dir .. "/trash"
    vim.fn.mkdir(trash_dir, "p")
    undo._set_trash_dir(trash_dir)
  end)

  after_each(function()
    -- Cleanup
    if temp_dir then
      vim.fn.delete(temp_dir, "rf")
    end
  end)

  describe("can_undo and can_redo", function()
    it("should return false when no operations", function()
      assert.is_false(undo.can_undo())
      assert.is_false(undo.can_redo())
    end)

    it("should return true after recording operation", function()
      undo.record_rename("/old", "/new")

      assert.is_true(undo.can_undo())
      assert.is_false(undo.can_redo())
    end)
  end)

  describe("record and describe operations", function()
    it("should record rename operation", function()
      undo.record_rename("/path/old.txt", "/path/new.txt")

      local desc = undo.peek_undo()
      assert.is_not_nil(desc)
      assert.matches("Rename", desc)
    end)

    it("should record delete operation", function()
      undo.record_delete("/path/file.txt", "/trash/file.txt", false)

      local desc = undo.peek_undo()
      assert.is_not_nil(desc)
      assert.matches("Delete", desc)
    end)

    it("should record copy operation", function()
      undo.record_copy("/src/file.txt", "/dest/file.txt")

      local desc = undo.peek_undo()
      assert.is_not_nil(desc)
      assert.matches("Copy", desc)
    end)

    it("should record mkdir operation", function()
      undo.record_mkdir("/path/newdir")

      local desc = undo.peek_undo()
      assert.is_not_nil(desc)
      assert.matches("Create directory", desc)
    end)

    it("should record touch operation", function()
      undo.record_touch("/path/newfile.txt")

      local desc = undo.peek_undo()
      assert.is_not_nil(desc)
      assert.matches("Create file", desc)
    end)
  end)

  describe("rename_with_undo", function()
    it("should rename file and record operation", function()
      -- Create test file
      local src = temp_dir .. "/source.txt"
      local dest = temp_dir .. "/dest.txt"
      local file = io.open(src, "w")
      file:write("test content")
      file:close()

      local ok, err = undo.rename_with_undo(src, dest)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_false(fs.exists(src))
      assert.is_true(fs.exists(dest))
      assert.is_true(undo.can_undo())
    end)

    it("should undo rename operation", function()
      local src = temp_dir .. "/source.txt"
      local dest = temp_dir .. "/dest.txt"
      local file = io.open(src, "w")
      file:write("test content")
      file:close()

      undo.rename_with_undo(src, dest)
      local ok, err = undo.undo()

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.exists(src))
      assert.is_false(fs.exists(dest))
      assert.is_true(undo.can_redo())
    end)

    it("should redo rename operation", function()
      local src = temp_dir .. "/source.txt"
      local dest = temp_dir .. "/dest.txt"
      local file = io.open(src, "w")
      file:write("test content")
      file:close()

      undo.rename_with_undo(src, dest)
      undo.undo()
      local ok, err = undo.redo()

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_false(fs.exists(src))
      assert.is_true(fs.exists(dest))
    end)
  end)

  describe("delete_with_undo", function()
    it("should move file to trash and record operation", function()
      local path = temp_dir .. "/todelete.txt"
      local file = io.open(path, "w")
      file:write("delete me")
      file:close()

      local ok, err = undo.delete_with_undo(path)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_false(fs.exists(path))
      assert.is_true(undo.can_undo())
    end)

    it("should restore file from trash on undo", function()
      local path = temp_dir .. "/todelete.txt"
      local file = io.open(path, "w")
      file:write("delete me")
      file:close()

      undo.delete_with_undo(path)
      local ok, err = undo.undo()

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.exists(path))

      -- Verify content is preserved
      local restored = io.open(path, "r")
      local content = restored:read("*all")
      restored:close()
      assert.equals("delete me", content)
    end)

    it("should delete directory and restore on undo", function()
      local dir = temp_dir .. "/todeleteDir"
      vim.fn.mkdir(dir, "p")

      -- Create a file inside
      local file = io.open(dir .. "/file.txt", "w")
      file:write("content")
      file:close()

      undo.delete_with_undo(dir)
      assert.is_false(fs.exists(dir))

      undo.undo()
      assert.is_true(fs.exists(dir))
      assert.is_true(fs.exists(dir .. "/file.txt"))
    end)
  end)

  describe("copy_with_undo", function()
    it("should copy file and record operation", function()
      local src = temp_dir .. "/source.txt"
      local dest = temp_dir .. "/copy.txt"
      local file = io.open(src, "w")
      file:write("original")
      file:close()

      local ok, err = undo.copy_with_undo(src, dest)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.exists(src))
      assert.is_true(fs.exists(dest))
      assert.is_true(undo.can_undo())
    end)

    it("should remove copy on undo", function()
      local src = temp_dir .. "/source.txt"
      local dest = temp_dir .. "/copy.txt"
      local file = io.open(src, "w")
      file:write("original")
      file:close()

      undo.copy_with_undo(src, dest)
      local ok, err = undo.undo()

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.exists(src))
      assert.is_false(fs.exists(dest))
    end)
  end)

  describe("mkdir_with_undo", function()
    it("should create directory and record operation", function()
      local dir = temp_dir .. "/newdir"

      local ok, err = undo.mkdir_with_undo(dir)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.is_dir(dir))
      assert.is_true(undo.can_undo())
    end)

    it("should remove directory on undo", function()
      local dir = temp_dir .. "/newdir"

      undo.mkdir_with_undo(dir)
      local ok, err = undo.undo()

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_false(fs.exists(dir))
    end)

    it("should not undo mkdir if directory has contents", function()
      local dir = temp_dir .. "/newdir"

      undo.mkdir_with_undo(dir)

      -- Add a file to the directory
      local file = io.open(dir .. "/file.txt", "w")
      file:write("content")
      file:close()

      local ok, err = undo.undo()

      assert.is_false(ok)
      assert.matches("not empty", err)
      assert.is_true(fs.exists(dir))
    end)
  end)

  describe("touch_with_undo", function()
    it("should create file and record operation", function()
      local path = temp_dir .. "/newfile.txt"

      local ok, err = undo.touch_with_undo(path)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.is_file(path))
      assert.is_true(undo.can_undo())
    end)

    it("should remove file on undo", function()
      local path = temp_dir .. "/newfile.txt"

      undo.touch_with_undo(path)
      local ok, err = undo.undo()

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_false(fs.exists(path))
    end)
  end)

  describe("get_history", function()
    it("should return empty list when no operations", function()
      local history = undo.get_history()

      assert.equals(0, #history)
    end)

    it("should return operations in reverse order", function()
      undo.record_mkdir("/dir1")
      undo.record_mkdir("/dir2")
      undo.record_mkdir("/dir3")

      local history = undo.get_history()

      assert.equals(3, #history)
      assert.matches("dir3", history[1].description)
      assert.matches("dir1", history[3].description)
    end)

    it("should respect limit parameter", function()
      for i = 1, 20 do
        undo.record_mkdir("/dir" .. i)
      end

      local history = undo.get_history(5)

      assert.equals(5, #history)
    end)
  end)

  describe("clear_history", function()
    it("should clear all undo and redo stacks", function()
      undo.record_mkdir("/dir1")
      undo.record_mkdir("/dir2")

      undo.clear_history()

      assert.is_false(undo.can_undo())
      assert.is_false(undo.can_redo())
    end)
  end)

  describe("undo count", function()
    it("should track undo stack size", function()
      assert.equals(0, undo.get_undo_count())

      undo.record_mkdir("/dir1")
      assert.equals(1, undo.get_undo_count())

      undo.record_mkdir("/dir2")
      assert.equals(2, undo.get_undo_count())
    end)

    it("should track redo stack size", function()
      local dir = temp_dir .. "/testdir"
      undo.mkdir_with_undo(dir)

      assert.equals(0, undo.get_redo_count())

      undo.undo()
      assert.equals(1, undo.get_redo_count())
    end)
  end)
end)
