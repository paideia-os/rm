# rm — enhancement plan (v1.x)

**Author:** softarch enhancement pass, 2026-08-25
**Baseline:** `v1.0.0` (commit `d522842`), issues #1–#17 all closed
**Scope:** design + issue plan only; no code lands with this document.

---

## 0. Executive summary

rm 1.0.0 is a structurally complete, well-factored front-end: eleven
modules, a frozen argv surface, a five-lane schema record, a six-lane
undo record, a three-call audit envelope, and a real `libpdx-elevate`
dependency that is genuinely linked and genuinely invoked. The module
decomposition is good and every enhancement below is a body edit or a
small new module — none of them force a signature break or a
`caps.decl` change.

It also ships a **capability-security regression**: the `-r` branch
takes none of the gates the non-recursive branch enforces. The elevate
check, the audit record, the schema record, the undo record and the
retention deadline are all wired into `rm_process_one` and **none** of
them are wired into `walk_recursive`. Three of the project's stated
pillars — capability discipline (D4: destructive ops require per-op
consent), audit-first (D3), and universal undoability (I5) — are
silently unenforced on the recursive path.

The hole is **latent, not live**: PdxFS mutating ops are not in-tree,
so no `rm` invocation presently deletes anything. That is the only
reason this is not an active incident. It also sets the deadline —
these fixes must land **before** the R42 substrate, not after, because
the day `sys_pdxfs_move` lands, `rm -r /system/...` becomes an
unprivileged recursive delete of the system subtree.

A second, independent bypass of the same gate: the `/system/` detector
compares the **unresolved argv bytes**. rm does no path resolution at
all — no `sys_getcwd`, no `sys_chdir`, no `..` normalisation anywhere
in `src/`. Any relative path that resolves into `/system/` evades the
gate on the non-recursive path too.

**Verdict on the tag:** `v1.0.0` stands as a historical marker of the
M1–M5 skeleton, but rm must not be described as elevate-gated and is
**not v1.1-ready** until #18, #19 and #21 close. See §10.

---

## 1. Current state (verified against source at `d522842`)

| Module | File | Role | Reached by `-r`? |
|---|---|---|---|
| `RmMain` | `src/main.pdx` | entry, audit envelope, dispatch | yes |
| `RmFlags` | `src/flags.pdx` | five-flag first-byte scanner | yes |
| `RmRemove` | `src/remove.pdx` | positional loop + `rm_process_one` | loop only |
| `RmWalk` | `src/walk.pdx` | `-r` branch | yes |
| `RmElevate` | `src/elevate.pdx` | `/system/` gate | **no** |
| `RmRetention` | `src/retention.pdx` | 24h deadline | **no** |
| `RmUndo` | `src/undo.pdx` | 6-lane undo record | **no** |
| `RmSchema` | `src/schema.pdx` | `RemoveRecord@0.1` | **no** |
| `RmAudit` | `src/audit.pdx` | per-target audit record | **no** |
| `RmWipe` | `src/wipe.pdx` | `--wipe` shred | **no** |
| `Print` | `src/print.pdx` | unbuffered `sys_write` | yes |

The right-hand column is the whole problem in one view. `rm_remove_body`
(`src/remove.pdx:346-371`) is a two-way switch, and one of the two arms
was built as a print-only skeleton that never grew the gates the other
arm accumulated across M2–M3.

### 1.1 What is genuinely real

Confirming the README pass's positive finding, with the correction it
needs:

- `libpdx-elevate @ ^0.1` is a declared dependency
  (`manifest.pdxproj`, deps list).
- `RmElevate::elevate_check_and_request` (`src/elevate.pdx:178`)
  performs a real 8-byte `/system/` prefix compare and, on match,
  really calls `ElevateClient::elevate_client_request`
  (`src/elevate.pdx:234`).
- That function is called from exactly **one** site in the entire
  repo: `src/remove.pdx:456`, inside `rm_process_one`.

