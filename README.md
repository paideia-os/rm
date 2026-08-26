# rm

paideia-os remove with undo record + destructive-op audit + elevate for system paths.

## Synopsis

```
rm [-r] [-f] [-v] [--wipe] [--dry-run] <path> [<path> ...]
```

Flags follow the D3 grammar enforced by `libpdx-argv`: long flags are
long-only, short flags are one-per-hyphen. Clustering is a parse error —
`rm -rf x` is rejected as `ERR_CLUSTERED_SHORT` and rm exits 2. Write
`rm -r -f x`.

## Description

`rm` unlinks one or more filesystem entries. Unlike POSIX `rm`, a Paideia
removal is *journaled before it is destructive*: each target is moved into
the per-user trash subtree inside a single PdxFS v1 transaction, tagged with
a 24-hour retention deadline, and described by a 6-lane undo record, so
`undo` can put it back for as long as the deadline holds. Every target also
produces a `RemoveRecord@0.1` on the semantic-pipe stream and an entry in the
destructive-op audit envelope opened by `libpdx-audit` before any user-visible
output. `--wipe` is the one path that deliberately forgoes all of that.

**Elevation.** Before any observable action on a target,
`RmElevate::elevate_check_and_request` (`src/elevate.pdx:178`) compares the
first eight bytes of the target path against the literal `"/system/"`
(`SYSTEM_PREFIX`, `src/elevate.pdx:74`). The match is an exact 8-byte prefix
compare, and the trailing `/` is significant: `/system/audit/x` triggers,
`/systemic-notes` does not, and a target shorter than eight bytes never
matches. On a match rm calls
`ElevateClient::elevate_client_request(caps=0, dur=0, req_buf, reply_buf)`.
`ELVC_OK` (0) and `ELVC_STUB` (`0xFFFFEA00`) mean proceed; **any other return
code blocks the removal outright** — no confirmation hop, no print, no
retention, no undo record, no schema emit, no audit record. The refusal is
visible in the `rm_blocked_by_elevate` counter (`src/remove.pdx:99`). Note
that `/bin`, `/etc`, and every other path outside `/system/` take no elevate
hop at this release, and the "cross-subtree" half of the elevate contract is
not implemented — only the `/system/` prefix detector is in-tree.

**Where the substrate stops.** rm 1.0.0 is a complete, signed, audited
front-end sitting on a filesystem that cannot yet mutate. The PdxFS v1
mutating ops (`sys_pdxfs_txn_open`, `sys_pdxfs_move`, `sys_pdxfs_txn_commit`,
`sys_pdxfs_readdir`) and `sys_pdxfs_undo_append` are not in-tree; `KIND_PDXFS_FILE`
and `KIND_PDXFS_TXN` are query-only at paideia-os HEAD. Every body therefore
emits the exact shape of the future call — composes the record, bumps the
counters, prints a line naming the missing op — without inventing an outcome
it did not observe. Concretely: **no file is presently removed**, and stdout
carries `(M2 stub -- ...)` suffixes saying so. The audit, schema, undo, and
elevate wiring above is real and runs on every invocation; only the final
syscall is pending. See `CHANGELOG.md` § "Substrate gaps documented".

**Dispatch priority** inside `rm_process_one` (`src/remove.pdx:425`) is fixed:
elevate check → confirmation hop → `--dry-run` beats `--wipe` beats the
default retention path.

## Options

