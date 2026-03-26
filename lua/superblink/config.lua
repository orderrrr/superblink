--- superblink configuration
--- Single source of truth for all defaults and validation.

local M = {
  server_url = "http://127.0.0.1:7878",
  timeout_ms = 5000,
  auto_start = true,
  ollama_model = "qwen2.5-coder:1.5b",
  ollama_url = "http://localhost:11434",
  max_context_chunks = 8,
  max_tokens = 128,
  log_level = "warn",
  python_cmd = "python3",
  server_port = 7878,
}

local valid_log_levels = { debug = true, info = true, warn = true, error = true }

--- Deep-merge user options into config and validate.
--- @param user_opts table|nil
function M.apply(user_opts)
  if not user_opts then
    return
  end
  local merged = vim.tbl_deep_extend("force", M, user_opts)
  for k, v in pairs(merged) do
    M[k] = v
  end

  -- Validate port
  if type(M.server_port) ~= "number" or M.server_port < 1 or M.server_port > 65535 then
    vim.notify("[superblink] server_port must be a number between 1 and 65535, got: " .. tostring(M.server_port), vim.log.levels.ERROR)
    M.server_port = 7878
  end

  -- Keep server_url in sync with port if the user changed the port but not the url
  if not user_opts.server_url and user_opts.server_port then
    M.server_url = "http://127.0.0.1:" .. M.server_port
  end

  -- Validate timeout
  if type(M.timeout_ms) ~= "number" or M.timeout_ms < 100 then
    vim.notify("[superblink] timeout_ms must be a number >= 100, got: " .. tostring(M.timeout_ms), vim.log.levels.WARN)
    M.timeout_ms = 5000
  end

  -- Validate log_level
  if not valid_log_levels[M.log_level] then
    vim.notify("[superblink] log_level must be one of: debug, info, warn, error. Got: " .. tostring(M.log_level), vim.log.levels.WARN)
    M.log_level = "warn"
  end

  -- Validate python_cmd exists on PATH
  if vim.fn.executable(M.python_cmd) ~= 1 then
    vim.notify("[superblink] python_cmd '" .. M.python_cmd .. "' not found on PATH", vim.log.levels.WARN)
  end
end

return M
