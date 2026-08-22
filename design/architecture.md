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
