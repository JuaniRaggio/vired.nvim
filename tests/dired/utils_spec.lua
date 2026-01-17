local utils = require("dired.utils")

describe("dired.utils", function()
  describe("normalize", function()
    it("should convert backslashes to forward slashes", function()
      assert.are.equal("/home/user/file", utils.normalize("\\home\\user\\file"))
    end)

    it("should remove trailing slash", function()
      assert.are.equal("/home/user", utils.normalize("/home/user/"))
    end)

    it("should preserve root slash", function()
      assert.are.equal("/", utils.normalize("/"))
    end)

    it("should handle empty string", function()
      assert.are.equal("", utils.normalize(""))
    end)

    it("should handle nil", function()
      assert.are.equal("", utils.normalize(nil))
    end)
  end)

  describe("join", function()
    it("should join path segments", function()
      assert.are.equal("/home/user/file", utils.join("/home", "user", "file"))
    end)

    it("should handle absolute paths in segments", function()
      assert.are.equal("/other/path", utils.join("/home", "/other/path"))
    end)

    it("should handle empty segments", function()
      assert.are.equal("/home/file", utils.join("/home", "", "file"))
    end)

    it("should handle single segment", function()
      assert.are.equal("/home", utils.join("/home"))
    end)
  end)

  describe("parent", function()
    it("should return parent directory", function()
      assert.are.equal("/home/user", utils.parent("/home/user/file.txt"))
    end)

    it("should handle root", function()
      assert.are.equal("/", utils.parent("/"))
    end)

    it("should handle single level", function()
      assert.are.equal("/", utils.parent("/home"))
    end)
  end)

  describe("basename", function()
    it("should return filename", function()
      assert.are.equal("file.txt", utils.basename("/home/user/file.txt"))
    end)

    it("should handle directories", function()
      assert.are.equal("user", utils.basename("/home/user"))
    end)

    it("should handle root", function()
      assert.are.equal("/", utils.basename("/"))
    end)
  end)

  describe("extension", function()
    it("should return extension", function()
      assert.are.equal("txt", utils.extension("/home/file.txt"))
    end)

    it("should handle multiple dots", function()
      assert.are.equal("gz", utils.extension("/home/file.tar.gz"))
    end)

    it("should return nil for no extension", function()
      assert.is_nil(utils.extension("/home/file"))
    end)

    it("should handle dotfiles", function()
      assert.are.equal("gitignore", utils.extension("/home/.gitignore"))
    end)
  end)

  describe("stem", function()
    it("should return filename without extension", function()
      assert.are.equal("file", utils.stem("/home/file.txt"))
    end)

    it("should handle multiple dots", function()
      assert.are.equal("file.tar", utils.stem("/home/file.tar.gz"))
    end)

    it("should handle no extension", function()
      assert.are.equal("file", utils.stem("/home/file"))
    end)
  end)

  describe("is_absolute", function()
    it("should detect absolute unix paths", function()
      assert.is_true(utils.is_absolute("/home/user"))
    end)

    it("should detect relative paths", function()
      assert.is_false(utils.is_absolute("home/user"))
      assert.is_false(utils.is_absolute("./file"))
      assert.is_false(utils.is_absolute("../file"))
    end)

    it("should handle empty string", function()
      assert.is_false(utils.is_absolute(""))
    end)

    it("should handle nil", function()
      assert.is_false(utils.is_absolute(nil))
    end)
  end)

  describe("expand", function()
    it("should expand tilde", function()
      local result = utils.expand("~/file")
      assert.is_not_nil(result:match("^/"))
      assert.is_true(result:match("/file$") ~= nil)
    end)

    it("should not modify paths without tilde", function()
      assert.are.equal("/home/user", utils.expand("/home/user"))
    end)
  end)

  describe("format_size", function()
    it("should format bytes", function()
      assert.are.equal("100B", utils.format_size(100))
    end)

    it("should format kilobytes", function()
      assert.are.equal("1.0K", utils.format_size(1024))
    end)

    it("should format megabytes", function()
      assert.are.equal("1.0M", utils.format_size(1024 * 1024))
    end)

    it("should format gigabytes", function()
      assert.are.equal("1.0G", utils.format_size(1024 * 1024 * 1024))
    end)
  end)

  describe("format_permissions", function()
    it("should format file permissions", function()
      -- 644 = rw-r--r--
      assert.are.equal("-rw-r--r--", utils.format_permissions(420, "file"))
    end)

    it("should format directory permissions", function()
      -- 755 = rwxr-xr-x
      assert.are.equal("drwxr-xr-x", utils.format_permissions(493, "directory"))
    end)

    it("should format symlink permissions", function()
      assert.are.equal("lrwxrwxrwx", utils.format_permissions(511, "link"))
    end)
  end)

  describe("relative", function()
    it("should return relative path", function()
      assert.are.equal("file.txt", utils.relative("/home/user/file.txt", "/home/user"))
    end)

    it("should handle nested paths", function()
      assert.are.equal("sub/file.txt", utils.relative("/home/user/sub/file.txt", "/home/user"))
    end)

    it("should return original if not under base", function()
      assert.are.equal("/other/file.txt", utils.relative("/other/file.txt", "/home/user"))
    end)
  end)

  describe("fuzzy_match", function()
    it("should match exact string", function()
      local score, positions = utils.fuzzy_match("config", "config")
      assert.is_not_nil(score)
      assert.is_true(score > 0)
      assert.are.same({ 1, 2, 3, 4, 5, 6 }, positions)
    end)

    it("should match substring", function()
      local score, positions = utils.fuzzy_match("cfg", "config")
      assert.is_not_nil(score)
      -- c=1, o=2, n=3, f=4, i=5, g=6
      assert.are.same({ 1, 4, 6 }, positions)
    end)

    it("should be case insensitive", function()
      local score, positions = utils.fuzzy_match("CFG", "config")
      assert.is_not_nil(score)
      assert.are.same({ 1, 4, 6 }, positions)
    end)

    it("should return nil for no match", function()
      local score, positions = utils.fuzzy_match("xyz", "config")
      assert.is_nil(score)
      assert.is_nil(positions)
    end)

    it("should return nil if pattern is longer than string", function()
      local score, positions = utils.fuzzy_match("configfile", "config")
      assert.is_nil(score)
      assert.is_nil(positions)
    end)

    it("should handle empty pattern", function()
      local score, positions = utils.fuzzy_match("", "config")
      assert.are.equal(0, score)
      assert.are.same({}, positions)
    end)

    it("should handle empty string", function()
      local score, positions = utils.fuzzy_match("cfg", "")
      assert.is_nil(score)
      assert.is_nil(positions)
    end)

    it("should give bonus for consecutive matches", function()
      local score_consecutive, _ = utils.fuzzy_match("con", "config")
      local score_scattered, _ = utils.fuzzy_match("cfg", "config")
      assert.is_true(score_consecutive > score_scattered)
    end)

    it("should give bonus for start of string", function()
      local score_start, _ = utils.fuzzy_match("con", "config")
      local score_middle, _ = utils.fuzzy_match("fig", "config")
      assert.is_true(score_start > score_middle)
    end)

    it("should match after separators", function()
      local score, positions = utils.fuzzy_match("fb", "foo_bar")
      assert.is_not_nil(score)
      assert.are.same({ 1, 5 }, positions)
    end)

    it("should match path segments", function()
      local score, positions = utils.fuzzy_match("ul", "user/local")
      assert.is_not_nil(score)
    end)
  end)

  describe("fuzzy_filter", function()
    it("should filter and sort by score", function()
      local items = { "config", "container", "constant", "cfg" }
      local matches = utils.fuzzy_filter("con", items)

      assert.is_true(#matches >= 2)
      -- First results should be better matches
      assert.is_true(matches[1].score >= matches[2].score)
    end)

    it("should exclude non-matching items", function()
      local items = { "config", "data", "test" }
      local matches = utils.fuzzy_filter("cfg", items)

      assert.are.equal(1, #matches)
      assert.are.equal("config", matches[1].str)
    end)

    it("should respect limit", function()
      local items = {}
      for i = 1, 100 do
        table.insert(items, "file" .. i)
      end

      local matches = utils.fuzzy_filter("file", items, 10)
      assert.are.equal(10, #matches)
    end)

    it("should return empty for no matches", function()
      local items = { "aaa", "bbb", "ccc" }
      local matches = utils.fuzzy_filter("xyz", items)
      assert.are.equal(0, #matches)
    end)
  end)

  describe("prefix_match", function()
    it("should match prefix", function()
      assert.is_true(utils.prefix_match("con", "config"))
    end)

    it("should be case insensitive", function()
      assert.is_true(utils.prefix_match("CON", "config"))
    end)

    it("should return false for non-match", function()
      assert.is_false(utils.prefix_match("xyz", "config"))
    end)

    it("should return true for empty prefix", function()
      assert.is_true(utils.prefix_match("", "config"))
    end)
  end)
end)
