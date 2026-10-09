import SwiftUI
import AVKit
import AVFoundation
import Network
import UniformTypeIdentifiers
import Darwin

private final class BoardHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label:"com.yourdartclub.airplay.http")
    private let store: LiveBoardStream
    private let listener: NWListener
    private var clients: [UUID:NWConnection] = [:]
    init(store: LiveBoardStream) throws { self.store = store; listener = try NWListener(using:.tcp,on:.any) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                var waiting = true
                self.listener.stateUpdateHandler = { state in
                    guard waiting else { return }
                    switch state {
                    case .ready:
                        waiting = false
                        continuation.resume(returning:self.listener.port!.rawValue)
                    case .failed(let error): waiting = false; continuation.resume(throwing:error)
                    case .cancelled: waiting = false; continuation.resume(throwing:CancellationError())
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener.start(queue:self.queue)
                self.queue.asyncAfter(deadline:.now() + 10) {
                    if waiting { waiting = false; self.listener.cancel(); continuation.resume(throwing:URLError(.timedOut)) }
                }
            }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 16 else { connection.cancel(); return }
        let id = UUID(); clients[id] = connection
        connection.start(queue:queue)
        receive(connection,id:id,data:Data())
        queue.asyncAfter(deadline:.now() + 8) { [weak self] in self?.finish(id) }
    }
    private func finish(_ id: UUID) { clients.removeValue(forKey:id)?.cancel() }
    private func receive(_ connection: NWConnection,id: UUID,data: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:4096) { [weak self] bytes,_,complete,error in
            guard let self, self.clients[id] != nil else { return }
            var request = data; request.append(bytes ?? Data())
            guard request.count <= 16_384, error == nil else { self.finish(id); return }
            guard let headerEnd = request.range(of:Data("\r\n\r\n".utf8)) else {
                if complete { self.finish(id) } else { self.receive(connection,id:id,data:request) }; return
            }
            let lines = String(decoding:request[..<headerEnd.lowerBound],as:UTF8.self).components(separatedBy:"\r\n")
            let first = lines[0].split(separator:" ")
            guard first.count == 3, first[0] == "GET" || first[0] == "HEAD" else {
                self.send(.init(status:405,type:"text/plain",data:Data()),head:false,connection:connection,id:id); return
            }
            let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in:.whitespaces) }
            self.send(self.store.reply(path:String(first[1]),range:range),head:first[0] == "HEAD",connection:connection,id:id)
        }
    }
    private func send(_ reply: LiveBoardStream.Reply,head: Bool,connection: NWConnection,id: UUID) {
        let reason = [200:"OK",206:"Partial Content",404:"Not Found",405:"Method Not Allowed",416:"Range Not Satisfiable"][reply.status] ?? "Error"
        var response = Data("HTTP/1.1 \(reply.status) \(reason)\r\nContent-Type: \(reply.type)\r\nContent-Length: \(reply.data.count)\r\nCache-Control: no-store\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\(reply.headers)\r\n".utf8)
        if !head { response.append(reply.data) }
        connection.send(content:response,completion:.contentProcessed { [weak self] _ in self?.finish(id) })
    }
    func stop() { store.close(); queue.async { self.listener.cancel(); for id in Array(self.clients.keys) { self.finish(id) } } }
    static func wifiHost() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }; defer { freeifaddrs(first) }
        var current = first, ipv6: String?
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString:entry.pointee.ifa_name)
            guard name.hasPrefix("en"), entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating:0,count:Int(NI_MAXHOST))
            if getnameinfo(address,socklen_t(address.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST) == 0 {
                let value = String(cString:host)
                if family == AF_INET { return value }
                if !value.hasPrefix("fe80:"), !value.contains("%") { ipv6 = "[\(value)]" }
            }
        }
        return ipv6
    }
}

