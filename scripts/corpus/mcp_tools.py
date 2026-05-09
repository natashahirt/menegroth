"""Implementation of the corpus MCP tools.

These functions are pure Python (no dependency on the MCP runtime) so they
can be unit-tested directly. ``mcp_server.py`` adapts them into MCP tool
handlers.

Manifest semantics:

- A regular manifest entry maps to exactly one ``SourceRef`` whose ``text_path``
  points at one normalized ``.txt`` file.
- A ``text_only`` entry (currently the AISC chapter excerpts) maps to one
  implicit ``SourceRef`` per file in its ``text_dir``, with derived ids of the
  form ``"<parent_id>/<filename>"``. This keeps every result citable by a
  single source id.
"""

from __future__ import annotations

import bisect
import json
import re
from dataclasses import replace
from pathlib import Path
from typing import Any, Callable, Iterable

from .mcp_schemas import (
    CharInterval,
    ClauseLookup,
    ExtractionHit,
    PageRange,
    SourceRef,
    TextHit,
    ToolEnvelope,
    to_jsonable,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "corpus" / "manifests" / "sources.yml"
EXTRACTIONS_ROOT = REPO_ROOT / "corpus" / "extractions"

PAGE_MARKER_RE = re.compile(
    r"={20,}\s*\nPAGE\s+(\d+)\b[^\n]*\n={20,}",
    re.MULTILINE,
)


# ── manifest loading ──────────────────────────────────────────────────────

def _load_yaml(path: Path) -> Any:
    """Load a YAML file using PyYAML (already a dependency of ingest.py)."""
    import yaml
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f) or []


def _expand_text_only_entry(d: dict, repo_root: Path) -> list[SourceRef]:
    """Expand a text-only manifest entry into one ``SourceRef`` per file."""
    text_dir = repo_root / d["text_dir"]
    if not text_dir.exists():
        return []
    refs: list[SourceRef] = []
    for txt in sorted(text_dir.glob("*.txt")):
        refs.append(SourceRef(
            id=f"{d['id']}/{txt.name}",
            family=d["family"],
            role=d["role"],
            edition=d.get("edition", ""),
            tier=int(d.get("tier", 99)),
            source_path=None,
            text_path=str(txt.relative_to(repo_root)),
            encrypted=False,
            text_only=True,
            notes=d.get("notes", ""),
        ))
    return refs


def _entry_to_sources(d: dict, repo_root: Path) -> list[SourceRef]:
    """Normalize one manifest entry to one or more ``SourceRef``s."""
    if d.get("text_only"):
        return _expand_text_only_entry(d, repo_root)
    return [SourceRef(
        id=d["id"],
        family=d["family"],
        role=d["role"],
        edition=d.get("edition", ""),
        tier=int(d.get("tier", 99)),
        source_path=d.get("source_path"),
        text_path=d.get("text_path"),
        encrypted=bool(d.get("encrypted", False)),
        text_only=False,
        notes=d.get("notes", ""),
    )]


# ── corpus index (in-memory) ──────────────────────────────────────────────

class CorpusIndex:
    """Lazy, cached view of the corpus.

    Used by the MCP tools to avoid re-reading manifests/text files on every
    request. The index is cheap (Tier 1 corpus is ~10 MB of text), and we
    deliberately keep it in-process rather than persisting to disk so the
    agent never queries a stale snapshot.
    """

    def __init__(
        self,
        repo_root: Path = REPO_ROOT,
        manifest_path: Path = MANIFEST_PATH,
        extractions_root: Path = EXTRACTIONS_ROOT,
    ):
        self.repo_root = repo_root
        self.manifest_path = manifest_path
        self.extractions_root = extractions_root
        self._sources: list[SourceRef] | None = None
        self._sources_by_id: dict[str, SourceRef] = {}
        self._text_cache: dict[str, str] = {}
        self._page_cache: dict[str, list[tuple[int, int]]] = {}

    def sources(self) -> list[SourceRef]:
        if self._sources is None:
            entries = _load_yaml(self.manifest_path)
            refs: list[SourceRef] = []
            for d in entries:
                refs.extend(_entry_to_sources(d, self.repo_root))
            self._sources = refs
            self._sources_by_id = {r.id: r for r in refs}
        return self._sources

    def get_source(self, source_id: str) -> SourceRef | None:
        self.sources()
        return self._sources_by_id.get(source_id)

    def text(self, source_id: str) -> str:
        if source_id in self._text_cache:
            return self._text_cache[source_id]
        src = self.get_source(source_id)
        if src is None or src.text_path is None:
            return ""
        path = self.repo_root / src.text_path
        if not path.exists():
            return ""
        text = path.read_text(encoding="utf-8", errors="replace")
        self._text_cache[source_id] = text
        return text

    def page_index(self, source_id: str) -> list[tuple[int, int]]:
        """Return ``[(char_offset_at_page_start, page_num), ...]``."""
        if source_id in self._page_cache:
            return self._page_cache[source_id]
        text = self.text(source_id)
        pages: list[tuple[int, int]] = []
        for m in PAGE_MARKER_RE.finditer(text):
            pages.append((m.end(), int(m.group(1))))
        self._page_cache[source_id] = pages
        return pages


