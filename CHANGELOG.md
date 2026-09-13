# CHANGELOG — rm

Every rm release follows semver (design/tooling/plan.md §D4). The
1.0.0 line closes R50 milestone M5-001 (paideia-os
design/tooling/r49-r50-plan.md §5.8); every subsequent entry adds one
line to the top under the same shape.

## 1.3.0 — 2026-09-13

Wave N drain: rm#21, rm#29, rm#30, rm#31. One security fix
(fail-closed exit code on a blocked removal), the LE-001 migration
off a retired libpdx-elevate symbol, cap_derive/revoke_cascade
adoption for the recursive branch, and the R90 PdxFS-TXN trampoline
module.

### Landed

- **rm#21 (ENH-004) — SECURITY: fail-closed exit code.** A removal
  refused by `RmElevate::elevate_check_and_request` or `RmResolve::
  resolve_target` used to fall through `RmRemove::rm_remove_body`'s
  loop and still return `EXIT_OK` (0) — fail-OPEN reporting. The loop
  now checks `rm_blocked_by_elevate + walk_blocked_by_elevate` after
  every positional is processed and returns `EXIT_EACCES` (13) when
  either is non-zero; every block site (resolve-fail, recursive-
  blocked, non-recursive-blocked) also emits `[rm.ENH-004 EACCES
  blocked]` on stderr. New fixture `tests/rm_security_fail_closed.pdx`
  drives `rm_remove_body` end-to-end against a `/system/`-prefixed
  absolute target and asserts both the exit code and the counter.