private final class BoardSegmentSink: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    let store: LiveBoardStream
    init(_ store: LiveBoardStream) { self.store = store }
    func assetWriter(_ writer: AVAssetWriter,didOutputSegmentData data: Data,segmentType: AVAssetSegmentType,segmentReport: AVAssetSegmentReport?) {
        // Copy Apple's transient segment buffer; never retain its backing allocation.
        let copy = data.withUnsafeBytes { Data($0) }
        if segmentType == .initialization { store.initialize(copy) }
        else if let report = segmentReport?.trackReports.first(where:{$0.mediaType == .video}) {
            store.append(copy,duration:report.duration.seconds)
        }
    }
}

@MainActor final class AirPlayBoardStream: ObservableObject {
    static let shared = AirPlayBoardStream()
    @Published private(set) var preparing = false
    @Published private(set) var ready = false
    @Published private(set) var connected = false
    @Published private(set) var issue: String?
    let player = AVPlayer()
    private var generation = UUID()
    private var server: BoardHTTPServer?
    private var store: LiveBoardStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sink: BoardSegmentSink?
    private var pump: Task<Void,Never>?
    private var observation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var background: NSObjectProtocol?
    private var interruption: NSObjectProtocol?
    private var priorIdleSetting: Bool?
    private var playbackURL: URL?
    private var diagnosticError = ""
    private var started = Date()
    private var lastTime = CMTime.invalid
    private init() {
        player.allowsExternalPlayback = true
        observation = player.observe(\.isExternalPlaybackActive,options:[.initial,.new]) { [weak self] player,_ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor in self?.connected = active }
        }
        background = NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in if self?.ready == true || self?.preparing == true { self?.stop(); self?.issue = "airplay_stream_background" } }
        }
        interruption = NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in if self?.ready == true { self?.stop(); self?.issue = "airplay_stream_background" } }
        }
    }
    func start() async {
        guard !preparing, !ready else { return }
        stop(); preparing = true; issue = nil
        let current = generation
        priorIdleSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            guard let host = BoardHTTPServer.wifiHost() else { throw URLError(.notConnectedToInternet) }
            let store = LiveBoardStream(); self.store = store
            let server = try BoardHTTPServer(store:store); self.server = server
            let port = try await server.start()
            guard generation == current else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback,mode:.moviePlayback,options:[])
            try AVAudioSession.sharedInstance().setActive(true)
            let writer = AVAssetWriter(contentType:.mpeg4Movie)
            writer.outputFileTypeProfile = .mpeg4AppleHLS
            writer.preferredOutputSegmentInterval = CMTime(seconds:1,preferredTimescale:600)
            writer.initialSegmentStartTime = .zero
            let sink = BoardSegmentSink(store); self.sink = sink; writer.delegate = sink
            let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:1280,AVVideoHeightKey:720,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:1_500_000,AVVideoExpectedSourceFrameRateKey:10,AVVideoMaxKeyFrameIntervalKey:10,AVVideoMaxKeyFrameIntervalDurationKey:1,AVVideoAllowFrameReorderingKey:false,AVVideoProfileLevelKey:AVVideoProfileLevelH264MainAutoLevel]])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:1280,kCVPixelBufferHeightKey as String:720,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
            guard writer.canAdd(input) else { throw URLError(.cannotCreateFile) }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? URLError(.cannotCreateFile) }
            writer.startSession(atSourceTime:.zero)
            self.writer = writer; self.input = input; self.adaptor = adaptor
            started = Date(); lastTime = .invalid
            pump = Task { [weak self] in
                while !Task.isCancelled {
                    self?.appendFrame()
                    do { try await Task.sleep(for:.milliseconds(100)) } catch { break }
                }
            }
            for _ in 0..<100 {
                guard generation == current else { return }
                if store.count >= 4 { break }
                if writer.status == .failed { throw writer.error ?? URLError(.cannotDecodeContentData) }
                try await Task.sleep(for:.milliseconds(200))
            }
            guard generation == current, store.count >= 4 else { throw URLError(.timedOut) }
            let url = URL(string:"http://\(host):\(port)/\(store.key)/live.m3u8")!
            playbackURL = url
            let item = AVPlayerItem(url:url)
            item.preferredForwardBufferDuration = 1
            item.configuredTimeOffsetFromLive = CMTime(seconds:3,preferredTimescale:600)
            item.automaticallyPreservesTimeOffsetFromLive = true
            statusObservation = item.observe(\.status,options:[.new]) { [weak self] item,_ in
                if item.status == .failed { Task { @MainActor in guard self?.generation == current else { return }; self?.stop(); self?.issue = "airplay_stream_failed" } }
            }
            player.replaceCurrentItem(with:item); player.play()
            ready = true; preparing = false
        } catch {
            guard generation == current else { return }
            diagnosticError = String(describing:error)
            stop(); issue = "airplay_stream_failed"
        }
    }
    func stop() {
        generation = UUID(); pump?.cancel(); pump = nil
        statusObservation = nil; player.pause(); player.replaceCurrentItem(with:nil)
        writer?.cancelWriting(); writer = nil; input = nil; adaptor = nil; sink = nil
        server?.stop(); server = nil; store = nil; playbackURL = nil
        preparing = false; ready = false; connected = false
        if let priorIdleSetting { UIApplication.shared.isIdleTimerDisabled = priorIdleSetting }; priorIdleSetting = nil
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
    }
    private func appendFrame() {
        guard let input, let adaptor, let writer else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        if writer.status == .failed || (ready && store?.count == 0) { stop(); issue = "airplay_stream_failed"; return }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer,[]); defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        guard let context = CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:1280,height:720,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        context.translateBy(x:0,y:720); context.scaleBy(x:1,y:-1)
        UIGraphicsPushContext(context)
        BoardVideoArtwork.draw(BoardCasting.shared.frame)
        UIGraphicsPopContext()
        let time = CMTime(seconds:Date().timeIntervalSince(started),preferredTimescale:600)
        guard !lastTime.isValid || time > lastTime else { return }
        if adaptor.append(buffer,withPresentationTime:time) { lastTime = time }
        else if writer.status == .failed { stop(); issue = "airplay_stream_failed" }
    }
}