# ── helpers ───────────────────────────────────────────────────────────────

def _page_range_at(pages: list[tuple[int, int]], start: int, end: int) -> PageRange | None:
    """Return the page range containing the half-open interval [start, end)."""
    if not pages:
        return None
    starts = [p[0] for p in pages]
    i = max(0, bisect.bisect_right(starts, start) - 1)
    j = max(0, bisect.bisect_right(starts, max(end - 1, start)) - 1)
    return PageRange(start=pages[i][1], end=pages[j][1])


def _filter_sources(
    sources: Iterable[SourceRef],
    *,
    family: str | None = None,
    role: str | None = None,
    tier: int | None = None,
    edition: str | None = None,
    source_id: str | None = None,
) -> list[SourceRef]:
    """Apply common manifest filters."""
    out: list[SourceRef] = []
    for s in sources:
        if family and s.family != family:
            continue
        if role and s.role != role:
            continue
        if tier is not None and s.tier != tier:
            continue
        if edition and edition.lower() not in s.edition.lower():
            continue
        if source_id and s.id != source_id:
            continue
        out.append(s)
    return out


def _slice_window(text: str, start: int, end: int, ctx: int) -> tuple[str, str, str]:
    """Return ``(before, match, after)`` slices clamped to text bounds."""
    n = len(text)
    s = max(0, min(start, n))
    e = max(s, min(end, n))
    before = text[max(0, s - ctx):s]
    after = text[e:min(n, e + ctx)]
    return before, text[s:e], after


# ── text-side tools ───────────────────────────────────────────────────────

def list_sources(
    index: CorpusIndex,
    *,
    family: str | None = None,
    role: str | None = None,
    tier: int | None = None,
    edition: str | None = None,
    limit: int | None = None,
) -> ToolEnvelope:
    """Return manifest entries (expanded for text-only) matching filters."""
    sources = _filter_sources(
        index.sources(), family=family, role=role, tier=tier, edition=edition,
    )
    truncated = False
    if limit is not None and limit >= 0 and len(sources) > limit:
        sources = sources[:limit]
        truncated = True
    return ToolEnvelope(status="ok", results=list(sources), truncated=truncated)


def get_source_text(
    index: CorpusIndex,
    source_id: str,
    *,
    char_start: int | None = None,
    char_end: int | None = None,
    max_chars: int = 20_000,
) -> ToolEnvelope:
    """Read a slice of a source's normalized ``.txt``.

    Hard-capped at ``max_chars`` to keep MCP transport payloads sane.
    """
    src = index.get_source(source_id)
    if src is None:
        return ToolEnvelope(status="error", message=f"unknown source_id: {source_id!r}")
    text = index.text(source_id)
    if not text:
        return ToolEnvelope(status="error", message=f"no text available for {source_id!r}")

    n = len(text)
    s = 0 if char_start is None else max(0, min(char_start, n))
    e = n if char_end is None else max(s, min(char_end, n))
    if e - s > max_chars:
        e = s + max_chars
        truncated = True
    else:
        truncated = False

    page_range = _page_range_at(index.page_index(source_id), s, e)
    hit = TextHit(
        source=src,
        match_text=text[s:e],
        char_interval=CharInterval(start=s, end=e),
        context_before="",
        context_after="",
        page_range=page_range,
    )
    return ToolEnvelope(status="ok", results=[hit], truncated=truncated)


