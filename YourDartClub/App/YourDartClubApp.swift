import SwiftUI
@main struct YourDartClubApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).preferredColorScheme(.dark).tint(ClubStyle.lime)
                .onChange(of: phase) { _, value in if value == .active { Task { await model.refresh(force:true) } } }
        }
    }
}
func tr(_ key: String) -> String { NSLocalizedString(key,comment: "") }
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showIntro = true
    var body: some View {
        TabView {
            GamesView().tabItem { Label("play",systemImage:"target") }
            FavoritesView().tabItem { Label("favorites",systemImage:"star") }
            TeamView().tabItem { Label("team",systemImage:"person.3") }
            AccountView().tabItem { Label("account",systemImage:"person.crop.circle") }
        }
        .toolbarBackground(ClubStyle.background,for:.tabBar)
        .overlay { if showIntro { LogoIntro { showIntro = false }.transition(.opacity).zIndex(10) } }
        .safeAreaInset(edge:.top) {
            if let issue = model.issue {
                HStack { Image(systemName:"exclamationmark.triangle"); Text(tr(issue)).font(.caption); Spacer(); Button { model.issue = nil } label: { Image(systemName:"xmark.circle.fill").frame(minWidth:44,minHeight:44) }.accessibilityLabel(Text("dismiss")) }.padding(.horizontal).background(.orange.opacity(0.18))
            }
        }
        .task { while !Task.isCancelled { await model.refresh(); try? await Task.sleep(for:.seconds(15)) } }
    }
}
struct GamesView: View {
    @EnvironmentObject var model: AppModel
    @State private var newGame = false
    @State private var selectedGame: String?
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    var body: some View {
        NavigationSplitView(preferredCompactColumn:$compactColumn) {
            List(selection:$selectedGame) {
                Section {
                    homeHero
                }
                Section("saved_games") {
                    if model.games.isEmpty { Text("no_games").foregroundStyle(.secondary) }
                    ForEach(model.games) { g in
                        NavigationLink(value:g.id) {
                            VStack(alignment:.leading,spacing:6) {
                                Text(g.config.players.joined(separator:" · ")).font(.headline)
                                Text("\(g.config.game) · \(tr(g.config.checkout)) · \(g.createdAt.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary)
                                if let s = try? DartRules.replay(g) { Text(s.legs.map(String.init).joined(separator:" – ")).monospacedDigit().foregroundStyle(ClubStyle.lime) }
                                SyncLabel(game:g)
                            }.padding(.vertical,8)
                        }.listRowBackground(ClubStyle.card)
                    }
                }
            }.clubScreen().navigationTitle(Text("play"))
                .navigationSplitViewColumnWidth(min:280,ideal:340,max:400)
        } detail: {
            if let id = selectedGame {
                GameView(id:id).id(id)
            } else {
                VStack(spacing:24) {
                    Image("Brand").resizable().scaledToFit().frame(width:116,height:116).clipShape(RoundedRectangle(cornerRadius:28)).shadow(color:ClubStyle.lime.opacity(0.12),radius:40).accessibilityHidden(true)
                    Text("home_title").font(.system(.largeTitle,design:.rounded,weight:.bold)).multilineTextAlignment(.center)
                    Text("choose_match_description").font(.title3).foregroundStyle(ClubStyle.muted).multilineTextAlignment(.center)
                    Button { newGame = true } label: { Label("new_game",systemImage:"play.fill") }.buttonStyle(ClubButton(primary:true)).frame(maxWidth:300).disabled(model.fatalStorage)
                }.padding(32).frame(maxWidth:.infinity,maxHeight:.infinity).background(ClubBackdrop())
            }
        }
        .navigationSplitViewStyle(.balanced).background(ClubStyle.background)
        .onChange(of:selectedGame) { _,id in if id != nil { compactColumn = .detail } }
        .sheet(isPresented:$newGame) {
            NewGameView { id in newGame = false; selectedGame = id; compactColumn = .detail }
        }
    }
    private var homeHero: some View {
VStack(alignment:.leading,spacing:20) {
                        Image("Wordmark").resizable().scaledToFit().frame(height:65).accessibilityLabel("YourDartClub")
                        Text("home_eyebrow").font(.caption.weight(.bold)).tracking(2).foregroundStyle(ClubStyle.lime)
                        Text("home_title").font(.system(.largeTitle,design:.rounded,weight:.bold)).fixedSize(horizontal:false,vertical:true)
                        Text("home_subtitle").font(.subheadline).foregroundStyle(ClubStyle.muted)
                        Button { newGame = true } label: { Label("new_game",systemImage:"play.fill") }.buttonStyle(ClubButton(primary:true)).disabled(model.fatalStorage)
                        HStack { Label("offline_ready",systemImage:"checkmark.shield"); Spacer(); Text("2–4").bold(); Image(systemName:"person.3") }.font(.caption).foregroundStyle(ClubStyle.muted)
                    }.padding(22).background { ClubBackdrop().clipShape(RoundedRectangle(cornerRadius:24)) }
                        .overlay(RoundedRectangle(cornerRadius:24).stroke(ClubStyle.border,lineWidth:1))
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

}
struct SyncLabel: View {
    @EnvironmentObject var model: AppModel
    let game: LocalGame
    var body: some View {
        Label(status,systemImage:!game.uploadRequested ? "internaldrive" : (!model.online ? "wifi.slash" : "arrow.triangle.2.circlepath"))
            .font(.caption).foregroundStyle(.secondary)
    }
    var status: String {
        if let problem = game.syncProblem { return tr(problem) }
        if !game.uploadRequested { return tr("local_only") }
        if !model.online { return tr("offline") + " · \(game.pending) " + tr("queued") }
        if model.syncing { return tr("syncing") }
        if game.pending > 0 || game.serverConfirmed != true { return "\(max(1,game.pending)) " + tr("queued") }
        return tr("synced")
    }
}
struct TeamView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationStack {
            List {
                if let account = model.account {
                    Picker("team",selection:$model.selectedTeam) { ForEach(account.teams) { Text($0.name).tag($0.id) } }.onChange(of:model.selectedTeam) { _,_ in model.evenings = []; Task { await model.refresh() } }
                    Text(model.online ? "team_online_notice" : "offline_notice").font(.footnote).foregroundStyle(.secondary)
                    if model.evenings.isEmpty { Text("no_evenings") }
                    ForEach(model.evenings) { evening in
                        Section(evening.name) {
                            ForEach(evening.matches) { match in VStack(alignment:.leading,spacing:5) { Text(match.a + " · " + match.b).font(.headline); HStack { Text(match.score).monospacedDigit(); Spacer(); Text(tr(match.status)).font(.caption) } } }
                        }
                    }
                } else { Text("login_required") }
            }.clubScreen().navigationTitle(Text("team")).refreshable { await model.refresh(force:true) }
        }
    }
}
struct AccountView: View {
    @EnvironmentObject var model: AppModel
    private let base = "https://www.yourdartclub.com"
    @State private var login = ""
    @State private var password = ""
    @State private var busy = false
    @State private var logout = false
    var body: some View {
        NavigationStack {
            Form {
                if model.loggedIn {
                    Section("team") { ForEach(model.account?.teams ?? []) { team in VStack(alignment:.leading) { Text(team.name).font(.headline); Text(team.active ? "access_active" : "access_required").font(.caption) } } }
                    Button("sync_now") { Task { await model.refresh(force:true) } }.disabled(model.syncing)
                    Button("logout",role:.destructive) { logout = true }
                } else {
                    Section("login") {
                        Label("yourdartclub.com",systemImage:"lock.shield").font(.footnote).foregroundStyle(ClubStyle.muted)
                        TextField("login_name",text:$login).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("password",text:$password).textContentType(.password)
                        Button("login") { busy = true; Task { await model.login(base:base,login:login,password:password); password = ""; busy = false } }.disabled(busy || login.isEmpty || password.isEmpty)
                    }
                }
                Section { Text("account_notice"); Text("practice_notice") }.font(.footnote).foregroundStyle(.secondary)
            }.clubScreen().navigationTitle(Text("account"))
                .confirmationDialog("logout",isPresented:$logout,titleVisibility:.visible) { Button("logout",role:.destructive) { Task { await model.logout() } } } message: { Text("logout_notice") }
        }
    }
}
