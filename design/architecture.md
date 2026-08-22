# rm — architecture

**Wave:** R50 (Wave 2)
**Repo:** github.com/paideia-os/rm
**Upstream design:** `design/tooling/r49-r50-plan.md` §5.8 in
[paideia-os](https://github.com/paideia-os/paideia-os).

This document describes the internal shape of rm. It does not repeat
the wave-level rationale from the paideia-os plan doc; read that first
for the D3 audit-first contract, the I5 undo invariant (every
destructive op ships a PdxFS-v1 undo record), and the KIND allocations
this tool consumes (none new — all four kinds pre-existed the M1
milestone).

## 1. Milestone position

M1 lands the frame: the argv surface, the flag scanner, the caps-
manifest, the paideia-as build manifest, and a first-runnable body
that walks the full chain end-to-end. It does **not** land any real
PdxFS transaction, any trash-subtree move, any undo-record write, any
audit-journal emission, any semantic-pipe record, or any elevate hop.

The M1 first-runnable shape is one command: `rm <path>` walks the
dispatch chain (argv → parse → flag scan → positional extract →
remove body → print → exit) end-to-end and produces a placeholder
line on stdout naming the target. Real trash-subtree move via TXN is
deferred to M2 because the R48-close substrate exposes KIND_PDXFS_
FILE with six query ops only (`PFF_OP_QUERY_INODE` … `PFF_OP_QUERY_
REFS` at `src/kernel/core/cap/kind_pdxfs_file.pdx` L94-99 in
paideia-os) — no `unlink`, no `rename`, no `move` — and KIND_PDXFS_
TXN with the same query-only surface (`PXT_OP_QUERY_ID` …
`PXT_OP_QUERY_MODE` at `src/kernel/core/cap/kind_pdxfs_txn.pdx`
L91-96). M2 either lands mutating ops on those two kinds or reaches
them through a userspace transaction service; the substrate choice is
a §5.8 M2 concern in the plan doc, not an M1 one. This mirrors the
pkg.M1 discipline for `pkg list` (see `design/architecture.md` in the
pkg repo).

The three M1 issues are #1 (scaffold + caps.decl + build manifest +
this doc), #2 (argv surface + flag scanner + libpdx-argv wire-up + the
argv-surface design doc), #3 (first-runnable body that recognises the
target, prints the placeholder, exits 0). The design docs for each
land alongside the code.

## 2. Public surface

M1 has one public entry point, exported by src/main.pdx:

```
pub let rm_main : (u64, u64) -> u64 !{mem, sysreg} @{}
```

