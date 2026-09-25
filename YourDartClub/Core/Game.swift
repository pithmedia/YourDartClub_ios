import Foundation

public enum GameError: Error { case invalidVisit, invalidCheckout, finished, invalidUndo, corruptHistory, database }
public struct GameConfig: Codable, Equatable, Sendable {
    public var players: [String]
    public var game: Int
    public var checkout: String
    public var bestOf: Int
    public var starter: String
    public init(players: [String], game: Int = 501, checkout: String = "double", bestOf: Int = 3, starter: String = "A") {
        self.players = players; self.game = game; self.checkout = checkout; self.bestOf = bestOf; self.starter = starter
    }
}
public struct ScoreEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var score: Int
    public var darts: Int
    public var finish: Bool
    public var bust: Bool
    public var target: String?
    public init(score: Int, darts: Int = 3, finish: Bool = false, bust: Bool = false) {
        id = UUID().uuidString.lowercased(); kind = "visit"; self.score = score; self.darts = darts; self.finish = finish; self.bust = bust
    }
    public static func undo(_ target: String) -> Self {
        var event = Self(score: 0); event.kind = "undo"; event.target = target; return event
    }
}
public struct LocalGame: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString.lowercased()
    public var config: GameConfig
    public var events: [ScoreEvent] = []
    public var acknowledged = 0
    public var uploadRequested = false
    public var teamID: Int?
    public var userID: Int?
    public var serverOrigin: String?
    public var serverConfirmed: Bool?
    public var syncProblem: String?
    public var createdAt = Date()
    public init(config: GameConfig) { self.config = config }
    public var pending: Int { events.count - acknowledged }
}
public struct ScoreState: Equatable, Sendable {
    public var remaining: [Int]
    public var legs: [Int]
    public var points: [Int]
    public var dartsThrown: [Int]
    public var maximums: [Int]
    public var turn: Int
    public var winner: Int?
    public var lastBust = false
}
public enum DartRules {
    static let hits: [(String, Int)] = {
        var result: [(String, Int)] = []
        for n in (1...20).reversed() { result.append(("T\(n)", n * 3)) }
        result += [("Bull",50),("25",25)]
        for n in (1...20).reversed() { result.append(("D\(n)",n * 2)) }
        for n in (1...20).reversed() { result.append((String(n),n)) }
        return result
    }()
    static let totals: [Set<Int>] = {
        var result = [Set([0])]
        for _ in 1...3 { result.append(Set(result.last!.flatMap { a in ([0] + hits.map(\.1)).map { a + $0 } })) }
        return result
    }()
    public static func possible(_ score: Int, darts: Int) -> Bool { (0...3).contains(darts) && totals[darts].contains(score) }
    public static func checkout(_ score: Int, mode: String, darts: Int) -> Bool {
        guard (1...3).contains(darts), score > 0 else { return false }
        return hits.filter { mode == "single" || $0.0.hasPrefix("D") || $0.0 == "Bull" }.contains { possible(score - $0.1, darts: darts - 1) }
    }
    private static let preferred: [Int:String] = [
        41:"S9 D16",
        42:"S10 D16",
        43:"S11 D16",
        44:"S12 D16",
        45:"S13 D16",
        46:"S14 D16",
        47:"S15 D16",
        48:"S16 D16",
        49:"S17 D16",
        51:"S19 D16",
        52:"S20 D16",
        53:"S13 D20",
        54:"S14 D20",
        55:"S15 D20",
        56:"S16 D20",
        57:"S17 D20",
        58:"S18 D20",
        59:"S19 D20",
        60:"S20 D20",
        61:"T15 D8",
        62:"T10 D16",
        63:"T13 D12",
        64:"T16 D8",
        65:"25 D20",
        66:"T10 D18",
        67:"T17 D8",
        68:"T20 D4",
        69:"T19 D6",
        70:"T18 D8",
        71:"T13 D16",
        72:"T16 D12",
        73:"T19 D8",
        74:"T14 D16",
        75:"T17 D12",
        76:"T20 D8",
        77:"T19 D10",
        78:"T18 D12",
        79:"T19 D11",
        80:"T20 D10",
        81:"T19 D12",
        82:"Bull D16",
        83:"T17 D16",
        84:"T20 D12",
        85:"T15 D20",
        86:"T18 D16",
        87:"T17 D18",
        88:"T16 D20",
        89:"T19 D16",
        90:"T18 D18",
        91:"T17 D20",
        92:"T20 D16",
        93:"T19 D18",
        94:"T18 D20",
        95:"T19 D19",
        96:"T20 D18",
        97:"T19 D20",
        98:"T20 D19",
        99:"T19 S10 D16",
        100:"T20 D20",
        110:"T20 S18 D16",
        120:"T20 S20 D20",
        121:"T20 T11 D14",
        130:"T20 T20 D5",
        132:"Bull Bull D16",
        135:"25 T20 Bull",
        140:"T20 T20 D10",
        150:"T20 T18 D18",
        160:"T20 T20 D20",
        164:"T20 T18 Bull",
        167:"T20 T19 Bull",
        170:"T20 T20 Bull"
    ]
    public static func advice(_ score: Int, mode: String, darts: Int = 3) -> String? {
        guard score > 0 && score <= 180 && (1...3).contains(darts) else { return nil }
        if mode == "double", let route = preferred[score], route.split(separator:" ").count <= darts { return route.replacingOccurrences(of:" ",with:" · ") }
        let singles = (1...20).reversed().map { ("S\($0)",$0) }
        let triples = (1...20).reversed().map { ("T\($0)",$0 * 3) }
        let doubles = (1...20).reversed().map { ("D\($0)",$0 * 2) }
        let beds = triples + singles + [("25",25),("Bull",50)] + doubles
        let doubleEnds = [20,16,18,12,10,8,4,2,1,14,6,15,17,19,13,11,9,7,5,3].map { ("D\($0)",$0 * 2) } + [("Bull",50)]
        let ends = mode == "double" ? doubleEnds : doubleEnds + beds
        func find(_ rest: Int, _ left: Int) -> [String]? {
            if left == 1 { return ends.first(where:{$0.1 == rest}).map { [$0.0] } }
            for bed in score <= 60 ? singles + beds : beds {
                guard rest - bed.1 >= (mode == "double" ? 2 : 1) else { continue }
                if let tail = find(rest - bed.1,left - 1) { return [bed.0] + tail }
            }
            return nil
        }
        for n in 1...darts { if let route = find(score,n) { return route.joined(separator:" · ") } }
        return nil
    }
    public static func activeVisits(_ events: [ScoreEvent]) throws -> [ScoreEvent] {
        var visits: [ScoreEvent] = []; var ids = Set<String>()
        for e in events {
            guard ids.insert(e.id).inserted else { throw GameError.corruptHistory }
            if e.kind == "visit" { visits.append(e) }
            else if e.kind == "undo", visits.last?.id == e.target, !visits.isEmpty { visits.removeLast() }
            else { throw GameError.invalidUndo }
        }
        return visits
    }
    public static func replay(_ game: LocalGame) throws -> ScoreState {
        let c = game.config
        guard (2...4).contains(c.players.count), c.players.allSatisfy({ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count <= 60 }), [301,501,701].contains(c.game), [1,3,5,7,9,11].contains(c.bestOf), ["single","double"].contains(c.checkout), Array(["A","B","C","D"].prefix(c.players.count)).contains(c.starter) else { throw GameError.corruptHistory }
        let count = c.players.count
        let start = ["A","B","C","D"].firstIndex(of:c.starter)!
        var s = ScoreState(remaining:Array(repeating:c.game,count:count),legs:Array(repeating:0,count:count),points:Array(repeating:0,count:count),dartsThrown:Array(repeating:0,count:count),maximums:Array(repeating:0,count:count),turn:start)
        for v in try activeVisits(game.events) {
            guard s.winner == nil else { throw GameError.finished }
            guard possible(v.score, darts: v.darts), (1...3).contains(v.darts) else { throw GameError.invalidVisit }
            let side = s.turn; let before = s.remaining[side]; let rest = before - v.score
            if v.finish && (v.bust || rest != 0 || !checkout(before, mode: c.checkout, darts: v.darts)) { throw GameError.invalidCheckout }
            let bust = v.bust || rest < 0 || (c.checkout == "double" && rest == 1) || (rest == 0 && !v.finish)
            s.lastBust = bust
            s.dartsThrown[side] += v.darts
            s.points[side] += bust ? 0 : v.score
            if !bust && v.score == 180 { s.maximums[side] += 1 }
            if !bust { s.remaining[side] = rest }
            if !bust && rest == 0 && v.finish {
                s.legs[side] += 1
                if s.legs[side] >= (c.bestOf + 1) / 2 { s.winner = side }
                else { s.remaining = Array(repeating:c.game,count:count); s.turn = (start + s.legs.reduce(0,+)) % count }
            } else { s.turn = (side + 1) % count }
        }
        return s
    }
}
