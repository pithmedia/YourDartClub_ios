import XCTest
@testable import DartCore

final class PlatformTests: XCTestCase {
    private func snapshot(firstStatus: String = "live", nextStatus: String = "queued") throws -> PlatformSnapshot {
        let json = """
        {"players":[{"id":"a","name":"Alex"},{"id":"b","name":"Sam"}],"evenings":[{"id":"e","name":"Club","date":"2026-09-26","mode":"knockout","game":"501","checkout":"double","bestOf":3,"boards":2,"revision":7,"status":"active","players":["a","b"],"matches":[
        {"id":"old","a":"a","b":"b","status":"\(firstStatus)","board":1,"scoreA":0,"scoreB":0,"round":1,"stage":"knockout","counter":{"revision":2,"visits":[{"id":"lost-response-visit","score":60,"darts":3,"bust":false,"finish":false}],"state":{"remainingA":441,"remainingB":501,"scoreA":1,"scoreB":0,"turn":"B","leg":2,"pendingWinner":null}}},
        {"id":"other-board","a":"a","b":"b","status":"live","board":2,"scoreA":0,"scoreB":0,"round":1,"stage":"knockout"},
        {"id":"next","a":"b","b":"a","status":"\(nextStatus)","board":1,"scoreA":0,"scoreB":0,"round":2,"stage":"knockout"},
        {"id":"bye","a":"a","b":null,"status":"done","board":null,"scoreA":0,"scoreB":0,"round":1,"stage":"knockout"}
        ],"standings":[{"id":"a","played":1,"won":1,"points":2,"diff":2}]}]}
        """
        return try JSONDecoder().decode(PlatformSnapshot.self,from:Data(json.utf8))
    }
    func testBoardSelectionFollowsBoardInsteadOfOldMatch() throws {
        let initial = try snapshot().evenings[0]
        XCTAssertEqual(initial.live(on:1)?.id,"old")
        XCTAssertEqual(initial.live(on:1)?.legsA,1)
        let next = try snapshot(firstStatus:"done",nextStatus:"live").evenings[0]
        XCTAssertEqual(next.live(on:1)?.id,"next")
        XCTAssertEqual(next.live(on:2)?.id,"other-board")
        XCTAssertNil(next.live(on:3))
    }
    func testSnapshotKeepsVisitIDsForLostResponseReconciliationAndAllowsByes() throws {
        let data = try snapshot()
        XCTAssertEqual(data.evenings[0].matches[0].counter?.visits.first?.id,"lost-response-visit")
        XCTAssertNil(data.evenings[0].matches.last?.b)
        XCTAssertEqual(data.evenings[0].standings?.first?.points,2)
        XCTAssertNil(data.createdId)
    }
}

