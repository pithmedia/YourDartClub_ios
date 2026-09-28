import SwiftUI

struct TeamView: View {
    @EnvironmentObject var model: AppModel
    @State private var create = false
    var body: some View {
        NavigationStack {
            List {
                if model.loggedIn {
                    Section {
                        Picker("team",selection:$model.selectedTeam) { ForEach(model.account?.teams ?? []) { Text($0.name).tag($0.id) } }
                        Button { create = true } label: { Label("create_event",systemImage:"plus.circle.fill") }.buttonStyle(ClubButton(primary:true)).disabled(!active)
                    }.listRowBackground(ClubStyle.card)
                    Section {
                        NavigationLink { TeamStatisticsView(team:model.selectedTeam) } label: { Label("team_statistics",systemImage:"chart.bar.xaxis") }
                        NavigationLink { TeamHistoryView(team:model.selectedTeam) } label: { Label("team_history",systemImage:"clock.arrow.circlepath") }
                        NavigationLink { TeamParticipantsView(team:model.selectedTeam) } label: { Label("team_participants",systemImage:"person.3") }
                    }.listRowBackground(ClubStyle.card)
                    Section("team_events") {
                        if model.evenings.filter({ $0.status == "active" }).isEmpty { Text("no_evenings") }
                        ForEach(model.evenings.filter { $0.status == "active" }) { event in
                            NavigationLink { NativeEventView(id:event.id,team:model.selectedTeam) } label: {
                                VStack(alignment:.leading,spacing:10) {
                                    HStack { Text(event.name).font(.headline); Spacer(); Image(systemName:event.mode == "free" ? "target" : "trophy").foregroundStyle(ClubStyle.lime) }
                                    Text("\(event.date) · \(tr("mode_" + event.mode))").font(.caption).foregroundStyle(ClubStyle.muted)
                                    HStack { Label("\(event.boards)",systemImage:"target"); Label("\(event.players.count)",systemImage:"person.2"); Spacer(); Text(tr("status_" + event.status)) }.font(.caption).foregroundStyle(ClubStyle.lime)
                                }.padding(.vertical,10)
                            }.listRowBackground(ClubStyle.card)
                        }
                    }
                } else { Text("login_required") }
            }.clubScreen().toolbar(.hidden,for:.navigationBar)
                .refreshable { await model.refresh(force:true) }
                .onChange(of:model.selectedTeam) { _,_ in model.evenings = []; model.teamPlayers = []; Task { await model.refresh(force:true) } }
                .sheet(isPresented:$create) { CreateEventView(team:model.selectedTeam) }
        }
    }
    private var active: Bool { model.online && model.account?.teams.contains { $0.id == model.selectedTeam && $0.active } == true }
}

