import Foundation

@main
struct FramingHarness {
    struct Sample: Codable, Equatable { let title: String }
    static func require(_ condition: Bool, _ reason: String) {
        if !condition { fatalError(reason) }
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("frames")
        FileManager.default.createFile(atPath: location.path, contents: nil)
        let output = try FileHandle(forWritingTo: location)
        let samples = [Sample(title: "MVD 🌊"), Sample(title: "Second frame")]
        for sample in samples { try NativeMessageFraming.write(sample, to: output) }
        try output.close()
        let input = try FileHandle(forReadingFrom: location)
        for sample in samples {
            let frame = try NativeMessageFraming.read(from: input)
            let actual = try JSONDecoder().decode(Sample.self, from: frame!)
            require(actual == sample, "UTF-8 byte length or consecutive-frame handling failed")
        }
        let eof = try NativeMessageFraming.read(from: input)
        require(eof == nil, "Clean EOF should terminate normally")
        try input.close()
        for malformed in [Data([1, 0]), Data([4, 0, 0, 0, 123]), Data([0, 0, 0, 0]), Data([0, 0, 8, 0])] {
            try malformed.write(to: location)
            let handle = try FileHandle(forReadingFrom: location)
            var rejected = false
            do { _ = try NativeMessageFraming.read(from: handle) } catch { rejected = true }
            try handle.close()
            require(rejected, "Truncated, zero or oversized frame was accepted")
        }
        for url in ["https://youtube.com/watch?v=x", "https://r1.googlevideo.com/a", "file:///etc/passwd", "http://localhost/a", "http://192.168.0.1/a", "http://127.0.0.1/a", "http://100.64.0.1/a", "http://169.254.169.254/a", "http://[::1]/a", "http://203.0.113.1/a", "https://name:secret@public-site.com/a"] {
            var rejected = false
            do { _ = try PublicNetworkPolicy.validate(url) } catch { rejected = true }
            require(rejected, "Browser-source URL policy accepted a prohibited/private target")
        }
        print("Native message framing: Unicode, consecutive frames, EOF, truncation and size limits passed.")
        print("Browser-source policy: prohibited domains, credentials, unsupported schemes, private/reserved addresses passed.")
    }
}
