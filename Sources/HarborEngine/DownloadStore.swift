import Foundation
import CSQLite
import HarborCore

/// The broker is the only writer. Every acceptance and control change is committed
/// before its acknowledgement is returned to a client.
final class DownloadStore {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw EngineError.storage("Could not open the download database.")
        }
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, idempotency_key TEXT NOT NULL UNIQUE, data BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY CHECK(id=1), data BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS retired_requests (idempotency_key TEXT PRIMARY KEY, data BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY, data BLOB NOT NULL)")
    }

    deinit { sqlite3_close(db) }

    func loadJobs() throws -> [DownloadJob] {
        let statement = try prepare("SELECT data FROM jobs")
        defer { sqlite3_finalize(statement) }
        var jobs: [DownloadJob] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            jobs.append(try decoder.decode(DownloadJob.self, from: blob(statement, column: 0)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return jobs
    }

    func loadSettings() throws -> DownloadSettings? {
        let statement = try prepare("SELECT data FROM settings WHERE id=1")
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return try decoder.decode(DownloadSettings.self, from: blob(statement, column: 0))
        case SQLITE_DONE: return nil
        default: throw databaseError()
        }
    }

    func save(_ job: DownloadJob) throws {
        let data = try encoder.encode(job)
        let statement = try prepare("INSERT INTO jobs(id,idempotency_key,data) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, job.id.uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, job.idempotencyKey, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func save(_ settings: DownloadSettings) throws {
        let data = try encoder.encode(settings)
        let statement = try prepare("INSERT INTO settings(id,data) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data")
        defer { sqlite3_finalize(statement) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func delete(_ id: UUID) throws {
        // Keep the accepted identity when history is removed. A delayed native
        // messaging retry must not recreate an explicitly removed download.
        let retire = try prepare("INSERT OR IGNORE INTO retired_requests(idempotency_key,data) SELECT idempotency_key,data FROM jobs WHERE id=?")
        defer { sqlite3_finalize(retire) }
        sqlite3_bind_text(retire, 1, id.uuidString, -1, transient)
        guard sqlite3_step(retire) == SQLITE_DONE else { throw databaseError() }
        let statement = try prepare("DELETE FROM jobs WHERE id=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func retiredRequest(_ key: String) throws -> DownloadJob? {
        let statement = try prepare("SELECT data FROM retired_requests WHERE idempotency_key=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return try decoder.decode(DownloadJob.self, from: blob(statement, column: 0))
        case SQLITE_DONE: return nil
        default: throw databaseError()
        }
    }

    func loadFolders() throws -> [DownloadFolder] {
        let statement = try prepare("SELECT data FROM folders")
        defer { sqlite3_finalize(statement) }
        var folders: [DownloadFolder] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            folders.append(try decoder.decode(DownloadFolder.self, from: blob(statement, column: 0)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return folders
    }

    func save(_ folder: DownloadFolder) throws {
        let data = try encoder.encode(folder)
        let statement = try prepare("INSERT INTO folders(id,data) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, folder.id.uuidString, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func removeFolder(_ id: UUID, detaching jobs: [DownloadJob]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for job in jobs { try save(job) }
            let statement = try prepare("DELETE FROM folders WHERE id=?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id.uuidString, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func blob(_ statement: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func databaseError() -> EngineError {
        // SQL and bound fields can contain private URLs, so never expose raw data.
        .storage("The download database could not be updated (SQLite \(sqlite3_errcode(db))). Check free disk space and folder permissions.")
    }
}

enum EngineError: LocalizedError {
    case invalid(String), storage(String), unavailable(String), transfer(String), cancelled
    var errorDescription: String? {
        switch self {
        case let .invalid(message), let .storage(message), let .unavailable(message), let .transfer(message): return message
        case .cancelled: return "The download was stopped."
        }
    }
}
