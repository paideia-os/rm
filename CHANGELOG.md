# CHANGELOG — rm

Every rm release follows semver (design/tooling/plan.md §D4). The
1.0.0 line closes R50 milestone M5-001 (paideia-os
design/tooling/r49-r50-plan.md §5.8); every subsequent entry adds one
line to the top under the same shape.

## 1.0.1 — 2026-09-12

Patch release closing enhancement-v1.x issue #25 (`rm.ENH-007`). The
1.0.0 unknown-flag hole is closed: `rm --nonesuch x` now prints
`rm: unknown option: --nonesuch\n` on stderr and returns
`EXIT_USAGE` (2) instead of silently performing a non-recursive
removal on a typo'd `--recursive`.

### Landed

- **rm.ENH-007 (issue #25)** — unknown flags rejected with exit 2.
  - `src/flags.pdx` — `flags_scan` signature changed from `() -> ()`
    to `() -> u64`. Return value: 0 = every parsed flag recognised,
    non-zero = interior name-pointer (into the argv byte-page libpdx-
    argv NUL-terminated in place) of the first unknown flag. Every
    branch that previously fell to `flags_advance` on a NON-match
    (first-byte-switch fallthrough, and every partial-tail mismatch
    inside a long-form compare) now jumps to `flags_scan_unknown`
    which returns the name-pointer in rax. Branches that fall to
    `flags_advance` after a successful match are unchanged. A `'p'`
    arm was added to recognise `--pdx-schema` (well-known D3 flag
    libpdx-argv's parser inline-toggles `ParsedArgs::emit_schema`
    for; rm has no local state change but the name must not land in
    the unknown path).
  - `src/main.pdx` — after `call flags_scan`, `cmp rax, 0` gates the
    diagnostic. On non-zero, `r12` holds the name-pointer across a
    four-write emission sequence on fd 2: `rm: unknown option: ` +
    `-` or `--` (chosen by `strlen_nul` result: 1 → short, else long)
    + name + `\n`. Sets `rax = EXIT_USAGE` and jumps to the epilogue
    so `audit_post` still commits the envelope with exit=2. The
    reserved `[rsp+0]` pad slot spills the name length across the
    dash-emission print_err call.
  - `src/print.pdx` — new leaf `strlen_nul(ptr) -> len`. Same
    byte-loop shape as `mkfs.pdxfs`'s `format_record_strlen`; no
    push/pop parity, only caller-save touched, `xor rax,rax` +
    `mov_b rcx,[rdi]` per the #1248 byte-load mitigation.
  - `tests/m4_005_unknown_flag_reject.pdx` — three-scenario witness
    directly exercising the flags_scan return contract. (A) known
    short `-r`: rax==0, flag_r==1. (B) unknown long `--nonesuch`:
    rax==&NAME_NONESUCH, flag_r==0. (C) partial-tail typo
    `--recursve` (silently ignored pre-ENH-007): rax==&NAME_RECURSVE,
    flag_r==0. Reset between scenarios so cross-scenario leakage
    fails immediately. Emits `[rm.M4-005 OK]` / `[rm.M4-005 FAIL]`.
    Wired into `tests/m4_runner.pdx` (fifth call, unchanged shape)
    and `tests/expected-m4-fingerprints.txt`.
  - `design/argv-surface.md` — §5 exit-code table §5 amended: the
    unknown-flag path now joins the parse-error and zero-positional
    paths as an EXIT_USAGE producer.
  - `README.md` — §Options paragraph updated: the "silently
    fall-through" caveat that named issue #25 is replaced with the
    new ENH-007 reject-and-diagnose contract.
  - `STATUS.md` — ENH-007 added to the enhancement-v1.x landed list;
    the "Not landed this pass" line no longer names #25.

### Substrate + release notes carried forward

- The three substrate gaps documented under 1.0.0 (PdxFS v1 mutating
  ops, `sys_pdxfs_undo_append`, signing bot host) are unchanged; no
  transition happens with this patch.
- The `v1.1` gate from `design/enhancement-plan.md` §10 (needs #18,
  #19, #21 to close) still holds. 1.0.1 is a patch bump under that
  gate; the tag remains under 1.x.
- The `manifest.pdxsig` dual-sig footprint is unchanged in size, so
  the re-sign path when the signing bot host stands up (T-INFRA-001/
  002) requires no format changes.

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
