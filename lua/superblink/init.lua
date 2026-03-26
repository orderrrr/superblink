--- superblink — project-aware FIM code completions for blink.cmp
--- Public API and user command registration.

local M = {}

local config = require("superblink.config")
local server = require("superblink.server")

--- Set up superblink: merge config, register commands and autocommands.
--- @param opts table|nil User configuration overrides
function M.setup(opts)
  config.apply(opts)

  -- User commands
  vim.api.nvim_create_user_command("SuperblinkStart", function()
    server.start()
  end, { desc = "Start the superblink server" })

  vim.api.nvim_create_user_command("SuperblinkStop", function()
    server.stop()
  end, { desc = "Stop the superblink server" })

  vim.api.nvim_create_user_command("SuperblinkRestart", function()
    server.restart()
  end, { desc = "Restart the superblink server" })

  vim.api.nvim_create_user_command("SuperblinkStatus", function()
    server.status(function(ok, data)
      if not ok or not data then
        vim.notify("[superblink] server not reachable", vim.log.levels.WARN)
        return
      end
      local lines = { "superblink status:" }
      table.insert(lines, "  model: " .. (data.model or "?"))
      table.insert(lines, "  ollama_url: " .. (data.ollama_url or "?"))
      if data.projects then
        for root, info in pairs(data.projects) do
          table.insert(lines, string.format("  project: %s (%d files, %d chunks)", root, info.files or 0, info.chunks or 0))
        end
      end
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end)
  end, { desc = "Show superblink server status" })

  vim.api.nvim_create_user_command("SuperblinkIndex", function()
    local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
    if vim.v.shell_error ~= 0 or not git_root or git_root == "" then
      vim.notify("[superblink] not in a git repository", vim.log.levels.WARN)
      return
    end
    vim.notify("[superblink] re-indexing " .. git_root .. "...", vim.log.levels.INFO)
    server.index(git_root, function(ok, data)
      if ok and data then
        vim.notify(string.format("[superblink] indexed: %d files, %d chunks", data.files or 0, data.chunks or 0), vim.log.levels.INFO)
      else
        vim.notify("[superblink] index request failed", vim.log.levels.ERROR)
      end
    end)
  end, { desc = "Force re-index the current project" })

  vim.api.nvim_create_user_command("SuperblinkLog", function()
    vim.cmd("split " .. vim.fn.fnameescape(server.log_path))
  end, { desc = "Open superblink server log" })

  vim.api.nvim_create_user_command("SuperblinkHealth", function()
    vim.cmd("checkhealth superblink")
  end, { desc = "Run superblink health checks" })

  -- Clean up on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("superblink_cleanup", { clear = true }),
    callback = function()
      server.stop()
    end,
  })
end

function M.start()
  server.start()
end

function M.stop()
  server.stop()
end

function M.status()
  server.status(function(ok, data)
    if ok and data then
      vim.print(data)
    else
      vim.notify("[superblink] server not reachable", vim.log.levels.WARN)
    end
  end)
end

return M
