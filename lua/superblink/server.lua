--- superblink server lifecycle management
--- Spawns, monitors, and stops the Python server process.

local config = require("superblink.config")

local M = {}

--- @type vim.SystemObj|nil
local _process = nil
local _health_cache = nil
local _health_cache_time = 0
local _server_confirmed = false -- true after first successful response

--- Append a timestamped line to the superblink log file.
--- @param level string "DEBUG"|"INFO"|"WARN"|"ERROR"
--- @param fmt string format string
--- @param ... any format arguments
local function log(level, fmt, ...)
  local msg = string.format(fmt, ...)
  local line = string.format("%s [%s] lua/server: %s\n", os.date("%H:%M:%S"), level, msg)
  local f = io.open(M.log_path, "a")
  if f then
    f:write(line)
    f:close()
  end
end

-- Resolve plugin root from this file's location:
-- this file is at <plugin_root>/lua/superblink/server.lua
local _this_file = debug.getinfo(1, "S").source:sub(2) -- strip leading @
local _plugin_root = vim.fn.fnamemodify(_this_file, ":h:h:h")
local _server_script = _plugin_root .. "/server/main.py"
local _venv_python = _plugin_root .. "/server/.venv/bin/python3"

--- Resolve the python command: prefer the bundled venv if it exists.
--- @return string
local function resolve_python()
  if vim.fn.executable(_venv_python) == 1 then
    return _venv_python
  end
  return config.python_cmd
end

M.log_path = vim.fn.stdpath("log") .. "/superblink.log"

--- Check if the server process handle is still alive.
--- @return boolean
local function process_alive()
  if not _process then
    return false
  end
  -- vim.system objects have no direct "is running" check;
  -- we test by checking if :wait(0) returns (exited) or not.
  -- A simpler approach: try a non-blocking wait. If it returns
  -- a result, the process has exited.
  local ok, result = pcall(function()
    return _process:wait(0)
  end)
  if ok and result and result.code ~= nil then
    _process = nil
    return false
  end
  return true
end

--- Start the Python server as a detached background process.
function M.start()
  if process_alive() then
    log("INFO", "start() skipped — process already alive")
    vim.notify("[superblink] server already running", vim.log.levels.INFO)
    return
  end

  if vim.fn.filereadable(_server_script) ~= 1 then
    log("ERROR", "server script not found: %s", _server_script)
    vim.notify("[superblink] server script not found: " .. _server_script, vim.log.levels.ERROR)
    return
  end

  local env = vim.fn.environ()
  env.OLLAMA_MODEL = config.ollama_model
  env.OLLAMA_URL = config.ollama_url
  env.MAX_CONTEXT_CHUNKS = tostring(config.max_context_chunks)
  env.MAX_RAG_CHARS = tostring(config.max_rag_chars)
  env.MAX_TOKENS = tostring(config.max_tokens)

  -- Python logging uses "warning" not "warn"
  local log_level_map = { warn = "warning" }
  local py_log_level = log_level_map[config.log_level] or config.log_level

  local python = resolve_python()
  log("INFO", "starting server: python=%s script=%s port=%d log_level=%s", python, _server_script, config.server_port, py_log_level)

  local cmd = {
    python,
    _server_script,
    "--port", tostring(config.server_port),
    "--log-level", py_log_level,
  }

  _process = vim.system(cmd, {
    detach = true,
    text = true,
    env = env,
    stdout = function(_, data)
      if data then
        local f = io.open(M.log_path, "a")
        if f then
          f:write(data)
          f:close()
        end
      end
    end,
    stderr = function(_, data)
      if data then
        local f = io.open(M.log_path, "a")
        if f then
          f:write(data)
          f:close()
        end
      end
    end,
  })

  -- Invalidate health cache so next check is fresh
  _health_cache = nil
  _health_cache_time = 0
  _server_confirmed = false

  log("INFO", "server process spawned (detached), _process=%s", tostring(_process))
  vim.notify("[superblink] server started", vim.log.levels.INFO)
end

--- Stop the server process (SIGTERM, then SIGKILL after 2s).
function M.stop()
  if not _process then
    return
  end

  -- Try SIGTERM first
  pcall(function()
    _process:kill(15) -- SIGTERM
  end)

  -- Give it 2 seconds to exit gracefully, then force kill
  vim.defer_fn(function()
    if process_alive() then
      pcall(function()
        _process:kill(9) -- SIGKILL
      end)
    end
    _process = nil
  end, 2000)

  _health_cache = nil
  _health_cache_time = 0