struct NativeEventView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    let team: Int
    @State private var section = 0
    @State private var busy = false
    @State private var manage = false
    var event: Evening? { model.evenings.first { $0.id == id } }
    var body: some View {
        Group {
            if let e = event {
                List {
                    Section {
                        VStack(alignment:.leading,spacing:12) {
                            HStack { Image(systemName:"trophy").foregroundStyle(ClubStyle.lime); Text(e.name).font(.headline); Spacer() }
                            Text("\(e.game) · \(tr(e.checkout)) · \(tr("best_of")) \(e.bestOf)").font(.subheadline).foregroundStyle(ClubStyle.muted)
                            Text("\(e.date) · \(tr("mode_" + e.mode))").font(.caption).foregroundStyle(ClubStyle.muted)
                        }.padding(.vertical,8)
                        Picker("event_sections",selection:$section) {
                            Text("boards").tag(0); Text("schedule").tag(1); Text("standings").tag(2); Text("players").tag(3)
                        }.pickerStyle(.segmented)
                    }.listRowBackground(ClubStyle.card)
                    if section == 0 {
                        ForEach(1...max(1,e.boards),id:\.self) { board in
                            Section {
                                NavigationLink { TeamBoardView(eventID:id,board:board,team:team) } label: {
                                    VStack(alignment:.leading,spacing:14) {
                                        Label("\(tr("board")) \(board)",systemImage:"target").foregroundStyle(ClubStyle.lime)
                                        if let match = e.live(on:board) {
                                            if match.placement == 3 { Text("third_place_title").foregroundStyle(ClubStyle.lime) }
                                            HStack { Text(model.playerName(match.a)); Spacer(); Text("\(match.legsA) – \(match.legsB)").font(ClubStyle.numberFont(28)); Spacer(); Text(model.playerName(match.b)) }
                                        } else { Text("board_waiting").foregroundStyle(ClubStyle.muted) }
                                        Label("score_board",systemImage:"keyboard").font(.subheadline.bold())
                                    }.padding(.vertical,12)
                                }
                            }.listRowBackground(ClubStyle.card)
                        }
                    } else if section == 1 {
                        ForEach(Array(Set(e.matches.filter { $0.placement == nil }.map(\.round))).sorted(),id:\.self) { round in
                            Section("\(tr("round")) \(round)") {
                                ForEach(e.matches.filter { $0.round == round && $0.placement == nil }) { m in
                                    VStack(alignment:.leading,spacing:8) {
                                        HStack { TeamPlayerLink(playerID:m.a,team:team); Spacer(); Text("\(m.legsA) – \(m.legsB)").font(ClubStyle.numberFont(24)); Spacer(); TeamPlayerLink(playerID:m.b,team:team) }
                                        HStack { Text(tr("stage_" + m.stage)); Spacer(); Text(tr("status_" + m.status)); if let board = m.board { Text("· \(tr("board")) \(board)") } }.font(.caption).foregroundStyle(ClubStyle.muted)
                                    }.padding(.vertical,8)
                                }
                            }.listRowBackground(ClubStyle.card)
                        }
                        if e.thirdPlaceMatch == true || e.matches.contains(where: { $0.placement == 3 }) {
                            Section("third_place_title") {
                                if let match = e.matches.first(where: { $0.placement == 3 }) {
                                    HStack { TeamPlayerLink(playerID:match.a,team:team); Spacer(); Text("\(match.legsA) – \(match.legsB)").font(ClubStyle.numberFont(24)); Spacer(); TeamPlayerLink(playerID:match.b,team:team) }
                                    Text(tr("status_" + match.status)).font(.caption)
                                    if let board = match.board, match.status == "live" {
                                        NavigationLink { TeamBoardView(eventID:id,board:board,team:team) } label: { Label("\(tr("board")) \(board)",systemImage:"target") }
                                    }
                                } else { Text("third_place_pending").foregroundStyle(ClubStyle.muted) }
                            }.listRowBackground(ClubStyle.card)
                        }
                    } else if section == 2 {
                        Section {
                            HStack { Text("#").frame(width:28); Text("players"); Spacer(); Text("played").frame(width:45); Text("points").frame(width:40); Text("difference").frame(width:35) }.font(.caption).foregroundStyle(ClubStyle.muted)
                            ForEach(Array((e.standings ?? []).enumerated()),id:\.element.id) { index, row in
                                HStack { Text("\(index + 1)").font(ClubStyle.numberFont(22)).foregroundStyle(ClubStyle.lime).frame(width:28); TeamPlayerLink(playerID:row.id,team:team); Spacer(); Text("\(row.played)").frame(width:45); Text("\(row.points)").bold().foregroundStyle(ClubStyle.lime).frame(width:40); Text("\(row.diff)").frame(width:35) }.padding(.vertical,8)
                            }
                        }.listRowBackground(ClubStyle.card)
                    } else {
                        Section {
                            Text(tr("participants_count").replacingOccurrences(of:"{count}",with:String(e.players.count))).font(.headline).foregroundStyle(ClubStyle.lime)
                            ForEach(Array(e.players.enumerated()),id:\.element) { index, player in
                                HStack { Text("\(index + 1)").font(ClubStyle.numberFont(22)).foregroundStyle(ClubStyle.lime).frame(width:32); TeamPlayerLink(playerID:player,team:team) }.padding(.vertical,8)
                            }
                        }.listRowBackground(ClubStyle.card)
                    }
                }.clubScreen().refreshable { await reload() }
                    .sheet(isPresented:$manage) { ManageEventView(event:e,team:team) }
            } else { ContentUnavailableView(tr("no_evenings"),systemImage:"calendar") }
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { manage = true } label: { Image(systemName:"slider.horizontal.3") }.accessibilityLabel(Text("match_details")) } }
            .task { while !Task.isCancelled { await reload(); do { try await Task.sleep(for:.seconds(8)) } catch { break } } }
            .onChange(of:model.selectedTeam) { _,new in if new != team { dismiss() } }
    }
    private func reload() async { guard !busy else { return }; busy = true; defer { busy = false }; do { try await model.platformUpdate(team:team) } catch { if !Task.isCancelled { model.explain(error) } } }
}

