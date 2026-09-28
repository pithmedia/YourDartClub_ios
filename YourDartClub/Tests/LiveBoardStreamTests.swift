import XCTest
@testable import DartCore

final class LiveBoardStreamTests: XCTestCase {
    private func stream() -> LiveBoardStream {
        let store = LiveBoardStream(key:"test-capability")
        store.initialize(Data("init".utf8))
        for i in 0..<20 { store.append(Data("segment-\(i)".utf8),duration:1) }
        return store
    }
    func testBoundedSlidingWindowAndStableSequence() {
        let store = stream()
        XCTAssertEqual(store.count,12)
        let reply = store.reply(path:"/test-capability/live.m3u8")
        let text = String(decoding:reply.data,as:UTF8.self)
        XCTAssertEqual(reply.status,200)
        XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:14\n"))
        XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:1\n"))
        XCTAssertTrue(text.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertFalse(text.contains("#EXT-X-ENDLIST"))
        XCTAssertEqual(store.reply(path:"/test-capability/7.m4s").status,404)
        XCTAssertEqual(store.reply(path:"/test-capability/8.m4s").status,200)
        store.append(Data(),duration:1.1)
        XCTAssertTrue(String(decoding:store.reply(path:"/test-capability/live.m3u8").data,as:UTF8.self).contains("#EXT-X-TARGETDURATION:1\n"))
    }
    func testCapabilityAndStopRevokeAllResources() {
        let store = stream()
        for path in ["/live.m3u8","/wrong/live.m3u8","/test-capability/../init.mp4","/test-capability/%2e%2e/init.mp4"] { XCTAssertEqual(store.reply(path:path).status,404) }
        store.close()
        store.initialize(Data("late".utf8)); store.append(Data("late".utf8),duration:1)
        XCTAssertEqual(store.count,0)
        XCTAssertEqual(store.reply(path:"/test-capability/init.mp4").status,404)
        XCTAssertEqual(store.reply(path:"/test-capability/live.m3u8").status,404)
        XCTAssertNotEqual(LiveBoardStream().key,LiveBoardStream().key)
    }
    func testByteRangesForMediaPlayers() {
        let store = stream()
        let path = "/test-capability/init.mp4"
        XCTAssertEqual(String(decoding:store.reply(path:path,range:"bytes=1-2").data,as:UTF8.self),"ni")
        XCTAssertEqual(store.reply(path:path,range:"bytes=1-2").status,206)
        XCTAssertEqual(store.reply(path:path,range:"bytes=1-2").headers,"Content-Range: bytes 1-2/4\r\n")
        XCTAssertEqual(String(decoding:store.reply(path:path,range:"bytes=-2").data,as:UTF8.self),"it")
        XCTAssertEqual(String(decoding:store.reply(path:path,range:"bytes=2-").data,as:UTF8.self),"it")
        for invalid in ["bytes=9-10","bytes=2-1","bytes=1-2,3-4","bytes=abc-2","bytes=-0"] { XCTAssertEqual(store.reply(path:path,range:invalid).status,416) }
    }
    func testPlaylistWaitsForPlayableWindow() {
        let store = LiveBoardStream(key:"test")
        store.initialize(Data("init".utf8))
        store.append(Data(),duration:.nan); store.append(Data(),duration:-1)
        XCTAssertEqual(store.count,0)
        for _ in 0..<3 { store.append(Data(),duration:1) }
        XCTAssertEqual(store.reply(path:"/test/live.m3u8").status,404)
        store.append(Data(),duration:1)
        XCTAssertEqual(store.reply(path:"/test/live.m3u8").status,200)
    }
}
