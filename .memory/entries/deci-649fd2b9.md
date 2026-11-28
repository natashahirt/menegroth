---
id: deci-649fd2b9
type: decision
project: menegroth
parent_id: plan-ad399e86
title: 'Vaults are unreinforced: mandatory middle-third kern check, ribbed vaults
  refused, limits flagged as judgment'
node_label: 'Vault: no-tension always'
tags: vault,unreinforced,kern,haile,thrust-line,engineering-judgment
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-78ed7ea6
created_at: '2026-11-09T17:13:10.698769+00:00'
updated_at: '2026-11-09T17:13:10.698769+00:00'
---
User decisions 2026-11-09.

- Kern check under half-span live load is always on: `check_asymmetric` removed from `VaultOptions`, `vault_load_cases`, `_find_min_thickness`, `optimize_vault`, `VaultNLPProblem`. Three-hinge statics: M = q_L L^2/64 at the quarter point, N = H cos(theta) + V sin(theta), tan(theta) = 2f/L, require e = M/N <= t cos(theta)/6. `kern_check` is `(e, limit, ratio, ok)`.
- Only `HaileAnalytical()` is accepted (`_require_vault_method`); ShellFEA fails closed.
- Ribbed vaults (rib_depth > 0 and rib_apex_rise > 0) throw `ArgumentError` (`_require_unribbed_kern`): the rectangular kern does not hold for a T section, and the rib weight is not uniform over the span, so the full-span load is not funicular.
- `solve_equilibrium_rise` only treats `Roots.ConvergenceFailed` / `DomainError` as non-convergence; other errors rethrow.
- `_find_min_thickness` bisects the 5 mm grid (all checks are monotone in t; the returned t has always passed) and honors `VaultOptions.thickness_bounds`.
- Defaults live in `vault_allowable_stress` (0.45 f'c) and `vault_rise_loss_limit` (span/240). Corpus search 2026-11-09 found no code source for either: 0.45 f'c is a project choice (ACI 318-11 Eq. 22-14 uses 0.45 f'c in a different method), span/240 is Haile's MATLAB reference choice. ACI 318-11 22.2.1(b) (page 382) permits plain concrete where arch action keeps compression under all loading, which the kern check enforces.

Tests updated, not yet run: `StructuralSizer/test/haile_vault/test_vault.jl`.
