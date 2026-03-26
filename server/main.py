"""
superblink - local project-aware code completion server

Auto-indexes projects via BM25 at function-level granularity,
enriches FIM completion requests with relevant code chunks,
and forwards to Ollama.
"""

import argparse
import hashlib
import logging
import os
import re
import threading
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path

import httpx
import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel
from rank_bm25 import BM25Okapi
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

log = logging.getLogger("superblink")

# Config

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5-coder:1.5b")
MAX_CONTEXT_CHUNKS = int(os.getenv("MAX_CONTEXT_CHUNKS", "8"))
MAX_TOKENS = int(os.getenv("MAX_TOKENS", "128"))
CHUNK_MAX_LINES = int(os.getenv("CHUNK_MAX_LINES", "60"))
MAX_FILE_SIZE = int(os.getenv("MAX_FILE_SIZE", str(512 * 1024)))  # 512KB
MAX_PROMPT_CHARS = int(os.getenv("MAX_PROMPT_CHARS", str(32_000)))  # rough cap

CODE_EXTENSIONS = frozenset(
    {
        ".zig",
        ".py",
        ".js",
        ".ts",
        ".tsx",
        ".jsx",
        ".rs",
        ".go",
        ".c",
        ".cpp",
        ".h",
        ".hpp",
        ".lua",
        ".rb",
        ".java",
        ".kt",
        ".swift",
        ".cs",
        ".ex",
        ".exs",
        ".clj",
        ".ml",
        ".mli",
        ".hs",
        ".sh",
        ".bash",
        ".fish",
        ".toml",
        ".yaml",
        ".yml",
        ".json",
        ".html",
        ".css",
        ".scss",
        ".sql",
        ".proto",
        ".glsl",
        ".hlsl",
        ".slang",
        ".wgsl",
        ".vert",
        ".frag",
        ".comp",
    }
)

IGNORE_DIRS = frozenset(
    {
        ".git",
        "node_modules",
        "__pycache__",
        ".zig-cache",
        "zig-out",
        "target",
        "build",
        "dist",
        ".venv",
        "venv",
        ".mypy_cache",
        "vendor",
        ".cache",
        "zig-cache",
        ".next",
        "out",
    }
)

# FIM templates keyed by model family substring

FIM_TEMPLATES = {
    "qwen": {
        "prefix": "<|fim_prefix|>",
        "suffix": "<|fim_suffix|>",
        "middle": "<|fim_middle|>",
    },
    "starcoder": {
        "prefix": "<fim_prefix>",
        "suffix": "<fim_suffix>",
        "middle": "<fim_middle>",
    },
    "granite": {
        "prefix": "<fim_prefix>",
        "suffix": "<fim_suffix>",
        "middle": "<fim_middle>",
    },
    "deepseek": {
        "prefix": "<\uff5cfim\u2581begin\uff5c>",
        "suffix": "<\uff5cfim\u2581hole\uff5c>",
        "middle": "<\uff5cfim\u2581end\uff5c>",
    },
    "codellama": {
        "prefix": "<PRE> ",
        "suffix": " <SUF>",
        "middle": " <MID>",
    },
}


def detect_fim_template(model: str) -> dict:
    model_lower = model.lower()
    for family, tpl in FIM_TEMPLATES.items():
        if family in model_lower:
            return tpl
    return FIM_TEMPLATES["qwen"]


# Tokenizer — code-aware, splits camelCase and snake_case

_CAMEL_BOUNDARY = re.compile(
    r"(?<=[a-z])(?=[A-Z])"  # camelCase boundary
    r"|(?<=[A-Z])(?=[A-Z][a-z])"  # ABCDef → ABC Def
)
_SPLIT_NON_ALNUM = re.compile(r"[^a-zA-Z0-9]+")


def tokenize(text: str) -> list[str]:
    """
    Code-aware tokenizer. Splits on non-alphanumeric chars, then further
    splits camelCase identifiers. Lowercased, drops single-char tokens.

    'getUserName' → ['get', 'user', 'name']
    'MAX_RETRY_COUNT' → ['max', 'retry', 'count']
    'SDL_GPUTexture' → ['sdl', 'gpu', 'texture']
    """
    parts = _SPLIT_NON_ALNUM.split(text)
    tokens = []
    for part in parts:
        sub = _CAMEL_BOUNDARY.split(part)
        for s in sub:
            s_lower = s.lower()
            if len(s_lower) > 1:
                tokens.append(s_lower)
    return tokens


# Chunker — splits source files at declaration boundaries

