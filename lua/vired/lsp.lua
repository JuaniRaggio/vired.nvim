---LSP integration for file operations
---Implements workspace/willRenameFiles to notify LSP servers of renames

local M = {}

local config = require("vired.config")

-- ============================================================================
-- LSP Client Discovery
-- ============================================================================

---Get LSP clients that support willRenameFiles
---@param path string File path to check
---@return table[] clients List of capable LSP clients
local function get_capable_clients(path)
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  local capable = {}

  for _, client in ipairs(clients) do
    local caps = client.server_capabilities
    if caps and caps.workspace and caps.workspace.fileOperations then
      local file_ops = caps.workspace.fileOperations
      if file_ops.willRename then
        table.insert(capable, client)
      end
    end
  end

  return capable
end

---Check if any file in a directory is open in a buffer
---@param dir_path string Directory path
---@return number|nil bufnr Buffer number if found
local function find_buffer_for_path(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local buf_name = vim.api.nvim_buf_get_name(bufnr)
      if buf_name == path or buf_name:find(path, 1, true) == 1 then
        return bufnr
      end
    end
  end
  return nil
end

-- ============================================================================
-- Rename Notification
-- ============================================================================

---Notify LSP servers about a file rename (willRenameFiles)
---@param old_path string Original file path
---@param new_path string New file path
---@param callback fun(ok: boolean, edits: table|nil) Called with result
function M.will_rename_files(old_path, new_path, callback)
  local cfg = config.get()

  if not cfg.lsp.enabled then
    callback(true, nil)
    return
  end

  -- Find buffer for the file being renamed
  local bufnr = find_buffer_for_path(old_path)
  if not bufnr then
    -- No buffer open, can't find LSP clients
    callback(true, nil)
    return
  end

  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local capable_clients = {}

  for _, client in ipairs(clients) do
    local caps = client.server_capabilities
    if caps and caps.workspace and caps.workspace.fileOperations then
      local file_ops = caps.workspace.fileOperations
      if file_ops.willRename then
        table.insert(capable_clients, client)
      end
    end
  end

  if #capable_clients == 0 then
    callback(true, nil)
    return
  end

  -- Build the rename request
  local params = {
    files = {
      {
        oldUri = vim.uri_from_fname(old_path),
        newUri = vim.uri_from_fname(new_path),
      },
    },
  }

  local pending = #capable_clients
  local all_edits = {}
  local had_error = false

  for _, client in ipairs(capable_clients) do
    client.request("workspace/willRenameFiles", params, function(err, result)
      pending = pending - 1

      if err then
        had_error = true
        vim.notify("vired: LSP willRename error: " .. vim.inspect(err), vim.log.levels.WARN)
      elseif result and result.documentChanges then
        -- Collect workspace edits
        for _, change in ipairs(result.documentChanges) do
          table.insert(all_edits, change)
        end
      elseif result and result.changes then
        -- Alternative format
        for uri, edits in pairs(result.changes) do
          table.insert(all_edits, { uri = uri, edits = edits })
        end
      end

      -- All clients responded
      if pending == 0 then
        if #all_edits > 0 then
          M.apply_workspace_edits(all_edits, function(apply_ok)
            callback(apply_ok and not had_error, all_edits)
          end)
        else
          callback(not had_error, nil)
        end
      end
    end, bufnr)
  end

  -- Set timeout
  vim.defer_fn(function()
    if pending > 0 then
      vim.notify("vired: LSP rename request timed out", vim.log.levels.WARN)
      pending = 0
      callback(false, nil)
    end
  end, cfg.lsp.timeout_ms)
end

---Notify LSP servers after a file rename (didRenameFiles)
---@param old_path string Original file path
---@param new_path string New file path
function M.did_rename_files(old_path, new_path)
  local cfg = config.get()

  if not cfg.lsp or not cfg.lsp.enabled then
    return
  end

  local bufnr = find_buffer_for_path(new_path) or find_buffer_for_path(old_path)
  if not bufnr then
    return
  end

  local clients = vim.lsp.get_clients({ bufnr = bufnr })

  local params = {
    files = {
      {
        oldUri = vim.uri_from_fname(old_path),
        newUri = vim.uri_from_fname(new_path),
      },
    },
  }

  for _, client in ipairs(clients) do
    local caps = client.server_capabilities
    if caps and caps.workspace and caps.workspace.fileOperations then
      local file_ops = caps.workspace.fileOperations
      if file_ops.didRename then
        client.notify("workspace/didRenameFiles", params)
      end
    end
  end
end

-- ============================================================================
-- Workspace Edit Application
-- ============================================================================

---Apply workspace edits returned by LSP
---@param edits table[] List of document changes
---@param callback fun(ok: boolean)
function M.apply_workspace_edits(edits, callback)
  local success = true

  for _, edit in ipairs(edits) do
    if edit.textDocument and edit.edits then
      -- TextDocumentEdit format
      local uri = edit.textDocument.uri
      local bufnr = vim.uri_to_bufnr(uri)

      if vim.api.nvim_buf_is_valid(bufnr) then
        local ok = pcall(vim.lsp.util.apply_text_edits, edit.edits, bufnr, "utf-16")
        if not ok then
          success = false
          vim.notify("vired: Failed to apply edit to " .. uri, vim.log.levels.WARN)
        end
      end
    elseif edit.uri and edit.edits then
      -- Simple format
      local bufnr = vim.uri_to_bufnr(edit.uri)

      if vim.api.nvim_buf_is_valid(bufnr) then
        local ok = pcall(vim.lsp.util.apply_text_edits, edit.edits, bufnr, "utf-16")
        if not ok then
          success = false
        end
      end
    elseif edit.kind == "rename" then
      -- RenameFile operation - LSP wants us to rename a file
      -- We're already doing that, so just acknowledge
    end
  end

  callback(success)
end

-- ============================================================================
-- Utility Functions
-- ============================================================================

---Check if LSP rename is available for a file
---@param path string File path
---@return boolean
function M.is_rename_available(path)
  local bufnr = find_buffer_for_path(path)
  if not bufnr then
    return false
  end

  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    local caps = client.server_capabilities
    if caps and caps.workspace and caps.workspace.fileOperations then
      local file_ops = caps.workspace.fileOperations
      if file_ops.willRename then
        return true
      end
    end
  end

  return false
end

---Notify LSP about file creation
---@param path string Created file path
function M.did_create_files(path)
  local cfg = config.get()
  if not cfg.lsp or not cfg.lsp.enabled then
    return
  end

  -- Find any buffer with LSP client
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local clients = vim.lsp.get_clients({ bufnr = bufnr })
      for _, client in ipairs(clients) do
        local caps = client.server_capabilities
        if caps and caps.workspace and caps.workspace.fileOperations then
          local file_ops = caps.workspace.fileOperations
          if file_ops.didCreate then
            client.notify("workspace/didCreateFiles", {
              files = { { uri = vim.uri_from_fname(path) } },
            })
            return
          end
        end
      end
    end
  end
end

---Notify LSP about file deletion
---@param path string Deleted file path
function M.did_delete_files(path)
  local cfg = config.get()
  if not cfg.lsp or not cfg.lsp.enabled then
    return
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local clients = vim.lsp.get_clients({ bufnr = bufnr })
      for _, client in ipairs(clients) do
        local caps = client.server_capabilities
        if caps and caps.workspace and caps.workspace.fileOperations then
          local file_ops = caps.workspace.fileOperations
          if file_ops.didDelete then
            client.notify("workspace/didDeleteFiles", {
              files = { { uri = vim.uri_from_fname(path) } },
            })
            return
          end
        end
      end
    end
  end
end

return M
