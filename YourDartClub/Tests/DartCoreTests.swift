import XCTest
import SQLite3
@testable import DartCore
final class DartCoreTests: XCTestCase {
    func testStarterSwitchPersistsAndControlsFirstTurn() throws {
        var game = LocalGame(config:.init(players:["Hans","Joris","Sam"],game:301))
        try game.changeStarter(to:2)
        XCTAssertEqual(try DartRules.replay(game).turn,2)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath:path+suffix) } }
        let db = try GameDatabase(path:path); try db.save(game)
        game = try XCTUnwrap(db.load().first)
        XCTAssertEqual(game.config.starter,"C")
        try game.changeStarter(to:1)
        game.events.append(.init(score:60))
        XCTAssertEqual(try DartRules.replay(game).remaining,[301,241,301])
        XCTAssertEqual(try DartRules.replay(game).turn,2)
        XCTAssertThrowsError(try game.changeStarter(to:0))
    }
    func testStarterLockedAfterZeroBustUndoOrUploadAndRejectsInvalidPlayer() throws {
        for visit in [ScoreEvent(score:0),ScoreEvent(score:0,bust:true)] {
            var game = LocalGame(config:.init(players:["A","B"]))
            game.events = [visit,.undo(visit.id)]
            XCTAssertFalse(game.canChangeStarter)
            XCTAssertThrowsError(try game.changeStarter(to:1))
        }
        var game = LocalGame(config:.init(players:["A","B"]))
        XCTAssertThrowsError(try game.changeStarter(to:2))
        XCTAssertThrowsError(try game.changeStarter(to:-1))
        game.uploadRequested = true
        XCTAssertThrowsError(try game.changeStarter(to:1))
        var solo = LocalGame(config:.init(players:["A"]))
        XCTAssertThrowsError(try solo.changeStarter(to:0))
    }

    func testCheckoutBustUndoAndAlternatingLegs() throws {
        var g = LocalGame(config: .init(players: ["A","B"],game: 301,bestOf: 3))
        g.events = [.init(score: 180), .init(score: 0), .init(score: 120)]
        XCTAssertEqual(try DartRules.replay(g).remaining,[121,301]) // leaving one is bust
        g.events.append(.undo(g.events.last!.id))
        g.events.append(.init(score: 121,finish: true))
        let state = try DartRules.replay(g)
        XCTAssertEqual(state.legs,[1,0]); XCTAssertEqual(state.turn,1)
        XCTAssertEqual(state.remaining,[301,301])
    }
    func testImpossibleVisitsAndCheckoutRejected() throws {
        XCTAssertFalse(DartRules.possible(179,darts: 3))
        XCTAssertFalse(DartRules.checkout(169,mode: "double",darts: 3))
        XCTAssertTrue(DartRules.checkout(170,mode: "double",darts: 3))
        var g = LocalGame(config: .init(players: ["A","B"],game: 301))
        g.events = [.init(score: 179)]
        XCTAssertThrowsError(try DartRules.replay(g))
        g.events = [.init(score: 180), .init(score: 0), .init(score: 121,darts: 1,finish: true)]
        XCTAssertThrowsError(try DartRules.replay(g))
    }
    func testRestartPreservesPendingEventsAndUndoAudit() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath: path+suffix) } }
        var g = LocalGame(config: .init(players: ["Alex","Sam"]))
        g.events = [.init(score: 60)]; g.events.append(.undo(g.events[0].id)); g.uploadRequested = true; g.teamID = 42; g.userID = 7
        do { let db = try GameDatabase(path: path); try db.save(g) }
        let reopened = try GameDatabase(path: path); let restored = try XCTUnwrap(reopened.load().first)
        XCTAssertEqual(restored.events,g.events); XCTAssertEqual(restored.pending,2)
        XCTAssertEqual(restored.teamID,42); XCTAssertEqual(try DartRules.replay(restored).remaining,[501,501])
    }
    func testDuplicateAndWrongUndoRejected() {
        var g = LocalGame(config: .init(players: ["A","B"]))
        let event = ScoreEvent(score: 60); g.events = [event,event]
        XCTAssertThrowsError(try DartRules.replay(g))
        g.events = [event,.undo(UUID().uuidString)]
        XCTAssertThrowsError(try DartRules.replay(g))
    }
    func testFailedWriteDoesNotReplaceSavedGame() throws {
        let db = try GameDatabase(path: ":memory:")
        var g = LocalGame(config: .init(players:["A","B"]))
        try db.save(g); g.events = [.init(score: 179)]
        XCTAssertThrowsError(try db.save(g)); XCTAssertEqual(try db.load()[0].events.count,0)
    }
}