CHUNK_BOUNDARY = re.compile(
    r"^(?:"
    r"(?:pub\s+)?(?:fn|const|var|test)\s+"  # zig
    r"|(?:@\w+\s+)*(?:def|class|async\s+def)\s+"  # python (with decorators)
    r"|(?:export\s+)?(?:function|const|let|class)\s+"  # js/ts
    r"|(?:pub(?:\(crate\))?\s+)?(?:fn|struct|enum|impl|mod|trait|type)\s+"  # rust
    r"|(?:func)\s+"  # go
    r"|(?:typedef|struct|enum|union|static|inline)\s+"  # c/c++
    r")",
    re.MULTILINE,
)


@dataclass
class Chunk:
    filepath: str
    content: str
    lineno: int
    tokens: list[str] = field(default_factory=list)


def chunk_file(filepath: str, content: str) -> list[Chunk]:
    """Split a source file into chunks at top-level declaration boundaries."""
    lines = content.split("\n")
    if not lines:
        return []

    boundaries = [i for i, line in enumerate(lines) if CHUNK_BOUNDARY.match(line)]

    if not boundaries:
        # No declarations — treat whole file as one chunk if small enough
        if len(lines) <= CHUNK_MAX_LINES:
            text = content.strip()
            return [Chunk(filepath, text, 1, tokenize(text))] if text else []
        return []

    chunks = []

    # Preamble (imports, module-level docs)
    if boundaries[0] > 0:
        preamble = "\n".join(lines[: boundaries[0]]).strip()
        if preamble:
            chunks.append(Chunk(filepath, preamble, 1, tokenize(preamble)))

    for idx, start in enumerate(boundaries):
        end = boundaries[idx + 1] if idx + 1 < len(boundaries) else len(lines)
        end = min(end, start + CHUNK_MAX_LINES)
        text = "\n".join(lines[start:end]).strip()
        if text:
            # Prepend filepath to tokens so file-level relevance is captured
            toks = tokenize(filepath) + tokenize(text)
            chunks.append(Chunk(filepath, text, start + 1, toks))

    return chunks


# Project index


@dataclass
class ProjectIndex:
    root: str
    chunks: list[Chunk] = field(default_factory=list)
    bm25: BM25Okapi | None = None
    file_hashes: dict[str, str] = field(default_factory=dict)
    _bm25_dirty: bool = False
    _last_bm25_rebuild: float = 0.0

    def build(self):
        """Full index build from disk."""
        t0 = time.time()
        self.chunks.clear()
        self.file_hashes.clear()

        root = Path(self.root)
        file_count = 0

        for path in root.rglob("*"):
            if any(part in IGNORE_DIRS for part in path.parts):
                continue
            if path.suffix not in CODE_EXTENSIONS or not path.is_file():
                continue
            # Skip large files (generated code, vendored, etc.)
            try:
                if path.stat().st_size > MAX_FILE_SIZE:
                    continue
            except OSError:
                continue

            self._index_file(path, root)
            file_count += 1

        self._rebuild_bm25()
        elapsed = time.time() - t0
        log.info(
            f"Indexed {self.root}: {len(self.chunks)} chunks "
            f"from {file_count} files in {elapsed:.2f}s"
        )

    def _index_file(self, path: Path, root: Path):
        try:
            content = path.read_text(encoding="utf-8", errors="ignore")
        except (OSError, PermissionError) as e:
            log.warning(f"Cannot read {path}: {e}")
            return

        h = hashlib.md5(content.encode()).hexdigest()
        rel = str(path.relative_to(root))
        self.file_hashes[rel] = h
        self.chunks.extend(chunk_file(rel, content))

    def update_file(self, filepath: str):
        """Incrementally re-index a single file."""
        root = Path(self.root)
        full_path = root / filepath

        # Remove old chunks for this file
        self.chunks = [c for c in self.chunks if c.filepath != filepath]

        if full_path.exists() and full_path.suffix in CODE_EXTENSIONS:
            try:
                size = full_path.stat().st_size
                if size > MAX_FILE_SIZE:
                    self.file_hashes.pop(filepath, None)
                    self._mark_dirty()
                    return

                content = full_path.read_text(encoding="utf-8", errors="ignore")
                h = hashlib.md5(content.encode()).hexdigest()

                if self.file_hashes.get(filepath) == h:
                    return  # unchanged

                self.file_hashes[filepath] = h
                self.chunks.extend(chunk_file(filepath, content))
            except (OSError, PermissionError) as e:
                log.warning(f"Cannot update {filepath}: {e}")
        else:
            self.file_hashes.pop(filepath, None)

        self._mark_dirty()

    def _mark_dirty(self):
        """Debounced BM25 rebuild — avoids thrashing on burst writes."""
        self._bm25_dirty = True
        now = time.time()
        # Rebuild at most once per second
        if now - self._last_bm25_rebuild > 1.0:
            self._rebuild_bm25()

    def ensure_bm25(self):
        """Call before search to flush any pending rebuild."""
        if self._bm25_dirty:
            self._rebuild_bm25()

    def _rebuild_bm25(self):
        if self.chunks:
            self.bm25 = BM25Okapi([c.tokens for c in self.chunks])
        else:
            self.bm25 = None
        self._bm25_dirty = False
        self._last_bm25_rebuild = time.time()

    def search(self, query: str, top_k: int = MAX_CONTEXT_CHUNKS) -> list[Chunk]:
        """Find the most relevant chunks for a query string."""
        self.ensure_bm25()
        if not self.bm25 or not self.chunks:
            return []

        tokens = tokenize(query)
        if not tokens:
            return []

        scores = self.bm25.get_scores(tokens)
        ranked = sorted(enumerate(scores), key=lambda x: x[1], reverse=True)
        return [self.chunks[idx] for idx, score in ranked[:top_k] if score > 0]


