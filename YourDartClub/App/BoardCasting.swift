import SwiftUI
import UIKit
import Combine
import GoogleCast

struct BoardFrame: Codable, Equatable {
    struct Player: Codable, Equatable {
        let name: String; let remaining: Int; let legs: Int; let active: Bool; let advice: [String]
        var average = "—", maximums = "—", darts = "—", status = ""
        var recent: [String] = []
        // Keep the deployed TV relay protocol compatible. These additional fields
        // belong to the native AirPlay/external-display rendering; web TV uses its own counter.
        enum CodingKeys: String, CodingKey { case name, remaining, legs, active, advice }
    }
    var stale = false
    var staleMessage = tr("cast_stale")
    var title: String
    var subtitle: String
    var message: String
    var players: [Player]
    var legsLabel: String
    static var idle: Self { Self(title:"YourDartClub",subtitle:"",message:tr("cast_choose_board"),players:[],legsLabel:tr("legs")) }
}
enum CastTarget: Equatable {
    case local(String)
    case board(team: Int,event: String,board: Int)
}
@MainActor final class BoardCasting: NSObject, ObservableObject, @preconcurrency GCKSessionManagerListener {
    static let shared = BoardCasting()
    @Published var frame = BoardFrame.idle
    @Published var target: CastTarget?
    @Published var externalConnected = false
    @Published var castConnected = false
    @Published var tvPaired = false
    @Published var stale = false
    private var model: AppModel?
    private var subscriptions = Set<AnyCancellable>()
    private var feed: Task<Void,Never>?
    private var writer: String?
    private var pairedDisplay: (team: Int,id: String)?
    private var lastRemote = Date.distantPast
    private var channel: GCKCastChannel?
    private var sdkInitialized = false
    static var receiverID: String { Bundle.main.object(forInfoDictionaryKey:"GoogleCastReceiverID") as? String ?? "" }
    static var configured: Bool { receiverID.range(of:"^[A-Fa-f0-9]{8}$",options:.regularExpression) != nil }
    func configure() {
        guard Self.configured, !sdkInitialized else { return }
        let options = GCKCastOptions(discoveryCriteria:GCKDiscoveryCriteria(applicationID:Self.receiverID))
        options.disableAnalyticsLogging = true
        GCKCastContext.setSharedInstanceWith(options)
        sdkInitialized = true
        GCKCastContext.sharedInstance().sessionManager.add(self)
    }
    func select(_ target: CastTarget,model: AppModel) {
        if self.target != target { writer = nil; tvPaired = false; frame = .idle }
        self.target = target; self.model = model; lastRemote = .distantPast
        subscriptions.removeAll()
        Publishers.Merge(model.$games.map { _ in () },model.$evenings.map { _ in () })
            .debounce(for:.milliseconds(30),scheduler:DispatchQueue.main)
            .sink { [weak self] in Task { await self?.refresh(fetchRemote:false) } }.store(in:&subscriptions)
        feed?.cancel()
        feed = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for:.seconds(2)) } catch { break }
            }
        }
    }
    private func refresh(fetchRemote: Bool = true) async {
        guard let model,let selected = target else { return }
        if UIApplication.shared.applicationState != .active { stale = true; frame.stale = true; return }
        switch selected {
        case .local(let id):
            guard let game = model.games.first(where:{$0.id == id}),let state = try? DartRules.replay(game) else { frame = .idle; break }
            frame = BoardFrame(title:tr("new_game"),subtitle:"\(game.config.game) · \(tr(game.config.checkout)) · \(tr("best_of")) \(game.config.bestOf) · \(tr("tv_current_leg")) \(max(1,state.legs.reduce(0,+) + (state.winner == nil ? 1 : 0)))",message:state.winner.map { modelName in game.config.players[modelName] + " · " + tr("winner") } ?? "",players:game.config.players.indices.map { i in
                var player = BoardFrame.Player(name:game.config.players[i],remaining:state.remaining[i],legs:state.legs[i],active:state.winner == nil && state.turn == i,advice:DartRules.advice(state.remaining[i],mode:game.config.checkout,darts:3)?.components(separatedBy:" · ") ?? [])
                player.average = state.dartsThrown[i] > 0 ? tvAverage(state.points[i],state.dartsThrown[i]) : "—"
                player.maximums = String(state.maximums[i]); player.darts = String(state.dartsThrown[i])
                player.status = tr(state.winner == i ? "winner" : player.active ? "tv_throwing" : "tv_remaining")
                player.recent = state.recent[i].map { $0.map(String.init) ?? tr("bust") }
                return player
            },legsLabel:tr("legs")); stale = false
        case .board(let team,let id,let board):
            guard model.loggedIn, model.selectedTeam == team else { await stop(); return }
            do {
                if fetchRemote && Date().timeIntervalSince(lastRemote) >= 6 { try await model.platformUpdate(team:team); lastRemote = Date() }
                guard target == selected else { return }
                guard let e = model.evenings.first(where:{$0.id == id}) else { frame = .idle; break }
                let match = e.live(on:board)
                frame = BoardFrame(title:"\(e.name) · \(tr("board")) \(board)",subtitle:"\(e.game) · \(tr(e.checkout)) · \(tr("best_of")) \(e.bestOf) · \(tr("tv_current_leg")) \(match?.counter?.state.leg ?? 1)",message:match == nil ? tr(e.status == "completed" ? "status_completed" : "board_waiting") : "",players:match.map { m in
                    ["A","B"].map { side in
                        let rest = (side == "A" ? m.counter?.state.remainingA : m.counter?.state.remainingB) ?? e.initial
                        var player = BoardFrame.Player(name:model.playerName(side == "A" ? m.a : m.b),remaining:rest,legs:side == "A" ? m.legsA : m.legsB,active:m.counter?.state.pendingWinner == nil && (m.counter?.state.turn ?? "A") == side,advice:DartRules.advice(rest,mode:e.checkout,darts:3)?.components(separatedBy:" · ") ?? [])
                        let state = m.counter?.state
                        let points = side == "A" ? state?.pointsA : state?.pointsB
                        let darts = side == "A" ? state?.dartsA : state?.dartsB
                        if let points, let darts { player.average = tvAverage(points,darts); player.darts = String(darts) }
                        player.maximums = (side == "A" ? state?.maximumsA : state?.maximumsB).map(String.init) ?? "—"
                        player.status = tr(state?.pendingWinner == side ? "winner" : player.active ? "tv_throwing" : "tv_remaining")
                        player.recent = (m.counter?.recentScores(in:e)[side == "A" ? 0 : 1] ?? []).map { $0.map(String.init) ?? tr("bust") }
                        return player
                    }
                } ?? [],legsLabel:tr("legs")); stale = false
            } catch { stale = true }
        }
        guard target == selected else { return }
        frame.stale = stale
        sendCast()
        if let writer {
            do { _ = try await MobileAPI(base:URL(string:"https://www.yourdartclub.com")!,token:writer).request("local-cast/frame",body:JSONSerialization.data(withJSONObject:["frame":try frameObject()])) }
            catch { stale = true }
        }
    }
    func pair(code: String) async throws {
        guard let model,let target else { throw APIError(status:0) }
        let normalized = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        switch target {
        case .board(let team,let event,let board):
            let data = try await model.platformRequest("tv/pair",body:["code":normalized,"name":"iPhone · \(tr("board")) \(board)","evening_id":event,"board":board,"page_size":1,"rotation_seconds":10,"locale":AppLanguage.code],team:team)
            struct PairReply: Decodable { let displayId: String }
            pairedDisplay = (team,try JSONDecoder().decode(PairReply.self,from:data).displayId)
        case .local:
            let data = try await MobileAPI(base:URL(string:"https://www.yourdartclub.com")!,token:nil).request("local-cast/pair",body:JSONSerialization.data(withJSONObject:["code":normalized,"frame":try frameObject()]))
            struct Reply: Decodable { let writer: String }
            writer = try JSONDecoder().decode(Reply.self,from:data).writer
        }
        tvPaired = true
    }
    private func frameObject() throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(frame)) }
    func stop() async {
        AirPlayBoardStream.shared.stop()
        subscriptions.removeAll()
        feed?.cancel(); feed = nil; target = nil; frame = .idle; stale = false
        sendCast()
        if let writer {
            do { _ = try await MobileAPI(base:URL(string:"https://www.yourdartclub.com")!,token:writer).request("local-cast/stop",body:Data("{\"stop\":true}".utf8)) }
            catch { model?.explain(error) }
        }
        writer = nil
        if let pairedDisplay, let model {
            do { _ = try await model.platformRequest("tv/revoke",body:["displayId":pairedDisplay.id],team:pairedDisplay.team); self.pairedDisplay = nil }
            catch { model.explain(error) }
        }
        tvPaired = pairedDisplay != nil
        if Self.configured { GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true) }
    }
    func sessionManager(_ sessionManager: GCKSessionManager,didStart session: GCKSession) { attach() }
    func sessionManager(_ sessionManager: GCKSessionManager,didResumeSession session: GCKSession) { attach() }
    func sessionManager(_ sessionManager: GCKSessionManager,didEnd session: GCKSession,withError error: Error?) { channel = nil; castConnected = false }
    private func attach() {
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else { return }
        let channel = GCKCastChannel(namespace:"urn:x-cast:com.yourdartclub.board")
        session.add(channel); self.channel = channel; castConnected = true; sendCast()
    }
    private func sendCast() {
        guard let channel,let data = try? JSONEncoder().encode(frame),let text = String(data:data,encoding:.utf8) else { return }
        var error: GCKError?
        _ = channel.sendTextMessage(text,error:&error)
    }
}
private func tvAverage(_ points: Int,_ darts: Int) -> String { darts > 0 ? (Double(points) * 3 / Double(darts)).formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier:AppLanguage.code))) : "—" }

