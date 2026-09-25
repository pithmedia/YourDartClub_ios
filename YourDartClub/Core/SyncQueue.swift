import Foundation

public struct SyncBatch: Codable, Equatable, Sendable {
    public let id: String
    public let revision: Int
    public let config: GameConfig
    public let events: [ScoreEvent]
}
public struct SyncAck: Codable, Sendable {
    public let id: String
    public let revision: Int
    public init(id: String, revision: Int) { self.id = id; self.revision = revision }
}
public enum SyncQueue {
    public static func batch(_ game: LocalGame) throws -> SyncBatch {
        guard game.config.players.count == 2, (0...game.events.count).contains(game.acknowledged) else { throw GameError.corruptHistory }
        return SyncBatch(id:game.id,revision:game.acknowledged,config:game.config,events:Array(game.events.dropFirst(game.acknowledged).prefix(50)))
    }
    /// Apply only to the latest durable game, which may have new visits while the request was in flight.
    public static func acknowledge(_ ack: SyncAck, batch: SyncBatch, latest: LocalGame) throws -> LocalGame {
        guard ack.id == latest.id, batch.id == latest.id, ack.revision == batch.revision + batch.events.count,
              latest.acknowledged == batch.revision,
              Array(latest.events.dropFirst(batch.revision).prefix(batch.events.count)) == batch.events else { throw GameError.corruptHistory }
        var next = latest; next.acknowledged = ack.revision; next.serverConfirmed = true; return next
    }
}