def search_text(
    index: CorpusIndex,
    query: str,
    *,
    family: str | None = None,
    role: str | None = None,
    source_id: str | None = None,
    max_results: int = 20,
    context_chars: int = 300,
    regex: bool = False,
    case_sensitive: bool = False,
) -> ToolEnvelope:
    """Substring or regex search across selected ``corpus/text/`` sources.

    Documented as the **fallback** path: prefer ``search_extractions`` /
    ``get_clause`` when a structured extraction class covers the question.
    """
    if not query:
        return ToolEnvelope(status="error", message="query must be non-empty")

    flags = 0 if case_sensitive else re.IGNORECASE
    pattern = re.compile(query if regex else re.escape(query), flags)

    sources = _filter_sources(
        index.sources(), family=family, role=role, source_id=source_id,
    )
    hits: list[TextHit] = []
    for src in sources:
        text = index.text(src.id)
        if not text:
            continue
        pages = index.page_index(src.id)
        for m in pattern.finditer(text):
            start, end = m.span()
            before, match_text, after = _slice_window(text, start, end, context_chars)
            hits.append(TextHit(
                source=src,
                match_text=match_text,
                char_interval=CharInterval(start=start, end=end),
                context_before=before,
                context_after=after,
                page_range=_page_range_at(pages, start, end),
                line_number=text.count("\n", 0, start) + 1,
            ))
            if len(hits) >= max_results:
                break
        if len(hits) >= max_results:
            break
    truncated = len(hits) >= max_results
    return ToolEnvelope(status="ok", results=hits, truncated=truncated)


def page_window(
    index: CorpusIndex,
    source_id: str,
    page_start: int,
    page_end: int,
    *,
    max_chars: int = 30_000,
) -> ToolEnvelope:
    """Return the text spanning ``[page_start, page_end]`` (inclusive).

    Uses the ``===== PAGE N =====`` markers inserted by
    ``scripts/util/convert_pdfs_to_text.py``.
    """
    src = index.get_source(source_id)
    if src is None:
        return ToolEnvelope(status="error", message=f"unknown source_id: {source_id!r}")
    if page_end < page_start:
        return ToolEnvelope(status="error", message="page_end < page_start")
    text = index.text(source_id)
    pages = index.page_index(source_id)
    if not pages:
        return ToolEnvelope(
            status="error",
            message=f"no PAGE markers found in text for {source_id!r}",
        )

    # pages: list[(char_offset_at_page_start, page_num)] sorted by offset.
    by_num = {p: off for off, p in pages}
    if page_start not in by_num:
        return ToolEnvelope(status="error", message=f"page {page_start} not in source")
    start_off = by_num[page_start]

    # End offset is the start of the page *after* page_end (or EOF).
    next_pages = [(off, p) for off, p in pages if p > page_end]
    end_off = next_pages[0][0] if next_pages else len(text)

    truncated = False
    if end_off - start_off > max_chars:
        end_off = start_off + max_chars
        truncated = True

    hit = TextHit(
        source=src,
        match_text=text[start_off:end_off],
        char_interval=CharInterval(start=start_off, end=end_off),
        context_before="",
        context_after="",
        page_range=PageRange(start=page_start, end=page_end),
    )
    return ToolEnvelope(status="ok", results=[hit], truncated=truncated)


# ── extraction-side tools ─────────────────────────────────────────────────

def _no_extractions_envelope() -> ToolEnvelope:
    return ToolEnvelope(
        status="no_extractions_available",
        results=[],
        hint=(
            "No LangExtract output found under corpus/extractions/. "
            "Run `julia scripts/runners/corpus_extract_langextract.jl --apply` "
            "after defining a task config under scripts/corpus/tasks/."
        ),
    )


def _iter_extraction_files(extractions_root: Path, task: str | None = None) -> Iterable[Path]:
    if not extractions_root.exists():
        return []
    if task:
        task_dir = extractions_root / task
        if not task_dir.exists():
            return []
        return sorted(task_dir.rglob("*.jsonl"))
    return sorted(extractions_root.rglob("*.jsonl"))


