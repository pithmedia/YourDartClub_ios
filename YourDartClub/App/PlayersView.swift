import SwiftUI

struct FavoritesView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var editing = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment:.leading,spacing:12) {
                        Image(systemName:"star.fill").font(.largeTitle).foregroundStyle(ClubStyle.lime)
                        Text("favorites_notice").font(.subheadline).foregroundStyle(ClubStyle.muted)
                    }.padding(.vertical,8)
                    HStack {
                        TextField("player_name",text:$name).textInputAutocapitalization(.words).onSubmit(add)
                        Button(action:add) { Image(systemName:"plus").frame(minWidth:44,minHeight:44) }.accessibilityLabel(Text("add_favorite"))
                            .disabled(FavoritePlayer.clean(name).isEmpty || name.count > 60)
                    }
                }.listRowBackground(ClubStyle.card)
                Section {
                    HStack {
                        Text("favorites").font(.headline)
                        Spacer()
                        Button(editing ? "done" : "edit_favorites") { withAnimation { editing.toggle() } }
                            .disabled(model.favorites.isEmpty)
                    }
                    if editing { Text("reorder_favorites_notice").font(.caption).foregroundStyle(ClubStyle.muted) }
                }.listRowBackground(ClubStyle.card)
                Section {
                    if model.favorites.isEmpty { Text("no_favorites").foregroundStyle(ClubStyle.muted) }
                    ForEach(model.favorites) { player in
                        HStack {
                            Text(String(player.name.prefix(1)).uppercased()).font(.headline).frame(width:40,height:40).background(ClubStyle.elevated,in:Circle())
                            Group { if editing { Text(player.name).font(.headline) } else { NavigationLink { FavoriteMatchesView(name:player.name) } label: { Text(player.name).font(.headline) } } }; Spacer()
                            if !editing {
                            Button { model.removeFavorite(player.id) } label: { Image(systemName:"star.fill").frame(minWidth:44,minHeight:44) }.buttonStyle(.plain).foregroundStyle(ClubStyle.lime).accessibilityLabel(Text(textFormat("remove_favorite_name",player.name)))
                            }
                        }
                        .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                            Button(role:.destructive) { model.removeFavorite(player.id) } label: { Label("remove_favorite",systemImage:"trash") }.tint(ClubStyle.danger)
                        }
                    }
                    .onMove { offsets,destination in model.moveFavorites(from:offsets,to:destination) }
                    .onDelete { offsets in
                        let ids = offsets.map { model.favorites[$0].id }
                        for id in ids { model.removeFavorite(id) }
                    }
                }.listRowBackground(ClubStyle.card)
            }.environment(\.editMode,Binding(get:{editing ? .active : .inactive},set:{editing = $0.isEditing}))
                .onChange(of:model.favorites.isEmpty) { _,empty in if empty { editing = false } }
                .clubScreen().navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden,for:.navigationBar)
        }
    }
    private func add() { let clean = FavoritePlayer.clean(name); guard !clean.isEmpty, clean.count <= 60 else { return }; if !model.isFavorite(clean) { model.toggleFavorite(clean) }; if model.isFavorite(clean) { name = "" } }
}
struct NewGameView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var names = ["","","",""]
    @State private var count = 2
    @State private var game = 501
    @State private var checkout = "double"
    @State private var best = 3
    @State private var starter = "A"
    let started: (String) -> Void
    private let sides = ["A","B","C","D"]
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image("Wordmark").resizable().scaledToFit().frame(height:60).frame(maxWidth:.infinity).accessibilityLabel("YourDartClub")
                    Picker("player_count",selection:$count) { ForEach(1...4,id:\.self) { Text(String($0)).tag($0) } }.pickerStyle(.segmented)
                        .onChange(of:count) { _,value in if let index = sides.firstIndex(of:starter), index >= value { starter = "A" } }
                }.listRowBackground(ClubStyle.card)
                Section("players") {
                    ForEach(0..<count,id:\.self) { index in
                        HStack(spacing:8) {
                            Text(String(index + 1)).font(.caption.bold()).foregroundStyle(ClubStyle.lime).frame(width:24)
                            TextField(textFormat("player_number",index + 1),text:$names[index]).textInputAutocapitalization(.words)
                            if !model.favorites.isEmpty {
                                Menu {
                                    ForEach(model.favorites) { favorite in Button(favorite.name) { names[index] = favorite.name } }
                                } label: { Image(systemName:"person.crop.circle.badge.checkmark").frame(minWidth:44,minHeight:44) }.accessibilityLabel(Text("choose_favorite"))
                            }
                            Button { model.toggleFavorite(names[index]) } label: { Image(systemName:model.isFavorite(names[index]) ? "star.fill" : "star").frame(minWidth:44,minHeight:44) }
                                .buttonStyle(.borderless).disabled(FavoritePlayer.clean(names[index]).isEmpty || names[index].count > 60)
                                .accessibilityLabel(Text(model.isFavorite(names[index]) ? "remove_favorite" : "add_favorite"))
                        }
                    }
                    Text("favorite_tip").font(.caption).foregroundStyle(ClubStyle.muted)
                }.listRowBackground(ClubStyle.card)
                Section("rules") {
                    Picker("start_score",selection:$game) { ForEach([301,501,701],id:\.self) { Text(String($0)).tag($0) } }
                    Picker("checkout",selection:$checkout) { Text("double").tag("double"); Text("single").tag("single") }
                    Picker("best_of",selection:$best) { ForEach([1,3,5,7,9,11],id:\.self) { Text(String($0)).tag($0) } }
                    Picker("starter",selection:$starter) { ForEach(0..<count,id:\.self) { i in Text(names[i].isEmpty ? textFormat("player_number",i + 1) : names[i]).tag(sides[i]) } }
                }.listRowBackground(ClubStyle.card)
                Section {
                    if count != 2 { Label("multiplayer_local",systemImage:"internaldrive").font(.footnote) }
                    Text("practice_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                    Button { if let id = model.create(.init(players:Array(names.prefix(count)).map(FavoritePlayer.clean),game:game,checkout:checkout,bestOf:best,starter:starter)) { started(id) } } label: { Label("start",systemImage:"play.fill") }.buttonStyle(ClubButton(primary:true)).disabled(!valid)
                }.listRowBackground(ClubStyle.card)
            }.clubScreen().navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("cancel") { dismiss() } } }
        }
    }
    private var valid: Bool { names.prefix(count).allSatisfy { !FavoritePlayer.clean($0).isEmpty && FavoritePlayer.clean($0).count <= 60 } }
}

struct FavoriteMatchesView: View {
    @EnvironmentObject var model: AppModel
    let name: String
    private var matches: [LocalGame] {
        model.games.filter { $0.config.players.contains(name) }.sorted { $0.createdAt > $1.createdAt }
    }
    var body: some View {
        List {
            Section {
                Text(name).font(.headline)
                Text("favorite_match_history_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
            }.listRowBackground(ClubStyle.card)
            Section("saved_games") {
                ForEach(matches) { game in
                    NavigationLink { LocalMatchStatisticsView(gameID:game.id) } label: {
                        VStack(alignment:.leading,spacing:6) {
                            Text(game.config.players.joined(separator:" · ")).font(.headline)
                            Text(game.createdAt,style:.date).font(.caption).foregroundStyle(ClubStyle.muted)
                            if let state = try? DartRules.replay(game) { Text(state.legs.map(String.init).joined(separator:" – ")).foregroundStyle(ClubStyle.lime) }
                        }.padding(.vertical,6)
                    }
                }
                if matches.isEmpty { Text("no_saved_player_matches").foregroundStyle(ClubStyle.muted) }
            }.listRowBackground(ClubStyle.card)
        }.clubScreen().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar)
    }
}
