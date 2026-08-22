# CHANGELOG — rm

Every rm release follows semver (design/tooling/plan.md §D4). The
1.0.0 line closes R50 milestone M5-001 (paideia-os
design/tooling/r49-r50-plan.md §5.8); every subsequent entry adds one
line to the top under the same shape.

## 1.0.0 — 2026-08-22

**Signed release** (dual-signed manifest per D1.a, ML-DSA-65 by both
`author_pk` (paideia-os-team) and `paideia_root_pk` (R32 root); the
signing bot host stood up under T-INFRA-001/002 re-signs the tarball
into `pkgs.paideia-os/main/rm/1.0.0/`).

### Landed

- **M1 — design + skeleton** (#1, #2, #3): scaffold + caps.decl
  (KIND_USER, KIND_PDXFS_FILE(write,<target-parent>), KIND_PDXFS_TXN,
  KIND_IPC_ENDPOINT); argv surface via libpdx-argv
  (`rm [-r|-f|-v|--wipe|--dry-run]`); first runnable
  (single-file remove via trash-subtree move under a TXN skeleton).
- **M2 — core implementation** (#4, #5, #6, #7): recursive `-r`
  leaf-first walk under a single TXN; `-f` force flag; 24h retention
  deadline metadata on trash-subtree entry (24h ns = 0x4E94914F0000
  staged via r11 imm64 sweep); `--wipe` forensic shred flag
  (short-circuits retention + undo; stamps was_wiped=1).
- **M3 — semantic-pipe + audit + elevate** (#8, #9, #10, #11):
  RemoveRecord@0.1 schema bind (5 lanes: target_ptr, target_len,
  size, was_dir, trash_handle); libpdx-audit envelope
  (audit_pre → audit_record_target → audit_post); PdxFS v1 undo
  record composition (6-lane [UNDO_OP_RM, target_ptr, target_len,
  trash_handle, retention_deadline_ns, was_dir]); libpdx-elevate for
  `/system/` + cross-subtree targets (RE_PROCEED / RE_BLOCKED gate
  runs first in `rm_process_one`; refusal skips every observable
  action, bumps `rm_blocked_by_elevate`).
- **M4 — tests + smoke** (#12, #13, #14, #15): TXN-abort mid-remove
  (M4Test001, dry-run substrate proxy); undo within retention window
  (M4Test002, verifies retention_deadline_ns snapshot into undo
  record); undo after retention window (M4Test003, verifies the
  6-lane undo record's retention lane populated for the diagnostic
  reader); --wipe forensic flag correctness (M4Test004, was_wiped=1
  AND undo_write_count=0 AND retention_attach_count=0). M4Runner
  aggregator dispatches all four in issue-number order; corpus in
  `tests/expected-m4-fingerprints.txt`.
- **M5 — signed release** (#16, #17): dual-signed manifest.pdxsig;
  doc/rm.pdxdoc (`doc rm` back-end); CHANGELOG.md entry; mirror-push
  metadata (`.release/mirror.pdxmeta`) for pkgs.paideia-os staging;
  `remove_reset` widened to zero the four RmRetention + RmWalk slots
  the M4-001 test flagged as an umbrella-reset gap.

### Substrate gaps documented (not yet closed)

These are R42+ substrate work; the rm 1.0.0 bodies emit the shape of
the future syscall dispatch without inventing an outcome, so the
transition is a per-body edit with no signature churn:

- **PdxFS v1 mutating ops** — `sys_pdxfs_txn_open`,
  `sys_pdxfs_move`, `sys_pdxfs_txn_commit`, `sys_pdxfs_readdir`
  land at R42 substrate expansion; rm.M2 bodies are
  skeleton-with-stub-tail until they land. STATUS.md §Upstream
  substrate names the current query-only op set.
- **PdxFS v1 undo append** — `sys_pdxfs_undo_append` at the
  RmUndo::undo_write call site. Composition is complete at M3-003;
  the transition edits one call site.
- **Signing bot host** — T-INFRA-001/002 (design/tooling/plan.md
  §11) stand up the pkgs.paideia-os machine holding
  `paideia_root_pk`. rm 1.0.0 ships manifest.pdxsig with the author
  signature only until the bot re-signs the tarball; the sig block
  is padded to the full dual-sig footprint so the file size is
  stable across the re-sign.

### Fingerprint corpus additions

`tests/expected-m4-fingerprints.txt` (from M4) is authoritative for
the rm 1.0.0 smoke matrix; no new fingerprint lines added at M5.
