--- superblink server lifecycle management
--- Spawns, monitors, and stops the Python server process.

local config = require("superblink.config")

local M = {}

--- @type vim.SystemObj|nil
local _process = nil
local _health_cache = nil
local _health_cache_time = 0
local HEALTH_CACHE_TTL = 5 -- seconds

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
    vim.notify("[superblink] server already running", vim.log.levels.INFO)
    return
  end

  if vim.fn.filereadable(_server_script) ~= 1 then
    vim.notify("[superblink] server script not found: " .. _server_script, vim.log.levels.ERROR)
    return
  end

  local log_file = io.open(M.log_path, "a")
  if log_file then
    log_file:write(string.format("\n--- superblink server starting at %s ---\n", os.date()))
    log_file:close()
  end

  local env = vim.fn.environ()
  env.OLLAMA_MODEL = config.ollama_model
  env.OLLAMA_URL = config.ollama_url
  env.MAX_CONTEXT_CHUNKS = tostring(config.max_context_chunks)
  env.MAX_TOKENS = tostring(config.max_tokens)

  -- Python logging uses "warning" not "warn"
  local log_level_map = { warn = "warning" }
  local py_log_level = log_level_map[config.log_level] or config.log_level

  local python = resolve_python()
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

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 or not result.stdout or result.stdout == "" then
        callback(false, nil)
        return
      end
      local ok, data = pcall(vim.fn.json_decode, result.stdout)
      if ok then
        callback(true, data)
      else
        callback(false, nil)
      end
    end)
  end)
end

--- Ensure the server is running before a completion request.
--- Checks health first (handles externally-started servers), only starts if unreachable.
--- @param callback fun(healthy: boolean)
function M.ensure_running(callback)
  -- Check cache first
  local now = vim.uv.now() / 1000 -- ms -> seconds
  if _health_cache ~= nil and (now - _health_cache_time) < HEALTH_CACHE_TTL then
    callback(_health_cache)
    return
  end

  -- Always check health first — server may already be running (manually or from previous session)
  http_request("GET", "/health", nil, 2, function(ok, _)
    if ok then
      _health_cache = true
      _health_cache_time = vim.uv.now() / 1000
      callback(true)
      return
    end

    -- Server unreachable — try auto-starting if configured
    if config.auto_start and not process_alive() then
      M.start()
      vim.defer_fn(function()
        http_request("GET", "/health", nil, 2, function(started_ok, _)
          _health_cache = started_ok
          _health_cache_time = vim.uv.now() / 1000
          callback(started_ok)
        end)
      end, 1500)
    else
      _health_cache = false
      _health_cache_time = vim.uv.now() / 1000
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
