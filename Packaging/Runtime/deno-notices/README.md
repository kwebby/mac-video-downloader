# Deno 2.9.5 third-party notices

This directory accompanies the official Deno 2.9.5 runtime. It contains exact
legal texts extracted from all **1,051 registry archives** in the release's
Cargo.lock, with every archive verified against its locked SHA-256 checksum.
No code from these archives was executed. Archives are cached outside this notice
directory in Packaging/Runtime/cache/deno-crates; no repository clone/build was used.

Source tag: https://github.com/denoland/deno/tree/v2.9.5
Source commit: 17fadf33a8df3af9488b9f42efd1f2290d6dc7a3

## Included material

- `THIRD_PARTY_NOTICES.txt`: aggregate of exact crate/upstream legal texts and
  clearly identified copyright-header excerpts. Original files are also retained.
- `crate-inventory.json`: all locked registry names/versions, source archive URLs,
  verified checksums, Cargo license/authors/repository declarations and file hashes.
- `crates/`: original Cargo.toml/Cargo.toml.orig/VCS metadata plus legal text files.
- `upstream/` and `upstream-provenance.json`: 78 exact supplemental
  texts from pinned repositories, including Deno, rusty_v8/V8, ICU, SIMDUTF,
  Abseil, FP16, TypeScript, Node type declarations and Undici declarations.
- `supplemental-standard-texts/`: standard SPDX/LLVM/native license texts, with
  source URLs/hashes in supplemental-provenance.json. Current-branch native
  supplements are labeled; they are not falsely presented as pinned source proof.
- `source-copyrights/`: source copyright/SPDX excerpts where a published crate
  omitted a standalone legal file; its checked archive/member identity is retained.
- `source-metadata/`: exact release Cargo.lock and component metadata, including
  the pinned Rusty V8 native-submodule tree.

## Coverage and actual gaps

All 1,051 registry archive checksums passed; **zero download/checksum errors**.
933 archives supply standalone legal notices.
The rest were supplemented from their declared repositories when obtainable.
**52 packages still omit a recoverable standalone project notice** at the
published archive/pinned root paths; `gaps.json` names every one with its declared
license, authors and source revision. Their declaration and applicable standard
license text remain included. A standard license template does not invent a
missing project copyright or establish that a historically unavailable NOTICE
never existed; this residual distinction must remain visible.

This is deliberately a conservative whole-lock collection: target-specific,
build-only, test-only and unused feature crates may be listed. It is not a
binary-derived link map or a legal-compliance certification. The release provides
no aggregate official third-party notice asset to substitute for this work.
V8 native subcomponent provenance is recorded separately. The Node v24.0.0 aggregate
license is additional overinclusive reference material, not a claim that Deno's
Node-derived files all originate in that single Node release.

Keep the entire directory with the redistributed runtime, or include the aggregate,
README, inventory and gaps alongside the DMG with the detailed source collection.
Do not describe MIT-only Deno-LICENSE.md as covering all third-party components.
