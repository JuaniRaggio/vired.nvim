local config = require("vired.config")

describe("vired.config", function()
  before_each(function()
    -- Reset config before each test
    config.options = {}
  end)

  describe("setup", function()
    it("should use defaults when no user config provided", function()
      config.setup()
      assert.are.same(config.defaults.columns, config.options.columns)
      assert.are.same(config.defaults.path_picker, config.options.path_picker)
    end)

    it("should merge user config with defaults", function()
      config.setup({
        columns = { "icon", "name" },
      })
      assert.are.same({ "icon", "name" }, config.options.columns)
      -- Other defaults should still be present
      assert.are.same(config.defaults.path_picker, config.options.path_picker)
    end)

    it("should deep merge nested config", function()
      config.setup({
        path_picker = {
          backend = "fzf",
        },
      })
      assert.are.equal("fzf", config.options.path_picker.backend)
      -- Other path_picker defaults should be preserved
      assert.are.equal(true, config.options.path_picker.create_directories)
    end)

    it("should override keymaps", function()
      config.setup({
        keymaps = {
          ["<leader>d"] = "actions.delete",
        },
      })
      assert.are.equal("actions.delete", config.options.keymaps["<leader>d"])
      -- Original keymaps should still exist
      assert.are.equal("actions.move", config.options.keymaps["R"])
    end)
  end)

  describe("get", function()
    it("should return current options", function()
      config.setup({ confirm_delete = false })
      local opts = config.get()
      assert.are.equal(false, opts.confirm_delete)
    end)
  end)

  describe("defaults", function()
    it("should have all required fields", function()
      assert.is_not_nil(config.defaults.columns)
      assert.is_not_nil(config.defaults.path_picker)
      assert.is_not_nil(config.defaults.lsp)
      assert.is_not_nil(config.defaults.git)
      assert.is_not_nil(config.defaults.float)
      assert.is_not_nil(config.defaults.keymaps)
    end)

    it("should have valid path_picker config", function()
      local pp = config.defaults.path_picker
      assert.is_true(pp.backend == "auto" or pp.backend == "lua" or pp.backend == "fzf" or pp.backend == "telescope")
      assert.is_table(pp.sources)
      assert.is_boolean(pp.create_directories)
      assert.is_boolean(pp.show_hidden)
    end)
  end)
end)
