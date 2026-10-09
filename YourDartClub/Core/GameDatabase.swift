import Foundation
import SQLite3

/// One database transaction commits the complete game and its durable upload queue.
/// A failed write never changes the caller's displayed state.
public final class GameDatabase {
    private var db: OpaquePointer?
    public init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw GameError.database }
        do {
            try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA busy_timeout=5000")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&statement,nil) == SQLITE_OK else { throw GameError.database }
            let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement,0) : -1
            sqlite3_finalize(statement)
            guard (0...3).contains(version) else { throw GameError.database }
            if version == 0 {
                try execute("BEGIN IMMEDIATE")
                do { try execute("CREATE TABLE games (id TEXT PRIMARY KEY, payload BLOB NOT NULL)"); try execute("PRAGMA user_version=1"); try execute("COMMIT") }
                catch { try? execute("ROLLBACK"); throw error }
            }
            if version < 2 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("CREATE TABLE favorites (id TEXT PRIMARY KEY, name TEXT NOT NULL, normalized_name TEXT NOT NULL UNIQUE)")
                    try execute("PRAGMA user_version=2"); try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            if version < 3 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("ALTER TABLE favorites ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0")
                    // Preserve the alphabetical order existing installations already displayed.
                    try execute("UPDATE favorites SET sort_order=(SELECT COUNT(*) FROM favorites AS earlier WHERE earlier.normalized_name < favorites.normalized_name)")
                    try execute("PRAGMA user_version=3"); try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    /// Read the source and create its successor under the same write lock.
    /// Repeated taps (even after reopening the database) return the same match.
    public func rematch(_ sourceID: String, starter: Int? = nil) throws -> LocalGame {
        try execute("BEGIN IMMEDIATE")
        do {
            let games = try load()
            guard let source = games.first(where: { $0.id == sourceID }), source.canRematch else { throw GameError.invalidVisit }
            let result: LocalGame
            if let existing = games.first(where: { $0.rematchOf == sourceID }) { result = existing }
            else { result = try source.rematch(starter:starter); try save(result) }
            try execute("COMMIT")
            return result
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw GameError.database } }
    public func save(_ game: LocalGame) throws {
        _ = try DartRules.replay(game)
        let bytes = try JSONEncoder().encode(game)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"INSERT INTO games(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",-1,&stmt,nil) == SQLITE_OK else { throw GameError.database }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt,1,game.id,-1,transient) == SQLITE_OK else { throw GameError.database }
        let result = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt,2,$0.baseAddress,Int32($0.count),transient) }
        guard result == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw GameError.database }
    }
    public func deleteGame(_ id: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"DELETE FROM games WHERE id=?",-1,&stmt,nil) == SQLITE_OK else { throw GameError.database }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt,1,id,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else { throw GameError.database }
    }
    public func load() throws -> [LocalGame] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT payload FROM games",-1,&stmt,nil) == SQLITE_OK else { throw GameError.database }
        defer { sqlite3_finalize(stmt) }
        var games: [LocalGame] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let pointer = sqlite3_column_blob(stmt,0) else { throw GameError.database }
            let game = try JSONDecoder().decode(LocalGame.self,from: Data(bytes: pointer,count: Int(sqlite3_column_bytes(stmt,0))))
            _ = try DartRules.replay(game); games.append(game)
        }
        return games.sorted { $0.createdAt > $1.createdAt }
    }
    public func favorite(_ name: String) throws {
        let clean = FavoritePlayer.clean(name)
        guard !clean.isEmpty, clean.count <= 60 else { throw GameError.corruptHistory }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"INSERT OR IGNORE INTO favorites(id,name,normalized_name,sort_order) VALUES(?,?,?,(SELECT COALESCE(MAX(sort_order),-1)+1 FROM favorites))",-1,&stmt,nil) == SQLITE_OK else { throw GameError.database }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for (index,value) in [UUID().uuidString,clean,FavoritePlayer.key(clean)].enumerated() {
            guard sqlite3_bind_text(stmt,Int32(index + 1),value,-1,transient) == SQLITE_OK else { throw GameError.database }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw GameError.database }
    }
    public func removeFavorite(_ id: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"DELETE FROM favorites WHERE id=?",-1,&stmt,nil) == SQLITE_OK else { throw GameError.database }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt,1,id,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw GameError.database }
    }
    public func reorderFavorites(_ ids: [String]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let current = try favorites().map(\.id)
            guard ids.count == current.count, Set(ids).count == ids.count, Set(ids) == Set(current) else { throw GameError.corruptHistory }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,"UPDATE favorites SET sort_order=? WHERE id=?",-1,&stmt,nil) == SQLITE_OK else { throw GameError.database }
            defer { sqlite3_finalize(stmt) }
            for (position,id) in ids.enumerated() {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                guard sqlite3_bind_int64(stmt,1,Int64(position)) == SQLITE_OK,
                      sqlite3_bind_text(stmt,2,id,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_DONE else { throw GameError.database }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func favorites() throws -> [FavoritePlayer] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT id,name FROM favorites ORDER BY sort_order,normalized_name",-1,&stmt,nil) == SQLITE_OK else { throw GameError.database }
        defer { sqlite3_finalize(stmt) }
        var result: [FavoritePlayer] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let id = sqlite3_column_text(stmt,0), let name = sqlite3_column_text(stmt,1) else { throw GameError.database }
            result.append(FavoritePlayer(id:String(cString:id),name:String(cString:name)))
        }
    }

}