final class CompetitionTests: XCTestCase {
    private func overview(stale: Bool = false, unavailable: Bool = false) throws -> CompetitionOverview {
        let json = """
        {
          "settings":{"season":"26-27","division":"4G","teamId":"84086535","name":"Flight Club","venue":"Café De Proeverij"},
          "canManage":true,"currentSeason":"26-27",
          "standings":[
            {"id":"111","name":"Rivals","position":1,"played":2,"won":2,"lost":0,"points":"10","average":"5.0","penalty":""},
            {"id":"84086535","name":"Flight Club","position":2,"played":2,"won":1,"lost":1,"points":"9","average":"4.5","penalty":""}
          ],
          "fixtures":[
            {"id":"upcoming","date":"2026-10-13","homeId":"84086535","awayId":"111","home":"Flight Club","away":"Rivals","score":null},
            {"id":"played","date":"2026-10-06","homeId":"111","awayId":"84086535","home":"Rivals","away":"Flight Club","score":"4-5"}
          ],
          "fetchedAt":1791300000,"stale":\(stale),"unavailable":\(unavailable),
          "source":"https://feeds.teambeheer.nl/web/stand/?d=41&div=4G&s=26-27",
          "teamSource":"https://feeds.teambeheer.nl/web/team?d=41&t=84086535&s=26-27"
        }
        """
        return try JSONDecoder().decode(CompetitionOverview.self,from:Data(json.utf8))
    }
    func testFlightClubReferenceDecodesFullStandingsScheduleResultsVenueAndSources() throws {
        let data = try overview()
        XCTAssertEqual(data.settings?.name,"Flight Club")
        XCTAssertEqual(data.settings?.venue,"Café De Proeverij")
        XCTAssertEqual(data.table.count,2)
        XCTAssertEqual(data.table.first(where:{$0.id == "84086535"})?.position,2)
        XCTAssertEqual(data.schedule.map(\.id),["upcoming"])
        XCTAssertEqual(data.results.map(\.id),["played"])
        XCTAssertEqual(data.results.first?.score,"4-5")
        XCTAssertEqual(data.source?.host,"feeds.teambeheer.nl")
        XCTAssertEqual(data.teamSource?.host,"feeds.teambeheer.nl")
    }
    func testSetupVisibilityAndManagementRespectLanguageAndExistingLink() throws {
        let linked = try overview()
        XCTAssertTrue(CompetitionPolicy.visible(language:"nl",overview:nil))
        XCTAssertFalse(CompetitionPolicy.visible(language:"en",overview:nil))
        for language in ["nl","en","fr","de"] { XCTAssertTrue(CompetitionPolicy.visible(language:language,overview:linked)) }
        XCTAssertTrue(CompetitionPolicy.manageable(language:"nl",overview:linked))
        for language in ["en","fr","de"] { XCTAssertFalse(CompetitionPolicy.manageable(language:language,overview:linked)) }
        let readOnly = try JSONDecoder().decode(CompetitionOverview.self,from:Data("{\"settings\":null,\"canManage\":false,\"currentSeason\":\"26-27\"}".utf8))
        XCTAssertFalse(CompetitionPolicy.manageable(language:"nl",overview:readOnly))
    }
    func testRefreshPolicyRunsEachMinuteOnlyForVisibleActiveScreen() {
        XCTAssertEqual(CompetitionPolicy.pollInterval,60)
        XCTAssertTrue(CompetitionPolicy.shouldPoll(screenVisible:true,appActive:true))
        XCTAssertFalse(CompetitionPolicy.shouldPoll(screenVisible:false,appActive:true))
        XCTAssertFalse(CompetitionPolicy.shouldPoll(screenVisible:true,appActive:false))
        XCTAssertFalse(CompetitionPolicy.shouldPoll(screenVisible:false,appActive:false))
    }
    func testStaleSourceResponseKeepsLastSuccessfulDataVisible() throws {
        let data = try overview(stale:true)
        XCTAssertEqual(data.stale,true)
        XCTAssertEqual(data.unavailable,false)
        XCTAssertEqual(data.table.count,2)
        XCTAssertEqual(data.schedule.count,1)
        XCTAssertNotNil(data.fetchedAt)
    }
    func testSeasonChoicesMatchWebsiteCurrentPreviousAndLinkedBehavior() {
        XCTAssertEqual(CompetitionPolicy.seasons(current:"26-27",linked:nil),["26-27","25-26"])
        XCTAssertEqual(CompetitionPolicy.seasons(current:"26-27",linked:"24-25"),["26-27","25-26","24-25"])
        XCTAssertEqual(CompetitionPolicy.seasons(current:"26-27",linked:"26-27"),["26-27","25-26"])
    }
}