struct CreateEventView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let team: Int
    @State private var name = ""
    @State private var date = Date()
    @State private var mode = "round-robin"
    @State private var game = "501"
    @State private var checkout = "double"
    @State private var bestOf = 3
    @State private var boards = 1
    @State private var selected = Set<String>()
    @State private var track = true
    @State private var thirdPlace = true
    @State private var newPlayer = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("event_name",text:$name)
                DatePicker("date",selection:$date,displayedComponents:.date)
                Picker("mode",selection:$mode) { ForEach(["round-robin","playoffs","knockout","free"],id:\.self) { Text(tr("mode_" + $0)).tag($0).disabled($0 == "playoffs" && selected.count < 4) } }
                Picker("start_score",selection:$game) { ForEach(["301","501","701"],id:\.self) { Text($0).tag($0) } }
                Picker("checkout",selection:$checkout) { Text("double").tag("double"); Text("single").tag("single") }
                Picker("best_of",selection:$bestOf) { ForEach([1,3,5,7,9,11],id:\.self) { Text("\($0)").tag($0) } }
                Stepper("\(tr("boards")): \(boards)",value:$boards,in:1...8)
                Toggle("track_stats",isOn:$track)
                if mode == "playoffs" {
                    Toggle("third_place_option",isOn:$thirdPlace)
                    if thirdPlace { Text("third_place_notice").font(.footnote).foregroundStyle(ClubStyle.muted) }
                }
                if selected.count >= 2 { advice }

                Section("players") {
                    ForEach(model.teamPlayers) { player in
                        Button { if !selected.insert(player.id).inserted { selected.remove(player.id) } } label: {
                            HStack { Text(player.name); Spacer(); Image(systemName:selected.contains(player.id) ? "checkmark.circle.fill" : "circle") }
                        }
                    }
                    HStack { TextField("player_name",text:$newPlayer); Button { addPlayer() } label: { Image(systemName:"person.badge.plus") }.disabled(newPlayer.trimmingCharacters(in:.whitespaces).count < 2 || busy) }
                }
                Button { create() } label: { Label("create_event",systemImage:"play.fill") }.buttonStyle(ClubButton(primary:true)).disabled(busy || name.trimmingCharacters(in:.whitespaces).count < 2 || selected.count < (mode == "playoffs" ? 4 : 2))
            }.clubScreen().disabled(busy).toolbar { ToolbarItem(placement:.cancellationAction) { Button("cancel") { dismiss() } } }
        }.interactiveDismissDisabled(busy)
    }
    private func countText(_ key: String,_ count: Int) -> String { tr(key).replacingOccurrences(of:"{count}",with:String(count)) }
    private var advice: some View {
        Section("event_advice") {
            if mode == "knockout" {
                Text("event_knockout_advice")
                Text(countText("event_byes",EventAdvice.byes(selected.count)))
            } else if mode != "free" {
                Text(tr("event_league_advice").replacingOccurrences(of:"{players}",with:String(selected.count)).replacingOccurrences(of:"{matches}",with:String(selected.count - 1)))
            }
            if mode == "playoffs" { Text(selected.count >= 4 ? "event_playoffs_advice" : "event_playoffs_minimum") }
            if mode == "round-robin" || mode == "playoffs" {
                if selected.count % 2 == 1 { Text("event_odd_advice"); Text("event_odd_boards") }
            }
            if mode != "free" && (mode != "playoffs" || selected.count >= 4) { Text(countText("event_total",EventAdvice.total(selected.count,mode:mode,thirdPlace:thirdPlace))) }
            Text(countText("event_parallel",EventAdvice.simultaneous(selected.count,boards:boards)))
            if mode != "round-robin" { Button(tr("mode_round-robin")) { mode = "round-robin" } }
            if selected.count >= 4 && mode != "playoffs" { Button(tr("mode_playoffs")) { mode = "playoffs" } }
        }.font(.footnote)
    }
    private func addPlayer() { busy = true; Task { defer { busy = false }; do { let response = try await model.platformUpdate(["action":"add-player","name":newPlayer],team:team); if let id = response.addedPlayerId { selected.insert(id) }; newPlayer = "" } catch { model.explain(error) } } }
    private func create() {
        busy = true
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        Task { defer { busy = false }; do { try await model.platformUpdate(["action":"create","name":name,"date":f.string(from:date),"mode":mode,"game":game,"checkout":checkout,"bestOf":bestOf,"boards":boards,"players":model.teamPlayers.filter { selected.contains($0.id) }.map(\.id),"trackStats":track,"thirdPlaceMatch":mode == "playoffs" && thirdPlace],team:team); dismiss() } catch { model.explain(error) } }
    }
}

