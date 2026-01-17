.PHONY: test test-file lint clean

PLENARY_DIR ?= /tmp/plenary.nvim

# Run all tests
test:
	@nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

# Run a specific test file
# Usage: make test-file FILE=tests/dired/utils_spec.lua
test-file:
	@nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedFile $(FILE)"

# Lint with luacheck (if installed)
lint:
	@luacheck lua/ tests/ --no-unused-args --no-max-line-length

# Clean plenary cache
clean:
	@rm -rf $(PLENARY_DIR)

# Install plenary for testing
deps:
	@if [ ! -d "$(PLENARY_DIR)" ]; then \
		git clone https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR); \
	fi

# Show help
help:
	@echo "Available targets:"
	@echo "  test        - Run all tests"
	@echo "  test-file   - Run specific test file (FILE=path/to/spec.lua)"
	@echo "  lint        - Run luacheck linter"
	@echo "  deps        - Install test dependencies"
	@echo "  clean       - Clean dependencies cache"