| Short | Long | Argument | Default | Description |
|-------|------|----------|---------|-------------|
| `-r` | `--recursive` | none (boolean) | off | Recursive descent. `rm_remove_body` dispatches the target to `RmWalk::walk_recursive` instead of `rm_process_one`. The real leaf-first walk under one TXN lands with the PdxFS mutating ops; at this release the branch prints `recursive walk of: <target>` and bumps `walk_invocations`. The `/system/` elevate check runs once per target in `rm_remove_body`, before dispatch, so it gates the `-r` branch identically to the non-recursive one (fixed by issue #18; previously the recursive branch bypassed it entirely). |
| `-f` | `--force` | none (boolean) | off | Force. rm has no stdin binding at 1.0.0, so there is no confirmation prompt to skip and **both settings proceed with the removal**. `confirm_check` (`src/remove.pdx:246`) bumps `confirm_skips_by_f` when set and `confirm_prompts_stub` when unset; under `-v` it prints `-f: skipping confirmation` or `would prompt for confirmation (M2 stub)` respectively. The interactive prompt arrives with the shell's stdin plumbing. |
| `-v` | `--verbose` | none (boolean) | off | Verbose. Prepends `rm: ` to each target line and emits every decision the removal took: confirmation note, `rm: trash retention: 24h (M2 stub)`, shred line — each as its own complete, self-prefixed line (fixed by issue #23; previously the retention note fused into the unterminated target line). |
| — | `--wipe` | none (boolean) | off | Forensic shred. Skips the trash-subtree journal, skips retention, and **skips the undo record entirely** — a `--wipe` removal is by design irreversible. Sets `RmWipe::was_wiped_flag = 1` and bumps `wipe_count`; still emits its `RemoveRecord` and its audit record. Loses to `--dry-run`. |
| — | `--dry-run` | none (boolean) | off | Print what would happen and return 0. Zero side effects on the filesystem, the audit output stream, the schema stream, and the undo log — the dry-run branch takes **none** of the four M3 hooks. `--dry-run` outranks `--wipe`, so `rm --wipe --dry-run x` prints the ordinary `would remove:` line and emits no shred stub. |

`--recursive`, `--force`, and `--verbose` are recognised as long aliases of
`-r`, `-f`, `-v` respectively (issue #26; doc/rm.pdxdoc has documented all
three since 1.0.0, but the source did not implement them until this fix).
`RmFlags::flags_scan` (`src/flags.pdx`) still switches on first byte
(`r`/`f`/`v`/`w`/`d`) and now nests a second-byte check per branch: a NUL
right after the first byte is the short form, otherwise the remaining bytes
are matched against the long form's tail. An unrecognised flag (including a
long-form tail that doesn't match) still falls through **silently** rather
than failing with a usage error — that rejection contract remains open
(issue #25).

## Exit codes

rm has no `exit_map.pdx`; the codes below are the constants declared in
`src/main.pdx:60-62` and `src/remove.pdx:64-67`, with the reserved range from
`doc/rm.pdxdoc`.

| Code | Name | Emitted when |
|------|------|--------------|
| 0 | `EXIT_OK` | Every target processed. Also returned when an elevate refusal blocked a removal — the exit-1 gate lands with the smoke harness that guarantees a live broker. |
| 1 | `EXIT_OP_FAIL` | At least one target failed against the substrate. Declared; not reachable until the mutating PdxFS ops land. |
| 2 | `EXIT_USAGE` | `libpdx-argv` reported a parse error (including clustered shorts), or zero positionals were supplied. Prints `rm: argv parse error (run 'rm --help')` or `usage: rm [-r\|-f\|-v\|--wipe\|--dry-run] <path>` on stderr. |
| 3 | `EXIT_NOT_YET_IMPL` | Declared in `src/remove.pdx:67`; reserved by `doc/rm.pdxdoc` for system error (I/O, kernel refused, TXN aborted). Not currently emitted. |
| 4 | — | Reserved by `doc/rm.pdxdoc` for capability denied (target-parent write cap missing). Not emitted by rm at run time. |
| 5 | — | Reserved by `doc/rm.pdxdoc` for signature verification failure — raised by `pkg` during install, never by rm. |

Only 0 and 2 are reachable in the 1.0.0 binary.

## Capabilities

Declared cap footprint, verbatim from `caps.decl`:

```
requires:
  - KIND_USER
  - KIND_PDXFS_FILE(write, <target-parent>)
  - KIND_PDXFS_TXN
  - KIND_IPC_ENDPOINT

declares_output_schemas:
  - RemoveRecord@0.1
```

The loader narrows the ambient `KIND_PDXFS_FILE` cap to the *parent directory of
the target* via the shell's InitCap sidecar at exec, so rm cannot touch a path
outside its argv. `KIND_ELEVATE_CHANNEL` is deliberately **not** declared:
elevate is a per-operation request, and ambient elevate authority would violate
the rule that destructive ops require per-op consent.

Effect-and-capability tails on the public entry points, verbatim from source:

```
rm_main                    : (u64, u64) -> u64      !{mem, sysreg} @{}
rm_remove_body             : (u64) -> u64           !{mem, sysreg} @{}
rm_process_one             : (u64) -> u64           !{mem, sysreg} @{cap, sched}
remove_reset               : () -> ()               !{mem, sysreg} @{cap, sched}
walk_recursive             : (u64) -> u64           !{mem, sysreg} @{}
elevate_check_and_request  : (u64) -> u64           !{mem} @{}
audit_pre                  : (u64) -> u64           !{mem, sysreg} @{cap, sched}
audit_record_target        : (u64) -> u64           !{mem, sysreg} @{cap, sched}
audit_post                 : (u64) -> u64           !{mem, sysreg} @{cap, sched}
schema_bind_stdout         : () -> u64              !{mem, sysreg} @{cap}
record_emit                : (u64, u64, u64, u64) -> u64  !{mem, sysreg} @{cap}
undo_write                 : (u64, u64, u64, u64) -> u64  !{mem} @{}
retention_attach           : (u64) -> ()            !{mem, sysreg} @{}
wipe_emit                  : (u64) -> ()            !{mem, sysreg} @{}
```

## Examples

Remove one file, verbose. Each hook now emits its own complete,
self-prefixed line (issue #23 fixed the interleaving bug that used to fuse
`retention_attach`'s note into the still-open target line):

```
$ rm -v report.txt
would prompt for confirmation (M2 stub)
rm: report.txt
rm: trash retention: 24h (M2 stub)
rm: (M2 stub -- real trash-move lands with PdxFS mutating ops)
```

Preview without touching anything. The dry-run branch takes none of the
retention, undo, schema, or audit-record hooks:

```
$ rm --dry-run -v secrets.txt
would prompt for confirmation (M2 stub)
rm: would remove: secrets.txt
```

Forensic shred. No trash entry, no retention, no undo record —
`was_wiped_flag` and the absence of an undo record are the two signals a
forensic reader uses to tell an intentional shred from a later retention reap:

```
$ rm -f --wipe -v /var/log/old.log
-f: skipping confirmation
rm: shred: /var/log/old.log: (M2 stub -- immediate trash-unlink + best-effort byte overwrite)
```

Recursive removal. The `-r` branch dispatches to `walk_recursive`:

```
$ rm -r -v stale/
rm: recursive walk of: stale/: (M2 stub -- real walk lands with PdxFS mutating ops)
```

A target under `/system/` requests elevation. rm lodges a per-operation
elevate request and, if the broker refuses, skips the removal entirely and
bumps `rm_blocked_by_elevate` (or `walk_blocked_by_elevate` under `-r`,
since issue #18 the gate runs once in `rm_remove_body` before dispatch and
covers both branches) — nothing is printed, nothing is audited, nothing is
journaled, and the exit code stays 0 at this release:

```
$ rm -v /system/audit/user-events/2026-08.log
# elevate hop requested (8-byte "/system/" prefix matched).
# broker approves (ELVC_OK) or is stubbed (ELVC_STUB) -> removal proceeds,
#   elevate_ok_count += 1
# broker returns anything else                        -> removal skipped in full,
#   elevate_err_count += 1, rm_blocked_by_elevate += 1, exit 0

$ rm -v /var/log/old.log        # no "/system/" prefix: no elevate hop at all
```

## Audit records

rm emits three distinct record streams per invocation.

**Destructive-op audit envelope** — `src/audit.pdx`, via `libpdx-audit`'s
three-call API. `audit_pre` is hoisted to the top of `rm_main` so the envelope
opens before any output, and `audit_post` commits at the epilogue with the exit
code preserved across the call.

| Call | Arguments | Notes |
|------|-----------|-------|
| `audit_begin` | `op_name = "rm"` (`OP_NAME`), `op_args_ptr = 0` | Returned `audit_id` is stashed in `audit_id_slot`; a zero return means broker unreachable. |
| `audit_record_output` | `audit_id : u64`, `output_schema = &"RemoveRecord@0.1"` (`SCHEMA_LABEL`), `output_hash : u64` | One call per successfully processed target. `output_hash` currently carries `target_ptr` verbatim; the substrate transition swaps in a BLAKE3-truncated hash of the path bytes with no signature change. |
| `audit_commit` | `audit_id : u64`, `exit_code : u64` | Clears `audit_id_slot`. |

Observability slots: `audit_id_slot`, `audit_begin_ok`, `audit_begin_err`,
`audit_records_out`, `audit_records_err`, `audit_commit_ok`, `audit_commit_err`.
Audit failure is observability-only at 1.0.0 — rm does not yet gate its output
on a proven audit trail, because no audit broker is running at paideia-os HEAD.

**`RemoveRecord@0.1`** — `src/schema.pdx`, bound to fd 1 at start-of-run by
`schema_bind_stdout` and emitted per target by `record_emit`. Five 8-byte
lanes, 40 bytes (`RECORD_BYTES`), one in flight per process:

| Offset | Field | Type | Notes |
|--------|-------|------|-------|
| `[0..8]` | `target_ptr` | `u64` (VA) | Interior pointer into the emitting process's argv; consumers treat it as a snapshot. |
| `[8..16]` | `target_len` | `u64` | Path byte length, NUL excluded. |
| `[16..24]` | `size` | `u64` | File byte-size at removal. Always 0 until a stat-of-inode syscall exists. |
| `[24..32]` | `was_dir` | `u64` | 0 = regular file, 1 = directory. Always 0 at this release. |
| `[32..40]` | `trash_handle` | `u64` | Opaque handle into the trash-subtree entry. Always 0 until the trash substrate lands. |

The wire format is frozen at v0.1 so consumers can build against it now. There
is no `was_wiped` lane in the record itself — the shred signal lives in the
`RmWipe::was_wiped_flag` slot and in the absence of an undo record.

**PdxFS v1 undo record** — `src/undo.pdx`, composed by `undo_write` into the
48-byte `_undo_scratch` buffer (`UNDO_RECORD_BYTES`). Six 8-byte lanes, with
`op_kind` deliberately at offset 0 so a log scanner can dispatch on the first
qword without decoding the trailer:

| Offset | Field | Type | Notes |
|--------|-------|------|-------|
| `[0..8]` | `op_kind` | `u64` | `UNDO_OP_RM = 1`. Kind 1 is reserved for rm in the shared undo-log allocation. |
| `[8..16]` | `target_ptr` | `u64` (VA) | Original path at removal time. |
| `[16..24]` | `target_len` | `u64` | Path byte length, NUL excluded. |
| `[24..32]` | `trash_handle` | `u64` | Handle into the trash entry. Always 0 at this release. |
| `[32..40]` | `retention_deadline_ns` | `u64` | Snapshot of `RmRetention::retention_deadline_ns`. `RETENTION_24H_NS = 0x4E94914F0000` = 86 400 000 000 000 ns = 24 h. A replay past this deadline must return ENOENT *with a diagnostic*, which is why the lane must be non-zero — a zero would leave the replayer unable to tell "expired" from "never written". |
| `[40..48]` | `was_dir` | `u64` | 0 = regular file, 1 = directory. Always 0 at this release. |

Ordering is load-bearing: `retention_attach` runs *before* `undo_write` so the
deadline lane is populated when it is snapshotted, and `undo_write` runs before
`record_emit`. `--wipe` skips `undo_write` entirely. The record is composed but
not yet appended to any log — the substrate transition edits a single call site
to `sys_pdxfs_undo_append`.

## See also

- [libpdx-argv](https://github.com/paideia-os/libpdx-argv) — the flag grammar and `ParsedArgs` surface rm parses against.
- [libpdx-audit](https://github.com/paideia-os/libpdx-audit) — the three-call destructive-op audit envelope.
- [libpdx-elevate](https://github.com/paideia-os/libpdx-elevate) — the per-operation elevate client rm calls on a `/system/` target.
- [libpdx-semantic-pipe](https://github.com/paideia-os/libpdx-semantic-pipe) — schema binding and record send for `RemoveRecord@0.1`.
- [mv](https://github.com/paideia-os/mv) — cross-subtree rename under one TXN.
- [cp](https://github.com/paideia-os/cp) — the mirror-image write path, also journaled.

## License

MIT — see LICENSE.