# File watcher


class ProjectWatcher(FileSystemEventHandler):
    def __init__(self, index: ProjectIndex):
        self.index = index
        self._debounce: dict[str, float] = {}

    def _handle(self, event):
        if event.is_directory:
            return
        path = Path(event.src_path)
        if path.suffix not in CODE_EXTENSIONS:
            return
        if any(part in IGNORE_DIRS for part in path.parts):
            return
        try:
            rel = str(path.relative_to(self.index.root))
        except ValueError:
            return

        now = time.time()
        if now - self._debounce.get(rel, 0) < 1.0:
            return
        self._debounce[rel] = now
        self.index.update_file(rel)

    on_modified = _handle
    on_created = _handle
    on_deleted = _handle


# State

projects: dict[str, ProjectIndex] = {}
observers: dict[str, Observer] = {}


def get_or_create_index(project_root: str) -> ProjectIndex:
    project_root = str(Path(project_root).resolve())

    if project_root in projects:
        return projects[project_root]

    log.info(f"New project detected: {project_root}")
    index = ProjectIndex(root=project_root)
    index.build()
    projects[project_root] = index

    handler = ProjectWatcher(index)
    observer = Observer()
    observer.schedule(handler, project_root, recursive=True)
    observer.daemon = True
    observer.start()
    observers[project_root] = observer

    return index


def detect_git_root(filepath: str) -> str | None:
    path = Path(filepath).resolve()
    if path.is_file():
        path = path.parent
    for parent in [path, *path.parents]:
        if (parent / ".git").exists():
            return str(parent)
    return None


# App


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    for obs in observers.values():
        obs.stop()
        obs.join(timeout=2)
    log.info("Shut down file watchers")


app = FastAPI(title="superblink", lifespan=lifespan)


# Endpoints


class CompletionRequest(BaseModel):
    filepath: str
    content: str
    line: int  # 0-indexed cursor line
    col: int  # 0-indexed cursor column
    project_root: str | None = None


class CompletionResponse(BaseModel):
    completion: str
    chunks_used: int
    model: str
    elapsed_ms: float


@app.post("/complete", response_model=CompletionResponse)
async def complete(req: CompletionRequest):
    t0 = time.time()

    if not req.content.strip() or not req.filepath.strip():
        return CompletionResponse(
            completion="",
            chunks_used=0,
            model=OLLAMA_MODEL,
            elapsed_ms=0.0,
        )

    root = req.project_root or detect_git_root(req.filepath)
    if not root:
        # Fallback to parent dir, but log a warning
        root = str(Path(req.filepath).parent)
        log.warning(f"No git root found for {req.filepath}, falling back to {root}")

    index = get_or_create_index(root)

    # --- Split at cursor ---
    lines = req.content.split("\n")
    cursor_line = max(0, min(req.line, len(lines) - 1))
    cursor_col = max(0, req.col)

    prefix_lines = lines[:cursor_line]
    current = lines[cursor_line] if cursor_line < len(lines) else ""
    prefix_lines.append(current[:cursor_col])

    suffix_lines = [current[cursor_col:]]
    if cursor_line + 1 < len(lines):
        suffix_lines.extend(lines[cursor_line + 1 :])

    prefix = "\n".join(prefix_lines)
    suffix = "\n".join(suffix_lines)

    # --- Retrieve relevant chunks ---
    # Query = ~15 lines around cursor for better relevance
    ctx_start = max(0, cursor_line - 10)
    ctx_end = min(len(lines), cursor_line + 5)
    query = "\n".join(lines[ctx_start:ctx_end])

    chunks = index.search(query, top_k=MAX_CONTEXT_CHUNKS)

    # Remove chunks from the exact same region of the current file to avoid
    # duplication, but keep chunks from distant parts of the same file
    rel_path = _relative_path(req.filepath, root)
    chunks = [
        c
        for c in chunks
        if c.filepath != rel_path or abs(c.lineno - cursor_line) > CHUNK_MAX_LINES
    ]

    # --- Build FIM prompt ---
    tpl = detect_fim_template(OLLAMA_MODEL)

    rag_block = ""
    if chunks:
        parts = [f"// --- {c.filepath}:{c.lineno} ---\n{c.content}" for c in chunks]
        rag_block = "\n\n".join(parts) + "\n\n"

    # Cap total prompt size to avoid blowing past the model's context window
    budget = MAX_PROMPT_CHARS - len(prefix) - len(suffix) - 200  # headroom for tokens
    if len(rag_block) > budget:
        rag_block = rag_block[:budget]

    prompt = (
        f"{tpl['prefix']}"
        f"{rag_block}"
        f"// --- {rel_path} ---\n"
        f"{prefix}"
        f"{tpl['suffix']}"
        f"{suffix}"
        f"{tpl['middle']}"
    )

    # --- Call Ollama ---
    completion = await _ollama_generate(prompt, tpl)

    elapsed = (time.time() - t0) * 1000
    return CompletionResponse(
        completion=completion,
        chunks_used=len(chunks),
        model=OLLAMA_MODEL,
        elapsed_ms=round(elapsed, 1),
    )