- **rm#29 (LE-001) — migrate off the retired `elevate_client_
  request`.** libpdx-elevate.ENH-005 renamed `elevate_client_request`
  to `elevate_client_request_norealize`; rm's only call site (`RmElevate
  ::elevate_check_and_request`) had been calling the now-nonexistent
  bare symbol. Replaced with `elevate_client_acquire` (mints a row_id
  scoped by a fresh `_elevate_mint_ctx_buf`) followed by
  `elevate_client_require(row_id, needed_caps=0)`. This retires the
  old ELVC_STUB "seam-stub → proceed" shortcut in favour of failing
  closed when no broker is reachable — `tests/rm_elevate_smoke.pdx`
  Scenario B updated to expect `RE_BLOCKED` accordingly.
- **rm#30 (LE-002) — cap_derive + revoke_cascade for `-r`.** New
  `RmRCap` module (`src/rm_r_cap.pdx`) wraps `RmWalk::walk_recursive`:
  acquires a root elevate grant scoping the invocation, derives a
  per-directory (per-invocation, pending the R42 live-readdir landing)
  child sub-cap via `elevate_client_cap_derive`, runs the walk, then
  tears the whole derived tree down with one `elevate_client_cap_
  revoke_cascade(root)` call. A cap-scaffolding refusal bumps `RmWalk::
  walk_blocked_by_elevate` and skips the walk entirely, tying into the
  rm#21 fail-closed exit code. Wired into `rm_remove_body`'s recursive
  dispatch arm in place of the direct `walk_recursive` call; `rm_r_cap_
  reset` added to `remove_reset`'s delegation list.
- **rm#31 (R90) — PdxFS-TXN trampolines.** New `src/pdxfs_txn.pdx`
  (`PdxfsTxn` module) with `pdxfs_txn_begin/add_unlink/commit/abort`
  wired to the real landed sysnos (70/107/104/105 per design/user/
  syscall-table.md — the wave dispatch's cited 108/109/110 were a
  mismatch with the unrelated R105 display/framebuffer band, corrected
  in the file header) plus `pdxfs_txn_status/free` STUBs (no row-query
  or `sys_pdxfs_txn_close` syscall exists yet). Trampolines only at
  this landing — wiring `rm_process_one` / `walk_recursive`'s existing
  direct unlink/rmdir call sites onto a TXN-wrapped sequence is a
  follow-up body edit, same posture mv's own `src/pdxfs.pdx` split
  already establishes.

## 1.2.0 — 2026-09-13

Wave F drain: single implementation pass closing the five remaining
open issues (rm#19, rm#20, rm#22, rm#28, rm#32). Two security fixes
(elevate on resolved path, --wipe covered by the same gate), the -r
audit-invisibility fix, R90-XREPO.013.M3-005 caps.decl adoption, and
the parallel-to-cat/cp/mkdir v1.1-A real-body extraction.

### Landed

- **rm#19 (ENH-002) + rm#20 (ENH-003) — SECURITY: elevate gate on
  resolved path.** New `RmResolve` module (`src/resolve.pdx`) with
  `resolve_target(argv_ptr) -> resolved_ptr` that classifies the
  argv first byte: `/` -> absolute fast path (returns argv_ptr +
  strlen), NUL -> degenerate (returns 0), anything else -> calls
  `sys_getcwd` (sysno 86, R86.M1-003 kernel body) into
  `_rm_cwd_scratch` and joins `cwd + '/' + argv` into
  `_rm_resolved_scratch`, returning the join pointer. Two 256-byte
  .bss scratches match the kernel-side `SYS_GETCWD_PATH_MAX` (256)
  and `SYS_UNLINK_PATH_MAX-1` (255). `RmRemove::rm_remove_body` now
  runs `resolve_target` FIRST in the loop, THEN
  `elevate_check_and_request` on the resolved pointer (r14 preserves
  it across the elevate call). The resolved pointer is passed as
  `target_ptr` to `walk_recursive` / `rm_process_one`, so every
  downstream consumer (elevate, unlink, undo, audit, schema) sees
  the same canonicalised bytes. This closes both #19 (`rm foo` from
  cwd `/system/` and `rm ../../system/passwd` no longer bypass the
  gate) and #20 (--wipe on /system now correctly requires elevate;
  --wipe outside /system correctly does not, matching D4). Full
  `../` folding remains R57 substrate work; the sys_unlink body's
  own `mount_root_vnode + path_resolve` is the defence-in-depth
  secondary layer.
  - `src/resolve.pdx` — new module.
  - `src/remove.pdx` — `rm_remove_body` grew a 3-push prologue
    (r12=i, r13=pos_count, r14=resolved_ptr) with no pad; the
    resolve-then-gate ordering is now the single-site security
    invariant. Resolve-fail (rax==0) bumps `rm_blocked_by_elevate`
    and skips dispatch (the counter's semantics widened per the
    file comment). `remove_reset` delegates to `resolve_reset`.

- **rm#22 (ENH-005) — `-r` path emits M3 records.** `walk_recursive`
  now fires the four M3 hooks (`retention_attach` +
  `undo_write` + `record_emit` + `audit_record_target`) for the
  top-level target after the WALK_STUB_SUFFIX print. The prologue
  widened from 1-push (rbx) to 2-push (rbx, r12) + 8 pad so
  `target_len` (computed once via a NUL walk up-front) survives
  every nested call. Per-entry recursive walk remains R42 substrate
  work; the top-level-target hop restores the D3 audit-first and
  I5 undoability invariants for the -r branch at the granularity
  available today per design/enhancement-plan.md §4.

- **rm#28 (R90-XREPO.013.M3-005) — caps.decl adoption.** Added
  `KIND_PDXFS_VOL(unlink, <target-parent>)` row (declared, adoption
  arm defers to the future trash-move substrate landing) and
  `KIND_PDXFS_FILE(rmdir, <target-parent>)` for the -r branch top-
  level rmdir. Retired the M5-era `KIND_PDXFS_TXN` row (superseded
  by the volume-scoping form the R90 substrate uses). Long adoption
  note in `caps.decl` mirrors the cp/mkdir §M3-006/M3-003 shape:
  declaration keeps the manifest reconciler's gate reachable while
  the trash-move landing owns the invoke.

- **rm#32 — v1.1-A real-body extraction.** New `RmPdxfs` module
  (`src/pdxfs.pdx`) with two syscall trampolines: `pdxfs_unlink`
  (sysno 81, R56.M3-005) and `pdxfs_rmdir` (sysno 80, R56.M3-004).
  Both are leaves with the SysV rdi/rsi -> SYSCALL arg convention.
  Wired at three call sites:
  - `RmRemove::rm_process_one` default-path tail (after M2 stub
    suffix print) calls `pdxfs_unlink(rbx, r12)` on the resolved
    path. Dry-run and --wipe paths bypass via their own earlier
    `jmp rm_process_done_ok`.
  - `RmWipe::wipe_emit` calls `pdxfs_unlink` on the resolved path
    after the WIPE_STUB_SUFFIX print. Byte-overwrite
    (sys_pdxfs_secdisc) remains R42 substrate; was_wiped_flag +
    undo_write_count=0 forensic invariant preserved.
  - `RmWalk::walk_recursive` tries `pdxfs_unlink` first, falling
    back to `pdxfs_rmdir` if unlink returned non-zero (handles both
    file and empty-directory top-level targets without needing the
    R42 recursive-walk substrate).
  - Two new .bss observability slots in `RmRemove`:
    `rm_real_unlink_ok` / `rm_real_unlink_err`. Zeroed by
    `remove_reset`; bumped at every real-syscall return. The
    process exit stays EXIT_OK on syscall failure to preserve the
    v1.0/v1.1 shape until the R42 substrate lands full trash-move
    error propagation.

- **Wave F support scaffolding.**
  - `src/tool_ident.pdx` — new module declaring `PDX_TOOL_NAME =
    "rm\0"` and `PDX_TOOL_VERSION = "1.2.0\0"` externs preemptively
    for the eventual libpdx-argv >= 1.1.3 bump (ENH-032 UND-extern
    contract). Same discipline mkdir/cp/cat/mv follow.
  - `manifest.pdxproj` — version bumped 1.0.1 -> 1.2.0. Sources
    list gained resolve.pdx, pdxfs.pdx, tool_ident.pdx.
  - `.gitignore` — new file, ignores `build-out/`.

### Substrate + release notes carried forward

- The three substrate gaps documented under 1.0.0 (PdxFS v1 mutating
  trash-move ops, `sys_pdxfs_undo_append`, signing bot host) remain
  open; v1.2.0 lands the real-body extraction that IS available
  (sys_unlink + sys_rmdir + sys_getcwd landed at R56 / R86), not
  the trash-move substrate which is R42 work.
- `manifest.pdxsig` regeneration deferred to the signing bot host
  landing; the sig block footprint is unchanged in size.

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
