"""Corpus pipeline package.

Holds Python entrypoints for the building-code corpus pipeline:

- ``ingest`` : copy/normalize source documents into ``corpus/`` based on
  ``corpus/manifests/sources.yml``.
- ``extract`` : run LangExtract tasks against ``corpus/text/...`` and emit
  ``corpus/extractions/...`` JSONL plus ``corpus/review/...`` HTML.

Julia "one-command" wrappers live in ``scripts/runners/corpus_*.jl``.
"""