final class SyncQueueTests: XCTestCase {
    func testLostResponseRetriesIdenticalBatchAfterRestart() throws {
        let db = try GameDatabase(path: ":memory:")
        var game = LocalGame(config:.init(players:["Alex","Sam"]))
        game.events = [.init(score:60),.init(score:45)]; game.uploadRequested = true
        try db.save(game)
        let sent = try SyncQueue.batch(game)
        // A server commit followed by a timeout must not locally acknowledge anything.
        let restored = try db.load()[0]
        XCTAssertEqual(restored.acknowledged,0)
        XCTAssertEqual(try SyncQueue.batch(restored),sent)
        let committed = try SyncQueue.acknowledge(.init(id:game.id,revision:2),batch:sent,latest:restored)
        try db.save(committed)
        XCTAssertEqual(try db.load()[0].pending,0)
    }
    func testVisitDuringUploadIsNeverLost() throws {
        var game = LocalGame(config:.init(players:["Alex","Sam"]))
        game.events = [.init(score:60)]
        let sent = try SyncQueue.batch(game)
        game.events.append(.init(score:100))
        let next = try SyncQueue.acknowledge(.init(id:game.id,revision:1),batch:sent,latest:game)
        XCTAssertEqual(next.events.count,2); XCTAssertEqual(next.pending,1)
        XCTAssertEqual(try SyncQueue.batch(next).events,[game.events[1]])
    }
    func testForeignOrImpossibleAckCannotAdvanceQueue() throws {
        var game = LocalGame(config:.init(players:["Alex","Sam"]))
        game.events = [.init(score:60)]
        let batch = try SyncQueue.batch(game)
        XCTAssertThrowsError(try SyncQueue.acknowledge(.init(id:UUID().uuidString,revision:1),batch:batch,latest:game))
        XCTAssertThrowsError(try SyncQueue.acknowledge(.init(id:game.id,revision:2),batch:batch,latest:game))
        XCTAssertEqual(game.acknowledged,0)
    }
    func testBatchesAreBoundedAndEmptyCreationCanBeAcknowledged() throws {
        var game = LocalGame(config:.init(players:["Alex","Sam"]))
        let creation = try SyncQueue.batch(game)
        let confirmed = try SyncQueue.acknowledge(.init(id:game.id,revision:0),batch:creation,latest:game)
        XCTAssertEqual(confirmed.serverConfirmed,true)
        game.events = (0..<51).map { _ in .init(score:0) }
        XCTAssertEqual(try SyncQueue.batch(game).events.count,50)
    }
}

