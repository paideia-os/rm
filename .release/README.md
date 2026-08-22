# .release/ — rm mirror-push procedure

Per design/tooling/plan.md §9.3, every rm release follows a five-step
flow. rm 1.0.0 is the first release; every subsequent release repeats
the same shape with the new version threaded through
`manifest.pdxproj`, `CHANGELOG.md`, `doc/rm.pdxdoc` (`@version`), and
`.release/mirror.pdxmeta` (`version`).

## The five steps

1. **Tag the repo.** `git tag v1.0.0` (annotated tag; message is the
   CHANGELOG.md entry for the version).
2. **Sign the manifest.** `paideia-as release --sign` reads
   `manifest.pdxproj`, computes the canonical-tuple BLAKE3 hash into
   `manifest.pdxsig[hash].value`, and produces the author signature
   into `manifest.pdxsig[sig.author]`. The paideia_root record's
   signature block stays placeholder until the bot re-signs.
3. **Push to staging.** `pkg push .` reads `.release/mirror.pdxmeta`
   and uploads `pkg.tar` + `manifest.pdxsig` into the `staging_path`
   under `target_repo`. Until T-INFRA-001 lands, this step writes
   to a local staging directory and prints the URL that will
   receive the tarball once the network path stands up.
4. **Bot re-signs.** The signing bot (T-INFRA-002) on the host that
   holds `paideia_root_pk` polls the staging directory, verifies the
   source-tree root commit matches the author's tag, re-signs
   `manifest.pdxsig[sig.paideia_root]`, and moves the tarball from
   `staging_path` to `main_path`. Human-in-the-loop review per
   §9.3 gates every promotion.
5. **`pkg upgrade` picks it up.** User machines running
   `pkg upgrade rm` (or `pkg install rm` for a first-time install)
   fetch from `main_path`, verify both signatures, and land
   `pkg.tar` at `/pkgs/rm-1.0.0/` with symlinks per
   `.release/mirror.pdxmeta`'s `post_install` block.

## What ships in `pkg.tar`

Per §6.4 and `.release/mirror.pdxmeta`'s `tar_layout`:

```
rm-1.0.0/
  bin/rm                         (build-out/rm)
  lib/                           (empty — rm has no shared-lib output)
  doc/rm.pdxdoc                  (doc/rm.pdxdoc)
  caps.decl                      (caps.decl)
  manifest.pdxsig                (manifest.pdxsig; dual-signed)
  CHANGELOG.md                   (CHANGELOG.md; full history)
```

The file order in the tarball is canonical (matches
`.release/mirror.pdxmeta`'s `tar_layout` verbatim) so the BLAKE3
hash inside the signed manifest is reproducible from a fresh source
tree at the tagged commit.

## Substrate gap (documented, not yet closed)

The network + bot path (steps 3-4 above) stands up under
T-INFRA-001 (dual-sign package repository infrastructure) and
T-INFRA-002 (signing bot host + policy for paideia_root_pk), both
scheduled in design/tooling/plan.md §11. Until they land, rm 1.0.0
is `author-signed-only` and `pkg install` requires
`--from-source` (D4 trust-zero fallback). `.release/mirror.pdxmeta`
[status] block tracks this transition.

The rm-side of every step is complete at M5-002 — the metadata,
canonical file order, verification policy, and installation layout
are all decided. When the infra lands, no rm-side change is
required.

## Version bump procedure

For a 1.0.x patch (bugfix; no schema change):
1. Edit `manifest.pdxproj` version, `doc/rm.pdxdoc` `@version` +
   `@since`, `.release/mirror.pdxmeta` `version`, and prepend a new
   `CHANGELOG.md` section.
2. `git tag v1.0.x`; re-run steps 2-5 above.

For a 1.x.0 minor (new feature; backward-compatible): same as
patch. RemoveRecord schema changes are a 2.0.0 major bump per
design/tooling/plan.md §D2 (schema versioning).
