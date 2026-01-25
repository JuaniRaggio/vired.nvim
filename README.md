# vired.nvim

A file manager for Neovim inspired by Emacs dired + ivy/vertico: file operations with interactive fuzzy completion for paths.

> [!NOTE]
> This project is in **beta**. I'm actively developing and testing it as my daily driver. Expect bugs and breaking changes. Feedback and issues are welcome!

## Philosophy

1. **Path-first, not tree-first** - Prioritizes path input with fuzzy completion over tree navigation
2. **Buffer as filesystem** - Directory shown as buffer, changes translate to filesystem operations
3. **Composable** - Each component (browser, path picker, operations) is independent and reusable
4. **Vim-native** - Leverages vim's power instead of reinventing it

## Features

### Core
- Directory browsing with configurable columns (icon, permissions, size, mtime)
- Fuzzy path completion with scoring (consecutive matches, word boundaries)
- Multiple sources: filesystem, recent directories, open buffers, projects
- File operations: rename, copy, delete, create (all with undo support)
- Mark system for batch operations
- Integrates with nvim-web-devicons (optional)

### Git Integration
- Status indicators (modified, staged, untracked, ignored, conflicts)
- Automatic `git mv` and `git rm` for tracked files
- Repository root detection

### Preview System
- File preview with syntax highlighting
- Directory preview with contents listing
- Binary file detection with file type info

### Edit Mode (wdired-like)
- **Full vim editing**: all your keymaps, plugins, and macros work
- Real-time highlighting of changes
- Use `:s/pattern/replace/g`, visual block, multicursor, etc.
- `:w` to apply, `:e!` to cancel

### LSP Integration
- Notifies LSP servers on file rename
- Automatic reference updates across project

### Project Management (Projectile-like)
- Automatic project detection (`.git`, `package.json`, `Cargo.toml`, etc.)
- Project bookmarking with fuzzy picker
- **Auto-cd**: changes Neovim's cwd to project root

### File Watcher
- **Auto-refresh** when external changes occur
- Debounced updates (configurable)
- Toggle on/off per buffer

### Jump List
- **Directory navigation history**
- Go back/forward through visited directories
- Per-buffer history (up to 100 entries)

### Path Picker
- Multiple backends: telescope.nvim, fzf-lua, or built-in
- Vertico-like directory-by-directory completion
- Live preview of directories

### Undo/Redo System
- Full undo for all operations
- Delete moves to trash (restorable)
- History kept in memory per session

## Requirements

- Neovim >= 0.9

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

**Minimal:**

```lua
{
  "juaniraggio/vired.nvim",
  config = function()
    require("vired").setup()
  end,
}
```

**Full configuration:**

```lua
-- ~/.config/nvim/lua/plugins/vired.lua
return {
  "juaniraggio/vired.nvim",
  config = function()
    require("vired").setup({
      -- Columns in directory buffer
      columns = { "icon", "permissions", "size", "mtime" },

      -- Path picker
      path_picker = {
        backend = "auto",  -- "auto" | "telescope" | "fzf" | "lua"
        sources = { "filesystem", "recent", "bookmarks", "buffers" },
        create_directories = true,
        show_hidden = false,
      },

      -- Behavior
      delete_to_trash = true,
      confirm_delete = true,
      skip_confirm_single = true,
      use_picker_by_default = false,

      -- LSP integration
      lsp = {
        enabled = true,
        timeout_ms = 3000,
      },

      -- Git integration
      git = {
        auto_add = false,
        use_git_mv = true,
        use_git_rm = true,
      },

      -- Preview
      preview = {
        max_lines = 100,
        max_file_size = 1024 * 1024,
        auto_preview = false,
      },

      -- Buffer editing
      buffer_editing = {
        enabled = true,
        confirm_changes = true,
      },

      -- Projects
      projects = {
        auto_prompt = true,
        auto_cd = true,
        markers = {
          ".git", ".hg", ".svn",
          "package.json", "Cargo.toml", "go.mod",
          "Makefile", "CMakeLists.txt",
          "pyproject.toml", "setup.py",
        },
        sort_by = "recent",
      },

      -- File watcher
      watcher = {
        enabled = true,
        debounce_ms = 200,
      },

      -- Floating windows
      float = {
        border = "rounded",
        width = 0.8,
        height = 0.8,
      },

      -- Keymaps
      keymaps = {
        ["<CR>"] = "actions.select",
        ["-"] = "actions.parent",
        ["q"] = "actions.close",
        ["gr"] = "actions.refresh",
        ["g."] = "actions.toggle_hidden",
        ["gw"] = "actions.toggle_watch",
        ["<C-o>"] = "actions.jump_back",
        ["<C-i>"] = "actions.jump_forward",
        ["<Tab>"] = "actions.preview",
        ["m"] = "actions.toggle_mark",
        ["u"] = "actions.unmark",
        ["U"] = "actions.unmark_all",
        ["R"] = "actions.move",
        ["C"] = "actions.copy",
        ["D"] = "actions.delete",
        ["+"] = "actions.mkdir",
        ["%"] = "actions.touch",
        ["<M-e>"] = "actions.edit",
        ["<C-z>"] = "actions.undo",
        ["<C-y>"] = "actions.redo",
        ["?"] = "actions.help",
      },
    })
  end,
}
```