struct ManageEventView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let event: Evening
    let team: Int
    @State private var a = ""
    @State private var b = ""
    @State private var player = ""
    @State private var busy = false
    @State private var password = ""
    @State private var deleting = false
    @State private var finishing = false
    var body: some View {
        NavigationStack {
            Form {
                if event.status != "completed" {
                    Button("add_board") { change("add-board") }.disabled(event.boards >= 8)
                    if event.mode == "free" {
                        Section("add_match") {
                            Picker("player_a",selection:$a) { Text("choose_player").tag(""); ForEach(event.players,id:\.self) { Text(model.playerName($0)).tag($0) } }
                            Picker("player_b",selection:$b) { Text("choose_player").tag(""); ForEach(event.players,id:\.self) { Text(model.playerName($0)).tag($0) } }
                            Button("add_match") { change("pair",extra:["a":a,"b":b]) }.disabled(a.isEmpty || b.isEmpty || a == b)
                        }
                        Section("players") {
                            Picker("choose_player",selection:$player) { Text("choose_player").tag(""); ForEach(model.teamPlayers.filter { !event.players.contains($0.id) }) { Text($0.name).tag($0.id) } }
                            Button("join_player") { change("join",extra:["playerId":player]) }.disabled(player.isEmpty)
                        }
                    }
                    if event.mode == "free" { Button("finish_event",role:.destructive) { finishing = true }.disabled(event.matches.contains { $0.status != "done" }) }
                }
                Section {
                    SecureField("password",text:$password)
                    Text("delete_event_notice").font(.footnote)
                    Button("delete_game",role:.destructive) { deleting = true }.disabled(password.isEmpty)
                }
            }.clubScreen().disabled(busy).toolbar { ToolbarItem(placement:.cancellationAction) { Button("done") { dismiss() } } }
                .confirmationDialog("delete_game",isPresented:$deleting,titleVisibility:.visible) { Button("delete_game",role:.destructive) { change("delete",extra:["password":password]) } }
                .confirmationDialog("finish_event",isPresented:$finishing,titleVisibility:.visible) { Button("finish_event",role:.destructive) { change("finish") } }
        }.interactiveDismissDisabled(busy)
    }
    private func change(_ action: String,extra: [String:Any] = [:]) {
        busy = true
        Task { defer { busy = false }; do { try await model.platformUpdate(extra.merging(["action":action,"id":event.id,"revision":event.revision]) { _,new in new },team:team); dismiss() } catch { model.explain(error) } }
    }
}

