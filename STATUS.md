# rm — status

**Wave:** R50 (Wave 2)
**Current milestone:** M5 (signed 1.0.0 release) — complete
**Version:** 1.0.0 (author-signed; awaits paideia_root_pk re-sign
              once T-INFRA-001/002 stand up the signing bot host)

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
  `rm_blocked_by_elevate`, EXIT_OK preserved at M3). Ran FIRST in
  `rm_process_one` — no observable action if refused.
  `walk_blocked_by_elevate` counter was added at M3-004 but nothing
  wrote it: the `src/walk.pdx` extension landed only the counter
  declaration, not a call into `elevate_check_and_request` from the
  `-r` branch, so `rm -r /system/...` bypassed the gate entirely
  until the enhancement-v1.x pass closed issue #18 (see below).

## M4 — tests + smoke (complete)

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
- `tests/m4_004_wipe_forensic.pdx` (issue #15, M4-004): --wipe audit
  flag correctness (forensic reader can detect intentional shred).
  Invokes rm_process_one on a --wipe target and asserts BOTH
  forensic signals a reader uses to distinguish intentional shred
  from later reap: `RmWipe::was_wiped_flag == 1` (positive stamp on
  the RemoveRecord's was_wiped field) AND `RmUndo::undo_write_count
  == 0` (no undo record exists to reverse). Also asserts
  `retention_attach_count == 0` (wipe path skips retention) and
  `removed_count == 1`. Fingerprint: `[rm.M4-004 OK]` /
  `[rm.M4-004 FAIL]`.
- `tests/m4_runner.pdx` + `tests/expected-m4-fingerprints.txt`: the
  M4Runner aggregator dispatches all four tests in issue-number order
  (no first-failure short-circuit -- the full matrix is visible from
  one run), brackets the run with `[rm.M4-runner]` +
  `[rm.M4-runner done]` markers, and returns 0 iff every test
  returned 0. The fingerprint corpus lists the six lines the smoke
  driver expects on stdout when every test passes; the M5 substrate
  integration commit wires the runner as an entry symbol of an
  `rm-tests` build target so the corpus becomes runnable end-to-end.

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
| M4-004 (#15) | --wipe audit flag correctness (forensic-shred detection)           | LANDED |
| M5-001 (#16) | dual-signed release + .pdxdoc + remove_reset gap close             | LANDED |
| M5-002 (#17) | mirror push (.release/mirror.pdxmeta + procedure doc)              | LANDED |

## M5 — 1.0 signed release (complete)

- `src/remove.pdx` + `manifest.pdxproj` + `doc/rm.pdxdoc` +
  `CHANGELOG.md` + `manifest.pdxsig` (issue #16, M5-001): dual-signed
  1.0.0 release scaffold. `manifest.pdxproj` bumped to `version =
  1.0.0` with the four release-time directives (`pdxdoc`,
  `manifest_sig`, `changelog`, `mirror_meta`). `doc/rm.pdxdoc` is the
  `doc rm` back-end per I7 §2 (@name / @synopsis / @description /
  @options / @differences-from-posix / @exit-codes / @see /
  @examples / @ergonomics / @since). `CHANGELOG.md` opens the 1.0.0
  entry chronicling M1-M5 landings and enumerating the three
  substrate gaps that carry forward (PdxFS mutating ops,
  sys_pdxfs_undo_append, signing bot host). `manifest.pdxsig` reserves
  the full 6714-byte dual-sig footprint (author + paideia_root, both
  ML-DSA-65, 3309 bytes each; 32-byte BLAKE3 canonical-tuple hash;
  padded placeholders so the file size does not shift when the bot
  re-signs). `RmRemove::remove_reset` widened to also zero the four
  slots M4-001 flagged (RmRetention::retention_attach_count,
  RmRetention::retention_deadline_ns, RmWalk::walk_invocations,
  RmWalk::walk_blocked_by_elevate) — closes the umbrella-reset gap
  documented at tests/m4_001_txn_abort.pdx L57-64 and
  src/walk.pdx L98-105.
- `.release/mirror.pdxmeta` + `.release/README.md` (issue #17,
  M5-002): mirror-push metadata + procedure doc. `mirror.pdxmeta`
  encodes the pkg-push contract (name, version, author key label,
  target repo / staging / main paths, canonical tar layout,
  verification policy, runtime deps, post-install symlink layout).
  Canonical `tar_layout` order (`bin/rm`, `lib/`, `doc/rm.pdxdoc`,
  `caps.decl`, `manifest.pdxsig`, `CHANGELOG.md`) keeps the
  tarball hash reproducible from a fresh source tree at the tagged
  commit. `.release/README.md` documents the five-step release
  flow (tag → author-sign → push staging → bot re-sign → pkg
  upgrade) per design/tooling/plan.md §9.3 and names the substrate
  gap that keeps the release `author-signed-only` until
  T-INFRA-001/002 land. STATUS.md rolls up to LANDED for both M5
  issues; the git tag `v1.0.0` marks the release commit.

## Enhancement v1.x (in progress, 2026-08-25)

Findings from `design/enhancement-plan.md`; issues #18-#27 (milestone
"Enhancement v1.x — rm"). See that document for full analysis.

- `src/remove.pdx` + `src/walk.pdx` (issue #18, ENH-001, SECURITY):
  the `/system/` elevate gate is now a single call in
  `rm_remove_body`'s dispatch loop, before the `flag_r` branch, so it
  covers `walk_recursive` (`-r`) and `rm_process_one` identically.
  Previously the gate lived only inside `rm_process_one` and `-r`
  bypassed it entirely. `rm_blocked_by_elevate` / `walk_blocked_by_
  elevate` are now bumped from the shared call site.
- `src/remove.pdx` + `src/retention.pdx` (issue #23, ENH-006): fixed
  the verbose-output interleaving bug (`rm: report.txttrash
  retention: ...`). Under `-v`, the target line is now closed with a
  newline before `retention_attach` runs; `RETENTION_NOTE` carries its
  own `rm: ` prefix; `M2_STUB_SUFFIX` has a verbose variant that is
  its own complete line instead of continuing an already-closed one.
- `src/flags.pdx` (issue #26, ENH-008): `--recursive`, `--force`,
  `--verbose` now work as documented long aliases of `-r`/`-f`/`-v`.
- `doc/rm.pdxdoc` + `STATUS.md` (issue #27, ENH-009, this entry):
  corrected the `rm -rf /` exit-code claim (clustered short flags are
  rejected by libpdx-argv at exit 2, never reaching a cap-check), the
  exit-code table (3 = `EXIT_NOT_YET_IMPL`, reserved; 4 is a
  loader-side exec-time denial rm's own body never returns), and the
  M3-004 entry above.
- Not landed this pass: #19 (elevate gate matches unresolved argv
  bytes — blocked on a shared path-canonicalisation library and a
  loader-narrowing answer neither of which exist yet; see issue #19
  and enhancement-plan.md §11 items 1-2), #20, #21, #22, #24, #25.

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
