import SwiftUI

struct GameView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var input = ""
    @State private var darts = 3
    @State private var previewDarts = 1
    @State private var mode = EntryMode.score
    @State private var finish = false
    @State private var upload = false
    private let keypad = [[26,1,2,3,60],[41,4,5,6,85],[45,7,8,9,100],[140,-1,0,-2,180]]
    @State private var statistics = false
    @State private var statisticsSide = 0
    @State private var details = false
    @State private var cast = false
    @State private var checkoutDialog = false
    var body: some View {
        GeometryReader { geometry in
            if let game = model.games.first(where:{$0.id == id}), let state = try? DartRules.replay(game) {
                let wide = geometry.size.width > geometry.size.height * 1.15
                let layout = wide ? AnyLayout(HStackLayout(spacing:12)) : AnyLayout(VStackLayout(spacing:8))
                layout {
                    scoreboard(game,state).frame(maxWidth:.infinity,maxHeight:.infinity)
                        .frame(width:wide ? geometry.size.width * 0.35 - 16 : nil)
                    controls(game,state,compact:wide && geometry.size.height < 380)
                        .frame(maxWidth:.infinity)
                        .frame(height:wide ? geometry.size.height - 16 : min(420,max(348,geometry.size.height * 0.59)))
                }.padding(8).background(ClubBackdrop())
                    .sheet(isPresented:$cast) { CastOptionsView(target:.local(id)).environmentObject(model) }
                    .sheet(isPresented:$details) { detailsView(game) }
                    .sheet(isPresented:$statistics) { NavigationStack { LocalMatchStatisticsView(gameID:id,side:statisticsSide).toolbar { ToolbarItem(placement:.confirmationAction) { Button("done") { statistics = false } } } }.tint(ClubStyle.lime) }
                    .alert(game.config.checkout == "double" ? "double_confirm" : "finish_confirm",isPresented:$checkoutDialog) {
                        Button("cancel",role:.cancel) { finish = false }
                        Button("save_score") { finish = true; save(mode,game,state) }
                    }
            }
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible,for:.navigationBar)
            .toolbar(.hidden,for:.tabBar)
            .toolbar { ToolbarItem(placement:.topBarTrailing) {
                Button { cast = true } label: { Image(systemName:"tv") }.accessibilityLabel(Text("tv_board"))
            }; ToolbarItem(placement:.topBarTrailing) {
                Button { details = true } label: { Image(systemName:"slider.horizontal.3").frame(minWidth:44,minHeight:44) }.accessibilityLabel(Text("match_details"))
            } }
            .toolbarBackground(ClubStyle.background,for:.navigationBar).toolbarBackground(.visible,for:.navigationBar)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .onChange(of:darts) { _,_ in finish = false }
            .onChange(of:mode) { _,_ in finish = false }
    }
    private func detailsView(_ game: LocalGame) -> some View {
        NavigationStack {
            Form {
                Section("language") { LanguagePicker() }
                Section("rules") {
                    Text("\(game.config.game) · \(tr(game.config.checkout))")
                    Toggle("quick_save",isOn:Binding(get:{model.quick},set:{model.setQuick($0)}))
                    Picker("advice_after",selection:$previewDarts) { ForEach(1...3,id:\.self) { Text(textFormat("advice_darts",$0)).tag($0) } }
                }
                Section {
                    SyncLabel(game:game)
                    ShareLink(item:export(game)) { Label("export",systemImage:"square.and.arrow.up") }
                    if game.config.players.count != 2 { Text("multiplayer_local") }
                    else if !game.uploadRequested {
                        Button("upload") { upload = true }.disabled(!model.loggedIn)
                            .confirmationDialog("upload",isPresented:$upload,titleVisibility:.visible) { Button("confirm_upload") { model.requestUpload(id) } } message: { Text("upload_notice") }
                    }
                    Text("offline_notice").font(.caption)
                }
                Section { NavigationLink { LocalMatchStatisticsView(gameID:id) } label: { Label("match_statistics",systemImage:"chart.bar.xaxis") } }
                Section("history") {
                    ForEach(game.events.reversed()) { event in
                        HStack { Text(tr(event.kind)); Spacer(); Text(event.kind == "visit" ? String(event.score) : "↶"); if event.bust { Text("bust") } }
                    }
                }
            }.clubScreen().navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("close_details") { details = false } } }
        }
    }
    private func preview(_ game: LocalGame, _ state: ScoreState) -> EntryPreview? {
        guard let number = Int(input), state.winner == nil else { return nil }
        let score = mode == .remaining ? state.remaining[state.turn] - number : number
        let minimum = (1...3).first(where:{DartRules.possible(score,darts:$0)}) ?? 1
        return ScoreEntry.preview(input:number,before:state.remaining[state.turn],mode:mode,checkout:game.config.checkout,darts:max(minimum,previewDarts))
    }
    private func scoreboard(_ game: LocalGame, _ state: ScoreState) -> some View {
        VStack(spacing:6) {
            HStack {
                Text("\(game.config.game) · \(tr(game.config.checkout))")
                Spacer()
                Text(textFormat("leg_number",state.legs.reduce(0,+) + (state.winner == nil ? 1 : 0)))
            }.font(.caption.bold()).foregroundStyle(ClubStyle.muted)
            if game.config.players.count <= 2 {
                HStack(spacing:8) {
                    ForEach(game.config.players.indices,id:\.self) { side in playerCard(game,state,side) }
                }.frame(maxHeight:.infinity)
            } else {
                playerCard(game,state,state.winner ?? state.turn).frame(maxHeight:.infinity)
                ForEach(game.config.players.indices,id:\.self) { side in
                    HStack {
                        Image(systemName:state.turn == side ? "play.fill" : "person.fill").frame(width:14)
                        Button { statisticsSide = side; statistics = true } label: { Text(game.config.players[side]).lineLimit(1) }.buttonStyle(.plain)
                        Spacer(minLength:4)
                        legBadge(state.legs[side],compact:true)
                        Button { selectStarter(game,side) } label: {
                            Text(String(state.remaining[side])).font(ClubStyle.numberFont(13,relativeTo:.caption)).frame(minWidth:44,minHeight:28,alignment:.trailing)
                        }.buttonStyle(.plain).disabled(!canSelectStarter(game) || side == state.turn)
                            .accessibilityLabel(Text("select_starter")).accessibilityValue(game.config.players[side])
                    }.font(.caption).padding(.horizontal,8).frame(height:28)
                        .background(state.turn == side ? ClubStyle.elevated : ClubStyle.card,in:RoundedRectangle(cornerRadius:6))
                }
            }
        }
    }
    private func canSelectStarter(_ game: LocalGame) -> Bool {
        game.canChangeStarter && input.isEmpty
    }
    private func selectStarter(_ game: LocalGame, _ side: Int) {
        guard canSelectStarter(game) else { return }
        if model.changeStarter(id,to:side) { reset() }
    }
    private func playerCard(_ game: LocalGame, _ state: ScoreState, _ side: Int) -> some View {
        let active = state.turn == side && state.winner == nil
        let provisional = active ? preview(game,state) : nil
        let remaining = provisional?.remaining ?? state.remaining[side]
        let suggestion = CheckoutSuggestion.make(remaining:remaining,checkout:game.config.checkout,dartsLeft:provisional?.dartsLeft ?? 3)
        return VStack(spacing:2) {
            HStack(spacing:4) {
                if active { Image(systemName:"play.fill").font(.caption2) }
                if state.winner == side { Image(systemName:"trophy.fill") }
                Button { statisticsSide = side; statistics = true } label: { HStack(spacing:4) { Text(game.config.players[side]); Image(systemName:"chart.bar.xaxis").font(.caption) } }.buttonStyle(.plain).font(.headline).lineLimit(1).minimumScaleFactor(0.6)
            }.foregroundStyle(active || state.winner == side ? ClubStyle.lime : ClubStyle.text)
            GeometryReader { space in
                let score = Text(String(remaining)).font(ClubStyle.fittedScoreFont(min(110,max(32,space.size.height * 0.85)))).tracking(-2)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth:.infinity,maxHeight:.infinity)
                    .foregroundStyle(ClubStyle.text)
                    .contentTransition(.numericText())
                if canSelectStarter(game) && !active {
                    Button { selectStarter(game,side) } label: { score }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("select_starter"))
                        .accessibilityValue("\(game.config.players[side]), \(remaining)")
                } else {
                    score.accessibilityLabel(Text("remaining_input"))
                        .accessibilityValue("\(game.config.players[side]), \(remaining)")
                }
            }
            if canSelectStarter(game) && !active {
                Text("tap_to_start").font(.caption2).foregroundStyle(ClubStyle.lime).lineLimit(1).minimumScaleFactor(0.7)
            }
            if state.winner == side || provisional?.bust == true || provisional?.checkout == true {
                Text(state.winner == side ? "winner" : provisional?.bust == true ? "bust_recorded" : "checkout_pending")
                    .font(.caption.bold()).foregroundStyle(ClubStyle.lime).lineLimit(2)
            } else if let suggestion {
                VStack(spacing:4) {
                    if suggestion.nextVisit { Text("advice_next_visit").font(.caption2.bold()).foregroundStyle(ClubStyle.muted) }
                    HStack(spacing:5) {
                        ForEach(suggestion.targets.indices,id:\.self) { index in
                            Text(suggestion.targets[index]).font(ClubStyle.numberFont(21,relativeTo:.title3))
                                .lineLimit(1).minimumScaleFactor(0.65)
                                .frame(maxWidth:.infinity).frame(height:36)
                                .background(ClubStyle.lime.opacity(active ? 0.18 : 0.08),in:RoundedRectangle(cornerRadius:6))
                                .overlay(RoundedRectangle(cornerRadius:6).stroke(ClubStyle.lime.opacity(0.5),lineWidth:1))
                        }
                    }.foregroundStyle(ClubStyle.lime)
                        .accessibilityElement(children:.ignore)
                        .accessibilityLabel(Text(suggestion.nextVisit ? "advice_next_visit" : "checkout_route"))
                        .accessibilityValue(suggestion.targets.joined(separator:", "))
                }
            } else {
                Text("no_checkout_route").font(.caption).foregroundStyle(ClubStyle.muted).lineLimit(2)
            }
            HStack {
                Text(state.dartsThrown[side] == 0 ? "Ø —" : String(format:"Ø %.1f",locale:locale,Double(state.points[side])*3 / Double(state.dartsThrown[side])))
                Spacer(minLength:2)
                legBadge(state.legs[side])
            }.font(.caption2).foregroundStyle(ClubStyle.muted).lineLimit(1).minimumScaleFactor(0.7)
        }.padding(8).frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(active ? Color(hex:0x20321b) : ClubStyle.card,in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(active ? ClubStyle.lime : ClubStyle.border,lineWidth:1))
    }
    private func legBadge(_ count: Int, compact: Bool = false) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:4) {
            Text(String(count)).font(ClubStyle.numberFont(compact ? 18 : 26,relativeTo:compact ? .headline : .title2)).monospacedDigit()
                .contentTransition(.numericText())
            Text("legs").font(.system(size:compact ? 9 : 11,weight:.semibold))
        }.foregroundStyle(ClubStyle.lime)
            .padding(.horizontal,compact ? 5 : 8).padding(.vertical,compact ? 2 : 4)
            .background(ClubStyle.lime.opacity(0.12),in:RoundedRectangle(cornerRadius:7))
            .accessibilityElement(children:.ignore).accessibilityLabel(Text("legs")).accessibilityValue(String(count))
    }
    private func controls(_ game: LocalGame, _ state: ScoreState, compact: Bool) -> some View {
        let keys = compact ? [[26,1,2,3,60,-1,-2],[41,4,5,6,85,0,140],[45,7,8,9,100,81,180]] : keypad
        return VStack(spacing:6) {
            HStack(spacing:8) {
                Button { undo(game) } label: { Image(systemName:"arrow.uturn.backward").frame(width:44,height:44) }
                    .accessibilityLabel(Text(input.isEmpty ? "back_visit" : "clear_input")).disabled(input.isEmpty && ((try? DartRules.activeVisits(game.events).isEmpty) ?? true))
                Text(input.isEmpty ? "—" : input).font(ClubStyle.numberFont(28,relativeTo:.title)).monospacedDigit().frame(minWidth:52)
                    .accessibilityLabel(Text(input.isEmpty ? tr("tap_score") : "\(tr("provisional")): \(input)"))
                Spacer(minLength:0)
                if compact {
                    Menu {
                        Button("no_score") { quickScore(0,game,state) }
                        Button("Bust") { if model.append(.init(score:0,darts:darts,bust:true),to:id) { reset() } }
                        Picker("darts",selection:$darts) { ForEach(1...3,id:\.self) { Text(textFormat("visit_darts",$0)).tag($0) } }
                    } label: { Image(systemName:"ellipsis.circle").frame(width:44,height:44) }.disabled(state.winner != nil).accessibilityLabel(Text("visit_options"))
                }
                Picker("input_mode",selection:$mode) { Text("thrown").tag(EntryMode.score); Text("remaining_input").tag(EntryMode.remaining) }
                    .pickerStyle(.menu).frame(minHeight:44)
            }
            VStack(spacing:6) {
                ForEach(keys.indices,id:\.self) { row in
                    HStack(spacing:6) {
                        ForEach(keys[row].indices,id:\.self) { col in
                            key(keys[row][col],quick:keys[row][col] > 9,game:game,state:state)
                        }
                    }.frame(maxHeight:.infinity)
                }
            }.frame(maxHeight:.infinity).disabled(state.winner != nil)
            if !compact { HStack(spacing:6) {
                Button("no_score") { quickScore(0,game,state) }.frame(maxWidth:.infinity,minHeight:44)
                Button("Bust") { if model.append(.init(score:0,darts:darts,bust:true),to:id) { reset() } }.frame(maxWidth:.infinity,minHeight:44)
                Picker("darts",selection:$darts) { ForEach(1...3,id:\.self) { Text(textFormat("visit_darts",$0)).tag($0) } }.pickerStyle(.menu).frame(minHeight:44)
            }.font(.caption.bold()).disabled(state.winner != nil) }
            Button { save(mode,game,state) } label: {
                Label(mode == .score ? "save_score" : "end_score",systemImage:"checkmark").font(.headline).frame(maxWidth:.infinity,minHeight:48)
            }.buttonStyle(.plain).background(ClubStyle.lime,in:RoundedRectangle(cornerRadius:12)).foregroundStyle(ClubStyle.ink)
                .disabled(!canSave(mode,game,state)).opacity(canSave(mode,game,state) ? 1 : 0.4)
        }
    }
    private func key(_ value: Int, quick: Bool, game: LocalGame, state: ScoreState) -> some View {
        Button {
            if quick { quickScore(value,game,state) }
            else if value == -1 { choose("") }
            else if value == -2 { choose(String(input.dropLast())) }
            else if input.count < 3 || input == "0" { choose(input == "0" ? String(value) : input + String(value)) }
        } label: {
            Group {
                if value == -2 { Image(systemName:"delete.left").font(.title3) }
                else { Text(value == -1 ? "CLR" : String(value)).font(ClubStyle.numberFont(value == -1 ? 12 : 24,relativeTo:value == -1 ? .caption : .title2)).minimumScaleFactor(0.6).lineLimit(1) }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).frame(minHeight:44)
                .foregroundStyle(quick ? Color(hex:0xcdf3ab) : ClubStyle.text)
                .background(quick ? Color(hex:0x20351b) : Color(hex:0x263025),in:RoundedRectangle(cornerRadius:11))
                .overlay(RoundedRectangle(cornerRadius:11).stroke(quick ? Color(hex:0x446435) : Color(hex:0x465141),lineWidth:1))
        }.buttonStyle(.plain).accessibilityLabel(value == -2 ? tr("delete_digit") : value == -1 ? tr("clear_input") : quick ? textFormat("quick_value",value) : String(value))
    }
    private func canSave(_ target: EntryMode, _ game: LocalGame, _ state: ScoreState) -> Bool {
        guard let number = Int(input), (try? ScoreEntry.event(input:number,before:state.remaining[state.turn],mode:target,checkout:game.config.checkout,darts:darts,confirmed:true)) != nil else { return false }
        return state.winner == nil
    }
    private func save(_ target: EntryMode, _ game: LocalGame, _ state: ScoreState) {
        guard let number = Int(input) else { return }
        do {
            let event = try ScoreEntry.event(input:number,before:state.remaining[state.turn],mode:target,checkout:game.config.checkout,darts:darts,confirmed:finish && mode == target)
            if model.append(event,to:id) { reset() }
        } catch EntryError.checkoutConfirmation { mode = target; finish = false; checkoutDialog = true }
        catch { model.issue = "invalid_score" }
    }
    private func quickScore(_ value: Int, _ game: LocalGame, _ state: ScoreState) {
        mode = .score
        choose(String(value))
        if model.quick && value != state.remaining[state.turn] && DartRules.possible(value,darts:darts) {
            if model.append(.init(score:value,darts:darts),to:id) { reset() }
        }
    }
    private func undo(_ game: LocalGame) {
        guard let action = try? InputBackAction.resolve(input:input,events:game.events) else { return }
        switch action {
        case .clearInput: choose("")
        case .undoVisit(let visit): if model.append(.undo(visit),to:id) { reset() }
        case .none: break
        }
    }
    private func choose(_ value: String) { input = value; finish = false; if value.isEmpty { previewDarts = 1 } }
    private func reset() { input = ""; finish = false; darts = 3; previewDarts = 1; mode = .score }
    private func export(_ game: LocalGame) -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; return (try? String(data:encoder.encode(game),encoding:.utf8)) ?? "" }
}

struct LocalMatchStatisticsView: View {
    @EnvironmentObject var model: AppModel
    let gameID: String
    var side: Int? = nil
    var body: some View {
        List {
            if let game = model.games.first(where:{ $0.id == gameID }), let state = try? DartRules.replay(game) {
                Section {
                    Text("match_statistics").font(.headline)
                    Text(game.createdAt,style:.date)
                    Text("local_match_stats_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                }.listRowBackground(ClubStyle.card)
                ForEach(game.config.players.indices.filter { side == nil || side == $0 },id:\.self) { index in
                    Section(game.config.players[index]) {
                        LabeledContent("legs",value:String(state.legs[index]))
                        LabeledContent("remaining_input",value:String(state.remaining[index]))
                        LabeledContent("team_average",value:teamAverage(state.dartsThrown[index] > 0 ? Double(state.points[index]) * 3 / Double(state.dartsThrown[index]) : nil))
                        LabeledContent("team_recorded_darts",value:String(state.dartsThrown[index]))
                        LabeledContent("team_maximums",value:String(state.maximums[index]))
                        if state.winner == index { Label("winner",systemImage:"trophy") }
                    }.listRowBackground(ClubStyle.card)
                }
            }
        }.clubScreen().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar)
    }
}