private struct TeamMetric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Text(value).font(ClubStyle.numberFont(28)).foregroundStyle(ClubStyle.lime)
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(ClubStyle.muted)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(ClubStyle.elevated,in:RoundedRectangle(cornerRadius:12))
    }
}
func teamAverage(_ value: Double?) -> String { value?.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier:AppLanguage.code))) ?? "—" }

struct TeamStatisticsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let team: Int
    var ranking: [TeamPlayerStats] { TeamPlayerStats.ranking(players:model.teamPlayers,events:model.evenings) }
    var body: some View {
        let rows = ranking
        List {
            Section("team_statistics") {
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:10) {
                    TeamMetric(title:"team_finished_events",value:String(model.evenings.filter { $0.status == "completed" }.count))
                    TeamMetric(title:"team_played_matches",value:String(model.evenings.flatMap(\.matches).filter { $0.status == "done" && $0.b != nil }.count))
                    TeamMetric(title:"team_maximums",value:String(rows.reduce(0) { $0 + $1.maximums }))
                    TeamMetric(title:"team_high_checkout",value:rows.map(\.checkout).max().flatMap { $0 > 0 ? String($0) : nil } ?? "—")
                }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section("team_ranking") {
                ForEach(Array(rows.enumerated()),id:\.element.id) { index, row in
                    NavigationLink { TeamPlayerProfile(player:row.player,team:team) } label: {
                        HStack(spacing:14) {
                            Text(String(index + 1)).font(ClubStyle.numberFont(24)).foregroundStyle(ClubStyle.lime).frame(minWidth:28)
                            VStack(alignment:.leading,spacing:6) {
                                Text(row.player.name).font(.headline)
                                Text("\(tr("team_won")): \(row.won) · \(tr("team_played_matches")): \(row.played)").font(.caption).foregroundStyle(ClubStyle.muted)
                            }
                            Spacer()
                            VStack { Text(teamAverage(row.total.value)).font(ClubStyle.numberFont(22)); Text("team_average").font(.caption2).foregroundStyle(ClubStyle.muted) }
                        }.padding(.vertical,6)
                    }
                }
                if rows.isEmpty { Text("team_no_players") }
            }.listRowBackground(ClubStyle.card)
            Section { Text("team_stats_explanation").font(.footnote).foregroundStyle(ClubStyle.muted) }.listRowBackground(Color.clear)
        }.clubScreen().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar)
            .refreshable { await model.refresh(force:true) }
            .onChange(of:model.selectedTeam) { _,value in if value != team { dismiss() } }
    }
}

struct TeamHistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let team: Int
    @State private var search = ""
    @State private var filter = "all"
    var events: [Evening] { model.evenings.filter { (filter == "all" || $0.status == filter) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }.sorted { $0.date > $1.date } }
    var body: some View {
        List {
            Section("team_history") {
                Picker("team_history",selection:$filter) { Text("team_all").tag("all"); Text("status_active").tag("active"); Text("status_completed").tag("completed") }.pickerStyle(.segmented)
            }.listRowBackground(ClubStyle.card)
            Section {
                ForEach(events) { event in
                    NavigationLink { NativeEventView(id:event.id,team:team) } label: {
                        VStack(alignment:.leading,spacing:8) {
                            HStack { Text(event.name).font(.headline); Spacer(); Text(tr("status_" + event.status)).font(.caption).foregroundStyle(ClubStyle.lime) }
                            Text("\(event.date) · \(tr("mode_" + event.mode)) · \(event.game)").font(.caption).foregroundStyle(ClubStyle.muted)
                            if let champion = event.champion { Label(model.playerName(champion),systemImage:"trophy").foregroundStyle(ClubStyle.lime) }
                            if event.trackStats == false { Text("team_untracked").font(.caption).foregroundStyle(ClubStyle.muted) }
                        }.padding(.vertical,6)
                    }
                }
                if events.isEmpty { Text("no_evenings") }
            }.listRowBackground(ClubStyle.card)
        }.clubScreen().searchable(text:$search,prompt:Text("team_search_events")).navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar)
            .refreshable { await model.refresh(force:true) }
            .onChange(of:model.selectedTeam) { _,value in if value != team { dismiss() } }
    }
}