def _hit_from_jsonl(
    raw: dict,
    *,
    source: SourceRef,
    jsonl_path: Path,
    line_number: int,
    repo_root: Path,
) -> ExtractionHit | None:
    """Parse a single JSONL row into an ``ExtractionHit``.

    Filters out ungrounded entries (LangExtract ``char_interval == null``).
    """
    ci = raw.get("char_interval")
    if not ci or ci.get("start_pos") is None or ci.get("end_pos") is None:
        return None
    return ExtractionHit(
        extraction_id=str(raw.get("extraction_id") or raw.get("id") or ""),
        extraction_class=str(raw.get("extraction_class", "")),
        extraction_text=str(raw.get("extraction_text", "")),
        attributes=dict(raw.get("attributes") or {}),
        source=source,
        char_interval=CharInterval(start=int(ci["start_pos"]), end=int(ci["end_pos"])),
        task=jsonl_path.parent.name,
        jsonl_path=str(jsonl_path.relative_to(repo_root)),
        line_number=line_number,
    )


def _resolve_source_for_jsonl(
    index: CorpusIndex, jsonl_path: Path
) -> SourceRef | None:
    """Find the SourceRef whose text_path mirrors this JSONL's relative path.

    Convention: ``corpus/extractions/<task>/<mirrored text path>.jsonl`` maps
    to ``corpus/text/<mirrored text path>.txt``.
    """
    rel = jsonl_path.relative_to(index.extractions_root)
    parts = rel.parts
    if len(parts) < 2:
        return None
    # Drop the leading task directory + replace .jsonl with .txt suffix.
    mirrored = Path(*parts[1:]).with_suffix(".txt")
    target_text = "corpus/text" / mirrored
    target_str = str(target_text)
    for s in index.sources():
        if s.text_path == target_str:
            return s
    return None


def search_extractions(
    index: CorpusIndex,
    extraction_class: str | None = None,
    *,
    family: str | None = None,
    role: str | None = None,
    source_id: str | None = None,
    task: str | None = None,
    attributes: dict[str, Any] | None = None,
    max_results: int = 50,
) -> ToolEnvelope:
    """Iterate JSONL extraction files and return matching ``ExtractionHit``s."""
    files = list(_iter_extraction_files(index.extractions_root, task=task))
    if not files:
        return _no_extractions_envelope()

    hits: list[ExtractionHit] = []
    for jsonl_path in files:
        src = _resolve_source_for_jsonl(index, jsonl_path)
        if src is None:
            continue
        if family and src.family != family:
            continue
        if role and src.role != role:
            continue
        if source_id and src.id != source_id:
            continue
        with jsonl_path.open("r", encoding="utf-8") as f:
            for i, line in enumerate(f, start=1):
                line = line.strip()
                if not line:
                    continue
                try:
                    raw = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if extraction_class and raw.get("extraction_class") != extraction_class:
                    continue
                if attributes:
                    attrs = raw.get("attributes") or {}
                    if not all(attrs.get(k) == v for k, v in attributes.items()):
                        continue
                hit = _hit_from_jsonl(
                    raw, source=src, jsonl_path=jsonl_path, line_number=i,
                    repo_root=index.repo_root,
                )
                if hit is None:
                    continue
                hits.append(hit)
                if len(hits) >= max_results:
                    break
        if len(hits) >= max_results:
            break

    return ToolEnvelope(
        status="ok", results=hits, truncated=len(hits) >= max_results,
    )


def get_extraction_by_id(
    index: CorpusIndex, extraction_id: str
) -> ToolEnvelope:
    """Return the single extraction matching ``extraction_id``."""
    files = list(_iter_extraction_files(index.extractions_root))
    if not files:
        return _no_extractions_envelope()
    for jsonl_path in files:
        src = _resolve_source_for_jsonl(index, jsonl_path)
        if src is None:
            continue
        with jsonl_path.open("r", encoding="utf-8") as f:
            for i, line in enumerate(f, start=1):
                line = line.strip()
                if not line:
                    continue
                try:
                    raw = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if (raw.get("extraction_id") or raw.get("id")) != extraction_id:
                    continue
                hit = _hit_from_jsonl(
                    raw, source=src, jsonl_path=jsonl_path, line_number=i,
                    repo_root=index.repo_root,
                )
                if hit:
                    return ToolEnvelope(status="ok", results=[hit])
    return ToolEnvelope(
        status="error", message=f"extraction not found: {extraction_id!r}",
    )


