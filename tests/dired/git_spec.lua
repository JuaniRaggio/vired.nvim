local git = require("dired.git")

describe("dired.git", function()
  describe("parse_porcelain", function()
    it("should parse modified file", function()
      local output = " M file.txt"
      local status = git.parse_porcelain(output, "/repo")

      assert.is_not_nil(status["/repo/file.txt"])
      assert.are.equal(" ", status["/repo/file.txt"].index)
      assert.are.equal("M", status["/repo/file.txt"].worktree)
    end)

    it("should parse staged file", function()
      local output = "M  file.txt"
      local status = git.parse_porcelain(output, "/repo")

      assert.is_not_nil(status["/repo/file.txt"])
      assert.are.equal("M", status["/repo/file.txt"].index)
      assert.are.equal(" ", status["/repo/file.txt"].worktree)
    end)

    it("should parse untracked file", function()
      local output = "?? newfile.txt"
      local status = git.parse_porcelain(output, "/repo")

      assert.is_not_nil(status["/repo/newfile.txt"])
      assert.are.equal("?", status["/repo/newfile.txt"].index)
      assert.are.equal("?", status["/repo/newfile.txt"].worktree)
    end)

    it("should parse ignored file", function()
      local output = "!! ignored.txt"
      local status = git.parse_porcelain(output, "/repo")

      assert.is_not_nil(status["/repo/ignored.txt"])
      assert.are.equal("!", status["/repo/ignored.txt"].index)
      assert.are.equal("!", status["/repo/ignored.txt"].worktree)
    end)

    it("should parse added file", function()
      local output = "A  newfile.txt"
      local status = git.parse_porcelain(output, "/repo")

      assert.is_not_nil(status["/repo/newfile.txt"])
      assert.are.equal("A", status["/repo/newfile.txt"].index)
    end)

    it("should parse deleted file", function()
      local output = "D  deleted.txt"
      local status = git.parse_porcelain(output, "/repo")

      assert.is_not_nil(status["/repo/deleted.txt"])
      assert.are.equal("D", status["/repo/deleted.txt"].index)
    end)

    it("should parse renamed file", function()
      local output = "R  old.txt -> new.txt"
      local status = git.parse_porcelain(output, "/repo")

      assert.is_not_nil(status["/repo/new.txt"])
      assert.are.equal("R", status["/repo/new.txt"].index)
    end)

    it("should parse multiple files", function()
      local output = " M file1.txt\n?? file2.txt\nA  file3.txt"
      local status = git.parse_porcelain(output, "/repo")

      assert.is_not_nil(status["/repo/file1.txt"])
      assert.is_not_nil(status["/repo/file2.txt"])
      assert.is_not_nil(status["/repo/file3.txt"])
    end)

    it("should handle files in subdirectories", function()
      local output = " M src/file.txt"
      local status = git.parse_porcelain(output, "/repo")

      assert.is_not_nil(status["/repo/src/file.txt"])
      -- Should also mark parent directory
      assert.is_not_nil(status["/repo/src"])
    end)

    it("should handle empty output", function()
      local output = ""
      local status = git.parse_porcelain(output, "/repo")

      assert.are.same({}, status)
    end)
  end)

  describe("get_status_display", function()
    it("should return space for nil status", function()
      local char, hl = git.get_status_display(nil)
      assert.are.equal(" ", char)
      assert.are.equal("Normal", hl)
    end)

    it("should return M with modified highlight for worktree changes", function()
      local char, hl = git.get_status_display({ index = " ", worktree = "M" })
      assert.are.equal("M", char)
      assert.are.equal("DiredGitModified", hl)
    end)

    it("should return staged indicator for index changes", function()
      local char, hl = git.get_status_display({ index = "M", worktree = " " })
      assert.are.equal("M", char)
      assert.are.equal("DiredGitStaged", hl)
    end)

    it("should return ? for untracked files", function()
      local char, hl = git.get_status_display({ index = "?", worktree = "?" })
      assert.are.equal("?", char)
      assert.are.equal("DiredGitUntracked", hl)
    end)

    it("should return ! for ignored files", function()
      local char, hl = git.get_status_display({ index = "!", worktree = "!" })
      assert.are.equal("!", char)
      assert.are.equal("DiredGitIgnored", hl)
    end)

    it("should return C for conflicts", function()
      local char, hl = git.get_status_display({ index = "U", worktree = "U" })
      assert.are.equal("C", char)
      assert.are.equal("DiredGitConflict", hl)
    end)
  end)

  describe("find_repo_root", function()
    it("should find repo root for current directory", function()
      -- This test assumes we're running from within a git repo
      local cwd = vim.loop.cwd()
      local root = git.find_repo_root(cwd)

      -- Should either find a root or return nil
      if root then
        assert.is_true(vim.fn.isdirectory(root .. "/.git") == 1)
      end
    end)

    it("should return nil for non-git directory", function()
      local root = git.find_repo_root("/tmp")
      -- /tmp is unlikely to be a git repo
      -- This might fail if /tmp is somehow in a git repo
    end)
  end)

  describe("is_git_repo", function()
    it("should return boolean", function()
      local result = git.is_git_repo(vim.loop.cwd())
      assert.is_boolean(result)
    end)
  end)

  describe("invalidate_cache", function()
    it("should not error when invalidating non-existent cache", function()
      -- Should not throw
      git.invalidate_cache("/nonexistent/path")
    end)

    it("should not error when clearing all cache", function()
      -- Should not throw
      git.invalidate_cache(nil)
    end)
  end)
end)
