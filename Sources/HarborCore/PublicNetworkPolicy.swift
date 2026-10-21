import Foundation
import Darwin

public enum PublicNetworkPolicy {
    private static let blockedDomains = ["youtube.com", "youtu.be", "youtube-nocookie.com", "googlevideo.com", "ytimg.com", "youtube.googleapis.com"]

    public static func validate(_ raw: String, allowVideoProviders: Bool = false) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= 8192,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let hostValue = components.host, let url = components.url else { throw PublicNetworkPolicyError.invalidURL }
        let host = hostValue.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard allowVideoProviders || !blockedDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { throw PublicNetworkPolicyError.unsupportedProvider }
        guard host.contains("."), !["localhost", "local", "internal", "invalid", "test", "example", "home.arpa"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              components.port == nil || (components.port! > 0 && components.port! <= 65535) else { throw PublicNetworkPolicyError.privateAddress }
        // DNS is checked again at the handoff boundary. The transfer layer must separately
        // enforce address policy for every redirect and nested resource (see README).
        try validateResolvedAddresses(host)
        return url.absoluteString
    }

    private static func validateResolvedAddresses(_ host: String) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { throw PublicNetworkPolicyError.dnsUnavailable }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var checked = false
        while let entry = cursor {
            let info = entry.pointee
            if info.ai_family == AF_INET, let address = info.ai_addr {
                let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let bytes = withUnsafeBytes(of: value) { Array($0) }
                guard isPublicIPv4(bytes) else { throw PublicNetworkPolicyError.privateAddress }
                checked = true
            } else if info.ai_family == AF_INET6, let address = info.ai_addr {
                let value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: value) { Array($0) }
                // Conservatively allow IPv6 global-unicast only; exclude documentation,
                // transition and embedded-address ranges to avoid private-address aliases.
                guard bytes.count == 16, (bytes[0] & 0xe0) == 0x20,
                      !(bytes[0] == 0x20 && bytes[1] == 0x01 && (bytes[2] < 0x02 || (bytes[2] == 0x0d && bytes[3] == 0xb8))),
                      !(bytes[0] == 0x20 && bytes[1] == 0x02),
                      !(bytes[0] == 0x3f && bytes[1] == 0xff) else { throw PublicNetworkPolicyError.privateAddress }
                checked = true
            } else { throw PublicNetworkPolicyError.privateAddress }
            cursor = info.ai_next
        }
        guard checked else { throw PublicNetworkPolicyError.dnsUnavailable }
    }

    static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1], c = bytes[2]
        return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
            (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) ||
            (a == 172 && (16...31).contains(b)) ||
            (a == 192 && (b == 168 || b == 0 || (b == 88 && c == 99))) ||
            (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
            (a == 203 && b == 0 && c == 113))
    }
}

public enum PublicNetworkPolicyError: LocalizedError {
    case invalidURL, unsupportedProvider, privateAddress, dnsUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Only public HTTP and HTTPS URLs without embedded credentials are supported."
        case .unsupportedProvider: return "YouTube downloads are outside this Chrome companion’s scope."
        case .privateAddress: return "Private, local and reserved network destinations are unavailable in the companion."
        case .dnsUnavailable: return "The source hostname could not be verified. Check the URL and network connection."
        }
    }
}
