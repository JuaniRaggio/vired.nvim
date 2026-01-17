local lsp = require("vired.lsp")

describe("vired.lsp", function()
  describe("is_rename_available", function()
    it("should return false for non-existent path", function()
      local available = lsp.is_rename_available("/nonexistent/path/file.txt")
      assert.is_false(available)
    end)
  end)

  -- Note: Most LSP tests require a running LSP server which is difficult
  -- to set up in headless test mode. These tests verify the module loads
  -- and basic functions don't error.

  describe("did_create_files", function()
    it("should not error when called with path", function()
      -- Should not throw, even without LSP
      lsp.did_create_files("/some/path/file.txt")
    end)
  end)

  describe("did_delete_files", function()
    it("should not error when called with path", function()
      -- Should not throw, even without LSP
      lsp.did_delete_files("/some/path/file.txt")
    end)
  end)

  describe("did_rename_files", function()
    it("should not error when called with paths", function()
      -- Should not throw, even without LSP
      lsp.did_rename_files("/some/old.txt", "/some/new.txt")
    end)
  end)
end)