end

--- Restart the server.
function M.restart()
  M.stop()
  -- Wait a beat for the port to free up, then start
  vim.defer_fn(function()
    M.start()
  end, 2500)
end

--- Make an HTTP request using curl via vim.system.
--- @param method string "GET" or "POST"
--- @param path string URL path (e.g. "/health")
--- @param body string|nil JSON body for POST
--- @param timeout_s number|nil timeout in seconds
--- @param callback fun(ok: boolean, data: any)
local function http_request(method, path, body, timeout_s, callback)
  local url = config.server_url .. path
  timeout_s = timeout_s or 2

  local cmd = { "curl", "-s", "-X", method, url, "--max-time", tostring(timeout_s) }
  if method == "POST" and body then
    table.insert(cmd, "-H")
    table.insert(cmd, "Content-Type: application/json")
    table.insert(cmd, "-d")
    table.insert(cmd, body)
  end

  local curl_path = vim.fn.exepath("curl") or "curl"
  cmd[1] = curl_path
  log("DEBUG", "http_request %s %s (timeout=%ds) curl=%s", method, path, timeout_s, curl_path)

  vim.system(cmd, { text = true }, function(result)
    log("DEBUG", "http_request %s %s → code=%s stdout_len=%d stderr=%s",
      method, path,
      tostring(result.code),
      result.stdout and #result.stdout or 0,
      tostring(result.stderr))

    vim.schedule(function()
      if result.code ~= 0 or not result.stdout or result.stdout == "" then
        log("WARN", "http_request %s %s failed: code=%s", method, path, tostring(result.code))
        callback(false, nil)
        return
      end
      local ok, data = pcall(vim.fn.json_decode, result.stdout)
      if ok then
        callback(true, data)
      else
        log("WARN", "http_request %s %s json decode failed: %s", method, path, tostring(result.stdout):sub(1, 200))
        callback(false, nil)
      end
    end)
  end)
end

--- Mark the server as confirmed running (called after a successful /complete response).
function M.confirm_alive()
  if not _server_confirmed then
    log("INFO", "confirm_alive: server now confirmed")
  end
  _server_confirmed = true
end

--- Mark the server as down (called after a failed /complete request).
function M.mark_down()
  if _server_confirmed then
    log("WARN", "mark_down: server marked unhealthy")
  end
  _server_confirmed = false
end

--- Ensure the server is running before a completion request.
--- Fast path: once server has responded successfully, skip health checks entirely.
--- Only does a health check on first call or after a failure.
--- @param callback fun(healthy: boolean)
function M.ensure_running(callback)
  -- Fast path: server already confirmed alive, skip health check entirely
  if _server_confirmed then
    log("DEBUG", "ensure_running: fast path (already confirmed)")
    callback(true)
    return
  end

  log("INFO", "ensure_running: server not confirmed, checking health...")

  -- First time or after failure: check if server is reachable
  http_request("GET", "/health", nil, 2, function(ok, _)
    if ok then
      log("INFO", "ensure_running: health check passed")
      _server_confirmed = true
      callback(true)
      return
    end

    log("WARN", "ensure_running: health check failed, auto_start=%s process_alive=%s",
      tostring(config.auto_start), tostring(process_alive()))

    -- Server unreachable — try auto-starting if configured
    if config.auto_start and not process_alive() then
      M.start()
      vim.defer_fn(function()
        http_request("GET", "/health", nil, 2, function(started_ok, _)
          log("INFO", "ensure_running: post-start health check → %s", tostring(started_ok))
          _server_confirmed = started_ok
          callback(started_ok)
        end)
      end, 1500)
    else
      log("WARN", "ensure_running: giving up, callback(false)")
      callback(false)
    end
  end)
end

--- Fetch server status (GET /status) and pass parsed JSON to callback.
--- @param callback fun(ok: boolean, data: table|nil)
function M.status(callback)
  http_request("GET", "/status", nil, 3, callback)
end

--- Force re-index a project root (POST /index).
--- @param project_root string
--- @param callback fun(ok: boolean, data: table|nil)|nil
function M.index(project_root, callback)
  local body = vim.fn.json_encode({ project_root = project_root })
  http_request("POST", "/index", body, 30, callback or function() end)
end

--- Check if the server process is currently alive.
--- @return boolean
function M.is_running()
  return process_alive()
end

return M
