--- superblink source for blink.cmp
--- Sends FIM completion requests to the local superblink server
--- and returns results as blink completion items.

local config = require("superblink.config")
local server = require("superblink.server")

local _log_path = vim.fn.stdpath("log") .. "/superblink.log"

--- @param level string "DEBUG"|"INFO"|"WARN"|"ERROR"
--- @param fmt string
--- @param ... any
local function log(level, fmt, ...)
  local msg = string.format(fmt, ...)
  local line = string.format("%s [%s] lua/source: %s\n", os.date("%H:%M:%S"), level, msg)
  local f = io.open(_log_path, "a")
  if f then
    f:write(line)
    f:close()
  end
end

--- @class superblink.Source
local source = {}
source.__index = source

local DEBOUNCE_MS = 300

function source.new()
  local self = setmetatable({}, source)
  self._pending = nil
  self._debounce_timer = nil
  return self
end

--- Characters that trigger a new completion request
function source:get_trigger_characters()
  return { ".", ":", "(", ",", " ", "\t", "{", "[", "=", "/", "@", '"', "'" }
end

--- Extract first line for the label
local function first_line(text)
  local nl = text:find("\n")
  if nl then
    local line = text:sub(1, nl - 1)
    if #text > nl then
      return line .. " …"
    end
    return line
  end
  return text
end

--- Fetch completions from the superblink server
--- @param context blink.cmp.Context
--- @param callback fun(response: blink.cmp.CompletionResponse)
function source:get_completions(context, callback)
  -- Cancel pending debounce timer
  if self._debounce_timer then
    self._debounce_timer:stop()
    self._debounce_timer = nil
  end

  local bufnr = context.bufnr or vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    log("DEBUG", "get_completions: empty filepath, skipping")
    callback({ items = {}, is_incomplete_forward = false })
    return
  end

  local cursor = context.cursor
  log("DEBUG", "get_completions: debouncing %s line=%d col=%d",
    vim.fn.fnamemodify(filepath, ":t"), cursor and cursor[1] or -1, cursor and cursor[2] or -1)

  -- Debounce: wait for typing to pause before firing an expensive request
  self._debounce_timer = vim.defer_fn(function()
    self._debounce_timer = nil

    -- Cancel any in-flight curl from a previous debounced request
    if self._pending then
      log("DEBUG", "cancelling previous in-flight request")
      pcall(function() self._pending:shutdown() end)
      self._pending = nil
    end

    log("INFO", "get_completions fired: %s line=%d col=%d",
      vim.fn.fnamemodify(filepath, ":t"), cursor and cursor[1] or -1, cursor and cursor[2] or -1)

    -- Ensure server is up before making the request
    server.ensure_running(function(healthy)
      if not healthy then
        log("WARN", "get_completions: server unhealthy, returning empty")
        callback({ items = {}, is_incomplete_forward = false })
        return
      end
      log("DEBUG", "get_completions: server healthy, firing request")
      local ok, err = pcall(function()
        self:_do_request(context, bufnr, filepath, callback)
      end)
      if not ok then
        log("ERROR", "get_completions: _do_request threw: %s", tostring(err))
        callback({ items = {}, is_incomplete_forward = false })
      end
    end)
  end, DEBOUNCE_MS)
end

--- Internal: actually fire the curl request to /complete
--- @param context blink.cmp.Context
--- @param bufnr number
--- @param filepath string
--- @param callback fun(response: blink.cmp.CompletionResponse)
function source:_do_request(context, bufnr, filepath, callback)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cursor = context.cursor
  local line = cursor[1] - 1 -- 0-indexed for server
  local col = cursor[2]      -- already 0-indexed byte offset

  local body = vim.fn.json_encode({
    filepath = filepath,
    content = table.concat(lines, "\n"),
    line = line,
    col = col,
  })

  local url = config.server_url .. "/complete"
  local timeout_s = math.floor(config.timeout_ms / 1000)

  log("DEBUG", "_do_request: POST /complete body=%d bytes, timeout=%ds", #body, timeout_s)

  self._pending = vim.system(
    {
      "curl", "-s",
      "-X", "POST",
      url,
      "-H", "Content-Type: application/json",
      "-d", body,
      "--max-time", tostring(timeout_s),
    },
    { text = true },
    function(result)
      self._pending = nil

      log("DEBUG", "_do_request: curl returned code=%s stdout_len=%d",
        tostring(result.code), result.stdout and #result.stdout or 0)

      vim.schedule(function()
        if result.code ~= 0 or not result.stdout or result.stdout == "" then
          log("WARN", "_do_request: curl failed code=%s stderr=%s",
            tostring(result.code), tostring(result.stderr):sub(1, 200))
          if result.code == 28 or result.code == 7 then
            server.mark_down() -- timeout or connection refused → re-check next time
          end
          callback({ items = {}, is_incomplete_forward = false })
          return
        end

        -- Server responded successfully
        server.confirm_alive()

        local ok, data = pcall(vim.fn.json_decode, result.stdout)
        if not ok or not data or not data.completion or data.completion == "" then
          log("DEBUG", "_do_request: empty or unparseable completion, stdout=%s",
            tostring(result.stdout):sub(1, 200))
          callback({ items = {}, is_incomplete_forward = false })
          return
        end

        local completion = data.completion
        local items = {}

        -- Re-read current cursor state — by the time the response arrives
        -- the user may have typed more, so the original cursor/keyword are stale.
        local now_cursor = vim.api.nvim_win_get_cursor(0)
        local now_line_nr = now_cursor[1]
        local now_col = now_cursor[2]
        local now_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local now_cursor_line = now_lines[now_line_nr] or ""
        local now_before = now_cursor_line:sub(1, now_col)
        local keyword = now_before:match("[%w_]+$") or ""

        -- Insert at current cursor position, replacing to end of line.
        local eol = #now_cursor_line
        local text_edit = {
          range = {
            start = { line = now_line_nr - 1, character = now_col },
            ["end"] = { line = now_line_nr - 1, character = eol },
          },
          newText = completion,
        }

        log("DEBUG", "_do_request: building item keyword=%q completion=%q label=%q",
          keyword, first_line(completion), keyword .. first_line(completion))

        table.insert(items, {
          label = keyword .. first_line(completion),
          kind = vim.lsp.protocol.CompletionItemKind.Text,
          filterText = keyword,
          insertTextFormat = 1, -- plain text
          textEdit = text_edit,
          documentation = {
            kind = "markdown",
            value = string.format(
              "```%s\n%s\n```\n*superblink · %s · %d chunks · %.0fms*",
              vim.bo[bufnr].filetype or "",
              completion,
              data.model or "?",
              data.chunks_used or 0,
              data.elapsed_ms or 0
            ),
          },
          source_name = "superblink",
          score_offset = 100,
        })

        log("INFO", "_do_request: returning completion (%d chars, %d chunks, %.0fms)",
          #completion, data.chunks_used or 0, data.elapsed_ms or 0)

        callback({
          items = items,
          is_incomplete_forward = false,
        })
      end)
    end
  )
end

return source
