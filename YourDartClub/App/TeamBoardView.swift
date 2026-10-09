import SwiftUI

@MainActor final class BoardCounter: ObservableObject {
    let eventID: String
    let board: Int
    let team: Int
    @Published var event: Evening?
    @Published var busy = false
    @Published var controlling = false
    @Published var ready = false
    @Published var issue: String?
    @Published var acknowledgedVisit: String?
    private var token = ""
    private var leasedMatch: String?
    private var wantsControl = false
    private var pendingVisit: String?
    private var model: AppModel?
    init(eventID: String, board: Int, team: Int) { self.eventID = eventID; self.board = board; self.team = team }
    var match: PlatformMatch? { event?.live(on:board) }
    private func newToken() -> String { UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased() + UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased() }
    func load(_ model: AppModel) async {
        self.model = model
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let snapshot = try await model.platformUpdate(team:team)
            event = snapshot.evenings.first { $0.id == eventID }; ready = true
            if issue == "board_connection_error" { issue = nil }
            if let pendingVisit {
                if event?.matches.contains(where: { $0.counter?.visits.contains { $0.id == pendingVisit } == true }) == true { acknowledgedVisit = pendingVisit }
                self.pendingVisit = nil
            }
            if wantsControl, let current = match {
                if leasedMatch != current.id { await release(); try await acquire(current) }
                else { try await lease("renew",match:current.id) }
            } else if match == nil { await release() }
        } catch { ready = false; controlling = false; wantsControl = false; if !Task.isCancelled { report(error) } }
    }
    private func lease(_ action: String,match: String) async throws {
        guard let model else { throw APIError(status:0) }
        _ = try await model.platformRequest("counter-access",body:["action":action,"id":eventID,"matchId":match,"counterToken":token],team:team)
    }
    private func acquire(_ match: PlatformMatch) async throws {
        token = newToken(); try await lease("acquire",match:match.id); leasedMatch = match.id; controlling = true
    }
    func takeControl(starter: String) async {
        guard !busy, ready, let current = match, model != nil else { return }
        busy = true; defer { busy = false }
        do {
            if leasedMatch != current.id || !controlling { await release(); try await acquire(current) }
            wantsControl = true; issue = nil
            if current.counter == nil, let event {
                try await update("counter-start",extra:["starter":starter,"initialA":event.initial,"initialB":event.initial])
            }
        } catch { controlling = false; wantsControl = false; report(error) }
    }
    private func update(_ action: String,extra: [String:Any] = [:]) async throws {
        guard let event, let match, let model, controlling else { throw APIError(status:423) }
        let body: [String:Any] = ["action":action,"id":event.id,"revision":event.revision,"matchId":match.id,"counterToken":token,"counterRevision":match.counter?.revision ?? 0]
        let snapshot = try await model.platformUpdate(body.merging(extra) { _,new in new },team:team)
        self.event = snapshot.evenings.first { $0.id == eventID }
    }
    func visit(_ event: ScoreEvent) async -> Bool {
        guard !busy, ready, controlling, pendingVisit == nil else { return false }
        busy = true; pendingVisit = event.id; defer { busy = false }
        do {
            try await update("counter-visit",extra:["visit":["id":event.id,"score":event.score,"darts":event.darts,"finish":event.finish,"bust":event.bust]])
            acknowledgedVisit = event.id; pendingVisit = nil; return true
        } catch {
            // Never retry a visit blindly after a lost response. Resolve its ID from the server first.
            ready = false; controlling = false; wantsControl = false; report(error); return false
        }
    }
    func action(_ action: String) async {
        guard !busy, ready, controlling else { return }; busy = true; defer { busy = false }
        do { try await update(action); if action == "counter-finish" { await release() } }
        catch { ready = false; controlling = false; wantsControl = false; report(error) }
    }
    private func report(_ error: Error) {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        switch (error as? APIError)?.status {
        case 401: issue = "login_required"
        case 402: issue = "access_required"
        case 403: issue = "team_denied"
        case 404: issue = "board_unavailable"
        case 409, 423: issue = "board_control_conflict"
        case 400, 422: issue = "invalid_score"
        default: issue = "board_connection_error"
        }
    }
    private func release() async {
        if let leasedMatch { try? await lease("release",match:leasedMatch) }
        leasedMatch = nil; controlling = false; token = ""
    }
    func stop() async { wantsControl = false; await release() }
}

