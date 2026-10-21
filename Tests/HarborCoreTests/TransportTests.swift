import XCTest
import Darwin
@testable import HarborCore

final class TransportTests: XCTestCase {
    func testFramingRoundTripsUnicodeAndSeparateMessages() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { Darwin.close($0) } }
        let first = Data("A filename — 日本語.mp4".utf8)
        let second = Data("second command".utf8)
        try LocalTransport.writeFrame(first, to: pair[0])
        try LocalTransport.writeFrame(second, to: pair[0])
        XCTAssertEqual(try LocalTransport.readFrame(pair[1]), first)
        XCTAssertEqual(try LocalTransport.readFrame(pair[1]), second)
    }

    func testOversizedFrameRejectedBeforePayloadRead() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { Darwin.close($0) } }
        var length = UInt32(LocalTransport.maximumFrameBytes + 1).littleEndian
        withUnsafeBytes(of: &length) { bytes in _ = Darwin.write(pair[0], bytes.baseAddress, bytes.count) }
        XCTAssertThrowsError(try LocalTransport.readFrame(pair[1]))
    }

    func testTruncatedFrameRejected() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { Darwin.close($0) } }
        var length: UInt32 = 9
        withUnsafeBytes(of: &length) { bytes in _ = Darwin.write(pair[0], bytes.baseAddress, bytes.count) }
        shutdown(pair[0], SHUT_WR)
        XCTAssertThrowsError(try LocalTransport.readFrame(pair[1]))
    }

    func testUnixSocketLengthCheckedWithoutTruncation() throws {
        XCTAssertNoThrow(try LocalTransport.address(path: "/tmp/harbor.sock"))
        XCTAssertThrowsError(try LocalTransport.address(path: String(repeating: "a", count: 200)))
    }

    func testJobIntentSurvivesWireEncoding() throws {
        let input = BrokerRequest(command: .enqueue, url: "https://example.com/video?token=a%2Fb", idempotencyKey: "replay-1", kind: .automatic)
        let decoded = try JSONDecoder().decode(BrokerRequest.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(decoded.url, input.url)
        XCTAssertEqual(decoded.idempotencyKey, "replay-1")
        XCTAssertEqual(decoded.requestID, input.requestID)
    }
}