async def _ollama_generate(prompt: str, tpl: dict) -> str:
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(
                f"{OLLAMA_URL}/api/generate",
                json={
                    "model": OLLAMA_MODEL,
                    "prompt": prompt,
                    "raw": True,
                    "stream": False,
                    "options": {
                        "num_predict": MAX_TOKENS,
                        "temperature": 0.2,
                        "top_p": 0.9,
                        "stop": [
                            "\n",
                            tpl["prefix"],
                            tpl["suffix"],
                            tpl["middle"],
                            "<|endoftext|>",
                            "<|end|>",
                            "<|cursor|>",
                        ],
                    },
                },
            )
            resp.raise_for_status()
            text = resp.json().get("response", "").rstrip()
            # Strip any FIM tokens that leaked through stop sequences
            # Includes closing-tag variants some models emit (e.g. </fim_middle>)
            for token in (tpl["prefix"], tpl["suffix"], tpl["middle"]):
                text = text.replace(token, "")
                # Also strip XML-style closing variants
                if token.startswith("<") and not token.startswith("</"):
                    text = text.replace("</" + token[1:], "")
            # Strip other common junk tokens models may emit
            for junk in (
                "<|endoftext|>",
                "<|end|>",
                "<|cursor|>",
                "<|file_sep|>",
                "<|end▁of▁sentence|>",
                "</solution>",
                "<number_of_arguments>",
                "</number_of_arguments>",
            ):
                text = text.replace(junk, "")
            return text.strip()
    except httpx.TimeoutException:
        log.warning("Ollama request timed out")
        return ""
    except httpx.HTTPStatusError as e:
        log.error(f"Ollama HTTP error: {e.response.status_code}")
        return ""
    except Exception as e:
        log.error(f"Ollama error: {e}")
        return ""


def _relative_path(filepath: str, root: str) -> str:
    try:
        return str(Path(filepath).relative_to(root))
    except ValueError:
        return filepath


class IndexRequest(BaseModel):
    project_root: str


@app.post("/index")
async def index_project(req: IndexRequest):
    """Force a full re-index."""
    index = get_or_create_index(req.project_root)
    index.build()
    return {
        "root": index.root,
        "files": len(index.file_hashes),
        "chunks": len(index.chunks),
    }


@app.get("/health")
async def health():
    """Quick liveness check."""
    return {"status": "ok"}


@app.get("/pid")
async def pid():
    """Return the server PID for process management."""
    return {"pid": os.getpid()}


@app.post("/shutdown")
async def shutdown():
    """Cleanly stop the server. Exits in a background thread so the response lands."""

    def _exit():
        time.sleep(0.3)
        os._exit(0)

    threading.Thread(target=_exit, daemon=True).start()
    return {"status": "shutting_down"}


@app.get("/status")
async def status():
    return {
        "projects": {
            root: {
                "files": len(idx.file_hashes),
                "chunks": len(idx.chunks),
            }
            for root, idx in projects.items()
        },
        "model": OLLAMA_MODEL,
        "ollama_url": OLLAMA_URL,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="superblink completion server")
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.getenv("PORT", "7878")),
        help="Port to listen on (env: PORT, default: 7878)",
    )
    parser.add_argument(
        "--log-level",
        default=os.getenv("LOG_LEVEL", "info"),
        choices=["debug", "info", "warning", "error", "critical"],
        help="Log level (env: LOG_LEVEL, default: info)",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper()),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    log.info(
        "superblink starting — model=%s ollama=%s port=%d",
        OLLAMA_MODEL,
        OLLAMA_URL,
        args.port,
    )
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level=args.log_level)
