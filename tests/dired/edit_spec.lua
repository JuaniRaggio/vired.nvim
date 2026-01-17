local edit = require("dired.edit")

describe("dired.edit", function()
  describe("parse_line_name", function()
    local columns = { "icon", "permissions", "size", "mtime" }

    it("should parse file name from rendered line", function()
      -- Simulated rendered line with all columns
      local line = "   M  -rw-r--r--   1.2K 2024-01-15 myfile.lua"
      local name, entry_type = edit.parse_line_name(line, columns)

      assert.are.equal("myfile.lua", name)
      assert.are.equal("file", entry_type)
    end)

    it("should parse directory name (ends with /)", function()
      local line = "*  M  drwxr-xr-x      - 2024-01-15 mydir/"
      local name, entry_type = edit.parse_line_name(line, columns)

      assert.are.equal("mydir", name)
      assert.are.equal("directory", entry_type)
    end)

    it("should parse symlink name", function()
      local line = "      -rw-r--r--   1.2K 2024-01-15 link.txt -> target.txt"
      local name, entry_type = edit.parse_line_name(line, columns)

      assert.are.equal("link.txt", name)
      assert.are.equal("link", entry_type)
    end)

    it("should return nil for empty line", function()
      local name, entry_type = edit.parse_line_name("", columns)
      assert.is_nil(name)
      assert.is_nil(entry_type)
    end)

    it("should return nil for header line", function()
      local line = "  /path/to/directory [hidden]"
      local name, entry_type = edit.parse_line_name(line, columns)
      assert.is_nil(name)
    end)
  end)

  describe("is_editing", function()
    it("should return false for non-editing buffer", function()
      assert.is_false(edit.is_editing(99999))
    end)
  end)

  describe("format_operations_summary", function()
    it("should format rename operation", function()
      local ops = {
        { type = "rename", source = "/path/old.txt", dest = "/path/new.txt" },
      }
      local summary = edit.format_operations_summary(ops)
      assert.is_truthy(summary:find("Rename"))
      assert.is_truthy(summary:find("old.txt"))
      assert.is_truthy(summary:find("new.txt"))
    end)

    it("should format delete operation", function()
      local ops = {
        { type = "delete", source = "/path/file.txt", dest = nil },
      }
      local summary = edit.format_operations_summary(ops)
      assert.is_truthy(summary:find("Delete"))
      assert.is_truthy(summary:find("file.txt"))
    end)

    it("should format create operation", function()
      local ops = {
        { type = "create", source = nil, dest = "/path/newfile.txt" },
      }
      local summary = edit.format_operations_summary(ops)
      assert.is_truthy(summary:find("Create"))
      assert.is_truthy(summary:find("newfile.txt"))
    end)

    it("should format multiple operations", function()
      local ops = {
        { type = "rename", source = "/path/a.txt", dest = "/path/b.txt" },
        { type = "delete", source = "/path/c.txt", dest = nil },
        { type = "create", source = nil, dest = "/path/d.txt" },
      }
      local summary = edit.format_operations_summary(ops)
      assert.is_truthy(summary:find("Rename"))
      assert.is_truthy(summary:find("Delete"))
      assert.is_truthy(summary:find("Create"))
    end)
  end)

  describe("snapshot management", function()
    it("should return nil for buffer without snapshot", function()
      local snapshot = edit.get_snapshot(99999)
      assert.is_nil(snapshot)
    end)

    it("should clear snapshot without error", function()
      -- Should not throw
      edit.clear_snapshot(99999)
    end)
  end)
end)