struct TeamParticipantsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let team: Int
    @State private var search = ""
    @State private var name = ""
    @State private var nickname = ""
    @State private var adding = false
    @State private var busy = false
    @State private var saveError = false
    private var limit: Int? { model.account?.teams.first { $0.id == team }?.playerLimit }
    private var full: Bool { limit.map { model.teamPlayers.count >= $0 } ?? false }
    var body: some View {
        List {
            Section {
                VStack(alignment:.leading,spacing:8) {
                    Text(tr(limit == nil ? "participants_count" : "participants_capacity")
                        .replacingOccurrences(of:"{count}",with:String(model.teamPlayers.count))
                        .replacingOccurrences(of:"{limit}",with:String(limit ?? 0)))
                        .font(.headline).foregroundStyle(ClubStyle.lime)
                    if let limit {
                        Text(tr("participants_available").replacingOccurrences(of:"{count}",with:String(max(0,limit - model.teamPlayers.count))))
                            .font(.subheadline).foregroundStyle(ClubStyle.muted)
                    }
                }.padding(.vertical,8)
            }.listRowBackground(ClubStyle.card)
            Section("team_participants") {
                ForEach(Array(model.teamPlayers.enumerated()).filter { search.isEmpty || $0.element.name.localizedCaseInsensitiveContains(search) || ($0.element.nickname ?? "").localizedCaseInsensitiveContains(search) },id:\.element.id) { index, player in
                    NavigationLink { TeamPlayerProfile(player:player,team:team) } label: {
                        HStack { Text("\(index + 1)").font(ClubStyle.numberFont(24)).foregroundStyle(ClubStyle.lime).frame(width:36)
                            VStack(alignment:.leading,spacing:4) { Text(player.name).font(.headline); if let nickname = player.nickname, !nickname.isEmpty { Text(nickname).font(.caption).foregroundStyle(ClubStyle.muted) } }
                        }.padding(.vertical,8)
                    }
                }
                if model.teamPlayers.isEmpty { Text("team_no_players") }
            }.listRowBackground(ClubStyle.card)
            Section { Button { adding = true } label: { Label("team_add_player",systemImage:"person.badge.plus") }.buttonStyle(ClubButton(primary:true)).disabled(!model.online || full) }.listRowBackground(Color.clear)
        }.clubScreen().searchable(text:$search,prompt:Text("team_search_players")).navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar)
            .refreshable { await model.refresh(force:true) }
            .onChange(of:model.selectedTeam) { _,value in if value != team { dismiss() } }
            .sheet(isPresented:$adding) {
                NavigationStack {
                    Form {
                        TextField("player_name",text:$name)
                        TextField("team_nickname",text:$nickname)
                        if saveError { Text("team_player_save_error").font(.footnote).foregroundStyle(ClubStyle.danger) }
                        Button { add() } label: { Label("team_add_player",systemImage:"person.badge.plus") }.buttonStyle(ClubButton(primary:true)).disabled(busy || full || name.trimmingCharacters(in:.whitespacesAndNewlines).count < 2)
                    }.clubScreen().toolbar { ToolbarItem(placement:.cancellationAction) { Button("cancel") { adding = false }.disabled(busy) } }
                }.tint(ClubStyle.lime).interactiveDismissDisabled(busy)
            }
    }
    private func add() {
        busy = true; saveError = false
        Task { defer { busy = false }; do {
            try await model.platformUpdate(["action":"add-player","name":name.trimmingCharacters(in:.whitespacesAndNewlines),"nickname":nickname],team:team)
            adding = false; name = ""; nickname = ""
        } catch { saveError = true } }
    }
}