@MainActor private enum BoardVideoArtwork {
    static func draw(_ frame: BoardFrame) {
        UIColor(ClubStyle.background).setFill(); UIRectFill(CGRect(x:0,y:0,width:1280,height:720))
        UIImage(named:"Wordmark")?.draw(in:CGRect(x:40,y:28,width:280,height:69))
        text(frame.title,CGRect(x:350,y:30,width:890,height:45),size:30,color:UIColor(ClubStyle.text),alignment:.right)
        text(frame.subtitle,CGRect(x:350,y:77,width:890,height:30),size:22,color:UIColor(ClubStyle.muted),alignment:.right)
        let count = max(1,frame.players.count), width = (1200 - CGFloat(count - 1) * 16) / CGFloat(count)
        for (i,p) in frame.players.enumerated() {
            let rect = CGRect(x:40 + CGFloat(i) * (width + 16),y:135,width:width,height:510)
            let path = UIBezierPath(roundedRect:rect,cornerRadius:22)
            UIColor(p.active ? ClubStyle.elevated : ClubStyle.card).setFill(); path.fill()
            UIColor(p.active ? ClubStyle.lime : ClubStyle.border).setStroke(); path.lineWidth = 2; path.stroke()
            text(p.status,CGRect(x:rect.minX + 12,y:143,width:width - 24,height:24),size:17,color:UIColor(ClubStyle.lime))
            text(p.name,CGRect(x:rect.minX + 12,y:170,width:width - 24,height:45),size:count > 2 ? 28 : 38,color:UIColor(p.active ? ClubStyle.lime : ClubStyle.text))
            text(String(p.remaining),CGRect(x:rect.minX + 12,y:218,width:width - 24,height:168),size:min(145,width * 0.43),color:UIColor(ClubStyle.text))
            text("Ø \(p.average) · \(p.maximums) × 180",CGRect(x:rect.minX + 12,y:389,width:width - 24,height:30),size:count > 2 ? 22 : 28,color:UIColor(ClubStyle.text))
            text("\(p.darts) \(tr("darts"))",CGRect(x:rect.minX + 12,y:420,width:width - 24,height:22),size:17,color:UIColor(ClubStyle.muted))
            text(tr("tv_recent_visits"),CGRect(x:rect.minX + 12,y:547,width:width - 24,height:24),size:17,color:UIColor(ClubStyle.muted))
            text(p.recent.isEmpty ? "—" : p.recent.joined(separator:"   ·   "),CGRect(x:rect.minX + 12,y:580,width:width - 24,height:38),size:count > 2 ? 22 : 30,color:UIColor(ClubStyle.lime))
            let targets = p.advice.prefix(3), tile = min(90,(width - 32) / 3)
            for (j,value) in targets.enumerated() {
                let box = CGRect(x:rect.midX - CGFloat(targets.count) * tile / 2 + CGFloat(j) * tile + 3,y:442,width:tile - 6,height:44)
                UIColor(ClubStyle.lime).withAlphaComponent(0.14).setFill(); UIBezierPath(roundedRect:box,cornerRadius:8).fill()
                text(value,box.insetBy(dx:2,dy:6),size:26,color:UIColor(ClubStyle.lime))
            }
            text("\(p.legs) \(frame.legsLabel)",CGRect(x:rect.minX + 12,y:496,width:width - 24,height:42),size:36,color:UIColor(ClubStyle.lime))
        }
        if !frame.message.isEmpty { text(frame.message,CGRect(x:40,y:650,width:1200,height:28),size:26,color:UIColor(ClubStyle.text)) }
        if frame.stale { text(frame.staleMessage,CGRect(x:40,y:684,width:1200,height:25),size:22,color:.orange) }
    }
    static func text(_ value: String,_ rect: CGRect,size: CGFloat,color: UIColor,alignment: NSTextAlignment = .center) {
        var size = size
        while size > 12 && (value as NSString).size(withAttributes:[.font:UIFont(name:"Arial-BoldMT",size:size) ?? .boldSystemFont(ofSize:size)]).width > rect.width { size -= 1 }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in:rect,withAttributes:[.font:UIFont(name:"Arial-BoldMT",size:size) ?? .boldSystemFont(ofSize:size),.foregroundColor:color,.paragraphStyle:paragraph])
    }
}