## Usage

```vim
:Vired           " Open vired in current directory
:Vired /path     " Open vired in specific directory
:ViredOpen       " Open with interactive directory picker
:ViredProjects   " Open project picker
```

## Keymaps

### Navigation

| Key | Action |
|-----|--------|
| `Enter` | Open file/directory |
| `-` | Go to parent directory |
| `<C-o>` | Jump back in directory history |
| `<C-i>` | Jump forward in directory history |
| `q` | Close vired |

### File Operations

| Key | Action |
|-----|--------|
| `R` | Rename/Move (opens path picker) |
| `C` | Copy (opens path picker) |
| `D` | Delete (to trash, with confirmation) |
| `+` | Create directory |
| `%` | Create file |
| `<C-z>` | Undo last operation |
| `<C-y>` | Redo last undone operation |

### Marking

| Key | Action |
|-----|--------|
| `m` | Toggle mark on file |
| `u` | Unmark file |
| `U` | Unmark all |

### View

| Key | Action |
|-----|--------|
| `Tab` | Toggle file preview |
| `gr` | Refresh directory |
| `g.` | Toggle hidden files |
| `gw` | Toggle auto-refresh (file watcher) |
| `?` | Show help popup |

### Edit Mode

| Key | Action |
|-----|--------|
| `<M-e>` | Enter edit mode (Alt+e) |
| `:w` | Apply changes (in edit mode) |
| `:e!` | Cancel changes (in edit mode) |

## Edit Mode

Press `<M-e>` (Alt+e) to enter edit mode. **All vired keymaps are disabled** - you get full vim:

```vim
" Rename with regex
<M-e>                    " Enter edit mode
:%s/\.jpeg$/.jpg/g       " Change all extensions
:w                       " Apply changes

" With multicursor plugin
<M-e>                    " Enter edit mode
<your-multicursor-key>   " Select multiple lines
cnew_name                " Change names
:w                       " Apply

" Visual block
<M-e>                    " Enter edit mode
<C-v>jjjI prefix_<Esc>   " Add prefix to multiple files
:w                       " Apply
```

**Highlights while editing:**
- Yellow: renamed files
- Red: deleted files
- Green: new files

## Project Management

### Commands

| Command | Description |
|---------|-------------|
| `:ViredProjects` | Open project picker (fuzzy search) |
| `:ViredProjectAdd` | Add current directory as project |
| `:ViredProjectRemove` | Remove project from bookmarks |

### Auto-cd

When opening a project, vired automatically changes Neovim's working directory:

```lua
-- Enabled by default, disable with:
require("vired").setup({
  projects = {
    auto_cd = false,
  },
})
```

This means `:!make` or `:terminal` run in the project root.

### Project Picker

The project picker (`<C-n>`/`<C-p>` to navigate, `<CR>` to select, `<C-d>` to remove):

```
+-- Projects ----------------------------------+
| Project: my-app                              |
+----------------------------------------------+
|   vired.nvim        ~/.config/nvim/vired     |
| > my-app            ~/projects/my-app        |
|   website           ~/projects/website       |
+----------------------------------------------+
```

## File Watcher

Auto-refresh when files change externally (other terminal, git operations, etc.):

```lua
require("vired").setup({
  watcher = {
    enabled = true,     -- Enable by default
    debounce_ms = 200,  -- Collapse rapid changes
  },
})
```

Toggle per-buffer with `gw`. Only refreshes visible buffers (performance).

## Jump List

Navigate directory history like browser back/forward:

| Key | Action |
|-----|--------|
| `<C-o>` | Go back to previous directory |
| `<C-i>` | Go forward to next directory |

History is per-buffer and persists until buffer closes.

## Path Picker

### Backends

| Backend | Description |
|---------|-------------|
| `auto` | Auto-detect (telescope > fzf > lua) |
| `telescope` | Use telescope.nvim |
| `fzf` | Use fzf-lua |
| `lua` | Built-in Vertico-like picker |

### Keymaps (in picker)

| Key | Action |
|-----|--------|
| `Tab` | Complete directory (continue navigating) |
| `Backspace` | Go up one directory (at boundary) |
| `<C-n>` / `Down` | Next result |
| `<C-p>` / `Up` | Previous result |
| `Enter` | Confirm selection |
| `Esc` | Cancel |

## API

```lua
local vired = require("vired")

-- Open vired
vired.open("/path/to/dir")

-- Path picker standalone
vired.pick_path({
  prompt = "Select: ",
  default = vim.fn.getcwd() .. "/",
  on_select = function(path)
    print("Selected: " .. path)
  end,
})

-- Open picker then vired
vired.pick_and_open()

-- Programmatic operations
vired.move("/src/file.txt", "/dest/file.txt")
vired.copy("/src/file.txt", "/dest/file.txt")
vired.delete("/path/to/file")
vired.mkdir("/path/to/new/dir")

-- Marks
vired.mark("/path/to/file")
vired.unmark("/path/to/file")
vired.get_marked()
vired.clear_marks()
```
