--- superblink source for blink.cmp
--- Sends FIM completion requests to the local superblink server
--- and returns results as blink completion items.

local config = require("superblink.config")
local server = require("superblink.server")

--- @class superblink.Source
local source = {}
source.__index = source

function source.new()
  local self = setmetatable({}, source)
  self._pending = nil
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
  -- Cancel any in-flight request
  if self._pending then
    pcall(function() self._pending:shutdown() end)
    self._pending = nil
  end

  local bufnr = context.bufnr or vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    callback({ items = {}, is_incomplete_forward = false })
    return
  end

  -- Ensure server is up before making the request
  server.ensure_running(function(healthy)
    if not healthy then
      callback({ items = {}, is_incomplete_forward = false })
      return
    end
    self:_do_request(context, bufnr, filepath, callback)
  end)
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

      vim.schedule(function()
        if result.code ~= 0 or not result.stdout or result.stdout == "" then
          callback({ items = {}, is_incomplete_forward = false })
          return
        end

        local ok, data = pcall(vim.fn.json_decode, result.stdout)
        if not ok or not data or not data.completion or data.completion == "" then
          callback({ items = {}, is_incomplete_forward = false })
          return
        end

        local completion = data.completion
        local items = {}

        -- FIM completions are insertions at cursor, not keyword replacements.
        -- filterText must match the current keyword so blink's fuzzy matcher
        -- keeps the item; textEdit inserts at cursor without replacing anything.
        local cursor_line = lines[cursor[1]] or ""
        local before_cursor = cursor_line:sub(1, cursor[2])
        local keyword = before_cursor:match("[%w_]+$") or ""

        -- Replace from cursor to end of line — the model already saw the
        -- suffix and generated what should be between prefix and suffix.
        local eol = #cursor_line
        local text_edit = {
          range = {
            start = { line = cursor[1] - 1, character = cursor[2] },
            ["end"] = { line = cursor[1] - 1, character = eol },
          },
          newText = completion,
        }

        -- Primary: the full completion
        table.insert(items, {
          label = keyword .. first_line(completion),
          kind = vim.lsp.protocol.CompletionItemKind.Text,
          filterText = keyword ~= "" and keyword or first_line(completion),
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

        callback({
          items = items,
          is_incomplete_forward = false,
        })
      end)
    end
  )
end

return source