So "rm truly calls libpdx-elevate" is **true but incompletely
applied**. The linkage is real; the gate covers one of two dispatch
branches and matches only unresolved absolute paths. Call it
*real-but-half-applied* rather than either "real" or "documented
only".

---

## 2. Finding A — SECURITY: `-r` bypasses the elevate gate

**Enforced path.** `src/remove.pdx:450-458`:

```
        mov rdi, rbx;
        call elevate_check_and_request;
        cmp rax, 0;                            // RE_PROCEED (0)
        jne rm_process_blocked;
```

This runs first in `rm_process_one`, before any observable action, and
a refusal jumps to `rm_process_blocked` (`src/remove.pdx:581-594`)
which performs no print, no retention, no undo, no schema emit, no
audit record.

**Bypass path.** `src/remove.pdx:355-363`:

```
        lea r11, [rip + flag_r];
        mov rax, [r11];
        cmp rax, 0;
        je rm_remove_call_process_one;

        // Recursive branch. RmWalk::walk_recursive(target) → rax=0 at M2.
        call walk_recursive;
```

When `flag_r == 1` the dispatch jumps directly to
`RmWalk::walk_recursive` (`src/walk.pdx:163-236`). That function's
complete body is: bump `walk_invocations`, print up to four strings,
return 0. There is no call to `elevate_check_and_request` anywhere in
`src/walk.pdx` — a repo-wide grep finds the symbol at
`src/remove.pdx:456` and nowhere else.

**The confirming artefact.** `src/walk.pdx:105` declares

```
  pub let mut walk_blocked_by_elevate : u64 = uninit @align(8)
```

with a doc comment (`src/walk.pdx:89-96`) stating it is "bumped when
`RmElevate::elevate_check_and_request` refuses at the walk-branch
top-level target". Nothing anywhere in `src/` ever increments it. It is
written exactly once, by the zeroing loop in `remove_reset`
(`src/remove.pdx:203-204`). It is a **dead counter** — the observability
slot for a check that was declared, documented, reset, and never
implemented.

`STATUS.md:78-88` compounds this by recording M3-004 as having extended
"`src/elevate.pdx` + `src/remove.pdx` + `src/walk.pdx`". `src/walk.pdx`
received the counter declaration and nothing else.