final class TeamStatisticsTests: XCTestCase {
    private func fixture(track: Bool = true, initial: Int = 501, visits: [[String:Any]]? = nil) throws -> PlatformSnapshot {
        func visit(_ score: Int,_ bust: Bool = false,_ finish: Bool = false,_ darts: Int = 3) -> [String:Any] {
            ["id":UUID().uuidString,"score":score,"darts":darts,"bust":bust,"finish":finish]
        }
        let counter: [String:Any] = ["revision":1,"initialA":initial,"initialB":501,"starter":"A","legStarter":"A","base":["scoreA":0,"scoreB":0],
            "state":["remainingA":0,"remainingB":501,"scoreA":1,"scoreB":0,"turn":"A","leg":1],
            "visits":visits ?? [visit(180),visit(0),visit(180),visit(0),visit(180,true),visit(0),visit(141,false,true)]]
        let match: [String:Any] = ["id":"m","a":"a","b":"b","status":"done","scoreA":1,"scoreB":0,"round":1,"stage":"league","winner":"a","maximumsA":2,"maximumsB":0,"checkoutA":141,"checkoutB":0,"counter":counter]
        var live = match; live["id"] = "live"; live["status"] = "live"
        var bye = match; bye["id"] = "bye"; bye["b"] = NSNull()
        let event: [String:Any] = ["id":"e","name":"Evening","date":"2026-09-26","mode":"round-robin","game":"501","checkout":"double","bestOf":1,"boards":1,"revision":1,"status":"completed","players":["a","b"],"champion":"a","trackStats":track,"matches":[match,live,bye]]
        return try JSONDecoder().decode(PlatformSnapshot.self,from:JSONSerialization.data(withJSONObject:["players":[["id":"a","name":"Alex"],["id":"b","name":"Sam"]],"evenings":[event]]))
    }
    func testWebsiteParityForBustsFirstNineScoringAndByes() throws {
        let snapshot = try fixture()
        let a = TeamPlayerStats.make(player:snapshot.players[0],events:snapshot.evenings)
        XCTAssertEqual(a.played,1); XCTAssertEqual(a.won,1); XCTAssertEqual(a.legs,1)
        XCTAssertEqual(a.titles,1); XCTAssertEqual(a.maximums,2); XCTAssertEqual(a.checkout,141)
        XCTAssertEqual(a.recordedMatches,1); XCTAssertEqual(a.total.darts,12)
        XCTAssertEqual(a.total.value,125.25); XCTAssertEqual(a.firstNine.value,120)
        XCTAssertEqual(a.scoring.value,180)
        let b = TeamPlayerStats.make(player:snapshot.players[1],events:snapshot.evenings)
        XCTAssertEqual(b.total.value,0); XCTAssertEqual(b.firstNine.value,0)
    }
    func testUntrackedEventsExcludedFromAllPlayerStats() throws {
        let snapshot = try fixture(track:false)
        let a = TeamPlayerStats.make(player:snapshot.players[0],events:snapshot.evenings)
        XCTAssertEqual(a.played,0); XCTAssertEqual(a.titles,0); XCTAssertEqual(a.maximums,0)
        XCTAssertNil(a.total.value); XCTAssertNil(a.firstNine.value)
    }
    func testPartialLegDoesNotInventFirstNineAndCrossingNineIsExcluded() throws {
        let snapshot = try fixture(initial:681)
        let a = TeamPlayerStats.make(player:snapshot.players[0],events:snapshot.evenings)
        XCTAssertNotNil(a.total.value); XCTAssertNil(a.firstNine.value)
        let visits = (0..<8).map { i -> [String:Any] in
            ["id":String(i),"score":0,"darts":i == 0 ? 2 : 3,"bust":false,"finish":false]
        }
        let crossed = try fixture(visits:visits)
        let result = TeamPlayerStats.make(player:crossed.players[0],events:crossed.evenings)
        XCTAssertEqual(result.total.darts,11); XCTAssertNil(result.firstNine.value)
    }
    func testRankingStableAndMissingVisitMetadataDoesNotInventAverages() throws {
        let snapshot = try fixture()
        let ranking = TeamPlayerStats.ranking(players:snapshot.players.reversed(),events:snapshot.evenings)
        XCTAssertEqual(ranking.first?.id,"a")
        let empty = TeamPlayerStats.ranking(players:snapshot.players.reversed(),events:[])
        XCTAssertEqual(empty.first?.id,"b")
        let raw = """
        {"players":[{"id":"a","name":"A"}],"evenings":[{"id":"e","name":"E","mode":"free","date":"2026-09-26","game":"501","checkout":"double","bestOf":1,"boards":1,"revision":0,"status":"completed","players":["a","b"],"matches":[{"id":"m","a":"a","b":"b","scoreA":1,"scoreB":0,"winner":"a","round":1,"stage":"friendly","status":"done"}]}]}
        """
        let manual = try JSONDecoder().decode(PlatformSnapshot.self,from:Data(raw.utf8))
        let stats = TeamPlayerStats.make(player:manual.players[0],events:manual.evenings)
        XCTAssertEqual(stats.played,1); XCTAssertEqual(stats.won,1); XCTAssertNil(stats.total.value)
    }
}

