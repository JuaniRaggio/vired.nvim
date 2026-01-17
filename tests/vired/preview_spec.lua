local preview = require("vired.preview")

describe("vired.preview", function()
  describe("is_open", function()
    it("should return false when preview is not open", function()
      preview.close() -- Ensure closed
      assert.is_false(preview.is_open())
    end)
  end)

  describe("close", function()
    it("should not error when closing non-existent preview", function()
      -- Should not throw
      preview.close()
      preview.close()
    end)
  end)

  -- Note: open() and toggle() tests require a display and are harder to test
  -- in headless mode. These would be tested manually or with a UI testing framework.
end)
