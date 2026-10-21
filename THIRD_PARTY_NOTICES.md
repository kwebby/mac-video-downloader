# Third-party software and source materials

The repository's first-party MVD license does not replace the licenses of third-party software or the original notices retained in this repository and its binary distributions. Those components remain available under their respective terms. Restrictions on MVD-authored code do not restrict rights granted by third-party licenses, including rights to modify or redistribute GPL components and to debug modifications to LGPL library components.

MVD invokes its media-provider and processing tools as separate programs. This document is an index of the actual pinned release inputs and retained notices; it is not a statement that every dependency has the same license or a legal-compliance certification.

## Media-processing tools

| Component | Pinned version | Retained license declaration |
| --- | --- | --- |
| FFmpeg and FFprobe | 9.0.2 | LGPL-2.1-or-later; this build disables GPL, nonfree and version3 components |
| LAME | 4.0 | LGPL-2.0-or-later |
| Opus | 1.6.1 | BSD-3-Clause and upstream patent notices |

See [media notices](Packaging/Runtime/MEDIA-NOTICES.md), the [source checksum lock](Packaging/Runtime/media-sources.lock), and [build instructions](Packaging/Runtime/README.md). The release's `MVD-media-sources-9.0.2-arm64.tar.gz` contains the exact unmodified source archives, original license texts, build scripts and configuration reports. These materials accompany the tools in the DMG. Preserve them when redistributing the tools. FFmpeg contains IJG-derived code: this software is based in part on the work of the Independent JPEG Group.

## Python interpreter and provider packages

The runtime uses CPython 3.14.8 from Python Build Standalone release 20261020. Its own licenses and those of its interpreter dependencies are distinct from MVD's first-party terms. [Python notices](Packaging/Runtime/python-notices/README.md), [unmodified upstream metadata](Packaging/Runtime/python-notices/PYTHON.json), [license inventory](Packaging/Runtime/python-notices/license-report.json), and [archive provenance](Packaging/Runtime/python-notices/provenance.lock.json) identify the exact retained texts. Preserve both the installed CPython license and its separate metadata-referenced notice.

The package versions below come from [media-requirements.txt](Scripts/media-requirements.txt), with exact wheel hashes in [python-wheels.lock.json](Packaging/Runtime/python-wheels.lock.json). License declarations were read from those installed wheel metadata records. Original notices remain in each package's `.dist-info` directory inside `MVD.app/Contents/Resources/Tools/Python/lib/python3.14/site-packages/`. Packaging also gathers notices under `MVD.app/Contents/Resources/Licenses/`; PyCryptodomex's original `LICENSE.rst` and `AUTHORS.rst` are retained at its installed `.dist-info` path.

| Python package | Version | Declared license |
| --- | --- | --- |
| brotli | 1.2.0 | MIT |
| certifi | 2026.10.19 | MPL-2.0 |
| charset-normalizer | 3.5.2 | MIT |
| idna | 3.20 | BSD-3-Clause |
| mutagen | 1.48.1 | GPL-2.0-or-later |
| pycryptodomex | 3.24.1 | BSD and public-domain notices |
| requests | 2.34.2 | Apache-2.0 |
| urllib3 | 2.8.0 | MIT |
| websockets | 17.3 | BSD-3-Clause |
| yt-dlp | 2026.8.19 | Unlicense |
| yt-dlp-ejs | 0.8.0 | Unlicense AND MIT AND ISC |

The release's additional `MVD-Mutagen-1.48.1-source.zip` preserves the exact unmodified PyPI source distribution, its GPL notice and build/packaging inputs, provenance and SHA-256 record. The installed provider runtime also retains Mutagen's Python source modules. MVD's reserved-rights terms do not apply to Mutagen or narrow its GPL permissions.

## Deno JavaScript runtime

Deno 2.9.5's project license is [MIT](Packaging/Runtime/deno-LICENSE.md); its dependency collection contains additional licenses. The [Deno notice index](Packaging/Runtime/deno-notices/README.md), [aggregate notices](Packaging/Runtime/deno-notices/THIRD_PARTY_NOTICES.txt), [crate inventory](Packaging/Runtime/deno-notices/crate-inventory.json), and [provenance](Packaging/Runtime/deno-notices/provenance.json) accompany the runtime.

That collection conservatively includes all 1,051 registry archives in the pinned Cargo.lock, including dependencies that may be build-only, target-specific, or unused by the distributed binary. All recorded archive checksums passed. It is not a binary-derived link map. **52 packages still have documented historical project-notice gaps**; [gaps.json](Packaging/Runtime/deno-notices/gaps.json) records those limitations. Standard license templates and supplemental material do not establish that unavailable historical project notices were recovered. Preserve these qualifications alongside the collection.

## Source repository and binary release contents

Runtime downloads, extracted build trees, wheel caches and generated installers are intentionally excluded from source control. Reviewed versions, hashes, source URLs, build scripts, legal texts and provenance records remain in the repository. The packaging scripts download the pinned inputs and verify their hashes; a source checkout does not rely on the original developer's runtime cache.

Binary release notices are inside `MVD.app/Contents/Resources/Licenses/`. The original terms of each bundled component govern that component. When redistributing third-party binaries, preserve their notices and the corresponding source/build materials required by their licenses; this index does not replace those original texts.
