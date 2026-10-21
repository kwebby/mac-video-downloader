# MVD acceleration: implementation and qualification

Reviewed against the source and primary references on 21 October 2026. The bolt enables bounded parallel transfer work. It does not raise the bandwidth of a connection, bypass source limits, or promise a fixed speed multiplier.

## Research basis

HTTP servers may ignore Range requests. An `Accept-Ranges` advertisement does not guarantee that a later request will return the requested bytes. `If-Range` permits a range only while its validator still matches; a changed representation can produce a complete response instead. Weak entity tags cannot be used in `If-Range`. These semantics motivate the conservative checks below. [RFC 9110 §14.2–14.4](https://www.rfc-editor.org/rfc/rfc9110.html#section-14.2), [RFC 9110 §13.1.5](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.5).

For segmented media, yt-dlp documents `--concurrent-fragments` for DASH and its native HLS downloader; its default is one. MVD requests additional concurrent fragments only when acceleration is enabled. The flag does not make every provider/protocol parallel. [yt-dlp download options](https://github.com/yt-dlp/yt-dlp#download-options).

libcurl's multi interface offers concurrent, application-driven transfers, including event-based integration. It remains a possible future transport backend. MVD's current direct implementation uses URLSession; it does not use libcurl multi or claim its APIs as shipped functionality. [libcurl multi interface overview](https://curl.se/libcurl/c/libcurl-multi.html).

## Direct-file algorithm in v0.3

The source of truth is [SegmentedDirectTransfer.swift](../Sources/HarborEngine/SegmentedDirectTransfer.swift), with ordinary transfer fallback in [DirectTransfer.swift](../Sources/HarborEngine/DirectTransfer.swift).

1. An accelerated desktop direct job first performs a real GET with `Range: bytes=0-0` and `Accept-Encoding: identity`. It does not rely on HEAD or an advertisement alone.
2. The probe must return HTTP 206, an exact `Content-Range` of byte 0 through byte 0, a known total of at least 4 MiB, identity content encoding, a quoted strong ETag, and exactly one received body byte. HTML responses are ineligible. Missing/weak validators, small files, unsupported responses, or an unsuccessful probe select the ordinary fresh download.
3. After a valid probe, the current implementation divides the known total into at most four contiguous, non-overlapping intervals. Each request uses the probe's final URL, identity encoding, its exact Range, and the same ETag in `If-Range`.
4. Before accepting a part, the response must be HTTP 206 and match that interval's start/end, the original total, encoding, ETag, and any reported content length. A part cannot write more than its assigned byte count. Writes are serialized into the app-owned staging file at the part's assigned offset.
5. All parts must complete with exactly their expected byte counts, and their total must equal the representation length before publication. Existing destination files are protected by the normal no-clobber publisher.

Part redirects or failed representation/range checks cancel the group, discard the entire segmented staging file, and allow an ordinary full GET to start afresh. Thus a `200` response to an ignored range or a changed ETag is never treated as a valid part. Probe errors also fall back. Cancellation remains cancellation; ordinary part network/storage errors fail the attempt rather than being universally hidden by automatic fallback. The normal worker still checks the response and its expected length.

Probe redirects are limited and must remain valid HTTP(S) destinations without an HTTPS-to-HTTP downgrade. Part redirects trigger fresh full-download fallback rather than carrying assumptions about the probed representation across a redirect. Browser-initiated direct-file handoffs currently skip this segmented path and use the ordinary worker with the companion's public-network checks.

## Queue and media budgets

[DownloadService.swift](../Sources/HarborEngine/DownloadService.swift) assigns a logical transfer reservation of one to ordinary jobs and four to accelerated jobs. The queue starts workers only while both the configured simultaneous-job count and an eight-unit broker budget permit them. Two accelerated jobs can therefore reserve all eight units even if a source ultimately falls back to one full response. Jobs retain queue order when the next reservation cannot fit.

For media, [MediaTransfer.swift](../Sources/HarborEngine/MediaTransfer.swift) passes the reservation as `--concurrent-fragments`; the broker currently supplies four for accelerated jobs and one otherwise. yt-dlp manages fragments, retries, assembly, and compatible partial-file reuse. FFmpeg remux/conversion remains processing work after acquisition.

The eight-unit accounting is a scheduler policy, not an exact count of all operating-system sockets. URLSession may multiplex requests; yt-dlp may perform metadata, audio/video, and provider requests beyond the fragment setting. Preview concurrency and thumbnail payload/cache sizes have separate bounds; they do not implement a global byte-rate limiter.

## Pause, edits, proxies, and limits

- Direct resume deliberately restarts from byte zero. This release does not persist a validator-backed interval map across pause, process restart, or network failure.
- Enabling/disabling acceleration for an active download explicitly restarts it. Paused jobs remain paused. Changing output options discards incompatible partial data; editing a completed job creates a new download copy.
- A configured media proxy is passed to the media tools. Direct downloads reject configured proxies instead of making a direct connection around them. Ranged direct proxies/authenticated sessions remain future work.
- One-file acceleration cannot fix a saturated connection, server-wide/account-wide rate limits, source throttling, slow disks, or expensive FFmpeg work. Extra requests can add latency and overhead. The 4 MiB threshold and four-part ceiling are conservative implementation choices, not universal optimal settings.
- More adaptive scheduling, per-origin fairness/backoff, durable range resume, network-condition measurements, direct proxy support, and broader HTTP/CDN qualification remain separate work.

## Executable coverage

[Integration case 12](../Tests/Integration/downloads.py) runs against a local owned 4 MiB HTTP fixture. It verifies multiple validated range requests with `If-Range`, overlapping server-side request lifetimes, and final byte-for-byte identity. Additional fixture variants ignore ranges after the probe, change the body/ETag after probing, or offer only a weak/malformed ETag; each must use an ordinary full request and publish the correct complete body. Case 13 updates a paused job's options/destination and verifies a fresh complete result. Existing cases exercise truncation, pause/restart, queue concurrency, and durable history.

These checks establish the exercised local behaviors, not an Internet throughput benchmark or exhaustive protocol/server compatibility. They do not currently quantify a speed multiplier, assert an exact process-wide socket ceiling, or independently benchmark media-fragment throughput. Run `python3 Tests/Integration/downloads.py` and inspect failures/skips to qualify the current checkout.
