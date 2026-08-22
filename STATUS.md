# rm — status

**Wave:** R50 (Wave 2)
**Current milestone:** M4 (tests + smoke) — in progress

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

## M2 — core implementation (complete)

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

## M3 — audit + undo + elevate (complete)

- `src/schema.pdx` + `src/main.pdx` + `src/remove.pdx` extend
  (issue #8, M3-001): RemoveRecord@0.1 = 5 lanes (target_ptr,
  target_len, size=0-M3, was_dir=0-M3, trash_handle=0-M3). New
  `RmSchema::schema_bind_stdout` binds fd 1 at start-of-run;
  `RmSchema::record_emit` composes into `_record_scratch` +
  `Send::send_record`. `rm_process_one` hoists `target_len` NUL-walk
  into r12; emits records in --wipe and default branches (dry-run
  skips, by design). `remove_reset` delegates `schema_reset`.
- `src/audit.pdx` + `src/main.pdx` + `src/remove.pdx` extend
  (issue #9, M3-002): D3 audit-first envelope via three
  `AuditClient` calls. `audit_pre(op_args=0)` hoisted to top of
  `rm_main` so `audit_id_slot` survives `remove_reset`;
  `audit_record_target(target_ptr)` per successful removal
  (`output_schema=RemoveRecord@0.1`, `output_hash=target_ptr` M3
  stub); `audit_post(exit_code)` commits at epilogue with exit
  preserved via r12. Failure is observability-only at M3 (exit-3
  gate lands with M4 smoke harness).
- `src/undo.pdx` + `src/remove.pdx` extend (issue #10, M3-003):
  6-lane PdxFS v1 undo record ([UNDO_OP_RM, target_ptr, target_len,
  trash_handle, retention_deadline_ns, was_dir]) composed into
  `_undo_scratch`. `undo_write` runs AFTER `retention_attach` (so
  the snapshot is populated) and BEFORE `record_emit`. --wipe
  explicitly skips undo (no trash entry, no reversal — forensic-
  detection invariant §3.1). No syscall at M3; substrate transition
  edits the body to `sys_pdxfs_undo_append` at the same call site.
- `src/elevate.pdx` + `src/remove.pdx` + `src/walk.pdx` extend
  (issue #11, M3-004): 8-byte "/system/" prefix scan on target;
  on match dispatches `ElevateClient::elevate_client_request` with
  `_elevate_req_buf` + `_elevate_reply_buf`. ELVC_STUB (0xFFFFEA00,
  staged via `mov r10, imm64` per imm64 sweep) and ELVC_OK both
  proceed; any other rc blocks the removal (bumps
  `rm_blocked_by_elevate`, EXIT_OK preserved at M3). Runs FIRST in
  `rm_process_one` — no observable action if refused.
  `walk_blocked_by_elevate` counter added for the walk-branch
  top-level target (walk-per-entry hook lands with the substrate
  transition).

## M4 — tests + smoke (in progress)

- `tests/m4_001_txn_abort.pdx` (issue #12, M4-001): TXN-abort mid-
  remove: no files removed. Uses `--dry-run` as the substrate proxy
  for TXN-abort mid-remove -- both branches produce zero observable
  side effects on `RmRetention::retention_attach_count`,
  `RmUndo::undo_write_count`, `RmSchema::record_emit_count`, and
  `RmAudit::audit_records_out`. `removed_count == 1` because dry-run
  reaches `rm_process_done_ok`; the M5 substrate patch extends this
  test to verify a live abort keeps `removed_count == 0` too.
  Fingerprint: `[rm.M4-001 OK]` / `[rm.M4-001 FAIL]`. Also documents
  the reset-list gap in `RmRemove::remove_reset` (retention slots +
  walk slots not covered) and zeros them at test entry.
- `tests/m4_002_undo_in_window.pdx` (issue #13, M4-002): undo within
  retention window succeeds. Exercises the exact ordering discipline
  from `rm_process_one` (retention_attach BEFORE undo_write) and
  asserts the composition invariant a live undo replay depends on:
  `retention_deadline_ns == 0x4E94914F0000` (24h ns constant),
  `undo_write_count == 1`, `undo_write_bytes == 48`
  (UNDO_RECORD_BYTES), `undo_last_deadline_ns == 0x4E94914F0000`
  (snapshot matches). Uses r10 to stage the 24h imm64 for the compare
  (paideia-as r11 imm64 sweep pattern; r10 free because r11 holds the
  .bss lea base). Fingerprint: `[rm.M4-002 OK]` / `[rm.M4-002 FAIL]`.
- `tests/m4_003_undo_after_window.pdx` (issue #14, M4-003): undo
  after retention window returns ENOENT-with-diagnostic (not silent).
  Asserts the composition precondition the replay's diagnostic
  dispatch depends on: `_undo_scratch[32]` (retention lane in the
  6-lane undo record) is populated with a non-zero deadline AND
  equals both `RmRetention::retention_deadline_ns` and
  `RmUndo::undo_last_deadline_ns`. A zero lane would leave the replay
  unable to distinguish "expired" from "never written"; a mismatch
  would let the diagnostic name a wrong deadline. Uses reg-reg
  compares via r8 so no imm64 stage is needed for the 24h constant.
  Fingerprint: `[rm.M4-003 OK]` / `[rm.M4-003 FAIL]`.

## Milestone rollup

| ID           | Title                                                              | State  |
|--------------|--------------------------------------------------------------------|--------|
| M1-001 (#1)  | scaffold + caps.decl (target-parent write + TXN)                   | LANDED |
| M1-002 (#2)  | argv surface via libpdx-argv (rm [-r|-f|-v|--wipe|--dry-run])      | LANDED |
| M1-003 (#3)  | first runnable: single-file remove via trash-subtree move          | LANDED |
| M2-001 (#4)  | recursive -r leaf-first walk under single TXN (skeleton)           | LANDED |
| M2-002 (#5)  | -f force flag (skip per-file confirmation)                         | LANDED |
| M2-003 (#6)  | 24h retention deadline metadata on trash-subtree entry             | LANDED |
| M2-004 (#7)  | --wipe: immediate trash-entry unlink + best-effort byte overwrite  | LANDED |
| M3-001 (#8)  | RemoveRecord[] schema bind (path, size, was_dir, trash_handle)     | LANDED |
| M3-002 (#9)  | RemoveRecord via libpdx-audit before trash-move                    | LANDED |
| M3-003 (#10) | PdxFS v1 undo record (replay reconstructs from trash)              | LANDED |
| M3-004 (#11) | libpdx-elevate for /system/ + cross-subtree targets                | LANDED |
| M4-001 (#12) | TXN-abort mid-remove: no files removed                             | LANDED |
| M4-002 (#13) | undo within retention window succeeds                              | LANDED |
| M4-003 (#14) | undo after retention window: ENOENT-with-diagnostic                | LANDED |
| M4-004 (#15) | --wipe audit flag correctness (forensic-shred detection)           | TBD    |

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
