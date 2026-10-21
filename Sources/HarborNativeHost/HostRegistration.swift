import Foundation
import HarborCore

enum HostRegistration {
    @discardableResult
    static func validateCaller(arguments: [String] = CommandLine.arguments, registrationURL: URL = ChromeCompanionConnection.registrationURL) throws -> String {
        guard arguments.count == 2, let caller = normalizedOrigin(arguments[1]) else { throw NativeMessageError.unregisteredOrigin }
        let manifest = try ChromeCompanionConnection.readRegistration(at: registrationURL)
        let executable = URL(fileURLWithPath: arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        guard manifest.name == "io.harbor.downloads", manifest.type == "stdio",
              manifest.path.hasPrefix("/"),
              URL(fileURLWithPath: manifest.path).standardizedFileURL.resolvingSymlinksInPath().path == executable,
              manifest.allowed_origins.count == 1,
              manifest.allowed_origins.compactMap(normalizedOrigin).contains(caller) else { throw NativeMessageError.unregisteredOrigin }
        return caller
    }

    private static func normalizedOrigin(_ raw: String) -> String? {
        ChromeCompanionConnection.normalizedOrigin(raw)
    }
}
