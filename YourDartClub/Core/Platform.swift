import Foundation

struct PlatformPlayer: Decodable, Identifiable { let id: String; let name: String; let nickname: String? }
struct PlatformSnapshot: Decodable {
    let players: [PlatformPlayer]
    let evenings: [Evening]
    let createdId: String?
    let addedPlayerId: String?
}
struct Evening: Decodable, Identifiable {
    let id: String
    let name: String
    let mode: String
    let date: String
    let game: String
    let checkout: String
    let bestOf: Int
    let boards: Int
    let revision: Int
    let status: String
    let players: [String]
    let matches: [PlatformMatch]
    let thirdPlaceMatch: Bool?
    let trackStats: Bool?
    let champion: String?
    let standings: [PlatformStanding]?
    var initial: Int { Int(game) ?? 501 }
    func live(on board: Int) -> PlatformMatch? { matches.first { $0.board == board && $0.status == "live" } }
}
struct PlatformStanding: Decodable, Identifiable {
    let id: String
    let played: Int
    let won: Int
    let points: Int
    let diff: Int
}
struct PlatformMatch: Decodable, Identifiable {
    let id: String
    let a: String
    let b: String?
    let status: String
    let board: Int?
    let scoreA: Int
    let scoreB: Int
    let round: Int
    let placement: Int?
    let stage: String
    let winner: String?
    let maximumsA: Int?
    let maximumsB: Int?
    let checkoutA: Int?
    let checkoutB: Int?
    let counter: PlatformCounter?
    var legsA: Int { counter?.state.scoreA ?? scoreA }
    var legsB: Int { counter?.state.scoreB ?? scoreB }
}
struct PlatformCounter: Decodable {
    struct Base: Decodable { let scoreA: Int; let scoreB: Int }
    let base: Base?
    let starter: String?
    let legStarter: String?
    let initialA: Int?
    let initialB: Int?
    let revision: Int
    let state: PlatformState
    let visits: [PlatformVisit]
}
struct PlatformVisit: Decodable { let id: String; let score: Int; let darts: Int; let bust: Bool; let finish: Bool }
struct PlatformState: Decodable {
    let pointsA: Int?
    let pointsB: Int?
    let dartsA: Int?
    let dartsB: Int?
    let maximumsA: Int?
    let maximumsB: Int?
    let remainingA: Int
    let remainingB: Int
    let scoreA: Int
    let scoreB: Int
    let turn: String
    let leg: Int
    let pendingWinner: String?
}

struct TeamAverage {
    var points = 0
    var darts = 0
    var value: Double? { darts > 0 ? Double(points) * 3 / Double(darts) : nil }
    mutating func add(_ points: Int,_ darts: Int) { self.points += points; self.darts += darts }
}
struct TeamPlayerStats: Identifiable {
    let player: PlatformPlayer
    var id: String { player.id }
    var played = 0, won = 0, legs = 0, titles = 0, maximums = 0, checkout = 0
    var total = TeamAverage(), firstNine = TeamAverage(), scoring = TeamAverage()
    var recordedMatches = 0
    static func ranking(players: [PlatformPlayer],events: [Evening]) -> [Self] {
        players.enumerated().map { index, player in (index,Self.make(player:player,events:events)) }.sorted {
            let a = $0.1, b = $1.1
            if a.won != b.won { return a.won > b.won }
            if a.titles != b.titles { return a.titles > b.titles }
            if a.legs != b.legs { return a.legs > b.legs }
            return $0.0 < $1.0
        }.map(\.1)
    }
    static func make(player: PlatformPlayer,events: [Evening]) -> Self {
        var result = Self(player:player)
        for event in events where event.trackStats != false {
            if event.champion == player.id { result.titles += 1 }
            for match in event.matches where match.status == "done" && match.b != nil && (match.a == player.id || match.b == player.id) {
                let side = match.a == player.id ? "A" : "B"
                if event.players.contains(player.id) {
                    result.played += 1
                    if match.winner == player.id { result.won += 1 }
                    result.legs += side == "A" ? match.scoreA : match.scoreB
                    result.maximums += (side == "A" ? match.maximumsA : match.maximumsB) ?? 0
                    result.checkout = max(result.checkout,(side == "A" ? match.checkoutA : match.checkoutB) ?? 0)
                }
                // Reconstruct only persisted visits, with the website's leg/start rules.
                guard let counter = match.counter, let initialA = counter.initialA, let initialB = counter.initialB,
                      let starter = counter.starter, let legStarter = counter.legStarter, let base = counter.base else { continue }
                var turn = starter, remaining = ["A":initialA,"B":initialB]
                var leg = base.scoreA + base.scoreB + 1
                let firstLeg = leg
                var completed = 0, recorded = false
                var beginnings: [Int:TeamAverage] = [:]
                for visit in counter.visits {
                    let before = remaining[turn] ?? event.initial
                    let rest = before - visit.score
                    let bust = visit.bust || rest < 0 || (event.checkout == "double" && rest == 1) || (rest == 0 && !visit.finish)
                    let won = !bust && rest == 0 && visit.finish
                    if turn == side {
                        recorded = true
                        let points = bust ? 0 : visit.score
                        result.total.add(points,visit.darts)
                        if event.checkout == "double" && before > 170 { result.scoring.add(points,visit.darts) }
                        if leg != firstLeg || (side == "A" ? initialA : initialB) == event.initial {
                            var beginning = beginnings[leg] ?? TeamAverage()
                            if beginning.darts < 9 { beginning.add(points,visit.darts); beginnings[leg] = beginning }
                        }
                    }
                    remaining[turn] = bust ? before : rest
                    if won {
                        completed += 1; leg += 1
                        remaining = ["A":event.initial,"B":event.initial]
                        turn = completed % 2 == 1 ? (legStarter == "A" ? "B" : "A") : legStarter
                    } else { turn = turn == "A" ? "B" : "A" }
                }
                if recorded { result.recordedMatches += 1 }
                for beginning in beginnings.values where beginning.darts == 9 { result.firstNine.add(beginning.points,9) }
            }
        }
        return result
    }
}


