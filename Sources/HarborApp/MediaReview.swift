import AppKit
import Foundation
import HarborCore
import ImageIO
import SwiftUI

/// Saved audio uses an audio mark rather than the original video's poster.
struct DownloadArtwork: View {
    let job: DownloadJob
    let width: CGFloat
    let height: CGFloat
    let proxyURL: String?
    var isSelected = false
    var hasPlaybackOverlay = false

    var body: some View {
        if job.isAudio {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.white.opacity(0.12) : Color.accentColor.opacity(0.10))
                Image(systemName: "waveform")
                    .font(.system(size: min(52, height * 0.52), weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: hasPlaybackOverlay && height < 60 ? .leading : .center)
                    .padding(.leading, hasPlaybackOverlay && height < 60 ? 5 : 0)
            }
            .frame(width: width, height: height)
            .accessibilityLabel("Audio file")
        } else if job.kind == .media || job.isVideo {
            MediaThumbnail(url: job.thumbnailURL, width: width, height: height, title: job.displayTitle, proxyURL: proxyURL)
        } else {
            Image(systemName: job.fileSymbol)
                .font(.system(size: min(34, height * 0.62), weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: width, height: height)
        }
    }
}

/// The artwork itself is the playback target in both the library and inspector.
struct PlayableDownloadArtwork: View {
    let job: DownloadJob
    let width: CGFloat
    let height: CGFloat
    let proxyURL: String?
    var isSelected = false
    var isOpening = false
    let onPlay: () -> Void
    @ViewState private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var badgeSize: CGFloat { min(48, max(20, height - 6)) }
    private var isActive: Bool { !isOpening && (isHovered || isFocused) }

    var body: some View {
        if job.canPlay {
            Button(action: onPlay) {
                DownloadArtwork(job: job, width: width, height: height, proxyURL: proxyURL, isSelected: isSelected, hasPlaybackOverlay: true)
                    .accessibilityHidden(true)
                    .overlay(alignment: job.isAudio ? .bottomTrailing : .center) {
                        ZStack {
                            Circle().fill(.black.opacity(isActive ? 0.76 : 0.46))
                            Circle().strokeBorder(.white.opacity(isActive ? 0.95 : 0.62), lineWidth: isActive ? 1.5 : 1)
                            if isOpening {
                                ProgressView()
                                    .controlSize(height < 60 ? .mini : .small)
                                    .tint(.white)
                                    .environment(\.colorScheme, .dark)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: badgeSize * 0.40, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .offset(x: badgeSize * 0.025)
                            }
                        }
                        .frame(width: badgeSize, height: badgeSize)
                        .shadow(color: .black.opacity(isActive ? 0.30 : 0.16), radius: isActive ? 6 : 3, y: 2)
                        .scaleEffect(isActive && !reduceMotion ? 1.06 : 1)
                        .padding(job.isAudio ? (height < 60 ? 2 : 12) : 0)
                        .accessibilityHidden(true)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(isFocused ? Color.accentColor : Color.white.opacity(isActive ? 0.28 : 0), lineWidth: isFocused ? 2 : 1)
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isActive)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(PlaybackArtworkButtonStyle())
            .focused($isFocused)
            .onHover { isHovered = $0 }
            .disabled(isOpening)
            .help(isOpening ? "Opening…" : job.isAudio ? "Preview audio" : "Open video in your default app")
            .accessibilityLabel("Play \(job.isAudio ? "audio" : "video"): \(job.displayTitle)")
            .accessibilityValue(isOpening ? "Opening" : "")
        } else {
            DownloadArtwork(job: job, width: width, height: height, proxyURL: proxyURL, isSelected: isSelected)
        }
    }
}

private struct PlaybackArtworkButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/// A bounded thumbnail view shared by URL review, the library, and the inspector.
struct MediaThumbnail: View {
    let url: String?
    let width: CGFloat
    let height: CGFloat
    var title: String? = nil
    let proxyURL: String?
    @ViewState private var thumbnail: NSImage?
    @ViewState private var loading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.55))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else if loading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "film")
                    .font(.system(size: min(24, height * 0.38), weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(thumbnail == nil ? "Video thumbnail unavailable" : "Thumbnail\(title.map { " for \($0)" } ?? "")")
        .task(id: "\(url ?? "")|\(proxyURL ?? "")") {
            thumbnail = nil
            // Do not leak image requests around the selected media proxy.
            guard proxyURL == nil else { loading = false; return }
            guard let url, ThumbnailFetcher.validURL(url) != nil else { loading = false; return }
            loading = true
            let loaded = await ThumbnailCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            thumbnail = loaded
            loading = false
        }
    }
}

@MainActor private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let images = NSCache<NSString, NSImage>()

    private init() {
        images.countLimit = 150
        images.totalCostLimit = 24 * 1024 * 1024
    }

    func image(for raw: String) async -> NSImage? {
        if let cached = images.object(forKey: raw as NSString) { return cached }
        guard let data = try? await ThumbnailFetcher.data(for: raw), !Task.isCancelled else { return nil }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
        }.value
        guard let image, !Task.isCancelled else { return nil }
        images.setObject(image, forKey: raw as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

private enum ThumbnailFetcher {
    static let maximumBytes = 5 * 1024 * 1024

    static func validURL(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let host = components.host, !host.isEmpty else { return nil }
        return components.url
    }

    static func data(for raw: String) async throws -> Data {
        guard let url = validURL(raw) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        _ = try await Task.detached { try PublicNetworkPolicy.validate(raw, allowVideoProviders: true) }.value
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: ThumbnailRedirectPolicy())
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = response.url, validURL(finalURL.absoluteString) != nil,
              response.mimeType?.lowercased().hasPrefix("image/") == true,
              response.expectedContentLength <= Int64(maximumBytes) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            if data.count >= maximumBytes { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}

private final class ThumbnailRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url,
              !(response.url?.scheme == "https" && target.scheme == "http"),
              (try? PublicNetworkPolicy.validate(target.absoluteString, allowVideoProviders: true)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct MediaPreviewCard: View {
    let preview: MediaPreview
    let sourceURL: String
    @Binding var qualityID: String
    var showsQuality = true
    let proxyURL: String?
    @AppAppearance private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 13) {
                MediaThumbnail(url: preview.thumbnailURL, width: 112, height: 68, title: preview.title, proxyURL: proxyURL)
                VStack(alignment: .leading, spacing: 5) {
                    Text(preview.title.isEmpty ? sourceURL : preview.title)
                        .harborFont(.headline)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(URL(string: sourceURL)?.host ?? sourceURL).lineLimit(1)
                        if let duration = Format.duration(preview.duration) {
                            Text(duration).monospacedDigit()
                        }
                    }
                    .harborFont(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if showsQuality && !preview.isDirectFile {
                HStack {
                    Label("Video quality", systemImage: "slider.horizontal.3")
                        .harborFont(.callout)
                    Spacer()
                    Picker("Video quality", selection: $qualityID) {
                        ForEach(preview.qualities) { quality in Text(quality.label).tag(quality.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 235)
                    .accessibilityIdentifier("videoQualityPicker")
                }
                Text("Choose from the qualities available for this video.")
                    .harborFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .background(appearance.surfaceColor, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary) }
    }
}
