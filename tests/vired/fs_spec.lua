local fs = require("vired.fs")
local utils = require("vired.utils")

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

describe("vired.fs", function()
  local temp_dir

  before_each(function()
    temp_dir = create_temp_dir()
  end)

  after_each(function()
    cleanup(temp_dir)
  end)

  describe("exists", function()
    it("should return true for existing directory", function()
      assert.is_true(fs.exists(temp_dir))
    end)

    it("should return false for non-existing path", function()
      assert.is_false(fs.exists(temp_dir .. "/nonexistent"))
    end)
  end)

  describe("is_dir", function()
    it("should return true for directory", function()
      assert.is_true(fs.is_dir(temp_dir))
    end)

    it("should return false for file", function()
      local file = temp_dir .. "/test.txt"
      vim.fn.writefile({}, file)
      assert.is_false(fs.is_dir(file))
    end)
  end)

  describe("is_file", function()
    it("should return true for file", function()
      local file = temp_dir .. "/test.txt"
      vim.fn.writefile({}, file)
      assert.is_true(fs.is_file(file))
    end)

    it("should return false for directory", function()
      assert.is_false(fs.is_file(temp_dir))
    end)
  end)

  describe("stat", function()
    it("should return entry info for file", function()
      local file = temp_dir .. "/test.txt"
      vim.fn.writefile({ "hello" }, file)

      local entry, err = fs.stat(file)
      assert.is_nil(err)
      assert.is_not_nil(entry)
      assert.are.equal("test.txt", entry.name)
      assert.are.equal(file, entry.path)
      assert.are.equal("file", entry.type)
    end)

    it("should return entry info for directory", function()
      local entry, err = fs.stat(temp_dir)
      assert.is_nil(err)
      assert.is_not_nil(entry)
      assert.are.equal("directory", entry.type)
    end)

    it("should return error for non-existing path", function()
      local entry, err = fs.stat(temp_dir .. "/nonexistent")
      assert.is_nil(entry)
      assert.is_not_nil(err)
    end)
  end)

  describe("readdir", function()
    it("should list directory contents", function()
      vim.fn.writefile({}, temp_dir .. "/file1.txt")
      vim.fn.writefile({}, temp_dir .. "/file2.txt")
      vim.fn.mkdir(temp_dir .. "/subdir")

      local entries, err = fs.readdir(temp_dir)
      assert.is_nil(err)
      assert.are.equal(3, #entries)
    end)

    it("should sort directories first", function()
      vim.fn.writefile({}, temp_dir .. "/aaa.txt")
      vim.fn.mkdir(temp_dir .. "/zzz")

      local entries, err = fs.readdir(temp_dir)
      assert.is_nil(err)
      assert.are.equal("zzz", entries[1].name) -- directory first
      assert.are.equal("aaa.txt", entries[2].name)
    end)

    it("should hide hidden files by default", function()
      vim.fn.writefile({}, temp_dir .. "/.hidden")
      vim.fn.writefile({}, temp_dir .. "/visible.txt")

      local entries, err = fs.readdir(temp_dir, false)
      assert.is_nil(err)
      assert.are.equal(1, #entries)
      assert.are.equal("visible.txt", entries[1].name)
    end)

    it("should show hidden files when requested", function()
      vim.fn.writefile({}, temp_dir .. "/.hidden")
      vim.fn.writefile({}, temp_dir .. "/visible.txt")

      local entries, err = fs.readdir(temp_dir, true)
      assert.is_nil(err)
      assert.are.equal(2, #entries)
    end)
  end)

  describe("mkdir", function()
    it("should create directory", function()
      local path = temp_dir .. "/newdir"
      local ok, err = fs.mkdir(path)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.is_dir(path))
    end)

    it("should create nested directories", function()
      local path = temp_dir .. "/a/b/c"
      local ok, err = fs.mkdir(path)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.is_dir(path))
    end)

    it("should succeed if directory already exists", function()
      local ok, err = fs.mkdir(temp_dir)
      assert.is_true(ok)
      assert.is_nil(err)
    end)
  end)

  describe("touch", function()
    it("should create empty file", function()
      local path = temp_dir .. "/newfile.txt"
      local ok, err = fs.touch(path)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.is_file(path))
    end)

    it("should create parent directories", function()
      local path = temp_dir .. "/a/b/newfile.txt"
      local ok, err = fs.touch(path)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.is_file(path))
    end)
  end)

  describe("delete", function()
    it("should delete file", function()
      local path = temp_dir .. "/todelete.txt"
      vim.fn.writefile({}, path)
      assert.is_true(fs.exists(path))

      local ok, err = fs.delete(path)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_false(fs.exists(path))
    end)

    it("should delete empty directory", function()
      local path = temp_dir .. "/emptydir"
      vim.fn.mkdir(path)
      assert.is_true(fs.exists(path))

      local ok, err = fs.delete(path)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_false(fs.exists(path))
    end)

    it("should succeed for non-existing path", function()
      local ok, err = fs.delete(temp_dir .. "/nonexistent")
      assert.is_true(ok)
      assert.is_nil(err)
    end)
  end)

  describe("delete_recursive", function()
    it("should delete directory with contents", function()
      local path = temp_dir .. "/fulldir"
      vim.fn.mkdir(path)
      vim.fn.writefile({}, path .. "/file.txt")
      vim.fn.mkdir(path .. "/subdir")
      vim.fn.writefile({}, path .. "/subdir/nested.txt")

      local ok, err = fs.delete_recursive(path)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_false(fs.exists(path))
    end)
  end)

  describe("rename", function()
    it("should rename file", function()
      local src = temp_dir .. "/original.txt"
      local dest = temp_dir .. "/renamed.txt"
      vim.fn.writefile({ "content" }, src)

      local ok, err = fs.rename(src, dest)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_false(fs.exists(src))
      assert.is_true(fs.exists(dest))
    end)

    it("should move file to different directory", function()
      local src = temp_dir .. "/file.txt"
      local dest_dir = temp_dir .. "/subdir"
      local dest = dest_dir .. "/file.txt"
      vim.fn.writefile({}, src)

      local ok, err = fs.rename(src, dest)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_false(fs.exists(src))
      assert.is_true(fs.exists(dest))
    end)

    it("should create destination directory if needed", function()
      local src = temp_dir .. "/file.txt"
      local dest = temp_dir .. "/a/b/c/file.txt"
      vim.fn.writefile({}, src)

      local ok, err = fs.rename(src, dest)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.exists(dest))
    end)
  end)

  describe("copy_file", function()
    it("should copy file", function()
      local src = temp_dir .. "/original.txt"
      local dest = temp_dir .. "/copy.txt"
      vim.fn.writefile({ "content" }, src)

      local ok, err = fs.copy_file(src, dest)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.exists(src)) -- original still exists
      assert.is_true(fs.exists(dest))
    end)
  end)

  describe("copy_dir", function()
    it("should copy directory recursively", function()
      local src = temp_dir .. "/srcdir"
      local dest = temp_dir .. "/destdir"
      vim.fn.mkdir(src)
      vim.fn.writefile({ "content" }, src .. "/file.txt")
      vim.fn.mkdir(src .. "/subdir")
      vim.fn.writefile({}, src .. "/subdir/nested.txt")

      local ok, err = fs.copy_dir(src, dest)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_true(fs.exists(dest))
      assert.is_true(fs.exists(dest .. "/file.txt"))
      assert.is_true(fs.exists(dest .. "/subdir/nested.txt"))
    end)
  end)
end)
