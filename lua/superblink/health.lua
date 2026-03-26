--- superblink health checks for :checkhealth superblink

local M = {}

local config = require("superblink.config")

local ok = vim.health.ok
local warn = vim.health.warn
local error = vim.health.error

-- Resolve plugin root the same way server.lua does
local _this_file = debug.getinfo(1, "S").source:sub(2)
local _plugin_root = vim.fn.fnamemodify(_this_file, ":h:h:h")
local _venv_python = _plugin_root .. "/server/.venv/bin/python3"

--- Run a command synchronously and return stdout, exit code.
--- @param cmd string[]
--- @param timeout_ms number|nil
--- @return string stdout
--- @return number code
local function run(cmd, timeout_ms)
  local result = vim.system(cmd, { text = true }):wait(timeout_ms or 5000)
  return result.stdout or "", result.code or -1
end

--- Resolve the python to check: prefer the bundled venv.
--- @return string
local function resolve_python()
  if vim.fn.executable(_venv_python) == 1 then
    return _venv_python
  end
  return config.python_cmd
end

function M.check()
  vim.health.start("superblink")

  -- 1. Python on PATH and version >= 3.11
  local python = resolve_python()
  if vim.fn.executable(python) == 1 then
    local stdout, code = run({ python, "--version" })
    if code == 0 then
      local version = stdout:match("Python%s+(%d+%.%d+%.%d+)")
      if version then
        local major, minor = version:match("^(%d+)%.(%d+)")
        major, minor = tonumber(major), tonumber(minor)
        if major >= 3 and minor >= 11 then
          ok(python .. " " .. version)
        else
          error(python .. " " .. version .. " found, but >= 3.11 is required")
        end
      else
        warn("Could not parse Python version from: " .. stdout)
      end
    else
      error(python .. " --version failed")
    end
  else
    error(python .. " not found on PATH")
  end

  -- 2. Required Python packages
  local packages = { "fastapi", "uvicorn", "httpx", "rank_bm25", "watchdog" }
  for _, pkg in ipairs(packages) do
    local _, code = run({ python, "-c", "import " .. pkg })
    if code == 0 then
      ok("Python package: " .. pkg)
    else
      error("Python package missing: " .. pkg .. " (run: bash server/setup.sh)")
    end
  end

  -- 3. Ollama available
  local ollama_ok = false
  if vim.fn.executable("ollama") == 1 then
    ok("ollama binary found on PATH")
    ollama_ok = true
  else
    -- Try reaching the configured ollama URL
    local stdout, code = run({
      "curl", "-s", "--max-time", "3",
      config.ollama_url .. "/api/tags",
    })
    if code == 0 and stdout ~= "" then
      ok("ollama reachable at " .. config.ollama_url)
      ollama_ok = true
    else
      warn("ollama not on PATH and " .. config.ollama_url .. " not reachable")
    end
  end

  -- 4. Configured model available in Ollama
  if ollama_ok then
    local model_found = false
    -- Try ollama list first
    if vim.fn.executable("ollama") == 1 then
      local stdout, code = run({ "ollama", "list" }, 10000)
      if code == 0 then
        for line in stdout:gmatch("[^\n]+") do
          if line:find(config.ollama_model, 1, true) then
            model_found = true
            break
          end
        end
      end
    end
    -- Fallback: check API
    if not model_found then
      local stdout, code = run({
        "curl", "-s", "--max-time", "3",
        config.ollama_url .. "/api/tags",
      })
      if code == 0 and stdout ~= "" then
        local decode_ok, data = pcall(vim.fn.json_decode, stdout)
        if decode_ok and data and data.models then
          for _, m in ipairs(data.models) do
            if m.name and m.name:find(config.ollama_model, 1, true) then
              model_found = true
              break
            end
          end
        end
      end
    end
    if model_found then
      ok("Model available: " .. config.ollama_model)
    else
      warn("Model '" .. config.ollama_model .. "' not found in Ollama. Run: ollama pull " .. config.ollama_model)
    end
  end

  -- 5. superblink server reachable
  local stdout, code = run({
    "curl", "-s", "--max-time", "2",
    config.server_url .. "/health",
  })
  if code == 0 and stdout ~= "" then
    local decode_ok, data = pcall(vim.fn.json_decode, stdout)
    if decode_ok and data and data.status == "ok" then
      ok("superblink server reachable at " .. config.server_url)
    else
      warn("superblink server at " .. config.server_url .. " returned unexpected response")
    end
  else
    warn("superblink server not reachable at " .. config.server_url .. ". Run :SuperblinkStart")
  end

  -- 6. blink.cmp installed and loaded
  local blink_ok, _ = pcall(require, "blink.cmp")
  if blink_ok then
    ok("blink.cmp is installed")
  else
    error("blink.cmp is not installed (required for completions)")
  end
end

return M