final class MultiplayerTests: XCTestCase {
    func testFourPlayersTakeTurnsAndUndoRestoresCorrectPlayer() throws {
        var game = LocalGame(config:.init(players:["A","B","C","D"],game:301,starter:"C"))
        game.events = [.init(score:60),.init(score:45),.init(score:100),.init(score:26)]
        let state = try DartRules.replay(game)
        XCTAssertEqual(state.remaining,[201,275,241,256]); XCTAssertEqual(state.turn,2)
        game.events.append(.undo(game.events.last!.id))
        XCTAssertEqual(try DartRules.replay(game).turn,1)
        XCTAssertEqual(try DartRules.replay(game).remaining,[201,301,241,256])
    }
    func testThreePlayerCheckoutRotatesStarterAndUndoCrossesLegBoundary() throws {
        var game = LocalGame(config:.init(players:["Alex","Sam","Kim"],game:301,bestOf:3,starter:"B"))
        game.events = [.init(score:180),.init(score:0),.init(score:0),.init(score:121,finish:true)]
        let state = try DartRules.replay(game)
        XCTAssertEqual(state.legs,[0,1,0]); XCTAssertEqual(state.turn,2)
        XCTAssertEqual(state.remaining,[301,301,301])
        game.events.append(.undo(game.events.last!.id))
        XCTAssertEqual(try DartRules.replay(game).remaining,[301,121,301])
        XCTAssertEqual(try DartRules.replay(game).turn,1)
    }
    func testMultiplayerCannotAccidentallyEnterTwoPlayerUploadContract() {
        for count in 3...4 {
            let game = LocalGame(config:.init(players:Array(["A","B","C","D"].prefix(count))))
            XCTAssertThrowsError(try SyncQueue.batch(game))
        }
    }
    func testFourPlayerMatchWinnerAndRestart() throws {
        let db = try GameDatabase(path:":memory:")
        var game = LocalGame(config:.init(players:["A","B","C","D"],game:301,bestOf:1))
        game.events = [.init(score:180),.init(score:0),.init(score:0),.init(score:0),.init(score:121,finish:true)]
        try db.save(game)
        let restored = try db.load()[0]
        XCTAssertEqual(try DartRules.replay(restored).winner,0)
        game.events.append(.init(score:0)); XCTAssertThrowsError(try DartRules.replay(game))
    }
    func testBustAndAverageFollowWebsiteRules() throws {
        var game = LocalGame(config:.init(players:["A","B","C"],game:301))
        game.events = [.init(score:180),.init(score:45),.init(score:60),.init(score:120)]
        let state = try DartRules.replay(game)
        XCTAssertEqual(state.remaining,[121,256,241]); XCTAssertEqual(state.points,[180,45,60])
        XCTAssertEqual(state.dartsThrown,[6,3,3]); XCTAssertEqual(state.maximums,[1,0,0])
        XCTAssertEqual(state.turn,1); XCTAssertTrue(state.lastBust)
    }
}
final class WebsiteEntryTests: XCTestCase {
    func testScoreAndRemainingProduceSameVisit() throws {
        let score = try ScoreEntry.event(input:60,before:301,mode:.score,checkout:"double",darts:3,confirmed:false)
        let remaining = try ScoreEntry.event(input:241,before:301,mode:.remaining,checkout:"double",darts:3,confirmed:false)
        XCTAssertEqual(score.score,remaining.score); XCTAssertFalse(remaining.finish)
        XCTAssertThrowsError(try ScoreEntry.event(input:302,before:301,mode:.remaining,checkout:"double",darts:3,confirmed:false))
        XCTAssertThrowsError(try ScoreEntry.event(input:1,before:101,mode:.remaining,checkout:"double",darts:3,confirmed:false))
    }
    func testCheckoutMustBeConfirmedInBothModes() throws {
        for (mode,input) in [(EntryMode.score,40),(.remaining,0)] {
            XCTAssertThrowsError(try ScoreEntry.event(input:input,before:40,mode:mode,checkout:"double",darts:1,confirmed:false))
            XCTAssertTrue(try ScoreEntry.event(input:input,before:40,mode:mode,checkout:"double",darts:1,confirmed:true).finish)
        }
    }
    func testPreviewBustCheckoutAndDartsLeft() throws {
        let preview = try XCTUnwrap(ScoreEntry.preview(input:60,before:101,mode:.score,checkout:"double",darts:1))
        XCTAssertEqual(preview.remaining,41); XCTAssertEqual(preview.dartsLeft,2)
        let bust = try XCTUnwrap(ScoreEntry.preview(input:60,before:61,mode:.score,checkout:"double",darts:1))
        XCTAssertTrue(bust.bust); XCTAssertEqual(bust.remaining,61); XCTAssertEqual(bust.dartsLeft,0)
        XCTAssertTrue(try XCTUnwrap(ScoreEntry.preview(input:0,before:40,mode:.remaining,checkout:"double",darts:1)).checkout)
        XCTAssertNil(ScoreEntry.preview(input:179,before:501,mode:.score,checkout:"double",darts:3))
    }
    func testConventionalCheckoutRoutesMatchWebsite() {
        XCTAssertEqual(DartRules.advice(41,mode:"double"),"S9 · D16")
        XCTAssertEqual(DartRules.advice(121,mode:"double"),"T20 · T11 · D14")
        XCTAssertEqual(DartRules.advice(170,mode:"double"),"T20 · T20 · Bull")
        XCTAssertNil(DartRules.advice(169,mode:"double"))
        XCTAssertEqual(DartRules.advice(40,mode:"double",darts:1),"D20")
    }
}
final class FavoriteTests: XCTestCase {
    func testFavoritesPersistDeduplicateAndNeverDeleteSavedGames() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath:path+suffix) } }
        do {
            let db = try GameDatabase(path:path)
            try db.favorite("  Alex   Smith "); try db.favorite("alex smith")
            try db.save(LocalGame(config:.init(players:["Alex Smith","Sam"])))
        }
        let db = try GameDatabase(path:path)
        XCTAssertEqual(try db.favorites().count,1); XCTAssertEqual(try db.favorites()[0].name,"Alex Smith")
        try db.removeFavorite(db.favorites()[0].id)
        XCTAssertTrue(try db.favorites().isEmpty); XCTAssertEqual(try db.load()[0].config.players,["Alex Smith","Sam"])
        XCTAssertThrowsError(try db.favorite("   "))
    }
}

