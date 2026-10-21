import Foundation

enum NativeMessageError: Error {
    case truncatedFrame, invalidLength, invalidJSON, invalidRequest, unregisteredOrigin, unavailableBroker
}

/// Chrome uses a native-endian UInt32 byte length. All supported Macs are little-endian.
enum NativeMessageFraming {
    static let maximumBytes = 256 * 1024

    static func read(from input: FileHandle) throws -> Data? {
        guard let header = try readExactly(4, from: input, allowEOF: true) else { return nil }
        let length = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
        guard length > 0, length <= maximumBytes else { throw NativeMessageError.invalidLength }
        guard let payload = try readExactly(Int(length), from: input, allowEOF: false) else { throw NativeMessageError.truncatedFrame }
        return payload
    }

    static func write<T: Encodable>(_ value: T, to output: FileHandle) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count > 0, payload.count <= maximumBytes else { throw NativeMessageError.invalidLength }
        let count = UInt32(payload.count)
        let prefix = Data((0..<4).map { UInt8((count >> ($0 * 8)) & 0xff) })
        try output.write(contentsOf: prefix + payload)
    }

    private static func readExactly(_ count: Int, from input: FileHandle, allowEOF: Bool) throws -> Data? {
        var buffer = Data()
        while buffer.count < count {
            guard let chunk = try input.read(upToCount: count - buffer.count), !chunk.isEmpty else {
                if allowEOF && buffer.isEmpty { return nil }
                throw NativeMessageError.truncatedFrame
            }
            buffer.append(chunk)
        }
        return buffer
    }
}
