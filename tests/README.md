# tests/

M4 test corpus for `rm`. Each `m4_XXX_*.pdx` module lands one of the
four M4 issues from paideia-os `design/tooling/r49-r50-plan.md` §5.8:

| Issue                                                       | File                              | State  |
|-------------------------------------------------------------|-----------------------------------|--------|
| rm.M4-001 TXN-abort mid-remove: no files removed            | `m4_001_txn_abort.pdx`            | LANDED |
| rm.M4-002 undo within retention window succeeds             | `m4_002_undo_in_window.pdx`       | LANDED |
| rm.M4-003 undo after retention window: ENOENT-w/-diagnostic | `m4_003_undo_after_window.pdx`    | LANDED |
| rm.M4-004 `--wipe` audit flag correctness                   | `m4_004_wipe_forensic.pdx`        | LANDED |

Plus a runner and a fingerprint corpus:

| Component                 | File                             | Purpose                                                 |
|---------------------------|----------------------------------|---------------------------------------------------------|
| Runner                    | `m4_runner.pdx`                  | `M4Runner::m4_run_all` invokes every test in order      |
| Expected fingerprints     | `expected-m4-fingerprints.txt`   | Substring corpus the smoke driver matches on            |

## Test discipline

Every test module exposes a public `run_m4_XXX : () -> u64` entry
whose return code discriminates OK (0) from FAIL (1) and whose stdout
carries a compact fingerprint line (`[rm.M4-XXX OK]\n` or
`[rm.M4-XXX FAIL]\n`) the smoke driver matches on. The tests reset
`rm`'s observability state, drive its helpers via direct call, and
read the counter set the M2/M3 milestones exposed.

## Substrate-gap discipline

The PdxFS v1 mutating ops (`sys_pdxfs_txn_open`, `sys_pdxfs_move`,
`sys_pdxfs_txn_commit`, `sys_pdxfs_txn_abort`, `sys_pdxfs_readdir`)
scheduled at R42-PREP-004 are not in-tree at HEAD. The M4 tests
therefore assert the *structurally equivalent* observability shape a
live substrate would produce -- e.g. the dry-run branch through
`rm_process_one` as the M4-001 TXN-abort proxy (both leave the four
M3 counters at 0). Every test header calls out the substrate proxy it
uses and the specific body edit an M5 substrate landing patch will
apply to promote the test from proxy to live.

## Reset-list gap

`RmRemove::remove_reset` at M3 zeros the M1/M2 counters plus delegates
to the four M3 module resets, but does NOT cover
`RmRetention::retention_attach_count`,
`RmRetention::retention_deadline_ns`, or the two `RmWalk` slots
(`walk.pdx` L99-105 documents the gap). Every M4 test explicitly
zeros the slots it depends on before invoking any rm helper. The M5
substrate commit that lands per-entry walk hooks also expands
`remove_reset` to cover the gap; the M4 tests keep their explicit
resets either way so they stay self-contained.

## Build note (M4 is source-only)

M4 lands the tests as source. The `manifest.pdxproj` used to build
`build-out/rm` does NOT list the test modules -- adding them would
change the shipped binary's exported surface. A separate `rm-tests`
target that reuses `src/*.pdx` and adds `tests/*.pdx` lands with
`rm.M5-001` alongside the dual-signed release harness. Until then,
the tests are read for correctness against the M2/M3 body shapes; the
smoke driver stubs live in the paideia-os smoke matrix at
`tools/run-smoke.sh` and are wired at M5.