struct TeamBoardView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var phase
    @StateObject private var counter: BoardCounter
    @State private var input = ""
    @State private var mode = EntryMode.score
    @State private var darts = 3
    @State private var checkout = false
    @State private var cast = false
    @State private var autodartsDestination: PlatformDestination?
    init(eventID: String,board: Int,team: Int) { _counter = StateObject(wrappedValue:BoardCounter(eventID:eventID,board:board,team:team)) }
    var body: some View {
        GeometryReader { geo in
            if let event = counter.event {
                let wide = geo.size.width > geo.size.height * 1.15
                let layout = wide ? AnyLayout(HStackLayout(spacing:10)) : AnyLayout(VStackLayout(spacing:8))
                if let match = counter.match, let winner = match.counter?.state.pendingWinner {
                    ScrollView {
                        VStack(spacing:20) {
                            MatchResultSummary(names:[model.playerName(match.a),model.playerName(match.b)],
                                legs:[match.legsA,match.legsB],averages:[average(match.counter?.state.pointsA,match.counter?.state.dartsA),average(match.counter?.state.pointsB,match.counter?.state.dartsB)],winner:winner == "A" ? 0 : 1)
                            Text("official_result_pending").foregroundStyle(ClubStyle.muted).multilineTextAlignment(.center)
                            controls(match,event)
                        }.frame(maxWidth:640).frame(maxWidth:.infinity).padding(20)
                    }.background(ClubBackdrop())
                } else { layout {
                    VStack(spacing:8) {
                        HStack { Label("\(tr("board")) \(counter.board)",systemImage:"target"); Spacer(); Text("\(event.game) · \(tr(event.checkout))") }.font(.caption).foregroundStyle(ClubStyle.muted)
                        if let match = counter.match {
                            HStack(spacing:8) { playerCard(match,event,side:"A"); playerCard(match,event,side:"B") }
                        } else {
                            Spacer(); Image(systemName:"target").font(.system(size:60)).foregroundStyle(ClubStyle.lime)
                            Text(event.status == "completed" ? "status_completed" : "board_waiting").multilineTextAlignment(.center); Spacer()
                        }
                    }.frame(maxWidth:.infinity,maxHeight:.infinity).frame(width:wide ? geo.size.width * 0.43 : nil)
                    if let match = counter.match {
                        controls(match,event).frame(maxWidth:.infinity).frame(height:wide ? geo.size.height - 16 : min(410,geo.size.height * 0.57))
                    }
                }.padding(8).background(ClubBackdrop())
                }
            } else { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar).toolbar(.hidden,for:.tabBar)
            .safeAreaInset(edge:.bottom,spacing:0) {
                if let issue = counter.issue {
                    HStack(spacing:12) {
                        Image(systemName:"exclamationmark.triangle")
                        Text(LocalizedStringKey(issue)).font(.caption)
                        Spacer(minLength:0)
                        Button { Task { await counter.load(model) } } label: { Image(systemName:"arrow.clockwise").frame(width:44,height:44) }.accessibilityLabel(Text("board_retry"))
                    }.padding(.horizontal,12).foregroundStyle(ClubStyle.text).background(ClubStyle.archive.opacity(0.35))
                }
            }
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { cast = true } label: { Image(systemName:"tv") }.accessibilityLabel(Text("tv_board")) } }
            .sheet(item:$autodartsDestination) { TeamPlatformView(destination:$0) }
            .sheet(isPresented:$cast) { CastOptionsView(target:.board(team:counter.team,event:counter.eventID,board:counter.board)).environmentObject(model) }
            .task {
                UIApplication.shared.isIdleTimerDisabled = true
                while !Task.isCancelled {
                    if phase == .active { await counter.load(model) }
                    do { try await Task.sleep(for:.seconds(8)) } catch { break }
                }
            }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; Task { await counter.stop() } }
            .onChange(of:phase) { _,value in if value != .active { Task { await counter.stop() } } else { Task { await counter.load(model) } } }
            .onChange(of:counter.match?.id) { _,_ in input = ""; darts = 3 }
            .onChange(of:counter.acknowledgedVisit) { _,_ in input = ""; darts = 3 }
            .alert(counter.event?.checkout == "double" ? "double_confirm" : "finish_confirm",isPresented:$checkout) { Button("cancel",role:.cancel) {}; Button("save_score") { submit(confirmed:true) } }
    }
    private func average(_ points: Int?, _ darts: Int?) -> Double? {
        guard let points, let darts, darts > 0 else { return nil }
        return Double(points) * 3 / Double(darts)
    }
    private func playerCard(_ match: PlatformMatch,_ event: Evening,side: String) -> some View {
        let active = (match.counter?.state.turn ?? "A") == side
        let remaining = side == "A" ? match.counter?.state.remainingA : match.counter?.state.remainingB
        let before = remaining ?? event.initial
        let enteredScore = mode == .remaining ? before - (Int(input) ?? before) : (Int(input) ?? 0)
        let minimum = (1...3).first { DartRules.possible(enteredScore,darts:$0) } ?? 1
        let preview = active && !input.isEmpty ? ScoreEntry.preview(input:Int(input) ?? 0,before:before,mode:mode,checkout:event.checkout,darts:minimum) : nil
        let rest = preview?.remaining ?? before
        let route = CheckoutSuggestion.make(remaining:rest,checkout:event.checkout,dartsLeft:preview?.dartsLeft ?? 3)
        return VStack(spacing:6) {
            TeamPlayerLink(playerID:side == "A" ? match.a : match.b,team:counter.team).font(.headline).lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(active ? ClubStyle.lime : ClubStyle.text)
            Spacer(minLength:0)
            Text("\(rest)").font(ClubStyle.fittedScoreFont(120)).minimumScaleFactor(0.25).lineLimit(1).frame(maxWidth:.infinity)
            Spacer(minLength:0)
            if let route {
                if route.nextVisit { Text("advice_next_visit").font(.system(size:9)).lineLimit(1).minimumScaleFactor(0.7) }
                HStack(spacing:4) { ForEach(Array(route.targets.enumerated()),id:\.offset) { _,target in Text(target).font(ClubStyle.numberFont(20)).minimumScaleFactor(0.65).lineLimit(1).frame(maxWidth:.infinity,minHeight:32).background(ClubStyle.lime.opacity(0.15),in:RoundedRectangle(cornerRadius:6)) } }.foregroundStyle(ClubStyle.lime)
            }
            HStack { Text("\(side == "A" ? match.legsA : match.legsB)").font(ClubStyle.numberFont(27)); Text("legs").font(.caption.bold()) }.foregroundStyle(ClubStyle.lime)
        }.padding(10).background(active ? ClubStyle.lime.opacity(0.10) : ClubStyle.card,in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(active ? ClubStyle.lime : ClubStyle.border))
    }
    @ViewBuilder private func controls(_ match: PlatformMatch,_ event: Evening) -> some View {
        Button { Task { await counter.stop(); autodartsDestination = model.platformDestination(event:event.id,autodarts:match.id) } } label: { Label("autodarts_remote",systemImage:"target") }.buttonStyle(ClubButton(primary:false)).disabled(counter.busy || !counter.ready)

        if !counter.controlling || match.counter == nil {
            VStack(spacing:16) {
                Text("board_control_notice").font(.subheadline).foregroundStyle(ClubStyle.muted)
                if match.counter == nil {
                    Menu { ForEach(["A","B"],id:\.self) { side in Button(model.playerName(side == "A" ? match.a : match.b)) { Task { await counter.takeControl(starter:side) } } } } label: { Label("choose_starter",systemImage:"play.fill") }.buttonStyle(ClubButton(primary:true))
                } else {
                    Button { Task { await counter.takeControl(starter:"A") } } label: { Label("score_board",systemImage:"keyboard") }.buttonStyle(ClubButton(primary:true))
                }
            }.disabled(counter.busy || !counter.ready)
        } else if match.counter?.state.pendingWinner != nil {
            VStack(spacing:16) {
                Text("match_finished").font(.headline)
                Button { Task { await counter.action("counter-finish") } } label: { Label("finish_next_board",systemImage:"checkmark.circle") }.buttonStyle(ClubButton(primary:true))
                Button { Task { await counter.action("counter-undo") } } label: { Label("correct_result",systemImage:"arrow.uturn.backward").frame(minHeight:44) }
            }.disabled(counter.busy || !counter.ready)
        } else {
            VStack(spacing:6) {
                HStack {
                    Button { if !input.isEmpty { input = "" } else { Task { await counter.action("counter-undo") } } } label: { Image(systemName:"arrow.uturn.backward").frame(width:44,height:40) }.accessibilityLabel(Text("undo"))
                    Text(input.isEmpty ? "—" : input).font(ClubStyle.numberFont(28)); Spacer()
                    Picker("input_mode",selection:$mode) { Text("thrown").tag(EntryMode.score); Text("remaining_input").tag(EntryMode.remaining) }.labelsHidden()
                }
                Grid(horizontalSpacing:6,verticalSpacing:6) {
                    ForEach(0..<4) { row in
                        GridRow {
                            ForEach(0..<5) { column in
                                let value = [[26,1,2,3,60],[41,4,5,6,85],[45,7,8,9,100],[140,-1,0,-2,180]][row][column]
                                Button { key(value,quick:column == 0 || column == 4) } label: {
                                    Group { if value == -2 { Image(systemName:"delete.left") } else { Text(value == -1 ? "CLR" : String(value)) } }.font(ClubStyle.numberFont(value == -1 ? 17 : 26)).frame(maxWidth:.infinity,maxHeight:.infinity)
                                }.buttonStyle(.plain).background(column == 0 || column == 4 ? ClubStyle.lime.opacity(0.16) : ClubStyle.elevated,in:RoundedRectangle(cornerRadius:10))
                            }
                        }
                    }
                }
                HStack {
                    Button("no_score") { Task { if await counter.visit(ScoreEvent(score:0)) { input = "" } } }
                    Spacer(); Button("bust") { Task { if await counter.visit(ScoreEvent(score:0,bust:true)) { input = "" } } }; Spacer()
                    Picker("darts",selection:$darts) { ForEach(1...3,id:\.self) { Text("\($0) \(tr("darts"))").tag($0) } }.labelsHidden()
                }.font(.caption.bold()).frame(height:36)
                Button { submit() } label: { Label(counter.busy ? "syncing" : "save_score",systemImage:"checkmark") }.buttonStyle(ClubButton(primary:true)).disabled(input.isEmpty)
            }.disabled(counter.busy || !counter.ready || !model.online)
        }
    }
    private func key(_ value: Int,quick: Bool) {
        if value == -1 { input = "" }
        else if value == -2 { if !input.isEmpty { input.removeLast() } }
        else if quick { input = String(value); if model.quick { submit() } }
        else if input.count < 3 { input = input == "0" ? String(value) : input + String(value) }
    }
    private func submit(confirmed: Bool = false) {
        guard let e = counter.event,let state = counter.match?.counter?.state,let value = Int(input) else { return }
        do {
            let visit = try ScoreEntry.event(input:value,before:state.turn == "A" ? state.remainingA : state.remainingB,mode:mode,checkout:e.checkout,darts:darts,confirmed:confirmed)
            Task { if await counter.visit(visit) { input = ""; darts = 3 } }
        } catch EntryError.checkoutConfirmation { checkout = true } catch { model.issue = "invalid_score" }
    }
}
