import Foundation
import SQLite3

/// Persistance minimale des jobs pour reprise après interruption.
final class DownloadJobStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let dbURL: URL
    private let lock = NSLock()

    init(directory: URL? = nil) throws {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenStream", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dbURL = base.appendingPathComponent("downloads.sqlite")
        try open()
        try migrate()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func upsert(_ job: DownloadJob) throws {
        lock.lock()
        defer { lock.unlock() }

        let data = try JSONEncoder().encode(job)
        let sql = """
        INSERT INTO jobs (id, updated_at, payload)
        VALUES (?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, payload = excluded.payload;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("prepare upsert")
        }
        defer { sqlite3_finalize(statement) }

        let id = job.id.uuidString as NSString
        let updated = job.updatedAt.timeIntervalSince1970
        sqlite3_bind_text(statement, 1, id.utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, updated)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            sqlite3_bind_blob(statement, 3, base, Int32(data.count), transient)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw storeError("upsert step")
        }
    }

    func loadAll() throws -> [DownloadJob] {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT payload FROM jobs ORDER BY updated_at DESC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("prepare loadAll")
        }
        defer { sqlite3_finalize(statement) }

        var jobs: [DownloadJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(statement, 0) else { continue }
            let size = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: blob, count: size)
            if let job = try? JSONDecoder().decode(DownloadJob.self, from: data) {
                jobs.append(job)
            }
        }
        return jobs
    }

    func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        let sql = "DELETE FROM jobs WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError("prepare delete")
        }
        defer { sqlite3_finalize(statement) }
        let idString = id.uuidString as NSString
        sqlite3_bind_text(statement, 1, idString.utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw storeError("delete step")
        }
    }

    private func open() throws {
        let path = dbURL.path
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw storeError("open \(path)")
        }
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY NOT NULL,
            updated_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "migrate"
            sqlite3_free(errorMessage)
            throw DownloadError.message(message)
        }
    }

    private func storeError(_ context: String) -> DownloadError {
        let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return .message("SQLite \(context): \(message)")
    }
}