final class MigrationTests: XCTestCase {
    func testVersionOneGamesSurviveFavoriteMigration() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath:path+suffix) } }
        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path,&legacy),SQLITE_OK)
        var game = LocalGame(config:.init(players:["Alex","Sam"]))
        game.events = [.init(score:60)]
        let data = try JSONEncoder().encode(game).map { String(format:"%02x",$0) }.joined()
        XCTAssertEqual(sqlite3_exec(legacy,"CREATE TABLE games(id TEXT PRIMARY KEY,payload BLOB NOT NULL); PRAGMA user_version=1; INSERT INTO games VALUES('legacy',X'\(data)');",nil,nil,nil),SQLITE_OK)
        sqlite3_close(legacy)
        let db = try GameDatabase(path:path)
        XCTAssertEqual(try db.load()[0].events,game.events)
        try db.favorite("Alex"); XCTAssertEqual(try db.favorites().count,1)
    }
}

final class SoloTests: XCTestCase {
    func testSoloBustUndoAndNextLeg() throws {
        var game = LocalGame(config:.init(players:["Joris"],game:301,bestOf:3))
        game.events = [.init(score:180),.init(score:120)]
        var state = try DartRules.replay(game)
        XCTAssertEqual(state.remaining,[121]); XCTAssertEqual(state.turn,0)
        XCTAssertTrue(state.lastBust)
        game.events.append(.undo(game.events.last!.id))
        game.events.append(.init(score:121,finish:true))
        state = try DartRules.replay(game)
        XCTAssertEqual(state.legs,[1]); XCTAssertEqual(state.remaining,[301])
        XCTAssertEqual(state.turn,0); XCTAssertNil(state.winner)
        game.events += [.init(score:180),.init(score:121,finish:true)]
        state = try DartRules.replay(game)
        XCTAssertEqual(state.winner,0); XCTAssertEqual(state.legs,[2])
        game.events.append(.undo(game.events.last!.id))
        XCTAssertNil(try DartRules.replay(game).winner)
        XCTAssertEqual(try DartRules.replay(game).remaining,[121])
    }
    func testSoloPersistsAndCannotEnterTeamQueue() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath:path+suffix) } }
        var game = LocalGame(config:.init(players:["Joris"]))
        game.events = [.init(score:60),.init(score:100)]
        do { let db = try GameDatabase(path:path); try db.save(game) }
        let db = try GameDatabase(path:path)
        let restored = try XCTUnwrap(db.load().first)
        XCTAssertEqual(try DartRules.replay(restored).remaining,[341])
        XCTAssertEqual(restored.events,game.events)
        XCTAssertThrowsError(try SyncQueue.batch(restored))
    }
}

