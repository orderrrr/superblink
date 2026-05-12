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

  vim.api.nvim_create_user_command("SuperblinkDebug", function(opts)
    local include_prompt = opts.bang
    local url = config.server_url .. "/debug/last"
    if include_prompt then
      url = url .. "?include_prompt=true"
    end
    local curl_path = vim.fn.exepath("curl") or "curl"
    vim.system({ curl_path, "-s", url }, { text = true }, function(result)
      vim.schedule(function()
        if result.code ~= 0 or not result.stdout or result.stdout == "" then
          vim.notify("[superblink] debug: server not reachable", vim.log.levels.WARN)
          return
        end
        local ok, data = pcall(vim.fn.json_decode, result.stdout)
        if not ok or not data then
          vim.notify("[superblink] debug: bad response", vim.log.levels.WARN)
          return
        end
        if data.error then
          vim.notify("[superblink] " .. data.error, vim.log.levels.INFO)
          return
        end

        -- Format into a readable buffer
        local lines = { "superblink — last completion debug" , "" }

        table.insert(lines, string.format("seq:       %d", data.seq or 0))
        table.insert(lines, string.format("file:      %s", data.filepath or "?"))
        table.insert(lines, string.format("cursor:    line %d, col %d", (data.cursor or {}).line or 0, (data.cursor or {}).col or 0))
        table.insert(lines, string.format("model:     %s", data.model or "?"))
        table.insert(lines, string.format("total:     %.0fms (ollama: %.0fms)", data.total_ms or 0, data.ollama_ms or 0))
        table.insert(lines, "")
        table.insert(lines, string.format("prompt:    %d chars (~%d tokens)", data.prompt_chars or 0, data.prompt_tokens_approx or 0))
        table.insert(lines, string.format("  rag:     %d chars", data.rag_chars or 0))
        table.insert(lines, string.format("  prefix:  %d chars", data.prefix_chars or 0))
        table.insert(lines, string.format("  suffix:  %d chars (capped at %d lines)", data.suffix_chars or 0, data.suffix_lines_cap or 0))
        table.insert(lines, "")
        table.insert(lines, string.format("completion: %s", vim.inspect(data.completion or "")))
        table.insert(lines, "")

        table.insert(lines, string.format("bm25 query: lines %d–%d", (data.bm25_query_lines or {})[1] or 0, (data.bm25_query_lines or {})[2] or 0))
        table.insert(lines, string.format("chunks: %d", #(data.chunks or {})))
        for i, c in ipairs(data.chunks or {}) do
          table.insert(lines, string.format("  [%d] %s:%d (%d chars)", i, c.file, c.line, c.chars))
          table.insert(lines, "      " .. c.preview:gsub("\n", "\\n"))
        end

        if data.prompt then
          table.insert(lines, "")
          table.insert(lines, "--- full prompt ---")
          for _, l in ipairs(vim.split(data.prompt, "\n")) do
            table.insert(lines, l)
          end
        end

        -- Open in a scratch buffer
        vim.cmd("botright new")
        local buf = vim.api.nvim_get_current_buf()
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].swapfile = false
        vim.bo[buf].filetype = "markdown"
        vim.api.nvim_buf_set_name(buf, "superblink://debug")
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
      end)
    end)
  end, { bang = true, desc = "Show debug info for last completion (:SuperblinkDebug! includes full prompt)" })

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