def search_by_attributes(
    index: CorpusIndex,
    extraction_class: str,
    attributes: dict[str, Any],
    *,
    family: str | None = None,
    role: str | None = None,
    max_results: int = 50,
) -> ToolEnvelope:
    """Convenience wrapper: typed attribute filter for an extraction class."""
    return search_extractions(
        index,
        extraction_class=extraction_class,
        attributes=attributes,
        family=family,
        role=role,
        max_results=max_results,
    )


# Heuristic: ACI / AISC / fib clause headings as they typically appear in
# the published PDFs. These regexes are intentionally conservative — we'd
# rather return ``"not-found"`` than match the wrong clause.
_CLAUSE_HEADING_RE = {
    "aci": lambda clause: re.compile(
        rf"\b{re.escape(clause)}\b\s*[\—\-—]?\s*[A-Z]",
    ),
    "aisc": lambda clause: re.compile(
        rf"(?:Section\s+|§\s*)?{re.escape(clause)}\b",
    ),
    "fib": lambda clause: re.compile(
        rf"\b{re.escape(clause)}\b",
    ),
}


def get_clause(
    index: CorpusIndex,
    family: str,
    edition: str,
    clause_id: str,
    *,
    context_chars: int = 600,
) -> ToolEnvelope:
    """Best-effort clause lookup.

    Tries extractions first (preferred); falls back to a regex search of
    canonical clause headings in ``corpus/text/`` for the given source.
    """
    sources = _filter_sources(
        index.sources(), family=family, edition=edition,
    )
    if not sources:
        return ToolEnvelope(
            status="error",
            message=f"no source matches family={family!r} edition≈{edition!r}",
        )

    # 1. Try extractions whose `attributes.clause_id` equals the requested id.
    files = list(_iter_extraction_files(index.extractions_root))
    if files:
        for jsonl_path in files:
            src = _resolve_source_for_jsonl(index, jsonl_path)
            if src is None or src not in sources:
                continue
            with jsonl_path.open("r", encoding="utf-8") as f:
                for i, line in enumerate(f, start=1):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        raw = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    attrs = raw.get("attributes") or {}
                    if attrs.get("clause_id") != clause_id:
                        continue
                    hit = _hit_from_jsonl(
                        raw, source=src, jsonl_path=jsonl_path, line_number=i,
                        repo_root=index.repo_root,
                    )
                    if hit:
                        return ToolEnvelope(
                            status="ok",
                            results=[ClauseLookup(
                                family=family, edition=edition, clause_id=clause_id,
                                confidence="extracted", extraction=hit,
                            )],
                        )

    # 2. Fall back to a heading regex over the source text.
    builder = _CLAUSE_HEADING_RE.get(family)
    if builder is not None:
        pattern = builder(clause_id)
        for src in sources:
            text = index.text(src.id)
            if not text:
                continue
            m = pattern.search(text)
            if not m:
                continue
            start, end = m.span()
            before, match_text, after = _slice_window(text, start, end, context_chars)
            text_hit = TextHit(
                source=src,
                match_text=match_text,
                char_interval=CharInterval(start=start, end=end),
                context_before=before,
                context_after=after,
                page_range=_page_range_at(index.page_index(src.id), start, end),
                line_number=text.count("\n", 0, start) + 1,
            )
            return ToolEnvelope(
                status="ok",
                results=[ClauseLookup(
                    family=family, edition=edition, clause_id=clause_id,
                    confidence="text-match", hit=text_hit,
                )],
            )

    return ToolEnvelope(
        status="ok",
        results=[ClauseLookup(
            family=family, edition=edition, clause_id=clause_id,
            confidence="not-found",
        )],
    )


# ── public dispatch table (used by mcp_server.py and tests) ───────────────

TOOLS: dict[str, Callable[..., ToolEnvelope]] = {
    "list_sources": list_sources,
    "get_source_text": get_source_text,
    "search_text": search_text,
    "page_window": page_window,
    "search_extractions": search_extractions,
    "get_extraction_by_id": get_extraction_by_id,
    "search_by_attributes": search_by_attributes,
    "get_clause": get_clause,
}


def envelope_to_dict(env: ToolEnvelope) -> dict[str, Any]:
    """Serialize a ``ToolEnvelope`` for MCP transport."""
    return to_jsonable(env)
