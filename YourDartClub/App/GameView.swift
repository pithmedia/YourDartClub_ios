import SwiftUI

struct GameView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let id: String
    @State private var input = ""
    @State private var darts = 3
    @State private var previewDarts = 1
    @State private var mode = EntryMode.score
    @State private var finish = false
    @State private var upload = false
    @ScaledMetric(relativeTo:.largeTitle) private var scoreSize = 64.0
    private let keypad = [[26,1,2,3,60],[41,4,5,6,85],[45,7,8,9,100],[140,-1,0,-2,180]]
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 820 && !dynamicTypeSize.isAccessibilitySize
            ScrollView {
                if let game = model.games.first(where:{$0.id == id}), let state = try? DartRules.replay(game) {
                    VStack(spacing:20) {
                        HStack {
                            Image("Wordmark").resizable().scaledToFit().frame(width:180,height:52).accessibilityLabel("YourDartClub")
                            Spacer(); Text("\(game.config.game) · \(tr(game.config.checkout))").font(.caption.bold()).foregroundStyle(ClubStyle.muted)
                        }
                        let layout = wide ? AnyLayout(HStackLayout(alignment:.top,spacing:24)) : AnyLayout(VStackLayout(spacing:20))
                        layout {
                            scoreboard(game,state).frame(maxWidth:.infinity)
                            controls(game,state).frame(maxWidth:.infinity)
                        }
                        HStack { SyncLabel(game:game); Spacer(); ShareLink(item:export(game)) { Image(systemName:"square.and.arrow.up").frame(minWidth:44,minHeight:44) }.accessibilityLabel(Text("export")) }
                        if game.config.players.count > 2 { Label("multiplayer_local",systemImage:"internaldrive").font(.caption).foregroundStyle(ClubStyle.muted) }
                        else if !game.uploadRequested {
                            Button { upload = true } label: { Label("upload",systemImage:"icloud.and.arrow.up").frame(minHeight:44) }.disabled(!model.loggedIn)
                                .confirmationDialog("upload",isPresented:$upload,titleVisibility:.visible) { Button("confirm_upload") { model.requestUpload(id) } } message: { Text("upload_notice") }
                        }
                        DisclosureGroup("history") {
                            ForEach(game.events.reversed()) { event in
                                HStack { Text(tr(event.kind)); Spacer(); Text(event.kind == "visit" ? String(event.score) : "↶").bold(); if event.bust { Text("bust") } }.font(.caption).padding(.vertical,6)
                            }
                        }.clubCard()
                        Text("offline_notice").font(.caption).foregroundStyle(ClubStyle.muted)
                    }.padding(wide ? 24 : 14).frame(maxWidth:1260).frame(maxWidth:.infinity)
                }
            }.background(ClubBackdrop())
        }.navigationTitle(Text("match")).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ClubStyle.background,for:.navigationBar).toolbarBackground(.visible,for:.navigationBar)
            .onChange(of:darts) { _,_ in finish = false }
            .onChange(of:mode) { _,_ in finish = false }
    }
    private func preview(_ game: LocalGame, _ state: ScoreState) -> EntryPreview? {
        guard let number = Int(input), state.winner == nil else { return nil }
        let score = mode == .remaining ? state.remaining[state.turn] - number : number
        let minimum = (1...3).first(where:{DartRules.possible(score,darts:$0)}) ?? 1
        return ScoreEntry.preview(input:number,before:state.remaining[state.turn],mode:mode,checkout:game.config.checkout,darts:max(minimum,previewDarts))
    }
    private func scoreboard(_ game: LocalGame, _ state: ScoreState) -> some View {
        VStack(spacing:16) {
            HStack {
                Label(textFormat("leg_number",state.legs.reduce(0,+) + 1),systemImage:"target").font(.subheadline.bold())
                Spacer()
                if preview(game,state) != nil { Text("provisional").font(.caption.bold()).foregroundStyle(ClubStyle.lime) }
                else { Text("practice").font(.caption).foregroundStyle(ClubStyle.muted) }
            }
            HStack(spacing:10) {
                Text("legs").font(.caption).tracking(2).foregroundStyle(ClubStyle.muted)
                Text(state.legs.map(String.init).joined(separator:" : ")).font(.system(.title,design:.rounded,weight:.bold)).monospacedDigit()
            }
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:10),count:dynamicTypeSize.isAccessibilitySize ? 1 : 2),spacing:12) {
                ForEach(game.config.players.indices,id:\.self) { side in playerCard(game,state,side) }
            }
            if let winner = state.winner {
                Label(textFormat("winner_name",game.config.players[winner]),systemImage:"trophy.fill").font(.title2.bold()).foregroundStyle(ClubStyle.lime).padding()
            }
        }
    }
    private func playerCard(_ game: LocalGame, _ state: ScoreState, _ side: Int) -> some View {
        let active = state.turn == side && state.winner == nil
        let provisional = active ? preview(game,state) : nil
        let remaining = provisional?.remaining ?? state.remaining[side]
        let route = DartRules.advice(remaining,mode:game.config.checkout,darts:provisional?.dartsLeft ?? (active ? darts : 3))
        return VStack(spacing:10) {
            Text(state.winner == side ? "winner" : active ? "your_turn" : "remaining_label").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(active ? ClubStyle.lime : ClubStyle.muted)
            Text(game.config.players[side]).font(.headline).multilineTextAlignment(.center).lineLimit(2).frame(minHeight:24)
            Text(String(remaining)).font(.system(size:scoreSize,weight:.heavy,design:.rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.45).contentTransition(.numericText())
            if let provisional {
                Text(textFormat("preview_calculation",state.remaining[side],provisional.score,provisional.dartsLeft)).font(.caption2).foregroundStyle(ClubStyle.muted)
            }
            Divider().overlay(ClubStyle.border)
            HStack(spacing:8) {
                VStack(spacing:3) {
                    Text(state.dartsThrown[side] == 0 ? "Ø —" : String(format:"Ø %.1f",Double(state.points[side])*3 / Double(state.dartsThrown[side]))).font(.headline).monospacedDigit()
                    Text("average_three").font(.system(size:8,weight:.semibold)).foregroundStyle(ClubStyle.muted)
                }
                Spacer(minLength:2)
                Text("\(state.maximums[side]) × 180").font(.caption2).foregroundStyle(ClubStyle.muted)
            }
            if provisional?.bust == true { Text("bust_recorded").font(.caption).foregroundStyle(.orange) }
            else if provisional?.checkout == true { Text("checkout_pending").font(.caption).foregroundStyle(ClubStyle.lime) }
            else if let route { Text(route).font(.caption.bold()).foregroundStyle(ClubStyle.lime).multilineTextAlignment(.center) }
        }.frame(maxWidth:.infinity).padding(14)
            .background(active ? Color(hex:0x20321b) : Color(hex:0x131e15),in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).stroke(active ? ClubStyle.lime : Color(hex:0x344331),lineWidth:1))
    }
    private func controls(_ game: LocalGame, _ state: ScoreState) -> some View {
        VStack(spacing:12) {
            HStack {
                Text(textFormat("visit_of",game.config.players[state.turn])).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                Button { undo(game) } label: { Label("back_visit",systemImage:"arrow.uturn.backward").font(.caption.bold()).frame(minHeight:44) }.disabled((try? DartRules.activeVisits(game.events).isEmpty) ?? true)
            }
            if state.winner == nil {
                HStack {
                    Text(input.isEmpty ? "—" : input).font(.system(.largeTitle,design:.rounded,weight:.heavy)).monospacedDigit().foregroundStyle(input.isEmpty ? ClubStyle.muted : ClubStyle.text)
                    Spacer()
                    Text(input.isEmpty ? "tap_score" : "provisional_unsaved").font(.caption).multilineTextAlignment(.trailing).foregroundStyle(ClubStyle.muted)
                }.padding(16).background(Color(hex:0x0b140c),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(Color(hex:0x536b42),lineWidth:1))
                    .accessibilityElement(children:.combine)
                HStack {
                    Picker("input_mode",selection:$mode) { Text("thrown").tag(EntryMode.score); Text("remaining_input").tag(EntryMode.remaining) }.pickerStyle(.segmented)
                    Picker("advice_after",selection:$previewDarts) { ForEach(1...3,id:\.self) { Text(textFormat("advice_darts",$0)).tag($0) } }.pickerStyle(.menu).font(.caption)
                }
                VStack(spacing:7) {
                    ForEach(keypad.indices,id:\.self) { row in
                        HStack(spacing:7) {
                            ForEach(keypad[row].indices,id:\.self) { col in
                                key(keypad[row][col],quick:col == 0 || col == 4,game:game,state:state)
                            }
                        }
                    }
                }
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:8) { visitOptions(game,state) }
                    VStack(spacing:8) { visitOptions(game,state) }
                }
                if needsConfirmation(game,state,mode) {
                    Toggle(game.config.checkout == "double" ? "double_confirm" : "finish_confirm",isOn:$finish).font(.subheadline).tint(ClubStyle.lime).padding(12).background(ClubStyle.elevated,in:RoundedRectangle(cornerRadius:12))
                }
                if let number = Int(input), (try? ScoreEntry.event(input:number,before:state.remaining[state.turn],mode:mode,checkout:game.config.checkout,darts:darts,confirmed:true)) == nil {
                    Label("invalid_score",systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                }
                Toggle("quick_save",isOn:Binding(get:{model.quick},set:{model.setQuick($0)})).font(.caption).tint(ClubStyle.lime)
                HStack(spacing:10) {
                    saveButton(.score,game,state)
                    saveButton(.remaining,game,state)
                }
            }
        }.clubCard(padding:16)
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
                else { Text(value == -1 ? "CLR" : String(value)).font(.system(value == -1 ? .caption : .title2,design:.rounded,weight:.bold)).minimumScaleFactor(0.6).lineLimit(1) }
            }.frame(maxWidth:.infinity,minHeight:54)
                .foregroundStyle(quick ? Color(hex:0xcdf3ab) : ClubStyle.text)
                .background(quick ? Color(hex:0x20351b) : Color(hex:0x263025),in:RoundedRectangle(cornerRadius:11))
                .overlay(RoundedRectangle(cornerRadius:11).stroke(quick ? Color(hex:0x446435) : Color(hex:0x465141),lineWidth:1))
        }.buttonStyle(.plain).accessibilityLabel(value == -2 ? tr("delete_digit") : value == -1 ? tr("clear_input") : quick ? textFormat("quick_value",value) : String(value))
    }
    @ViewBuilder private func visitOptions(_ game: LocalGame, _ state: ScoreState) -> some View {
        Button("81") { quickScore(81,game,state) }.buttonStyle(.bordered).frame(minHeight:44)
        Button("no_score") { choose("0") }.buttonStyle(.bordered).frame(minHeight:44)
        Button("Bust") { if model.append(.init(score:0,darts:darts,bust:true),to:id) { reset() } }.buttonStyle(.bordered).frame(minHeight:44)
        Picker("darts",selection:$darts) { ForEach(1...3,id:\.self) { Text(textFormat("visit_darts",$0)).tag($0) } }.pickerStyle(.menu).font(.caption)
    }
    private func saveButton(_ target: EntryMode, _ game: LocalGame, _ state: ScoreState) -> some View {
        Button { save(target,game,state) } label: {
            VStack(spacing:5) {
                Label(target == .score ? "save_score" : "end_score",systemImage:target == .score ? "chevron.right" : "target").font(.subheadline.bold())
                Text(target == .score ? "thrown_points" : "points_left").font(.caption2)
            }.padding(.vertical,8)
        }.buttonStyle(ClubButton(primary:mode == target)).disabled(!canSave(target,game,state))
    }
    private func canSave(_ target: EntryMode, _ game: LocalGame, _ state: ScoreState) -> Bool {
        guard let number = Int(input), (try? ScoreEntry.event(input:number,before:state.remaining[state.turn],mode:target,checkout:game.config.checkout,darts:darts,confirmed:true)) != nil else { return false }
        return target != mode || !needsConfirmation(game,state,target) || finish
    }
    private func needsConfirmation(_ game: LocalGame, _ state: ScoreState, _ target: EntryMode) -> Bool {
        guard let number = Int(input) else { return false }
        do { _ = try ScoreEntry.event(input:number,before:state.remaining[state.turn],mode:target,checkout:game.config.checkout,darts:darts,confirmed:false); return false }
        catch EntryError.checkoutConfirmation { return true }
        catch { return false }
    }
    private func save(_ target: EntryMode, _ game: LocalGame, _ state: ScoreState) {
        guard let number = Int(input) else { return }
        do {
            let event = try ScoreEntry.event(input:number,before:state.remaining[state.turn],mode:target,checkout:game.config.checkout,darts:darts,confirmed:finish && mode == target)
            if model.append(event,to:id) { reset() }
        } catch EntryError.checkoutConfirmation { mode = target; finish = false }
        catch { model.issue = "invalid_score" }
    }
    private func quickScore(_ value: Int, _ game: LocalGame, _ state: ScoreState) {
        choose(String(value))
        if model.quick && value != state.remaining[state.turn] && DartRules.possible(value,darts:darts) {
            if model.append(.init(score:value,darts:darts),to:id) { reset() }
        }
    }
    private func undo(_ game: LocalGame) { if let last = try? DartRules.activeVisits(game.events).last, model.append(.undo(last.id),to:id) { reset() } }
    private func choose(_ value: String) { input = value; finish = false; if value.isEmpty { previewDarts = 1 } }
    private func reset() { input = ""; finish = false; darts = 3; previewDarts = 1; mode = .score }
    private func export(_ game: LocalGame) -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; return (try? String(data:encoder.encode(game),encoding:.utf8)) ?? "" }
}