extension PlatformCounter {
    func recentScores(in event: Evening) -> [[Int?]] {
        guard let initialA, let initialB, let starter, let legStarter, let base else { return [[],[]] }
        var remaining = [initialA,initialB], turn = starter == "A" ? 0 : 1
        var leg = base.scoreA + base.scoreB + 1, completed = 0
        var result: [[Int?]] = [[],[]]
        for visit in visits {
            let rest = remaining[turn] - visit.score
            let bust = visit.bust || rest < 0 || (event.checkout == "double" && rest == 1) || (rest == 0 && !visit.finish)
            if leg == state.leg {
                result[turn].insert(bust ? nil : visit.score,at:0)
                result[turn] = Array(result[turn].prefix(3))
            }
            if !bust { remaining[turn] = rest }
            if !bust && rest == 0 && visit.finish {
                leg += 1; completed += 1; remaining = [event.initial,event.initial]
                let first = legStarter == "A" ? 0 : 1
                turn = completed % 2 == 1 ? 1 - first : first
            } else { turn = 1 - turn }
        }
        return result
    }
}

enum EventAdvice {
    static func leagueMatches(_ count: Int) -> Int { max(0,count * (count - 1) / 2) }
    static func total(_ count: Int, mode: String, thirdPlace: Bool) -> Int {
        if mode == "knockout" { return max(0,count - 1) }
        return leagueMatches(count) + (mode == "playoffs" && count >= 4 ? (thirdPlace ? 4 : 3) : 0)
    }
    static func byes(_ count: Int) -> Int {
        guard count >= 2 else { return 0 }
        var size = 2; while size < count { size *= 2 }; return size - count
    }
    static func simultaneous(_ count: Int, boards: Int) -> Int { min(max(0,boards),max(0,count / 2)) }
}

/// TestFlight sometimes supplies the US catalog while the purchase sheet uses
/// the configured European tariff. These are reference tariffs, never an FX conversion.
struct SubscriptionPriceDisplay {
    let amount: Decimal
    let currency: String
    let usesEuropeanReference: Bool

    init(productID: String, amount: Decimal, currency: String, sandbox: Bool) {
        let reference: Decimal?
        switch productID {
        case "com.yourdartclub.iphone.team.monthly": reference = 10
        case "com.yourdartclub.iphone.team.yearly": reference = 100
        default: reference = nil
        }
        if sandbox, currency == "USD", let reference {
            self.amount = reference
            self.currency = "EUR"
            usesEuropeanReference = true
        } else {
            self.amount = amount
            self.currency = currency
            usesEuropeanReference = false
        }
    }
}