**Recommended fix (architectural, not a patch).** Do *not* duplicate
the gate inside `walk_recursive`. Hoist it into `rm_remove_body`'s loop
body, immediately after `pos_ptrs[i]` is loaded and **before** the
`flag_r` branch at `src/remove.pdx:355`. One gate, placed at the single
point where every target is in hand and no dispatch decision has been
taken yet. That makes the invariant structural: a future third dispatch
arm cannot silently skip it, which is precisely the failure mode that
produced this bug. `rm_process_one`'s own call site is then removed so
the check is not run twice (or kept as a cheap idempotent assertion —
implementer's call, but single-site is cleaner).

---

## 3. Finding B — SECURITY: the gate matches unresolved argv bytes

`elevate_check_and_request` compares `target_ptr[0..8]` against the
literal `"/system/"` (`src/elevate.pdx:74`, scan at
`src/elevate.pdx:192-219`). `target_ptr` is an interior pointer
straight into the process's argv buffer — rm never resolves it.

A repo-wide grep for `getcwd|chdir|cwd|resolve` across `src/` returns
two hits, both incidental words inside comments. rm has **no path
resolution of any kind**. Consequences:

- `rm foo` with cwd `/system/` → scan sees `foo`, no match, no elevate
  hop, gate passed.
- `rm ../../system/passwd` from anywhere → scan sees `../..`, no match,
  gate passed.
- A path shorter than 8 bytes never matches (`src/elevate.pdx:205-207`
  returns `RE_NO_ELEVATE` on an early NUL) — correct for `/tmp/x`, but
  it means the gate's coverage is a function of spelling, not of the
  file being addressed.

This is the same class of defect as Finding A — the gate is real but
its input is wrong — and it defeats the gate on the *non-recursive*
path too. It also lands rm in the R86 relative-path cohort named
alongside `mv` and `cp`: kernel `sys_chdir`/`sys_getcwd` landed after
rm shipped 1.0.0 and rm consumes neither.

The correct sequence is resolve-then-gate: canonicalise the target
(absolutise against `sys_getcwd`, fold `.`/`..`) and run the prefix
scan on the canonical form. Attempting to gate on unresolved input is
not fixable by widening the pattern list.

---

## 4. Finding C — the `-r` path is invisible to audit, schema and undo

Not in the original brief, and at least as consequential as Finding A.
`walk_recursive` calls none of `retention_attach`, `undo_write`,
`record_emit`, or `audit_record_target`. Every one of those hooks lives
only in `rm_process_one` (`src/remove.pdx:536-564`). So on the
recursive path:

- no `RemoveRecord@0.1` reaches the semantic pipe → a downstream
  consumer sees recursive removals as though they never happened;
- no undo record is composed → **I5 ("every removal is undoable within
  the retention window") does not hold for `rm -r`**, which is the
  single most destructive form of the command;
- no per-target audit record → **D3 audit-first does not hold for
  `rm -r`**;
- no retention deadline is attached.

`design/architecture.md:324-330` documents the retention omission as
deliberate-for-now ("the M2 walk emits only one line per top-level
target and there is no per-entry hook to attach the retention onto"),
and that reasoning is sound *for a skeleton*. But the net effect at
1.0.0 is that the three record streams the README advertises as
running "on every invocation" (README:52) do not run on the `-r`
branch at all. That claim needs either the code or the sentence
corrected; this plan proposes the code.

These hooks genuinely do need the per-entry substrate to be
*complete*. What does not need the substrate is the **top-level**
target record — the walk knows its target, and emitting one audit +
schema + undo record for it is available today and restores the
invariant's floor.

---

## 5. Finding D — verbose output interleaving

**Symptom** (reproduced verbatim in README:138-142):

```
$ rm -v report.txt
would prompt for confirmation (M2 stub)
rm: report.txttrash retention: 24h (M2 stub)
: (M2 stub -- real trash-move lands with PdxFS mutating ops)
```

**Mechanism.** Not a buffer bug, not a format-string bug, not a race.
`Print::print_str` (`src/print.pdx:73-85`) is an unbuffered, immediate
`sys_write(fd=1)` — every call emits its bytes at once, in call order.
The garble is therefore *deterministic emission ordering*.

`rm_process_one` builds its output line as four positional fragments.
Part 3 prints the raw target bytes with **no trailing separator**
(`src/remove.pdx:516-520`), by design: the line was meant to be closed
by Part 4's `M2_STUB_SUFFIX`, which is why that constant begins with a
colon and ends with a newline —
`": (M2 stub -- real trash-move lands with PdxFS mutating ops)\n"`
(`src/remove.pdx:124-126`).

M2-003 then inserted `retention_attach` **between** Part 3 and Part 4
(`src/remove.pdx:536-540`). Under `-v`, `retention_attach` performs its
own independent `print_str` of `"trash retention: 24h (M2 stub)\n"`
(`src/retention.pdx:92-94`, emitted at `src/retention.pdx:144-146`)
straight into the middle of a line that is still under construction.

So the bytes on fd 1 are exactly:

```
"rm: "  +  "report.txt"  +  "trash retention: 24h (M2 stub)\n"  +  ": (M2 stub …)\n"
```

producing both visible symptoms from one cause: the retention note
fused onto the unterminated target, and the suffix orphaned onto the
next line with a leading colon.

`retention_attach` is the *only* interposed hook that emits. Verified:
`audit_record_target` (`src/audit.pdx:226-256`) and `record_emit`
(`src/schema.pdx:259-304`) contain no `print_str` call at all — their
outbound traffic is `audit_record_output` and `send_record`
respectively, neither of which touches fd 1. `undo_write` is likewise
silent. So one hook causes the whole garble today; a second emitting
hook placed at the same point would compound it, which is why the fix
should be the line-ownership rule rather than a one-off reorder.

The other two output paths are clean **by construction**, and for a
reason worth preserving: `wipe_emit` (`src/wipe.pdx:162-190`) and
`walk_recursive` (`src/walk.pdx:187-227`) each close their own line
with a newline-terminated suffix before any non-printing hook runs.
The default path is the only one that leaves a line open across a
call.

**Root cause, stated precisely:** an emitting hook was interposed into
a multi-call line under construction, with no ownership rule for who
terminates a line on fd 1.

**Intended output** is not in dispute — `doc/rm.pdxdoc:101-104`
specifies it:

```
$ rm -v report.txt
rm: report.txt
rm: trash retention: 24h
```

Two complete lines, each independently prefixed. That is the
fingerprint the fix should hit. The structural fix is to make every
`print_str` call site emit a **whole line** — move the target-line
terminator to the end of Part 3 and give the retention note its own
`rm: ` prefix — rather than reordering the hooks, because reordering
only postpones the next occurrence.

---

## 6. Finding E — `--recursive` / `--force`: decision

**Source truth.** `RmFlags::flags_scan` (`src/flags.pdx:131-227`)
recognises exactly five names via a first-byte switch on
`r`/`f`/`v`/`w`/`d`: `-r`, `-f`, `-v`, `--wipe`, `--dry-run`. No long
aliases exist. `design/argv-surface.md:61-68` confirms this was
deliberate and even names the obstacle: a sixth flag whose first byte
is already in `{r,f,v,w,d}` — "e.g. `--force`" — needs a nested
second-byte compare.

`doc/rm.pdxdoc` nonetheless documents **three** aliases that do not
exist: `-r, --recursive` (L25), `-f, --force` (L30), `-v, --verbose`
(L36).

**Compounding defect.** Unrecognised flags fall through **silently**
(`src/flags.pdx:160`, `flags_scan_loop_head` → `flags_advance`; the
rejection contract was scheduled at M4 and never landed). So today
`rm --recursive stale/` does not error — it parses, ignores the flag,
and performs a **non-recursive** removal. A user following `doc rm`
gets silent, wrong behaviour from a documented flag. For `--force`
the failure is benign; for `--recursive` it is a safety trap.

**Decision: implement the long aliases; do not strip the doc.**

Rationale:

1. The org's own D3 grammar is *"long primary, short one-per-hyphen"*
   (`design/argv-surface.md:24`). Long forms are the canonical
   spelling under the project's own convention; their absence is the
   defect, not their documentation.
2. Clustering is a hard parse error — `rm -rf x` exits 2
   (README:11-14). Users must type `rm -r -f x`. Denying them
   `rm --recursive --force x` as well makes the most common
   destructive invocation needlessly awkward.
3. Cost is genuinely small: a nested second-byte compare inside the
   existing `flags_try_r` / `flags_try_f` / `flags_try_v` branches,
   which is exactly the resolution `argv-surface.md:61-68` already
   anticipated. No new first-byte allocation, no grammar change.
4. `doc/rm.pdxdoc` already promises them, and `doc rm` is the
   user-facing contract.

**Sequencing caveat:** the alias work must land *with* the
unknown-flag rejection, not before it. Fixing rejection alone would
turn `--recursive` into a hard exit-2 — safe but hostile given the doc
promises it. Fixing aliases alone leaves every *typo* a silent no-op.
Both together give: documented flags work, undocumented flags fail
loudly.

---

## 7. Finding F — no test target exists

`design/architecture.md:437-449` and `tests/expected-m4-fingerprints.txt`
both record it plainly: the M4 corpus is **source-only**.
`manifest.pdxproj` builds `build-out/rm` from `src/*.pdx` alone;
`tools/build.sh` compiles `tests/*.pdx` to separate objects, so they
are syntax-checked but never linked and never executed. The six
expected fingerprint lines have never been produced by a running
binary. The `rm-tests` build target was deferred to "the M5 substrate
integration commit", which landed as a signing/release commit and did
not include it.

This is the structural reason Findings A and D survived to a signed
1.0.0: nothing in this repo can fail. It is the highest-leverage item
after the security cluster, because it is what makes every other fix
verifiable and keeps the elevate gate from silently regressing again.

---

## 8. Gap vs. what paideia-os users need at HEAD

| Need | State at 1.0.0 | Issue |
|---|---|---|
| `/system/` protected against recursive delete | **bypassed** | #18 |
| `/system/` protected against relative paths | **bypassed** | #19 |
| Irreversible shred requires consent | no gate at all | #20 |
| A blocked removal is distinguishable by exit code | always exits 0 | #21 |
| `rm -r` is undoable (I5) | no undo record | #22 |
| `rm -r` is audited (D3) | no audit record | #22 |
| Readable verbose output | garbled | #23 |
| Typo'd flag fails loudly | silent no-op | #25 |
| `--recursive` / `--force` work | not implemented | #26 |
| `doc rm` matches reality | three false aliases | #27 |
| Regressions get caught | no runnable tests | #24 |
| Relative paths resolve via kernel cwd | no resolution at all | #19 |

---

## 9. Issue plan

Filed into milestone **"Enhancement v1.x — rm"** (milestone 6).

**P0 — security, blocks v1.1 and blocks the R42 substrate landing**

| # | ID | Title | Effort |
|---|---|---|---|
| [#18](https://github.com/paideia-os/rm/issues/18) | ENH-001 | SECURITY: `-r` bypasses the `/system/` elevate check | S |
| [#19](https://github.com/paideia-os/rm/issues/19) | ENH-002 | SECURITY: elevate gate matches unresolved argv bytes | M |

**P1 — correctness and consent**

| # | ID | Title | Effort |
|---|---|---|---|
| [#20](https://github.com/paideia-os/rm/issues/20) | ENH-003 | SECURITY: `--wipe` takes no elevate hop | S |
| [#21](https://github.com/paideia-os/rm/issues/21) | ENH-004 | SECURITY: blocked removals return exit 0 | S |
| [#22](https://github.com/paideia-os/rm/issues/22) | ENH-005 | `-r` emits no audit / schema / undo / retention records | M |
| [#23](https://github.com/paideia-os/rm/issues/23) | ENH-006 | Verbose output interleaving | S |
| [#24](https://github.com/paideia-os/rm/issues/24) | ENH-010 | Land `rm-tests` target + regression tests | M |

**P2 — surface and documentation**

| # | ID | Title | Effort |
|---|---|---|---|
| [#25](https://github.com/paideia-os/rm/issues/25) | ENH-007 | Unknown flags silently ignored; reject with exit 2 | S |
| [#26](https://github.com/paideia-os/rm/issues/26) | ENH-008 | Implement `--recursive` / `--force` / `--verbose` | S |
| [#27](https://github.com/paideia-os/rm/issues/27) | ENH-009 | `doc/rm.pdxdoc` + `STATUS.md` + comment errata | XS |

### 9.1 Errata inventory for #27

Collected during this pass; all verified against source:

- `doc/rm.pdxdoc:25,30,36` — documents `--recursive`, `--force`,
  `--verbose`; none exist (superseded if #26 lands, in which case
  this reduces to a re-check).
- `doc/rm.pdxdoc:58-60` — claims `rm -rf /` "exits 4". `-rf` is a
  clustered short and is rejected by libpdx-argv as
  `ERR_CLUSTERED_SHORT` → exit **2**, never reaching a cap check.
- `doc/rm.pdxdoc:82-90` — exit table lists 3 as "System error"; source
  declares `EXIT_NOT_YET_IMPL = 3` (`src/remove.pdx:67`) and
  `design/argv-surface.md:145-151` agrees with the source.
- `STATUS.md:78-88` — records M3-004 as extending `src/walk.pdx` with
  the elevate wire-up. It added a counter declaration only.
- `src/walk.pdx:90-93` — asserts `walk_blocked_by_elevate` is bumped on
  a walk-branch elevate refusal. No elevate call exists there.
- `src/walk.pdx:98-104` — asserts the slot is "intentionally NOT zeroed
  in remove_reset". It **is** zeroed, at `src/remove.pdx:203`. The
  comment predates the M5-001 widening and was not updated.
- `src/schema.pdx:130-135` — states
  `record_emit_count + record_emit_err_count == removed_count - wipe_count`.
  Self-contradictory: `record_emit` *is* called on the wipe path
  (`src/remove.pdx:485`). The true relation is `removed_count` minus
  dry-run targets minus elevate-blocked targets.

**Suggested landing order:** #24 first (so everything after it is
verifiable), then #18 → #21 → #19, then #22, #20, #23, then the P2
surface cluster (#25 and #26 jointly, then #27).

---

## 10. Release verdict

**`v1.0.0` is defensible only as a pre-substrate skeleton tag, and rm
must not be advertised as elevate-gated until #18 and #19 close.**

The reasoning, stated honestly:

- Nothing rm does at 1.0.0 deletes a file. The security hole is
  latent. Yanking or re-tagging the release would be theatre.
- But the release is *documented* as enforcing an elevate gate, and
  `doc/rm.pdxdoc` plus `STATUS.md` assert protections the binary does
  not implement. The README (refreshed 2026-08-25) already states both
  bypasses accurately — that honesty is the current mitigation, and it
  should not be the permanent one.
- The binding constraint is ordering, not versioning: **#18, #19 and
  #21 must merge before the R42 PdxFS mutating ops land in
  paideia-os.** The moment `sys_pdxfs_move` becomes callable,
  `rm -r /system/x` is an unprivileged recursive delete of the system
  subtree with no audit record and no undo record. Treat these three
  issues as a gate on the substrate wave, not as rm-local cleanup.

No **v1.1** until #18, #19 and #21 close.

---

## 11. Companion paideia-os monorepo work (flagged, not filed)

Consolidated by the coordinating pass; listed here for that pass to
pick up.

1. **`sys_getcwd` / `sys_chdir` consumption (R86).** #19 needs the
   kernel cwd surface. rm is in the same cohort as `mv` and `cp`;
   the path-canonicalisation helper should be promoted into a shared
   lib (a `libpdx-path`) rather than reimplemented per tool.
2. **InitCap narrowing semantics for `/system/` targets.** `caps.decl`
   states the loader narrows `KIND_PDXFS_FILE` to the target-parent at
   exec. Whether an unprivileged invoker's ambient cap can be narrowed
   *to* a `/system/` parent at all determines whether the elevate gate
   is the sole control or the second of two. This needs an authoritative
   answer from the loader side; it changes the exploitability
   assessment of #18 but not its priority.
3. **Elevate broker is a seam stub.** `svc.elevate-broker` returns
   `ELVB_DISPATCH_STUB`; `RmElevate` treats `ELVC_STUB` as proceed
   (`src/elevate.pdx:240-247`). Every tool with an elevate gate
   currently fails *open* against the stub. A wave-wide decision is
   needed on whether pre-broker builds should fail closed.
4. **Smoke-matrix wiring.** `tools/run-smoke.sh` is documented as the
   consumer of `tests/expected-m4-fingerprints.txt` but nothing
   produces that stdout. #24 lands the rm side; the smoke driver
   needs the matching entry.
5. **R42 substrate gate.** Record the §10 ordering constraint wherever
   the R42 wave is planned: rm's P0 cluster blocks it.
