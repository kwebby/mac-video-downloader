# Bundled Python notices

These notices come from Astral's official Python Build Standalone release
`20261020`, CPython `3.14.8`, target `aarch64-apple-darwin`, ordinary
`pgo+lto` build. This is the full archive corresponding to the non-freethreaded
`install_only_stripped` runtime selected in `../portable-tools.lock.json`.

The full archive and runtime archive URLs, sizes, and release-provided SHA-256
digests are recorded in `provenance.lock.json`. Both downloaded archives were
checked against those digests. The full and install-only archives also have
byte-identical `lib/python3.14/LICENSE.txt` and
`lib/python3.14/_sysconfigdata__darwin_darwin.py`; their digests are recorded in
`license-report.json`.

`PYTHON.json` is copied without modification from the full archive. Its
`license_path` and extension-module `license_paths` fields identify exactly the
15 files retained in `licenses/`. Those files are copied verbatim; the report
records their sizes, SHA-256 digests, metadata locations, license identifiers,
and link records. No interpreter binaries or build objects are extracted here.
The cached source archive stays outside this notices directory.

The notices cover CPython and the dependencies named by this build's metadata:
bzip2, libffi, ncurses, mpdecimal, OpenSSL 3, liblzma, SQLite, zlib and zlib-ng,
Tcl, libuuid, zstd, Expat, and libedit. Some links are system libraries in this
macOS build; the original upstream declarations and notices are preserved.
The `readline` extension names system `libedit` with `BSD-3-Clause`; this
archive's declared notices do not name GNU Readline or a GPL license.

These files supplement the CPython license already present in the installed
runtime. Upstream's metadata-referenced `LICENSE.cpython.txt` differs from the
installed `lib/python3.14/LICENSE.txt`; preserve both rather than replacing the
installed file with the metadata notice. If Python's bundled `pip` is retained in the app, retain its own
`pip-*.dist-info/licenses/` files as well. This directory does not replace
the notices in separately installed yt-dlp or EJS distributions.

Upstream archive format and metadata documentation:
https://github.com/astral-sh/python-build-standalone/blob/20261020/docs/distributions.rst

Official matching release:
https://github.com/astral-sh/python-build-standalone/releases/tag/20261020
