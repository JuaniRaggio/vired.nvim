local jumplist = require("vired.jumplist")

describe("vired.jumplist", function()
  local test_bufnr = 999

  before_each(function()
    jumplist.clear(test_bufnr)
  end)

  after_each(function()
    jumplist.clear_all()
  end)

  describe("push", function()
    it("should add paths to the stack", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/b")
      jumplist.push(test_bufnr, "/path/c")

      local stack, pos = jumplist.get_stack(test_bufnr)
      assert.are.equal(3, #stack)
      assert.are.equal(3, pos)
      assert.are.equal("/path/a", stack[1])
      assert.are.equal("/path/b", stack[2])
      assert.are.equal("/path/c", stack[3])
    end)

    it("should not add duplicate consecutive paths", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/a")

      local stack, _ = jumplist.get_stack(test_bufnr)
      assert.are.equal(1, #stack)
    end)

    it("should truncate forward history when pushing after going back", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/b")
      jumplist.push(test_bufnr, "/path/c")

      -- Go back
      jumplist.back(test_bufnr)
      jumplist.back(test_bufnr)

      -- Now push a new path
      jumplist.push(test_bufnr, "/path/new")

      local stack, pos = jumplist.get_stack(test_bufnr)
      assert.are.equal(2, #stack)
      assert.are.equal("/path/a", stack[1])
      assert.are.equal("/path/new", stack[2])
      assert.are.equal(2, pos)
    end)
  end)

  describe("can_go_back", function()
    it("should return false with empty stack", function()
      assert.is_false(jumplist.can_go_back(test_bufnr))
    end)

    it("should return false with single item", function()
      jumplist.push(test_bufnr, "/path/a")
      assert.is_false(jumplist.can_go_back(test_bufnr))
    end)

    it("should return true with multiple items", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/b")
      assert.is_true(jumplist.can_go_back(test_bufnr))
    end)
  end)

  describe("can_go_forward", function()
    it("should return false with empty stack", function()
      assert.is_false(jumplist.can_go_forward(test_bufnr))
    end)

    it("should return false at end of stack", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/b")
      assert.is_false(jumplist.can_go_forward(test_bufnr))
    end)

    it("should return true after going back", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/b")
      jumplist.back(test_bufnr)
      assert.is_true(jumplist.can_go_forward(test_bufnr))
    end)
  end)

  describe("back", function()
    it("should return nil when cannot go back", function()
      jumplist.push(test_bufnr, "/path/a")
      assert.is_nil(jumplist.back(test_bufnr))
    end)

    it("should return previous path", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/b")
      jumplist.push(test_bufnr, "/path/c")

      local path = jumplist.back(test_bufnr)
      assert.are.equal("/path/b", path)

      path = jumplist.back(test_bufnr)
      assert.are.equal("/path/a", path)
    end)

    it("should update position correctly", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/b")
      jumplist.push(test_bufnr, "/path/c")

      jumplist.back(test_bufnr)
      local pos, total = jumplist.get_position(test_bufnr)
      assert.are.equal(2, pos)
      assert.are.equal(3, total)
    end)
  end)

  describe("forward", function()
    it("should return nil when cannot go forward", function()
      jumplist.push(test_bufnr, "/path/a")
      assert.is_nil(jumplist.forward(test_bufnr))
    end)

    it("should return next path after going back", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/b")
      jumplist.push(test_bufnr, "/path/c")

      jumplist.back(test_bufnr)
      jumplist.back(test_bufnr)

      local path = jumplist.forward(test_bufnr)
      assert.are.equal("/path/b", path)

      path = jumplist.forward(test_bufnr)
      assert.are.equal("/path/c", path)
    end)
  end)

  describe("get_position", function()
    it("should return 0, 0 for empty jumplist", function()
      local pos, total = jumplist.get_position(test_bufnr)
      assert.are.equal(0, pos)
      assert.are.equal(0, total)
    end)

    it("should return correct position and total", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/b")
      jumplist.push(test_bufnr, "/path/c")

      local pos, total = jumplist.get_position(test_bufnr)
      assert.are.equal(3, pos)
      assert.are.equal(3, total)
    end)
  end)

  describe("clear", function()
    it("should clear jumplist for specific buffer", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(test_bufnr, "/path/b")

      jumplist.clear(test_bufnr)

      local stack, _ = jumplist.get_stack(test_bufnr)
      assert.are.equal(0, #stack)
    end)

    it("should not affect other buffers", function()
      local other_bufnr = 998
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(other_bufnr, "/path/b")

      jumplist.clear(test_bufnr)

      local stack1, _ = jumplist.get_stack(test_bufnr)
      local stack2, _ = jumplist.get_stack(other_bufnr)
      assert.are.equal(0, #stack1)
      assert.are.equal(1, #stack2)

      jumplist.clear(other_bufnr)
    end)
  end)

  describe("clear_all", function()
    it("should clear all jumplists", function()
      jumplist.push(test_bufnr, "/path/a")
      jumplist.push(998, "/path/b")
      jumplist.push(997, "/path/c")

      jumplist.clear_all()

      local stack1, _ = jumplist.get_stack(test_bufnr)
      local stack2, _ = jumplist.get_stack(998)
      local stack3, _ = jumplist.get_stack(997)
      assert.are.equal(0, #stack1)
      assert.are.equal(0, #stack2)
      assert.are.equal(0, #stack3)
    end)
  end)

  describe("navigation workflow", function()
    it("should handle typical back/forward navigation", function()
      -- Simulate browsing: a -> b -> c -> d
      jumplist.push(test_bufnr, "/home")
      jumplist.push(test_bufnr, "/home/projects")
      jumplist.push(test_bufnr, "/home/projects/myapp")
      jumplist.push(test_bufnr, "/home/projects/myapp/src")

      -- Go back twice
      local path = jumplist.back(test_bufnr)
      assert.are.equal("/home/projects/myapp", path)
      path = jumplist.back(test_bufnr)
      assert.are.equal("/home/projects", path)

      -- Go forward once
      path = jumplist.forward(test_bufnr)
      assert.are.equal("/home/projects/myapp", path)

      -- Now navigate to new path (should truncate forward history)
      jumplist.push(test_bufnr, "/home/documents")

      -- Can't go forward anymore
      assert.is_false(jumplist.can_go_forward(test_bufnr))

      -- But can go back
      assert.is_true(jumplist.can_go_back(test_bufnr))
      path = jumplist.back(test_bufnr)
      assert.are.equal("/home/projects/myapp", path)
    end)
  end)
end)