`rm_main(argc, argv) -> exit_code`. The loader-supplied `_start` stub
reads argc/argv from the stack per the SysV/x86_64 convention and
calls `rm_main` with them; `rm_main`'s return value is the process
exit code passed to `sys_exit` (paideia-os syscall #60).

The rest of the public surface is the argv grammar described in
`design/argv-surface.md`.

The internal module layout is:

| Module     | File              | Responsibility                                     |
|------------|-------------------|----------------------------------------------------|
| `RmMain`   | `src/main.pdx`    | `rm_main` entry; parse + scan + dispatch           |
| `RmFlags`  | `src/flags.pdx`   | walk `ParsedArgs::flag_names` → boolean .bss slots |
| `RmRemove` | `src/remove.pdx`  | `rm_remove_body` (M1: placeholder; M2: real move)  |
| `Print`    | `src/print.pdx`   | `sys_write(fd=1/2)` helpers for stdout / stderr    |

The build manifest at `manifest.pdxproj` names every source file
paideia-as compiles into the binary and sets the entry symbol to
`RmMain::rm_main`. The caps manifest at `caps.decl` declares the M1
baseline cap set the loader's InitCap sidecar must seed for rm to run.

## 3. Storage model (M1)

Every M1 module keeps its scratch state in `.bss` — the singleton
pattern from `src/user/tokenizer.pdx` and `src/user/dispatch.pdx` in
paideia-os, and from every R49 tool at M1 (pkg / shell / doc). This
is deliberate for bootstrap:

- One `rm_main` call per process. Every rm invocation is one command;
  M1 does not need to build multiple flag contexts.
- Zero heap dependency. rm predates any userspace allocator in the
  R50 wave; every buffer is a static array.
- Trivial reset. `RmFlags::flags_reset` clears the five boolean
  slots; `RmRemove::remove_reset` clears the M2 loop counter slot;
  the print helper is stateless.

Every `.bss` slot is 8-byte-aligned via `@align(8)` per the paideia-as
v0.33 #1248 mitigation. The five flag slots are u64-typed even though
they only ever hold 0 or 1 — the extra width is free and it means the
flag scanner can `mov [slot], rax` without a narrow-store mnemonic.

## 4. Control-flow chain (M1)

```
loader _start
  → sys_read argc/argv from stack
  → call RmMain::rm_main(argc, argv)
      → ParsedArgs::reset                         (libpdx-argv)
      → Parser::parse_argv(argv, argc)            (libpdx-argv)
          ↳ non-zero rax → print PARSE_FAIL_MSG on stderr, return 2
      → RmFlags::flags_reset                      (this repo)
      → RmFlags::flags_scan                       (this repo)
      → check ParsedArgs::pos_count == 0
          ↳ true → print USAGE_MSG on stderr, return 2
      → load ParsedArgs::pos_ptrs[0] = target_ptr
      → RmRemove::rm_remove_body(target_ptr)     (this repo)
          ↳ M1: print placeholder, return 0
          ↳ M2: open TXN, trash-subtree move, commit, return 0
  → sys_exit(rax)
```

M1 accepts multiple positionals in the argv but the M1 body only
consumes `pos_ptrs[0]`. The M2 recursive-walk body reads
`pos_ptrs[1..pos_count]` from the same slots — the M1 code path never
overwrites them, so the M2 body is a body-edit inside
`rm_remove_body` rather than a rework of `rm_main`.

## 5. Cross-module externs consumed

From libpdx-argv:

| Symbol                    | Consumer                     |
|---------------------------|------------------------------|
| `ParsedArgs::reset`       | `RmMain::rm_main`            |
| `Parser::parse_argv`      | `RmMain::rm_main`            |
| `ParsedArgs::flag_names`  | `RmFlags::flags_scan`        |
| `ParsedArgs::flag_count`  | `RmFlags::flags_scan`        |
| `ParsedArgs::pos_ptrs`    | `RmMain::rm_main`            |
| `ParsedArgs::pos_count`   | `RmMain::rm_main`            |

From within the repo:

| Symbol                          | Consumers                     |
|---------------------------------|-------------------------------|
| `RmFlags::flags_reset`          | `RmMain::rm_main`             |
| `RmFlags::flags_scan`           | `RmMain::rm_main`             |
| `RmFlags::flag_r`               | `RmRemove::rm_remove_body`    |
| `RmFlags::flag_f`               | `RmRemove::rm_remove_body`    |
| `RmFlags::flag_v`               | `RmRemove::rm_remove_body`    |
| `RmFlags::flag_wipe`            | `RmRemove::rm_remove_body`    |
| `RmFlags::flag_dry_run`         | `RmRemove::rm_remove_body`    |
| `RmRemove::rm_remove_body`      | `RmMain::rm_main`             |
| `Print::print_str`              | `RmRemove::rm_remove_body`    |
| `Print::print_err`              | `RmMain::rm_main`             |

## 6. Substrate note (why M1 is a placeholder body)

The M1 first-runnable body cannot open a live PdxFS transaction and
trash-move the target because the kernel substrate at R48-close is
query-only on both `KIND_PDXFS_FILE` and `KIND_PDXFS_TXN`. Every op
constant on those two kinds is a `QUERY_*` (six on the file cap; six
on the txn cap; see the L94-99 / L91-96 references in §1). There is
no mutating op, no `sys_pdxfs_move`, no `sys_pdxfs_txn_open`.

Two M2 paths are on the table for how the trash-move actually lands:

1. **Kernel-side mutation ops on the two KINDs.** Add
   `PFF_OP_UNLINK`, `PFF_OP_RENAME`, `PXT_OP_OPEN`, `PXT_OP_COMMIT`,
   `PXT_OP_ABORT` to the two dispatch tables in the paideia-os
   kernel. This is the smallest patch and keeps the trust boundary at
   the kernel/user line. The R42 PdxFS v1 substrate promised these
   ops in its scheduled work; the plan doc §5.0 makes the same
   promise.

2. **Userspace transaction service reached through
   KIND_IPC_ENDPOINT.** A userspace TXN broker (an M2-scheduled
   service) receives OpenTxn / CommitTxn / RenameFile requests over
   a semantic-pipe endpoint and reflects them to the raw PdxFS
   substrate. This defers the kernel patch but adds an IPC hop per
   filesystem op.

The plan-doc §5.8 M2 line does not commit to either; the choice is a
Round 2 outcome. rm.M1's shape does not prejudge it — `RmRemove::rm_
remove_body` will call into whichever substrate M2 lands, and the
argv → parse → scan → dispatch chain above stays put in either
choice.

## 7. Deferred capabilities and where they land

| Capability                      | Milestone | Rationale                                              |
|---------------------------------|-----------|--------------------------------------------------------|
| Recursive `-r` leaf-first walk  | M2-001    | Requires the mutating TXN substrate to exist          |
| `-f` force (skip confirm)       | M2-002    | M1 has no per-file confirmation to skip yet            |
| 24-hour retention metadata      | M2-003    | Requires trash-subtree entries to be creatable         |
| `--wipe` shred                  | M2-004    | Requires immediate-unlink + byte-overwrite ops         |
| `RemoveRecord[]` schema         | M3-001    | Requires libpdx-semantic-pipe.M2                       |
| `RemoveRecord` audit send       | M3-002    | Requires libpdx-audit.M2                               |
| PdxFS v1 undo record            | M3-003    | Requires PdxFS v1 undo-log substrate                   |
| `libpdx-elevate` for /system/   | M3-004    | Requires libpdx-elevate.M3 + kernel elevate broker     |
| Dual-signed release + .pdxdoc   | M5-001    | Requires pkg.M4                                        |

Each row above is a body edit inside an existing M1 module (or a new
module alongside them); none of them changes the caps.decl, the
manifest.pdxproj entry point, or the `RmMain::rm_main` signature.
This is the load-bearing intent behind M1's shape: every subsequent
milestone is a diff inside `RmRemove` or a new dependency, not a
scaffolding change.

## 8. M2 shape

M2 lands the core-behaviour scope of §5.8 M2-001 through M2-004 in
the plan doc: recursive `-r` walk, `-f` force flag (skip
confirmation), 24h retention metadata on the trash-subtree entry, and
`--wipe` immediate-unlink + best-effort byte-overwrite. Every M2
milestone is a body edit inside `RmRemove::rm_process_one` (the M1
single-target body, now extracted so the M2 iteration can dispatch
to it per positional) or a new module the dispatch reaches from
`RmRemove`. No M2 milestone edits `RmMain::rm_main`, changes the
`caps.decl`, or introduces a new KIND.

The M2 substrate note (from §6 above, restated): the mutating PdxFS
ops (`sys_pdxfs_txn_open`, `sys_pdxfs_readdir`, `sys_pdxfs_move`,
`sys_pdxfs_txn_commit`) are not in-tree at HEAD. Every M2 body ships
the shape of the future syscall dispatch without inventing an outcome
the substrate did not produce — the same discipline the mv.M1-003
skeleton and the cp.M1-003 skeleton observe. When the substrate
lands (R42-PREP-004 in the plan doc), the M2 stub tails become live
syscall dispatches; no rm.M2 signature or caps.decl edit is needed.

### 8.1 M2-001 recursive `-r` leaf-first walk (issue #4)

`RmRemove::rm_remove_body` now iterates `ParsedArgs::pos_ptrs[0..
pos_count]` and dispatches per-target on `flag_r`:

- `flag_r == 0` → `RmRemove::rm_process_one(target)` (the extracted
  M1-003 single-target body).
- `flag_r == 1` → `RmWalk::walk_recursive(target)` (new module
  `src/walk.pdx`).

The rm_remove_body prologue is 2-push (r12=i, r13=pos_count) + `sub
rsp, 8` = 24 bytes; entry rsp % 16 == 8, post-prologue rsp % 16 == 0
for every nested call. The M1-era `target_ptr` argument RmMain still
passes in rdi is now ignored — RmMain is unchanged (per §7's "no
rework of rm_main" invariant), so rdi carries `pos_ptrs[0]` on entry
which the M2 body reads back out of ParsedArgs anyway. This is a
deliberate signature-freeze: the M1 → M2 transition is a body edit.

`RmWalk::walk_recursive` is the M2 skeleton for the full-ripeness
walk sequence (open one TXN → leaf-first tree walk → per-node move
into `/system/pdxfs/trash/<uid>/<original-parent>/<name>` → single
commit). At M2 it:

- bumps `RmWalk::walk_invocations` so the smoke matrix can distinguish
  a dispatched -r invocation from a bare fall-through;
- emits a per-target four-part line: `(rm: )?recursive walk of:
  <target>(\n | : (M2 stub -- real walk lands with PdxFS mutating
  ops)\n)` (the newline branch is taken under `--dry-run`, the stub
  branch otherwise);
- returns `EXIT_OK` unconditionally.

The register plan matches `RmRemove::rm_process_one`: 1-push (rbx)
preserves target across the four `Print::print_str` calls, rdx is
the NUL-walk cursor. This shape survives the substrate landing —
the M2 stub tail becomes the syscall sequence in a body edit; the
prologue, epilogue, and dispatch remain identical.

**Walk-stack sizing note.** The full walk needs an explicit walk
stack (recursion via CALL is not safe against a symlink-loop attack
even inside a TXN). At M2 no such stack exists — the skeleton emits
one line per top-level positional and terminates. The stack will
land alongside the substrate ops as a bounded `.bss` array; the size
bound (initial target: 4096 entries × 24 bytes = 96 KiB) is a §8.1
addendum for the substrate-landing patch, not an M2 concern.

### 8.2 M2-002 `-f` force flag (issue #5)

`RmRemove::confirm_check(target_ptr)` is a new leaf that
`rm_process_one` calls immediately after preserving `target_ptr` in
rbx. It reads `RmFlags::flag_f` and bumps exactly one of two counters
per call:

- `flag_f == 1` → `confirm_skips_by_f` (the user granted the skip)
- `flag_f == 0` → `confirm_prompts_stub` (the future prompt path)

When `flag_v == 1` the branch additionally emits a one-line note via
`Print::print_str` — `F_SKIP_NOTE` ("-f: skipping confirmation\n",
26 bytes) or `PROMPT_STUB_NOTE` ("would prompt for confirmation (M2
stub)\n", 40 bytes). Without -v the counters bump silently.

M2 has no interactive prompt because rm has no stdin binding — that
lands with the shell.M3 stdin-plumbing work. `confirm_check` at M2
therefore always allows the caller to proceed; its signature is
`(u64) -> ()` at M2 and becomes `(u64) -> u64` (0 = proceed, 1 =
abort) at M3 when the real prompt lands. The M2 → M3 upgrade is a
body edit inside `confirm_check` + one branch in `rm_process_one`;
no other module needs touching.

The recursive walk branch (M2-001 `RmWalk::walk_recursive`) does
NOT call `confirm_check` — `-r`'s POSIX-canonical semantic is "one
implicit confirm for the whole subtree, granted by the presence of
`-r` itself". This is called out in `design/argv-surface.md` §3.1
under the -r entry.

`RmRemove::remove_reset` now zeros the two new counters alongside
`removed_count`; the counter-only observability at M2 is what the
M4 smoke matrix reads back.

### 8.3 M2-003 24h retention deadline metadata (issue #6)

`RmRetention::retention_attach(target_ptr)` (new module
`src/retention.pdx`) is called from `rm_process_one` in the
non-dry-run branch, immediately before the `M2_STUB_SUFFIX` print.
The helper:

1. bumps `retention_attach_count`;
2. stages `RETENTION_24H_NS = 0x4E94914F0000` (86_400_000_000_000)
   into r11 via `mov r11, imm64` (the paideia-as r11 imm64 sweep
   discipline — the value exceeds imm32's 0x7FFFFFFF window), then
   stores it into `retention_deadline_ns`;
3. under `flag_v == 1`, emits a 31-byte "trash retention: 24h (M2
   stub)\n" note.

At M2 `retention_deadline_ns` is the raw 24h ns constant; the M3
upgrade to `sys_now_ns() + RETENTION_24H_NS` (absolute timestamp)
is a body edit inside `retention_attach` that neither changes the
signature nor the caller — `rm_process_one` continues to call it
with the same `(target_ptr) -> ()` shape.

The dry-run branch does NOT call `retention_attach`: no trash entry
is (or will be) created under `--dry-run`, so no retention applies.
The recursive walk branch (M2-001 `RmWalk::walk_recursive`) does
NOT call `retention_attach` at M2 either — a substrate-live walk
would call it per-leaf inside the walk loop, but the M2 walk emits
only one line per top-level target and there is no per-entry hook
to attach the retention onto. The M2 → substrate transition adds
the hook alongside the readdir + move dispatch; no signature edits
needed.

M4-003 test invariant ("undo after retention window returns
ENOENT-with-diagnostic, not silent") reads back `retention_
deadline_ns` to verify the expected 24h window.

### 8.4 M2-004 `--wipe` shred + audit flag (issue #7)

`RmWipe::wipe_emit(target_ptr)` (new module `src/wipe.pdx`) is the
--wipe short-circuit inside `rm_process_one`. When
`flag_dry_run == 0 && flag_wipe == 1`, `rm_process_one` bypasses
Parts 1–4 entirely and dispatches to `wipe_emit`. The helper:

1. sets `RmWipe::was_wiped_flag = 1` (the M3-002 audit hook stamps
   this onto the `RemoveRecord`'s `was_wiped` boolean field so a
   forensic reader can distinguish intentional shred from a later
   retention-window reap);
2. bumps `RmWipe::wipe_count`;
3. emits the four-part line: `(rm: )?shred: <target>: (M2 stub --
   immediate trash-unlink + best-effort byte overwrite)\n`.

Priority order (design/argv-surface.md §3.2):

- `--dry-run` beats `--wipe`: dry-run always emits `would remove:
  <target>\n` and takes no real-side-effect path. Even in dry-run
  the `confirm_check` bump still records the intent.
- `--wipe` (without `--dry-run`) beats the default retention path:
  a shred creates no trash entry, so `retention_attach` is not
  called and no `RETENTION_NOTE` is emitted.
- Under `-r` at post-M2 substrate landing, the recursive walk
  threads wipe per-leaf. At M2 the walk branch does not
  short-circuit on wipe — the walk skeleton emits one line per
  top-level target regardless — and the wipe-in-walk composition
  lands with the substrate transition.

`confirm_check` runs BEFORE the wipe dispatch: under `-f --wipe`,
`confirm_skips_by_f` bumps; without `-f`, `confirm_prompts_stub`
bumps (M3-004 will require an elevate hop for --wipe under any
target, not just `/system/`).

`RmRemove::remove_reset` now zeros `was_wiped_flag` and `wipe_count`
alongside the earlier counters. The M4-004 test invariant ("--wipe
audit flag correctness: forensic reader can detect intentional
shred") reads back `was_wiped_flag` after a `--wipe` invocation and
asserts it is 1.

## 9. M4 test corpus

M4 lands four `tests/m4_XXX_*.pdx` modules -- one per issue on the
paideia-os plan doc §5.8 M4-00X line -- plus a `M4Runner` aggregator
and an expected-fingerprint corpus the smoke driver matches on.

### 9.1 What the tests exercise (given the substrate gap)

The PdxFS v1 mutating ops (`sys_pdxfs_txn_open`, `sys_pdxfs_move`,
`sys_pdxfs_txn_abort`, `sys_pdxfs_txn_commit`, `sys_pdxfs_readdir`)
scheduled at R42-PREP-004 are not in-tree at HEAD (STATUS.md §Upstream
substrate). The M2/M3 milestones therefore expose their invariants via
observability counters (`.bss` slots) rather than filesystem outcomes;
the M4 tests read those counters back and assert the deltas the live
substrate would produce.

Each test uses the closest structurally-equivalent path a live
substrate would touch and asserts the exact same observability shape
that path would leave:

| M4 test | Substrate proxy at HEAD                                                                | What the M5 substrate patch adds                                              |
|---------|----------------------------------------------------------------------------------------|-------------------------------------------------------------------------------|
| M4-001  | `--dry-run` branch of `rm_process_one` (dry-run and TXN-abort both leave M3 counters 0)| Real `sys_pdxfs_txn_abort` mid-remove; verify `removed_count == 0` too       |
| M4-002  | Composition assertion: undo record snapshots the retention deadline                    | Live undo-log append + within-window replay verify                            |
| M4-003  | Composition precondition: `_undo_scratch[32]` is non-zero and matches                  | Clock fast-forward past deadline + replay returns ENOENT-with-diagnostic     |
| M4-004  | `rm_process_one` --wipe dispatch: forensic flag + no undo record                       | Real `sys_pdxfs_secdisc` outcome: byte range on device is zeroed              |

The M4 tests document each substrate proxy inline in the module
header and name the specific body edit an M5 substrate patch will
apply to promote the test from proxy to live.

### 9.2 Runner + fingerprint corpus

`M4Runner::m4_run_all` (in `tests/m4_runner.pdx`) invokes each
`M4Test0XX::run_m4_00X` in issue order, ORs their return codes into
an accumulator, and returns 0 iff every test passed. It brackets the
run with `[rm.M4-runner]` and `[rm.M4-runner done]` markers so a
smoke driver can bracket the capture window and detect a crash-in-
progress (absent `[done]` line ⇒ at least one test crashed the
runner). No first-failure short-circuit -- every test runs so a
maintainer sees the full failure matrix from one execution.

`tests/expected-m4-fingerprints.txt` lists the six substring lines
the paideia-os smoke driver (`tools/run-smoke.sh`) matches on when
every test passes. The corpus follows the same grep-substring
in-order convention as `tools/hw-smoke-fingerprints.md` §0.

### 9.3 Reset-list gap surfaced by the corpus

`RmRemove::remove_reset` at M3 zeros the M1/M2 counters and delegates
to the four M3 module resets (`RmSchema::schema_reset`,
`RmAudit::audit_reset`, `RmUndo::undo_reset`,
`RmElevate::elevate_reset`) but does NOT cover
`RmRetention::retention_attach_count`,
`RmRetention::retention_deadline_ns`, or the two `RmWalk` slots
(`walk.pdx` L99-105 documents the gap). Every M4 test explicitly
zeros the RmRetention slots it depends on before invoking any rm
helper. The M5 substrate commit that lands per-entry walk hooks also
expands `remove_reset` to cover the gap; the M4 tests keep their
explicit resets even after the widening so they stay self-contained.

### 9.4 Build integration

The tests are source-only at M4 -- `manifest.pdxproj` continues to
build the shipped `build-out/rm` binary from `src/*.pdx` alone.
Adding `tests/*.pdx` to the shipped surface would change the tool's
exported symbol set, which is a signature-level change out of scope
for M4. The M5 substrate-integration commit lands a separate
`rm-tests` build target that reuses every `src/*.pdx` module and
adds the four test modules plus the runner, with
`M4Runner::m4_run_all` as its entry symbol. Until then the tests are
read for correctness against the M2/M3 body shapes; the smoke driver
stubs live in the paideia-os smoke matrix at `tools/run-smoke.sh`
and are wired at rm.M5.
