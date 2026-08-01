import Foundation
import SQLite3

public enum PlaylistStoreError: Error, Equatable, Sendable {
    case nameAlreadyExists(String)
    case unavailable(String)
}

public protocol PlaylistStore: Sendable {
    func create(_ playlist: Playlist) async throws
    func commit(_ library: PlaylistLibrary) async throws
    func loadLibrary() async throws -> PlaylistLibrary
    func updateMediaReferences(_ references: [PersistentLocalMediaReference]) async throws
}

public actor UnavailablePlaylistStore: PlaylistStore {
    private let message: String

    public init(message: String) {
        self.message = message
    }

    public func create(_ playlist: Playlist) throws {
        throw PlaylistStoreError.unavailable(message)
    }

    public func commit(_ library: PlaylistLibrary) throws {
        throw PlaylistStoreError.unavailable(message)
    }

    public func loadLibrary() throws -> PlaylistLibrary {
        throw PlaylistStoreError.unavailable(message)
    }

    public func updateMediaReferences(_ references: [PersistentLocalMediaReference]) throws {
        throw PlaylistStoreError.unavailable(message)
    }
}

public actor InMemoryPlaylistStore: PlaylistStore {
    private var library: PlaylistLibrary

    public init(library: PlaylistLibrary = PlaylistLibrary()) {
        self.library = library
    }

    public func create(_ playlist: Playlist) throws {
        library = try library.adding(playlist)
    }

    public func commit(_ library: PlaylistLibrary) throws {
        try library.validateUniqueNames()
        self.library = library
    }

    public func loadLibrary() -> PlaylistLibrary {
        library
    }

    public func updateMediaReferences(_ references: [PersistentLocalMediaReference]) {
        library = library.replacingMediaReferences(references)
    }
}

public actor SQLitePlaylistStore: PlaylistStore {
    private let connection: SQLiteConnection

    private var database: OpaquePointer { connection.raw }

    public init(databaseURL: URL) throws {
        var connection: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let connection { sqlite3_close(connection) }
            throw PlaylistStoreError.unavailable(message)
        }
        self.connection = SQLiteConnection(raw: connection)
        let schema = "CREATE TABLE IF NOT EXISTS playlist_library (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL)"
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(connection))
            sqlite3_close(connection)
            throw PlaylistStoreError.unavailable(message)
        }
    }

    public func create(_ playlist: Playlist) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let current = try readLibrary()
            let updated = try current.adding(playlist)
            try writeLibrary(updated)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func commit(_ library: PlaylistLibrary) throws {
        try library.validateUniqueNames()
        try execute("BEGIN IMMEDIATE")
        do {
            try writeLibrary(library)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func loadLibrary() throws -> PlaylistLibrary {
        try readLibrary()
    }

    public func updateMediaReferences(_ references: [PersistentLocalMediaReference]) throws {
        guard !references.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let current = try readLibrary()
            try writeLibrary(current.replacingMediaReferences(references))
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func readLibrary() throws -> PlaylistLibrary {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database,
            "SELECT payload FROM playlist_library WHERE id = 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw databaseError()
        }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return PlaylistLibrary()
        }
        guard result == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else {
            throw databaseError()
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        do {
            return try JSONDecoder().decode(
                PlaylistLibrary.self,
                from: Data(bytes: bytes, count: count)
            )
        } catch {
            throw PlaylistStoreError.unavailable("持久状态已损坏：\(error.localizedDescription)")
        }
    }

    private func writeLibrary(_ library: PlaylistLibrary) throws {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(library)
        } catch {
            throw PlaylistStoreError.unavailable("无法编码持久状态：\(error.localizedDescription)")
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO playlist_library(id, payload) VALUES(1, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw databaseError()
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindResult = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func databaseError() -> PlaylistStoreError {
        .unavailable(String(cString: sqlite3_errmsg(database)))
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let raw: OpaquePointer

    init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        sqlite3_close(raw)
    }
}

private func namesConflict(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(rhs, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
}

private extension PlaylistLibrary {
    func validateUniqueNames() throws {
        for (index, playlist) in playlists.enumerated() {
            guard !playlists[..<index].contains(where: { namesConflict($0.name, playlist.name) }) else {
                throw PlaylistStoreError.nameAlreadyExists(playlist.name)
            }
        }
    }

    func adding(_ playlist: Playlist) throws -> PlaylistLibrary {
        guard !playlists.contains(where: { namesConflict($0.name, playlist.name) }) else {
            throw PlaylistStoreError.nameAlreadyExists(playlist.name)
        }
        return PlaylistLibrary(
            playlists: playlists + [playlist],
            activePlaylistID: playlist.id
        )
    }

    func replacingMediaReferences(
        _ references: [PersistentLocalMediaReference]
    ) -> PlaylistLibrary {
        let referencesByID = Dictionary(
            references.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let updatedPlaylists = playlists.map { playlist in
            let updatedEntries = playlist.entries.map { entry in
                PlaylistEntry(
                    id: entry.id,
                    media: referencesByID[entry.media.id] ?? entry.media,
                    resumePosition: entry.resumePosition,
                    playbackPreferences: entry.playbackPreferences
                )
            }
            return Playlist(
                id: playlist.id,
                name: playlist.name,
                entries: updatedEntries,
                currentEntryID: playlist.currentEntryID
            )
        }
        return PlaylistLibrary(playlists: updatedPlaylists, activePlaylistID: activePlaylistID)
    }
}
