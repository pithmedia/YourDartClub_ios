import Foundation

/// Bounded, in-memory HLS store. The random path grants display-only access;
/// no platform credentials, files, or score-writing endpoints are exposed.
final class LiveBoardStream: @unchecked Sendable {
    struct Segment { let sequence: Int; let duration: Double; let data: Data; let date: Date }
    struct Reply { let status: Int; let type: String; let data: Data; var headers: String = "" }
    let key: String
    private let lock = NSLock()
    private var initialization: Data?
    private var segments: [Segment] = []
    private var next = 0
    private var nextDate = Date()
    private var closed = false
    init(key: String = UUID().uuidString + UUID().uuidString) { self.key = key }
    var count: Int { lock.lock(); defer { lock.unlock() }; return segments.count }
    func initialize(_ data: Data) { lock.lock(); defer { lock.unlock() }; if !closed { initialization = data } }
    func append(_ data: Data,duration: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, duration.isFinite, duration > 0, data.count <= 8_000_000 else { return }
        // A delayed encoder must fail rather than publish an invalid target duration.
        if duration >= 1.5 { closed = true; initialization = nil; segments = []; return }
        segments.append(Segment(sequence:next,duration:duration,data:data,date:nextDate)); next += 1; nextDate = nextDate.addingTimeInterval(duration)
        // Keep about 12 seconds of media; playlists advertise the most recent six.
        if segments.count > 12 { segments.removeFirst(segments.count - 12) }
    }
    func close() { lock.lock(); defer { lock.unlock() }; closed = true; initialization = nil; segments = [] }
    func reply(path: String,range: String? = nil) -> Reply {
        lock.lock(); defer { lock.unlock() }
        guard !closed, path.hasPrefix("/\(key)/") else { return Reply(status:404,type:"text/plain",data:Data()) }
        let resource = String(path.dropFirst(key.count + 2))
        let type: String, data: Data
        if resource == "live.m3u8", initialization != nil, segments.count >= 4 {
            let window = Array(segments.suffix(6))
            let target = 1 // Must stay constant for the lifetime of the playlist.
            var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(max(1,target))\n#EXT-X-MEDIA-SEQUENCE:\(window[0].sequence)\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n"
            text += "#EXT-X-START:TIME-OFFSET=-3.0,PRECISE=NO\n"
            let dateFormat = ISO8601DateFormatter(); dateFormat.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            for segment in window {
                text += "#EXT-X-PROGRAM-DATE-TIME:\(dateFormat.string(from:segment.date))\n"
                text += "#EXTINF:\(String(format:"%.6f",locale:Locale(identifier:"en_US_POSIX"),segment.duration)),\n\(segment.sequence).m4s\n"
            }
            type = "application/vnd.apple.mpegurl"; data = Data(text.utf8)
        } else if resource == "init.mp4", let initialization {
            type = "video/mp4"; data = initialization
        } else if let segment = segments.first(where:{ resource == "\($0.sequence).m4s" }) {
            type = "video/mp4"; data = segment.data
        } else { return Reply(status:404,type:"text/plain",data:Data()) }
        guard let range else { return Reply(status:200,type:type,data:data) }
        guard range.hasPrefix("bytes="), !range.contains(",") else { return Reply(status:416,type:type,data:Data(),headers:"Content-Range: bytes */\(data.count)\r\n") }
        let parts = range.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
        guard parts.count == 2 else { return Reply(status:416,type:type,data:Data()) }
        let start: Int, end: Int
        if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 {
            start = max(0,data.count - suffix); end = data.count - 1
        } else if let first = Int(parts[0]), first >= 0, let last = parts[1].isEmpty ? data.count - 1 : Int(parts[1]) {
            start = first; end = min(last,data.count - 1)
        } else { return Reply(status:416,type:type,data:Data()) }
        guard start < data.count, end >= start else { return Reply(status:416,type:type,data:Data(),headers:"Content-Range: bytes */\(data.count)\r\n") }
        return Reply(status:206,type:type,data:data.subdata(in:start..<(end + 1)),headers:"Content-Range: bytes \(start)-\(end)/\(data.count)\r\n")
    }
}