struct GoogleCastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton { let button = GCKUICastButton(frame:CGRect(x:0,y:0,width:48,height:48)); button.tintColor = UIColor(ClubStyle.lime); return button }
    func updateUIView(_ uiView: GCKUICastButton,context: Context) {}
}
// The external display delegate is selected by Info.plist. Leave SwiftUI's
// application scene configuration untouched; no UIApplicationDelegateAdaptor.
final class BoardSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene,willConnectTo session: UISceneSession,options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene:scene)
        window.rootViewController = UIHostingController(rootView:ExternalBoardView().preferredColorScheme(.dark))
        window.isHidden = false; self.window = window; BoardCasting.shared.externalConnected = true
    }
    func sceneDidDisconnect(_ scene: UIScene) { window = nil; BoardCasting.shared.externalConnected = false }
}
struct ExternalBoardView: View {
    @ObservedObject private var casting = BoardCasting.shared
    var body: some View {
        GeometryReader { geo in
            VStack(spacing:18) {
                HStack { Image("Wordmark").resizable().scaledToFit().frame(width:geo.size.width * 0.22,height:60); Spacer(); Text(casting.frame.title).font(.title2.bold()) }
                Text(casting.frame.subtitle).foregroundStyle(ClubStyle.muted)
                HStack(spacing:20) {
                    ForEach(Array(casting.frame.players.enumerated()),id:\.offset) { _,p in
                        VStack(spacing:16) {
                            Text(p.status).font(.caption).foregroundStyle(ClubStyle.lime)
                            Text(p.name).font(.system(size:geo.size.height * 0.055,weight:.bold)).lineLimit(1).minimumScaleFactor(0.4)
                            Spacer(); Text("\(p.remaining)").font(ClubStyle.fittedScoreFont(geo.size.height * 0.29)).lineLimit(1).minimumScaleFactor(0.3); Spacer()
                            Text("Ø \(p.average) · \(p.maximums) × 180 · \(p.darts) \(tr("darts"))").font(.title3).foregroundStyle(ClubStyle.muted)
                            HStack { ForEach(Array(p.advice.enumerated()),id:\.offset) { _,target in Text(target).font(ClubStyle.numberFont(geo.size.height * 0.04)).padding(12).background(ClubStyle.lime.opacity(0.16),in:RoundedRectangle(cornerRadius:10)) } }
                            Text("\(p.legs) \(casting.frame.legsLabel)").font(ClubStyle.numberFont(geo.size.height * 0.055)).foregroundStyle(ClubStyle.lime)
                            Text("\(tr("tv_recent_visits")): \(p.recent.isEmpty ? "—" : p.recent.joined(separator:" · "))").font(.title3)
                        }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity).background(p.active ? ClubStyle.elevated : ClubStyle.card,in:RoundedRectangle(cornerRadius:24)).overlay(RoundedRectangle(cornerRadius:24).stroke(p.active ? ClubStyle.lime : ClubStyle.border,lineWidth:2))
                    }
                }
                if !casting.frame.message.isEmpty { Text(casting.frame.message).font(.title2) }
                if casting.stale { Text("cast_stale").foregroundStyle(.orange) }
            }.padding(geo.size.width * 0.035).frame(maxWidth:.infinity,maxHeight:.infinity).background(ClubStyle.background).foregroundStyle(ClubStyle.text)
        }
    }
}
struct CastOptionsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var casting = BoardCasting.shared
    @ObservedObject private var airplay = AirPlayBoardStream.shared
    let target: CastTarget
    @State private var airplayHelp = false
    @State private var code = ""
    @State private var busy = false
    @State private var error = false
    var body: some View {
        NavigationStack {
            Form {
                Section { Label { Text("cast_separate") } icon: { Image(systemName:"tv").foregroundStyle(ClubStyle.lime) }.font(.headline); Text("cast_keep_open").font(.footnote).foregroundStyle(ClubStyle.muted) }
                Section("AirPlay") {
                    if airplay.ready {
                        Label(airplay.connected ? "airplay_connected" : "airplay_waiting_for_tv",systemImage:airplay.connected ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline).foregroundStyle(airplay.connected ? ClubStyle.lime : ClubStyle.muted)
                        ZStack {
                            Label(airplay.connected ? "airplay_change_tv" : "airplay_choose_tv",systemImage:"airplayvideo")
                                .font(.headline).foregroundStyle(ClubStyle.ink)
                                .frame(maxWidth:.infinity,minHeight:56)
                                .background(ClubStyle.lime,in:RoundedRectangle(cornerRadius:14))
                                .allowsHitTesting(false).accessibilityHidden(true)
                            AirPlayRouteButton(label:airplay.connected ? "airplay_change_tv" : "airplay_choose_tv")
                                .frame(maxWidth:.infinity).frame(height:56)
                        }
                        Text(airplay.connected ? "airplay_connected_notice" : "airplay_ready_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                        if airplay.connected {
                            Button("airplay_stop_stream",role:.destructive) { airplay.stop() }.foregroundStyle(ClubStyle.danger)
                        } else {
                            Button("cancel") { airplay.stop() }
                        }
                    } else {
                        Button { Task { await airplay.start() } } label: {
                            HStack { if airplay.preparing { ProgressView() } else { Image(systemName:"airplayvideo") }; Text(airplay.preparing ? "airplay_preparing" : "airplay_start_stream") }
                        }.buttonStyle(ClubButton(primary:true)).disabled(airplay.preparing)
                    }
                    if let issue = airplay.issue { Text(LocalizedStringKey(issue)).font(.footnote).foregroundStyle(ClubStyle.danger) }
                    Text("airplay_live_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                    Button("airplay_mirroring_fallback") { airplayHelp = true }.font(.footnote)
                }
                Section("Chromecast / Google TV") {
                    if BoardCasting.configured { HStack { GoogleCastButton().frame(width:48,height:48); Text(casting.castConnected ? "cast_connected" : "cast_select") } }
                    else { Text("cast_registration_needed").font(.footnote) }
                }
                Section("YourDartClub TV") {
                    Text("tv_board_notice").font(.footnote)
                    TextField("tv_code",text:$code).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.title2.monospaced())
                    Button { pair() } label: { Label(casting.tvPaired ? "cast_connected" : "pair_tv",systemImage:"link") }.buttonStyle(ClubButton(primary:true)).disabled(busy || code.count < 8)
                    if error { Text("tv_pair_failed").foregroundStyle(.orange) }
                }
                if airplay.connected || casting.castConnected || casting.tvPaired || casting.externalConnected {
                    Button("cast_stop",role:.destructive) { Task { await casting.stop(); dismiss() } }.foregroundStyle(ClubStyle.danger)
                }
            }.clubScreen().toolbar { ToolbarItem(placement:.confirmationAction) { Button("done") { dismiss() } } }
                .task { casting.select(target,model:model) }
        }.tint(ClubStyle.lime).preferredColorScheme(.dark)
            .sheet(isPresented:$airplayHelp) {
                NavigationStack {
                    VStack(alignment:.leading,spacing:24) {
                        Label("airplay_help_button",systemImage:"airplayvideo").font(.title2.bold()).foregroundStyle(ClubStyle.lime)
                        Text("airplay_step_one")
                        Text("airplay_step_two")
                        Text("airplay_step_three")
                        Text("airplay_network_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                        Spacer(minLength:0)
                    }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(ClubStyle.background)
                        .toolbar { ToolbarItem(placement:.confirmationAction) { Button("done") { airplayHelp = false } } }
                }.tint(ClubStyle.lime).preferredColorScheme(.dark).presentationDetents([.large])
            }
    }
    private func pair() { busy = true; error = false; Task { defer { busy = false }; do { try await casting.pair(code:code) } catch { self.error = true } } }
}
