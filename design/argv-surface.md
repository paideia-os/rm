# rm — argv surface

**Wave:** R50  Milestone: M1
**Upstream design:** `design/tooling/r49-r50-plan.md` §5.8 in
[paideia-os](https://github.com/paideia-os/paideia-os); D3 (flag
grammar) + I3 (standard flag vocabulary) in
[`design/tooling/plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/plan.md)
§3-4.

## 1. Purpose

This document freezes the rm command-line surface at M1. Every M2
body edit inherits this surface unchanged; adding a new flag or
changing an existing flag's meaning is a diff to this document plus
a code change gated on the review of the diff.

The surface is deliberately narrow at M1: five flags (recognised but
not all acted upon), one or more positional target paths. Every real
behaviour lands in later milestones and inherits this surface as its
call site.

## 2. Grammar

rm follows D3 (long primary, short one-per-hyphen — no clustering)
via libpdx-argv. The invocation shape is:

```
rm [flag ...] <path> [<path> ...]
```

- `--flag` accepts long-only well-known flags. The two long flags at
  M1 are `--wipe` and `--dry-run`. Neither takes a value; libpdx-
  argv's lookahead rule (see `design/architecture.md` §4 in
  libpdx-argv) means `--wipe /pdx/foo` is parsed as two argv entries
  (a boolean flag and a positional), not as `--wipe=/pdx/foo`.
  Consumers must ensure any argv value that BEGINS with `/` cannot be
  confused with a flag value — libpdx-argv already handles this
  because its lookahead rejects a candidate value that begins with
  `-`, and `/` is unambiguously a positional.
- `-f` accepts single-letter short flags. The three short flags at M1
  are `-r`, `-f`, `-v`. `-rf` is rejected as `ERR_CLUSTERED_SHORT` —
  libpdx-argv M1-002 enforces this at parse time; rm's exit code for
  that class of failure is 2 (usage error, handled by RmMain via
  the general PARSE_FAIL path).
- `<path>` is required. A zero-positional invocation is a usage error
  handled by RmMain's `USAGE_MSG` branch and exits with code 2.
- Additional positionals after the first are the M2 recursive-walk
  input. At M1 they are recognised (present in `ParsedArgs::pos_ptrs
  [1..pos_count]`) but not consumed by `RmRemove::rm_remove_body`.

## 3. Flag vocabulary (M1)

| Flag         | Type    | M1 status       | Landing body   |
|--------------|---------|-----------------|----------------|
| `-r`         | bool    | recognised only | M2-001         |
| `-f`         | bool    | recognised only | M2-002         |
| `-v`         | bool    | acted upon      | M1-003         |
| `--wipe`     | bool    | recognised only | M2-004         |
| `--dry-run`  | bool    | acted upon      | M1-003         |

The five flags have distinct first bytes (`r` / `f` / `v` / `w` /
`d`) which lets `RmFlags::flags_scan` use a first-byte switch +
per-branch inline byte-compare (same idiom as libpdx-argv's
`--pdx-schema` well-known check). Adding a sixth flag with a first
byte already in {r,f,v,w,d} — e.g. `--force` — requires either a
nested compare on the second byte inside the existing branch or an
allocation from the remaining first-byte space. ENH-008 (issue #26)
took the nested-second-byte route inside the `r`/`f`/`v` arms to
land `--recursive`/`--force`/`--verbose`; ENH-007 (issue #25) added
a `p` arm to recognise the well-known D3 `--pdx-schema` flag
(libpdx-argv's parser inline-toggles `ParsedArgs::emit_schema` for
it; the `p` arm in rm does no local state change but keeps the name
out of the ENH-007 unknown-flag rejection path).

### 3.1 Per-flag semantics

- `-r` — enable recursive descent. When set at M2-001 and the first
  positional is a directory, rm walks the subtree leaf-first under a
  single TXN and moves every entry (leaves first, directories last)
  into the trash subtree. Without `-r`, a directory target is
  rejected with `EXIT_OP_FAIL`. M1 recognises the flag but the M1
  body never acts on it — a directory target at M1 falls through to
  the same M1-003 placeholder as a file target.
- `-f` — force removal without per-file confirmation. M2-002 wires
  the per-file confirmation prompt and the `-f` skip; M1 has no
  confirmation prompt to skip.
- `-v` — verbose. When set, rm emits one status line per removed
  file on stdout naming the target. At M1-003 this is a single
  placeholder line prefixed with `rm: `; at M2+ it is one line per
  file the recursive walk trashes.
- `--wipe` — shred. When set at M2-004, rm bypasses the trash-
  subtree move and instead immediately unlinks the trash-entry AND
  attempts a best-effort byte-overwrite where the underlying device
  supports it. When `--wipe` is set the trash entry never persists
  and no undo record is written; the M3-002 audit record instead
  carries a "was_wiped" boolean so a forensic reader can detect
  intentional shred. M1 recognises the flag but the body never acts
  on it.
- `--dry-run` — no-side-effect probe. When set at M1-003 the body
  prints `would remove: <target>\n` on stdout and returns 0 without
  invoking any trash-move (there is no trash-move to invoke at M1
  anyway). M2+ bodies enforce the no-side-effect contract by
  aborting the TXN just before commit.

### 3.2 Combining flags

- `-r --dry-run` at M2+ walks the subtree and prints one "would
  remove:" line per entry it would trash, without opening a TXN.
- `-r -v` at M2+ walks the subtree and prints one "removing:" line
  per entry as it trashes them.
- `-r --wipe` at M2+ walks the subtree and shreds every entry
  bottom-up. This is the terminal-destructive form; M3-004 makes it
  require an elevate hop even when the target is under the invoker's
  home subtree.
- `-f` composes with any other flag as a no-op at M1 and as
  "skip confirmation" at M2+.

### 3.3 Unknown-flag rejection (ENH-007 / issue #25)

`flags_scan` returns 0 on all-recognised or the interior name-pointer
of the first unknown flag; `rm_main` short-circuits on the first hit
and prints `rm: unknown option: <flag>\n` on stderr, then returns
`EXIT_USAGE`. Partial-tail mismatches (e.g. `--recursve` as a typo
of `--recursive`) are surfaced too — the pre-ENH-007 fall-through
silently produced a non-recursive removal, defeating the flag's
safety purpose. The `--` end-of-options convention is preserved
by libpdx-argv upstream: tokens after a bare `--` are recorded in
`pos_ptrs[]` and never enter `flag_names[]`, so `flags_scan` cannot
see them (leading-hyphen positionals like `rm -- -weird-name` are
treated as literal paths).

## 4. Standard-vocabulary flags (D3)

The following flags are part of the wave-wide standard vocabulary
(design/tooling/plan.md §3.4) and rm inherits them at the wave-
schedule below rather than declaring them per-flag here:

- `--help` — landing at M3-001 via a call into `doc rm` once doc.M2
  is in-tree. M1 has no `--help` handler; a caller who passes
  `--help` at M1 sees the M1 usage message from RmMain's
  `USAGE_MSG` path when they also omit a positional, or the M1-003
  placeholder body when they pass a positional too. Neither is a
  regression the M3 handler cannot fix.
- `--version` — landing at M5-001 via the shared release-string
  helper.
- `--pdx-schema` — landing at M3-001 via the libpdx-semantic-pipe
  bind. When set, rm's stdout emits `RemoveRecord[]` records in
  addition to (or instead of, per D2) the text output. libpdx-argv
  already recognises `--pdx-schema` as a well-known long flag (it
  sets `ParsedArgs::emit_schema = 1`); rm.M1 does not read that slot
  because the semantic-pipe bind is deferred.

## 5. Exit codes

- `0 EXIT_OK` — the operation succeeded. rm.M1 always returns 0 on
  the parse-and-dispatch path; the M1-003 placeholder body always
  returns 0 too.
- `1 EXIT_OP_FAIL` — the trash-move failed (M2+ paths). rm.M1 never
  returns this.
- `2 EXIT_USAGE` — the argv did not parse, no positional was
  supplied, or an unrecognised flag was passed (issue #25 / ENH-007).
  rm.M1 returns this from the parse-fail path (`RmMain::
  PARSE_FAIL_MSG`) and the zero-positional path (`RmMain::
  USAGE_MSG`); rm 1.0.1 also returns it from the unknown-flag
  rejection path, which emits `rm: unknown option: <flag>\n` on
  stderr (the diagnostic reconstructs a `-` prefix for a one-byte
  name and `--` otherwise; libpdx-argv stores flag names sans
  leading dashes). `RmFlags::flags_scan` returns the first unknown
  flag's interior name-pointer, or 0 for all-recognised; `rm_main`
  short-circuits on the first hit.
- `3 EXIT_NOT_YET_IMPL` — reserved for M2+ bodies that recognise a
  flag combination they do not yet implement. rm.M1 never returns
  this.
- `4 EXIT_CAP_DENIED` — reserved. Landing at exec-time via the
  loader's cap_manifest_verify path (libpdx-cap M2-001); rm never
  writes this code from its own body because the process never
  starts on a cap-denied load.

## 6. Positional contract

rm reads one or more positional paths from `ParsedArgs::pos_ptrs
[0..pos_count]`. At M1, `rm_main` dispatches only on `pos_ptrs[0]`;
the remaining slots are visible to the M2 recursive-walk body edit
inside `rm_remove_body`. Each positional is a NUL-terminated string
pointing into the caller's argv buffer (owner: the shell that
launched the rm process; libpdx-argv preserves the interior-pointer
invariant).

A positional beginning with `-` is disambiguated from a flag by the
libpdx-argv grammar: a bare `-` is a positional, a `--` alone
switches libpdx-argv into positional-only mode (all subsequent argv
entries are positionals), and anything else beginning with `-` is a
flag or a flag prefix.

The M1 body imposes no length bound on a target path (the underlying
PdxFS substrate enforces the real bound at M2's trash-move op site).
libpdx-argv's `MAX_POS = 32` bounds the number of positionals per
invocation; a 33rd positional causes libpdx-argv to return
`ERR_POS_OVERFLOW` which rm surfaces as `EXIT_USAGE`.