extension TeamStatisticsTests {
    func testPlatformBoardRecentVisitsAreCurrentLegOnlyAndIncludeBusts() throws {
        let initial = try fixture().evenings[0]
        XCTAssertEqual(initial.matches[0].counter?.recentScores(in:initial),[[141,nil,180],[0,0,0]])
        let raw = """
        {"id":"e","name":"E","mode":"free","date":"2026-09-26","game":"501","checkout":"double","bestOf":3,"boards":1,"revision":0,"status":"active","players":["a","b"],"matches":[{"id":"m","a":"a","b":"b","scoreA":0,"scoreB":1,"round":1,"stage":"friendly","status":"live","counter":{"revision":2,"starter":"B","legStarter":"A","initialA":40,"initialB":40,"base":{"scoreA":0,"scoreB":0},"visits":[{"id":"one","score":40,"darts":1,"finish":true,"bust":false},{"id":"two","score":60,"darts":3,"finish":false,"bust":false}],"state":{"remainingA":501,"remainingB":441,"scoreA":0,"scoreB":1,"turn":"A","leg":2}}}]}
        """
        let next = try JSONDecoder().decode(Evening.self,from:Data(raw.utf8))
        XCTAssertEqual(next.matches[0].counter?.recentScores(in:next),[[],[60]])
    }
}

final class EventAdviceTests: XCTestCase {
    func testCountsAndConcurrentBoards() {
        for n in [3,5,7,15] {
            XCTAssertEqual(EventAdvice.leagueMatches(n),n*(n-1)/2)
            XCTAssertEqual(EventAdvice.simultaneous(n,boards:8),n/2)
            XCTAssertEqual(EventAdvice.simultaneous(n,boards:1),1)
        }
        XCTAssertEqual(EventAdvice.total(5,mode:"playoffs",thirdPlace:false),13)
        XCTAssertEqual(EventAdvice.total(5,mode:"playoffs",thirdPlace:true),14)
        XCTAssertEqual(EventAdvice.byes(7),1)
        XCTAssertEqual(EventAdvice.byes(8),0)
        XCTAssertEqual(EventAdvice.total(7,mode:"knockout",thirdPlace:true),6)
    }
    func testOldAndBronzeServerSnapshots() throws {
        let raw = """
        {"id":"e","name":"E","mode":"playoffs","date":"2026-09-26","game":"501","checkout":"double","bestOf":3,"boards":2,"revision":0,"status":"active","players":["a","b","c","d"],"matches":[]}
        """
        let old = try JSONDecoder().decode(Evening.self,from:Data(raw.utf8))
        XCTAssertNil(old.thirdPlaceMatch)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any])
        object["thirdPlaceMatch"] = true
        object["champion"] = "a"
        object["matches"] = [["id":"bronze","a":"c","b":"d","stage":"knockout","round":2,"placement":3,"status":"live","board":2,"scoreA":0,"scoreB":0]]
        let updated = try JSONDecoder().decode(Evening.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(updated.thirdPlaceMatch,true)
        XCTAssertEqual(updated.live(on:2)?.placement,3)
        XCTAssertEqual(updated.champion,"a")
        XCTAssertTrue(updated.matches.filter { $0.placement == nil }.isEmpty)
    }
}