final class GameLibraryTests: XCTestCase {
    func testArchiveRestoreAndDeletionPreserveOtherGamesAndFavorites() throws {
        let db = try GameDatabase(path:":memory:")
        var game = LocalGame(config:.init(players:["Solo"]))
        game.events = [.init(score:60)]
        let other = LocalGame(config:.init(players:["A","B"]))
        try db.save(game); try db.save(other); try db.favorite("Solo")
        game.archived = true; try db.save(game)
        let archived = try XCTUnwrap(db.load().first(where:{$0.id == game.id}))
        XCTAssertEqual(archived.archived,true)
        XCTAssertEqual(try DartRules.replay(archived).remaining,[441])
        game.archived = false; try db.save(game)
        XCTAssertEqual(try db.load().first(where:{$0.id == game.id})?.archived,false)
        try db.deleteGame(game.id)
        XCTAssertEqual(try db.load().map(\.id),[other.id])
        XCTAssertEqual(try db.favorites().map(\.name),["Solo"])
        try db.deleteGame("' OR 1=1 --")
        XCTAssertEqual(try db.load().count,1)
    }
    func testOldGameWithoutArchiveFieldDecodesAndSyncRetainsArchive() throws {
        var game = LocalGame(config:.init(players:["A","B"]))
        game.events = [.init(score:60)]
        let data = try JSONEncoder().encode(game)
        XCTAssertNil(try JSONDecoder().decode(LocalGame.self,from:data).archived)
        let batch = try SyncQueue.batch(game)
        game.archived = true
        let saved = try SyncQueue.acknowledge(.init(id:game.id,revision:1),batch:batch,latest:game)
        XCTAssertEqual(saved.archived,true)
        XCTAssertEqual(saved.pending,0)
    }
}

final class CheckoutDisplayTests: XCTestCase {
    func testFirstDartAdviceAndImpossibleTwoDartFinish() throws {
        let reachable = try XCTUnwrap(ScoreEntry.preview(input:20,before:101,mode:.score,checkout:"double",darts:1))
        let advice = try XCTUnwrap(CheckoutSuggestion.make(remaining:reachable.remaining,checkout:"double",dartsLeft:reachable.dartsLeft))
        XCTAssertFalse(advice.nextVisit); XCTAssertLessThanOrEqual(advice.targets.count,2)
        let preview = try XCTUnwrap(ScoreEntry.preview(input:20,before:140,mode:.score,checkout:"double",darts:1))
        XCTAssertEqual(preview.remaining,120); XCTAssertEqual(preview.dartsLeft,2)
        let next = try XCTUnwrap(CheckoutSuggestion.make(remaining:120,checkout:"double",dartsLeft:2))
        XCTAssertTrue(next.nextVisit); XCTAssertEqual(next.targets.count,3)
        let after81 = try XCTUnwrap(CheckoutSuggestion.make(remaining:60,checkout:"double",dartsLeft:1))
        XCTAssertTrue(after81.nextVisit)
        XCTAssertFalse(try XCTUnwrap(CheckoutSuggestion.make(remaining:40,checkout:"double",dartsLeft:1)).nextVisit)
        XCTAssertTrue(try XCTUnwrap(CheckoutSuggestion.make(remaining:40,checkout:"double",dartsLeft:0)).nextVisit)
        XCTAssertNil(CheckoutSuggestion.make(remaining:169,checkout:"double",dartsLeft:2))
    }
    func testBackClearsAnyDraftBeforeUndoingSavedVisit() throws {
        let event = ScoreEvent(score:60)
        for input in ["20","0","81","999"] {
            XCTAssertEqual(try InputBackAction.resolve(input:input,events:[event]),.clearInput)
            XCTAssertEqual(try InputBackAction.resolve(input:input,events:[]),.clearInput)
        }
        XCTAssertEqual(try InputBackAction.resolve(input:"",events:[event]),.undoVisit(event.id))
        XCTAssertEqual(try InputBackAction.resolve(input:"",events:[]),.none)
        XCTAssertEqual(try InputBackAction.resolve(input:"",events:[event,.undo(event.id)]),.none)
    }
}

