---
id: note-1e533bde
type: note
project: menegroth
parent_id: chec-b73d936d
title: ELF test comments now carry corpus id and PDF page
node_label: ELF citation comments
tags: asce-7-22,phase-6,seismic,note
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/test/loads/test_seismic_elf.jl@3ff70ed, StructuralSizer/test/loads/test_seismic_nehrp_examples.jl@3ff70ed,
  scripts/runners/check_nehrp_elf_oracles.jl@3ff70ed
session_id: sess-8c452688
created_at: '2026-10-25T19:32:06.322681+00:00'
updated_at: '2026-10-25T19:32:06.322681+00:00'
---
Added corpus source_id and PDF page to the new ELF hand-check and NEHRP example comments the critic flagged as P2. Eqs. 12.8-2 through 12.8-7 cite asce-7-22 PDF page 185, Eq. 12.8-14 and §12.8.3 cite PDF page 186, §12.8.6.1 and Eq. 12.8-16 cite PDF page 187, and C12.8.6.1 cites PDF page 731. No arithmetic change.