struct TeamPlayerProfile: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let player: PlatformPlayer
    let team: Int
    var tracked: [Evening] { model.evenings.filter { $0.trackStats != false } }
    var body: some View {
        let stats = TeamPlayerStats.make(player:player,events:tracked)
        List {
            Section {
                Label(player.name,systemImage:"person.crop.circle").font(.headline).foregroundStyle(ClubStyle.lime)
                Text("personal_event_stats_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                if let nickname = player.nickname, !nickname.isEmpty { Text(nickname).foregroundStyle(ClubStyle.muted) }
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:10) {
                    TeamMetric(title:"team_won",value:String(stats.won))
                    TeamMetric(title:"team_win_rate",value:stats.played > 0 ? "\(Int((Double(stats.won) * 100 / Double(stats.played)).rounded()))%" : "—")
                    TeamMetric(title:"team_played_matches",value:String(stats.played))
                    TeamMetric(title:"team_titles",value:String(stats.titles))
                    TeamMetric(title:"team_maximums",value:String(stats.maximums))
                    TeamMetric(title:"team_high_checkout",value:stats.checkout > 0 ? String(stats.checkout) : "—")
                }
            }.listRowBackground(ClubStyle.card)
            Section("team_averages") {
                LabeledContent("team_average",value:teamAverage(stats.total.value))
                LabeledContent("team_first_nine",value:teamAverage(stats.firstNine.value))
                LabeledContent("team_scoring_average",value:teamAverage(stats.scoring.value))
                LabeledContent("team_recorded_darts",value:String(stats.total.darts))
                Text("team_average_explanation").font(.footnote).foregroundStyle(ClubStyle.muted)
            }.listRowBackground(ClubStyle.card)
            Section("team_per_event") {
                ForEach(tracked.filter { $0.matches.contains { $0.b != nil && $0.status == "done" && ($0.a == player.id || $0.b == player.id) } }) { event in
                    let row = TeamPlayerStats.make(player:player,events:[event])
                    NavigationLink { NativeEventView(id:event.id,team:team) } label: {
                        VStack(alignment:.leading,spacing:6) {
                            Text(event.name).font(.headline)
                            Text(event.date).font(.caption).foregroundStyle(ClubStyle.muted)
                            Text("\(tr("team_average")): \(teamAverage(row.total.value)) · \(tr("team_first_nine")): \(teamAverage(row.firstNine.value))").font(.caption)
                            Text("\(tr("team_scoring_average")): \(teamAverage(row.scoring.value))").font(.caption)
                        }.padding(.vertical,4)
                    }
                }
            }.listRowBackground(ClubStyle.card)
            Section("team_head_to_head") {
                ForEach(model.teamPlayers.filter { $0.id != player.id }) { opponent in
                    let matches = tracked.flatMap(\.matches).filter { $0.status == "done" && (($0.a == player.id && $0.b == opponent.id) || ($0.b == player.id && $0.a == opponent.id)) }
                    if !matches.isEmpty {
                        HStack { TeamPlayerLink(playerID:opponent.id,team:team); Spacer(); Text("\(matches.filter { $0.winner == player.id }.count) – \(matches.filter { $0.winner == opponent.id }.count)").font(ClubStyle.numberFont(22)).foregroundStyle(ClubStyle.lime) }
                    }
                }
                if stats.played == 0 { Text("team_no_results") }
            }.listRowBackground(ClubStyle.card)
        }.clubScreen().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar)
            .refreshable { await model.refresh(force:true) }
            .onChange(of:model.selectedTeam) { _,value in if value != team { dismiss() } }
    }
}

// Use platform IDs within the selected team; never merge people by display name.
struct TeamPlayerLink: View {
    @EnvironmentObject var model: AppModel
    let playerID: String?
    let team: Int
    @State private var showing = false
    var body: some View {
        if let player = model.teamPlayers.first(where:{ $0.id == playerID }) {
            Button { showing = true } label: {
                HStack(spacing:4) { Text(player.name); Image(systemName:"chart.bar.xaxis").font(.caption) }
            }.buttonStyle(.borderless).foregroundStyle(ClubStyle.lime)
                .accessibilityLabel(Text(tr("player_statistics_named").replacingOccurrences(of:"{name}",with:player.name)))
                .sheet(isPresented:$showing) {
                    NavigationStack {
                        TeamPlayerProfile(player:player,team:team)
                            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("done") { showing = false } } }
                    }.tint(ClubStyle.lime)
                }
        } else { Text(model.playerName(playerID)) }
    }
}
