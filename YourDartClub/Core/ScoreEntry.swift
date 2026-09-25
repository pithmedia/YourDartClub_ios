import Foundation
public enum EntryMode: String, CaseIterable, Sendable { case score, remaining }
public enum EntryError: Error { case invalid, checkoutConfirmation }
public struct EntryPreview: Sendable {
    public let remaining: Int
    public let score: Int
    public let dartsLeft: Int
    public let bust: Bool
    public let checkout: Bool
}
/// Mirrors visitFromRemaining/previewVisit in the website's lib/counter.ts.
public enum ScoreEntry {
    public static func event(input: Int, before: Int, mode: EntryMode, checkout: String, darts: Int, confirmed: Bool) throws -> ScoreEvent {
        guard input >= 0 else { throw EntryError.invalid }
        let score = mode == .remaining ? before - input : input
        guard DartRules.possible(score,darts:darts) else { throw EntryError.invalid }
        if mode == .remaining && ((checkout == "double" && input == 1) || (input == 0 && !DartRules.checkout(before,mode:checkout,darts:darts))) { throw EntryError.invalid }
        let finishes = score == before && DartRules.checkout(before,mode:checkout,darts:darts)
        if finishes && !confirmed { throw EntryError.checkoutConfirmation }
        return ScoreEvent(score:score,darts:darts,finish:finishes && confirmed)
    }
    public static func preview(input: Int, before: Int, mode: EntryMode, checkout: String, darts: Int) -> EntryPreview? {
        let score = mode == .remaining ? before - input : input
        guard input >= 0, (1...3).contains(darts), DartRules.possible(score,darts:darts) else { return nil }
        let rest = before - score
        let bust = rest < 0 || (checkout == "double" && rest == 1) || (rest == 0 && !DartRules.checkout(before,mode:checkout,darts:darts))
        return EntryPreview(remaining:bust ? before : rest,score:score,dartsLeft:bust || rest == 0 ? 0 : 3 - darts,bust:bust,checkout:!bust && rest == 0)
    }
}
public struct FavoritePlayer: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public static func clean(_ name: String) -> String { name.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ") }
    public static func key(_ name: String) -> String { clean(name).lowercased() }
}