struct AirPlayRouteButton: UIViewRepresentable {
    let label: String
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.prioritizesVideoDevices = true
        // The system picker itself receives the tap across the whole row. The
        // non-interactive SwiftUI label supplies its visible icon and title.
        view.tintColor = .clear; view.activeTintColor = .clear
        view.accessibilityLabel = tr(label)
        return view
    }
    func updateUIView(_ view: AVRoutePickerView,context: Context) { view.accessibilityLabel = tr(label) }
}
/// A real player layer associates this app's video with the system route picker.
struct AirPlayVideoPreview: UIViewRepresentable {
    final class PlayerView: UIView { override class var layerClass: AnyClass { AVPlayerLayer.self } }
    func makeUIView(context: Context) -> PlayerView { let view = PlayerView(); (view.layer as? AVPlayerLayer)?.player = AirPlayBoardStream.shared.player; return view }
    func updateUIView(_ view: PlayerView,context: Context) {}
}

#if DEBUG && targetEnvironment(simulator)
extension AirPlayBoardStream {
    func runPickerSelfTest() {
        let picker = AVRoutePickerView(frame:CGRect(x:0,y:0,width:320,height:56))
        picker.prioritizesVideoDevices = true; picker.tintColor = .clear; picker.activeTintColor = .clear
        let host = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.rootViewController?.view
        host?.addSubview(picker); picker.setNeedsLayout(); picker.layoutIfNeeded()
        var results: [String:Bool] = [:]
        for x in [10,160,310] {
            var hit = picker.hitTest(CGPoint(x:x,y:28),with:nil)
            var control = false
            while let view = hit, view !== picker { if view is UIControl { control = true }; hit = view.superview }
            results["nativeButtonAtX\(x)"] = control
        }
        picker.removeFromSuperview()
        let path = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("AirPlayPickerTest.json")
        if let data = try? JSONEncoder().encode(results) { try? data.write(to:path) }
    }
    /// Opt-in integration diagnostic with synthetic scores, never a user's match.
    func runSelfTest() async {
        let folder = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("AirPlaySelfTest")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var result: [String:Any] = [:]
        BoardCasting.shared.frame = BoardFrame(title:"AirPlay stream test",subtitle:"501 · Double out",message:"",players:[.init(name:"Test A",remaining:301,legs:1,active:true,advice:[]),.init(name:"Test B",remaining:141,legs:0,active:false,advice:["T20","T19","D12"])],legsLabel:"Legs")
        await start()
        result["started"] = ready; result["failure"] = diagnosticError
        if let url = playbackURL, let store {
            do {
                let session = URLSession(configuration:.ephemeral)
                defer { session.invalidateAndCancel() }
                let (playlist,response) = try await session.data(from:url)
                result["playlistHTTP"] = (response as? HTTPURLResponse)?.statusCode
                try playlist.write(to:folder.appendingPathComponent("live.m3u8"))
                let files = String(decoding:playlist,as:UTF8.self).components(separatedBy:"\n").filter { $0.hasSuffix(".m4s") } + ["init.mp4"]
                for file in files { let (data,_) = try await session.data(from:url.deletingLastPathComponent().appendingPathComponent(file)); try data.write(to:folder.appendingPathComponent(file)) }
                let denied = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("wrong/live.m3u8")
                let (_,badResponse) = try await session.data(from:denied)
                result["unauthorizedHTTP"] = (badResponse as? HTTPURLResponse)?.statusCode
                for _ in 0..<80 {
                    if player.currentItem?.status == .readyToPlay && player.currentTime().seconds > 0 { break }
                    try await Task.sleep(for:.milliseconds(250))
                }
                result["playerReady"] = player.currentItem?.status == .readyToPlay
                result["playbackTime"] = player.currentTime().seconds.isFinite ? player.currentTime().seconds : -1
                result["playerError"] = player.currentItem?.error.map(String.init(describing:)) ?? ""
                result["boundedSegments"] = store.count <= 12
                BoardCasting.shared.frame = BoardFrame(title:"Next match · Board 1",subtitle:"501 · Double out",message:"",players:[.init(name:"Test C",remaining:60,legs:2,active:true,advice:["S20","D20"],average:"84,2",maximums:"2",darts:"36",status:"AAN DE WORP",recent:["100","60","Bust"]),.init(name:"Test D",remaining:120,legs:1,active:false,advice:["T20","S20","D20"],average:"71,5",maximums:"1",darts:"39",status:"RESTEREND",recent:["81","45","60"])],legsLabel:"Legs")
                try await Task.sleep(for:.seconds(12))
                let (updated,_) = try await session.data(from:url)
                result["playlistAdvanced"] = updated != playlist
                result["localPlaybackLagSeconds"] = Date().timeIntervalSince(started) - player.currentTime().seconds
                let updatedFolder = folder.appendingPathComponent("updated")
                try FileManager.default.createDirectory(at:updatedFolder,withIntermediateDirectories:true)
                try updated.write(to:updatedFolder.appendingPathComponent("live.m3u8"))
                let updatedFiles = String(decoding:updated,as:UTF8.self).components(separatedBy:"\n").filter { $0.hasSuffix(".m4s") } + ["init.mp4"]
                for file in updatedFiles { let (data,_) = try await session.data(from:url.deletingLastPathComponent().appendingPathComponent(file)); try data.write(to:updatedFolder.appendingPathComponent(file)) }
                stop()
                result["stopped"] = !ready && player.currentItem == nil && store.reply(path:"/\(store.key)/live.m3u8").status == 404
            } catch { result["testError"] = String(describing:error); stop() }
        }
        if let data = try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:folder.appendingPathComponent("result.json")) }
        BoardCasting.shared.frame = .idle
    }
}
#endif
