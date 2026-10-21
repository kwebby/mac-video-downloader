# Chrome companion packaging

Run `Scripts/package-extension.sh [output-directory]`. The default produces
`build/Chrome Companion/` containing an unpacked `MVD Companion/` runtime, a
runtime-only versioned ZIP, an external installation guide, the explicit per-user
installer/host-registration helper, the packaged ID and SHA-256 checksums. Include
this complete folder beside MVD.app in the DMG. Packaging never installs anything,
registers a native host, reads a Chrome profile or changes an installed extension.

The ZIP uses a reviewed runtime allowlist, sorted entries, fixed timestamps and
permissions, and excludes tests, documentation, package.json, hidden files and
signing material. Its manifest is at the archive root. Repeat builds of identical
inputs with the same Python/zlib toolchain produce identical ZIP bytes. Build-time
Python/OpenSSL are not required to run the packaged macOS installer.
The staged popup footer points users to the external INSTALL.txt instead of
linking to the excluded repository README; the source popup remains unchanged.

`public-key.b64` is a committed DER public key encoded as base64. The packager adds
it **only to the staged manifest**, leaving BrowserExtension/manifest.json and its
existing development install untouched. Chromium derives the 32-character ID from
the first 16 bytes of the public-key SHA-256 digest, mapping hex nibbles to a–p.
The original keypair was generated only to obtain this public identity; its private
half was discarded in memory and is neither stored nor needed for unpacked loads.
This package intentionally creates no CRX and cannot sign a matching CRX later.
The public key does not authenticate an unpacked folder or approve its behavior.

The existing source manifest had no key. Its path-derived developer ID cannot be
retained by inventing a new public key. Leave that development install unchanged;
the user explicitly re-pairs the packaged ID when running the installer. The
current native host accepts exactly one allowed origin and validates the registered
absolute host executable path. Packaging does not modify that native behavior.

For a future store edition, first establish the actual permitted scope, obtain its
public key/ID through the developer dashboard and reconcile it with the packaged
identity and host pairing. Do not publish or silently change this asset during a
routine packaging run. Do not extract keys or Chrome-private profile material.

Chrome consumer macOS distribution is store-hosted/signed; the development route
requires explicit Load unpacked. Enterprise-managed distribution is a distinct
deployment category and is not used by this installer. A local CRX is deliberately
not presented as an installable consumer alternative.

Sources: [Chrome distribution](https://developer.chrome.com/docs/extensions/how-to/distribute),
[alternative installation rules](https://developer.chrome.com/docs/extensions/how-to/distribute/install-extensions),
[public manifest key](https://developer.chrome.com/docs/extensions/reference/manifest/key),
[Chromium ID algorithm](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/crx_file/id_util.cc),
[Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).