final class FavoriteOrderTests: XCTestCase {
    func testVersionTwoFavoritesKeepOrderThenPersistReordering() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath:path+suffix) } }
        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path,&legacy),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(legacy,"CREATE TABLE games(id TEXT PRIMARY KEY,payload BLOB NOT NULL); CREATE TABLE favorites(id TEXT PRIMARY KEY,name TEXT NOT NULL,normalized_name TEXT NOT NULL UNIQUE); INSERT INTO favorites VALUES('h','Hans','hans'),('j','Joris','joris'),('a','Alex','alex'); PRAGMA user_version=2;",nil,nil,nil),SQLITE_OK)
        sqlite3_close(legacy)
        do {
            let db = try GameDatabase(path:path)
            XCTAssertEqual(try db.favorites().map(\.name),["Alex","Hans","Joris"])
            try db.reorderFavorites(["j","a","h"])
        }
        let reopened = try GameDatabase(path:path)
        XCTAssertEqual(try reopened.favorites().map(\.name),["Joris","Alex","Hans"])
        try reopened.favorite("Bram")
        try reopened.favorite("JORIS") // Duplicates must not move an existing favorite.
        XCTAssertEqual(try reopened.favorites().map(\.name),["Joris","Alex","Hans","Bram"])
        try reopened.removeFavorite("a")
        XCTAssertEqual(try reopened.favorites().map(\.name),["Joris","Hans","Bram"])
    }
    func testInvalidOrStaleReorderPreservesFavoritesAndSavedGames() throws {
        let db = try GameDatabase(path:":memory:")
        try db.favorite("Joris"); try db.favorite("Hans")
        let original = try db.favorites().map(\.id)
        let game = LocalGame(config:.init(players:["Joris","Hans"]))
        try db.save(game)
        XCTAssertThrowsError(try db.reorderFavorites([original[0],original[0]]))
        XCTAssertThrowsError(try db.reorderFavorites([original[0],"unknown"]))
        XCTAssertThrowsError(try db.reorderFavorites([original[0]]))
        XCTAssertEqual(try db.favorites().map(\.id),original)
        try db.removeFavorite(original[0])
        XCTAssertThrowsError(try db.reorderFavorites(original))
        XCTAssertEqual(try db.favorites().map(\.name),["Hans"])
        XCTAssertEqual(try db.load().first?.config.players,["Joris","Hans"])
    }
}

final class RecentBoardVisitsTests: XCTestCase {
    func testRecentScoresResetOnNewLegAndUndoRestoresWinningLeg() throws {
        var game = LocalGame(config:GameConfig(players:["Solo"],game:301,bestOf:3))
        game.events = [ScoreEvent(score:180),ScoreEvent(score:180,bust:true)]
        XCTAssertEqual(try DartRules.replay(game).recent[0],[nil,180])
        game.events.append(ScoreEvent(score:121,finish:true))
        XCTAssertEqual(try DartRules.replay(game).recent[0],[])
        game.events += [ScoreEvent(score:180),ScoreEvent(score:121,finish:true)]
        XCTAssertEqual(try DartRules.replay(game).recent[0],[121,180])
        game.events.append(.undo(game.events.last!.id))
        XCTAssertEqual(try DartRules.replay(game).recent[0],[180])
    }
    func testThreePlayersKeepSeparateRecentVisits() throws {
        var game = LocalGame(config:GameConfig(players:["A","B","C"]))
        game.events = [ScoreEvent(score:60),ScoreEvent(score:26),ScoreEvent(score:45),ScoreEvent(score:100)]
        XCTAssertEqual(try DartRules.replay(game).recent,[[100,60],[26],[45]])
    }
}
