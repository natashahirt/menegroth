"""Shared result envelopes for the corpus MCP server.

Every tool result carries enough provenance fields for the agent to cite a
clause without paraphrasing or inventing references. Plain dataclasses are
used so we have zero non-stdlib dependencies for serialization.

Python compatibility: dataclasses here intentionally avoid ``slots=True``
(Python 3.10+) so the server runs unchanged on macOS's stock Python 3.9
``/usr/bin/python3``. PEP 604 union annotations (``str | None``) are safe
because every module in this package uses ``from __future__ import
annotations`` — annotations are stringified and never evaluated at runtime.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any


@dataclass(frozen=True)
class SourceRef:
    """Identity + provenance of a corpus source.

    Mirrors the per-entry shape of ``corpus/manifests/sources.yml`` plus the
    derived on-disk paths so tools can return self-contained references.
    """

    id: str
    family: str
    role: str
    edition: str
    tier: int
    source_path: str | None = None
    text_path: str | None = None
    encrypted: bool = False
    text_only: bool = False
    notes: str = ""


@dataclass(frozen=True)
class CharInterval:
    """Inclusive-start, exclusive-end character interval into a normalized .txt."""

    start: int
    end: int


@dataclass(frozen=True)
class PageRange:
    """Page-window into the original PDF, derived from converter markers."""

    start: int
    end: int


@dataclass(frozen=True)
class TextHit:
    """A single hit from ``corpus.search_text`` or ``corpus.get_source_text``.

    ``match_text`` is verbatim from the normalized ``.txt`` and is exactly the
    span identified by ``char_interval``. Per the workspace safety rule,
    callers should cite ``source.id`` plus the relevant clause from the
    nearby text — never paraphrase ``match_text``.
    """

    source: SourceRef
    match_text: str
    char_interval: CharInterval
    context_before: str = ""
    context_after: str = ""
    page_range: PageRange | None = None
    line_number: int | None = None


@dataclass(frozen=True)
class ExtractionHit:
    """A single LangExtract entry surfaced via the corpus MCP tools.

    Only entries that LangExtract actually grounded (``char_interval`` is
    non-null in the underlying JSONL) are returned by these tools. Anything
    that LangExtract emitted with ``char_interval == null`` is filtered out
    upstream so the agent never sees ungrounded extractions.
    """

    extraction_id: str
    extraction_class: str
    extraction_text: str
    attributes: dict[str, Any]
    source: SourceRef
    char_interval: CharInterval
    task: str
    jsonl_path: str
    line_number: int | None = None


@dataclass(frozen=True)
class ClauseLookup:
    """Result of ``corpus.get_clause``.

    ``confidence`` is one of:

    - ``"extracted"``  - found via a LangExtract entry whose ``attributes``
      include this clause id (preferred, highest confidence).
    - ``"text-match"`` - found by regex over the normalized ``.txt`` for the
      canonical clause heading (fallback).
    - ``"not-found"``  - clause not located; ``hit`` will be ``None``.
    """

    family: str
    edition: str
    clause_id: str
    confidence: str
    hit: TextHit | None = None
    extraction: ExtractionHit | None = None


@dataclass(frozen=True)
class ToolEnvelope:
    """Standard wrapper for tool responses.

    ``status`` is one of:

    - ``"ok"`` - results are valid.
    - ``"no_extractions_available"`` - extraction tools called before any
      LangExtract task has run; ``results`` is empty and ``hint`` describes
      how to populate the cache.
    - ``"error"`` - tool failed; ``message`` describes why.
    """

    status: str
    results: list[Any] = field(default_factory=list)
    message: str | None = None
    hint: str | None = None
    truncated: bool = False


def to_jsonable(obj: Any) -> Any:
    """Recursively turn dataclasses into JSON-friendly dict / list scalars."""
    if hasattr(obj, "__dataclass_fields__"):
        return {k: to_jsonable(v) for k, v in asdict(obj).items()}
    if isinstance(obj, dict):
        return {k: to_jsonable(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [to_jsonable(v) for v in obj]
    return obj
