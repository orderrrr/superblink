# superblink

Project-aware FIM code completions for Neovim via blink.cmp, BM25 retrieval, and Ollama.

## How it works

When you type in Neovim, blink.cmp fires the superblink source, which sends
your cursor context to a local Python server. The server detects the git root,
indexes the project on first request using BM25 over function-level code chunks,
retrieves the most relevant chunks, builds a fill-in-the-middle (FIM) prompt
enriched with that context, and forwards it to Ollama. The completion flows back
through blink.cmp into your editor. No per-project config files, no manual
indexing -- just open a file and type.

```
  You type in Neovim
        |
  blink.cmp (superblink source)
        |
  superblink server (BM25 RAG retrieval)
        |
  Ollama (FIM model)
        |
  completion appears in blink.cmp menu
```

## Features

- **Auto-indexing** -- projects are indexed on first completion request, no setup needed
- **Git project detection** -- automatically finds the git root for each file
- **BM25 RAG** -- retrieves relevant code chunks at function-level granularity
- **FIM completions** -- fill-in-the-middle prompts with context-aware prefix/suffix splitting
- **blink.cmp integration** -- appears as a native blink.cmp source with full/single-line options
- **File watcher** -- incremental re-indexing on file changes via watchdog
- **Multi-language support** -- Zig, Python, JS/TS, Rust, Go, C/C++, Lua, Ruby, Java, Kotlin, Swift, C#, Elixir, Haskell, and more
- **Auto-start** -- the server is spawned and managed by the plugin automatically

## Requirements

- Neovim >= 0.10
- Python >= 3.11
- [Ollama](https://ollama.com)
- [blink.cmp](https://github.com/saghen/blink.cmp)

## Quick start

**1. Install an Ollama model:**

```bash
ollama pull qwen2.5-coder:1.5b
```

**2. Install Python dependencies:**

```bash
cd /path/to/superblink && bash server/setup.sh
```

**3. Add the plugin to Neovim (lazy.nvim):**

```lua
{
  "your-username/superblink",
  config = function()
    require("superblink").setup({
      ollama_model = "qwen2.5-coder:1.5b",
    })
  end,
}
```

Then register the source in your blink.cmp config (see [Installation](#installation) for the full example).

## Installation

Add both the superblink plugin and the blink.cmp source registration to your lazy.nvim specs:

```lua
-- superblink plugin
{
  "your-username/superblink",
  config = function()
    require("superblink").setup({
      ollama_model = "qwen2.5-coder:1.5b",
    })
  end,
},

-- blink.cmp with superblink source
{
  "saghen/blink.cmp",
  opts = {
    sources = {
      default = { "lsp", "path", "superblink" },
      providers = {
        superblink = {
          name = "superblink",
          module = "blink.cmp.sources.superblink",
        },
      },
    },
  },
}
```

The server starts automatically when blink.cmp requests its first completion.
To disable auto-start, set `auto_start = false` in the setup opts and use `:SuperblinkStart` manually.

## Configuration reference

All options are passed to `require("superblink").setup({})`.

| Option | Type | Default | Description |
|---|---|---|---|
| `server_url` | `string` | `"http://127.0.0.1:7878"` | URL of the superblink server |
| `server_port` | `number` | `7878` | Port for the server (updates `server_url` automatically if changed) |
| `timeout_ms` | `number` | `5000` | Completion request timeout in milliseconds |
| `auto_start` | `boolean` | `true` | Automatically start the server on first completion |
| `ollama_model` | `string` | `"qwen2.5-coder:1.5b"` | Ollama model to use for FIM completions |
| `ollama_url` | `string` | `"http://localhost:11434"` | Ollama API endpoint |
| `max_context_chunks` | `number` | `8` | Number of BM25 chunks to include in the prompt |
| `max_tokens` | `number` | `128` | Maximum tokens for the completion response |
| `log_level` | `string` | `"warn"` | Server log level (`debug`, `info`, `warn`, `error`) |
| `python_cmd` | `string` | `"python3"` | Python binary to use for the server |

### Recommended models

| Model | Quality | Speed |
|---|---|---|
| `qwen2.5-coder:1.5b` | Good | Fast (default) |
| `qwen2.5-coder:3b` | Better | ~200ms slower |
| `starcoder2:3b` | Good | Comparable |
| `deepseek-coder-v2:lite` | Strong | Larger, slower |

## Commands reference

| Command | Description |
|---|---|
| `:SuperblinkStart` | Start the superblink server |
| `:SuperblinkStop` | Stop the superblink server |
| `:SuperblinkRestart` | Restart the superblink server |
| `:SuperblinkStatus` | Show server status (model, projects, chunk counts) |
| `:SuperblinkIndex` | Force re-index the current git project |
| `:SuperblinkLog` | Open the server log file in a split |
| `:SuperblinkHealth` | Run `:checkhealth superblink` |

## Server config

The Python server reads configuration from environment variables and CLI arguments.
When launched by the plugin, these are set automatically from your `setup()` opts.
For manual usage:

```bash
cd server
python main.py --port 7878 --log-level info
```

With environment variable overrides:

```bash
OLLAMA_MODEL=qwen2.5-coder:3b MAX_TOKENS=256 python main.py
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_URL` | `http://localhost:11434` | Ollama endpoint |
| `OLLAMA_MODEL` | `qwen2.5-coder:1.5b` | FIM model |
| `MAX_CONTEXT_CHUNKS` | `8` | RAG chunks per request |
| `MAX_TOKENS` | `128` | Max completion tokens |
| `CHUNK_MAX_LINES` | `60` | Max lines per chunk |
| `MAX_FILE_SIZE` | `524288` | Skip files larger than this (bytes) |
| `MAX_PROMPT_CHARS` | `32000` | Cap total prompt size |
| `PORT` | `7878` | Server listen port |
| `LOG_LEVEL` | `info` | Log level |

### CLI arguments

| Argument | Default | Description |
|---|---|---|
| `--port` | `7878` (or `PORT` env) | Port to listen on |
| `--log-level` | `info` (or `LOG_LEVEL` env) | `debug`, `info`, `warning`, `error`, `critical` |

## Server endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/complete` | POST | Completion request (used by the plugin) |
| `/index` | POST | Force re-index a project root |
| `/status` | GET | Show indexed projects and model info |
| `/health` | GET | Liveness check |
| `/pid` | GET | Return the server PID |
| `/shutdown` | POST | Cleanly stop the server |

## Troubleshooting

Run the built-in health checks:

```vim
:checkhealth superblink
```

This verifies Python version, required packages, Ollama availability, model
presence, server reachability, and blink.cmp installation.

To inspect server logs:

```vim
:SuperblinkLog
```

Common issues:

- **Server not starting** -- check that `python3` is on your PATH and >= 3.11.
  Run `bash server/setup.sh` to install dependencies into a venv.
- **No completions appearing** -- verify Ollama is running (`ollama serve`) and
  the configured model is pulled (`ollama pull qwen2.5-coder:1.5b`).
- **Slow completions** -- try a smaller model or reduce `max_context_chunks`.
- **Wrong project indexed** -- ensure your project has a `.git` directory.
  The server uses git root detection to scope the index.

## License

MIT
