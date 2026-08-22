# rm — status

**Wave:** R50 (Wave 2)
**Current milestone:** M2 (core implementation) — complete

See `design/tooling/r49-r50-plan.md` §5.8 in paideia-os for the full
breakdown.

## M1 — design + skeleton (complete)

- `caps.decl` + `manifest.pdxproj` (issue #1): scaffold + target-parent
  write cap + TXN cap.
- `src/flags.pdx` + `src/main.pdx` (issue #2): argv surface via
  libpdx-argv (`-r`, `-f`, `-v`, `--wipe`, `--dry-run`) + `RmFlags`
  first-byte-switch scanner.
- `src/remove.pdx` + `src/print.pdx` (issue #3): first-runnable body
  — single-file remove via trash-subtree move skeleton (returns
  `EXIT_OK` with a placeholder line naming the target).

## M2 — core implementation (in progress)

- `src/walk.pdx` + `src/remove.pdx` extend (issue #4, M2-001):
  recursive `-r` leaf-first walk under a single TXN. `rm_remove_body`
  iterates `ParsedArgs::pos_ptrs[0..pos_count]`; on `flag_r == 1`
  dispatches to `RmWalk::walk_recursive`, otherwise to the extracted
  `RmRemove::rm_process_one` (the M1-003 single-target body). Skeleton
  returns `EXIT_OK`; the mutating PdxFS ops land at the R42 substrate
  patch.
- `src/remove.pdx` extend (issue #5, M2-002): -f force flag. New leaf
  `confirm_check(target_ptr)` bumps `confirm_skips_by_f` (flag_f == 1)
  or `confirm_prompts_stub` (flag_f == 0) and emits F_SKIP_NOTE /
  PROMPT_STUB_NOTE under -v. Called from `rm_process_one` before the
  target-print. `remove_reset` zeros the new counters.
- `src/retention.pdx` + `src/remove.pdx` extend (issue #6, M2-003):
  24h retention deadline metadata. New `RmRetention::retention_attach`
  stages `RETENTION_24H_NS = 0x4E94914F0000` in r11 (imm64 sweep),
  stores into `retention_deadline_ns`, bumps `retention_attach_count`,
  emits RETENTION_NOTE under -v. Called from `rm_process_one`
  non-dry-run path before the M2 stub suffix; skipped by dry-run and
  by the walk branch (per-leaf hook lands with the substrate move).
- `src/wipe.pdx` + `src/remove.pdx` extend (issue #7, M2-004):
  --wipe shred + audit flag. New `RmWipe::wipe_emit(target_ptr)`
  sets `was_wiped_flag = 1` (M3-002 audit reads this), bumps
  `wipe_count`, emits four-part shred line ((rm: )?shred: <target>
  + WIPE_STUB_SUFFIX 67B). Short-circuits in `rm_process_one` when
  `flag_wipe == 1 && flag_dry_run == 0` — skips both retention and
  M2 stub suffix. `remove_reset` zeros both new slots.

## Milestone rollup

| ID          | Title                                                              | State  |
|-------------|--------------------------------------------------------------------|--------|
| M1-001 (#1) | scaffold + caps.decl (target-parent write + TXN)                   | LANDED |
| M1-002 (#2) | argv surface via libpdx-argv (rm [-r|-f|-v|--wipe|--dry-run])      | LANDED |
| M1-003 (#3) | first runnable: single-file remove via trash-subtree move          | LANDED |
| M2-001 (#4) | recursive -r leaf-first walk under single TXN (skeleton)           | LANDED |
| M2-002 (#5) | -f force flag (skip per-file confirmation)                         | LANDED |
| M2-003 (#6) | 24h retention deadline metadata on trash-subtree entry             | LANDED |
| M2-004 (#7) | --wipe: immediate trash-entry unlink + best-effort byte overwrite  | LANDED |

## Upstream substrate (paideia-os, at HEAD 2026-08-21)

- `KIND_USER = 0x190` — R48.M1 at `src/kernel/core/cap/kind_user.pdx`.
- `KIND_IPC_ENDPOINT = 5` — R20b at `src/kernel/core/cap/kind.pdx:72`.
- `KIND_PDXFS_FILE = 0x195` — R48b substrate-prep at
  `src/kernel/core/cap/kind_pdxfs_file.pdx` (QUERY-ONLY at HEAD).
- `KIND_PDXFS_TXN = 0x196` — R48b substrate-prep at
  `src/kernel/core/cap/kind_pdxfs_txn.pdx` (QUERY-ONLY at HEAD).
- Mutating PdxFS ops (`sys_pdxfs_txn_open`, `sys_pdxfs_move`,
  `sys_pdxfs_txn_commit`, `sys_pdxfs_readdir`): scheduled at R42
  substrate expansion; rm.M2 bodies are skeleton-with-stub-tail until
  they land.
