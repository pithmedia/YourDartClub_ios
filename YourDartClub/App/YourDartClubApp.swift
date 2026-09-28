import SwiftUI
import StoreKit
@main struct YourDartClubApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(AppLanguage.preference) private var language = ""
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .environment(\.locale,Locale(identifier:AppLanguage.supported.contains(language) ? language : AppLanguage.code))
                .preferredColorScheme(.dark).tint(ClubStyle.lime)
                .onChange(of: phase) { _, value in if value == .active { Task { await model.refresh(force:true) } } }
        }
    }
}
func tr(_ key: String) -> String { AppLanguage.text(key) }
struct RootView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject var model: AppModel
    @State private var showIntro = true
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection:$selectedTab) {
            GamesView().tabItem { Label("play",systemImage:"target") }.tag(0)
            FavoritesView().tabItem { Label("favorites",systemImage:"star") }.tag(1)
            TeamView().tabItem { Label("team",systemImage:"person.3") }.tag(2)
            AccountView().tabItem { Label("account",systemImage:"person.crop.circle") }.tag(3)
        }
        .background { AirPlayVideoPreview().frame(width:1,height:1).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true) }
        .toolbarBackground(ClubStyle.background,for:.tabBar)
        .overlay { if showIntro { LogoIntro { showIntro = false }.transition(.opacity).zIndex(10) } }
        .safeAreaInset(edge:.top) {
            if let issue = model.issue {
                HStack { Image(systemName:"exclamationmark.triangle"); Text(tr(issue)).font(.caption); Spacer(); Button { model.issue = nil } label: { Image(systemName:"xmark.circle.fill").frame(minWidth:44,minHeight:44) }.accessibilityLabel(Text("dismiss")) }.padding(.horizontal).background(.orange.opacity(0.18))
            }
        }
        .task { for await result in Transaction.updates { await model.recoverPurchase(result) } }
        .task {
            for await intent in PurchaseIntent.intents {
                guard intent.product.type == .autoRenewable else { continue }
                // Never buy before authentication and an explicit team selection.
                // TeamSubscriptionView reloads the server's allowed products and token.
                model.pendingStoreProduct = intent.product
                showIntro = false
                selectedTab = 3
            }
        }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--airplay-picker-test") { AirPlayBoardStream.shared.runPickerSelfTest() }
            if ProcessInfo.processInfo.arguments.contains("--airplay-self-test") { await AirPlayBoardStream.shared.runSelfTest() }
            #endif
            BoardCasting.shared.configure(); while !Task.isCancelled { await model.refresh(); try? await Task.sleep(for:.seconds(15)) } }
    }
}
struct GamesView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject var model: AppModel
    @State private var showArchived = false
    @State private var deletingGame: LocalGame?
    @State private var newGame = false
    @State private var selectedGame: String?
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    var body: some View {
        NavigationSplitView(preferredCompactColumn:$compactColumn) {
            List(selection:$selectedGame) {
                Section {
                    homeHero
                }
                Section {
                    Picker("game_list",selection:$showArchived) {
                        Text("saved_games").tag(false)
                        Text("archive_list").tag(true)
                    }.pickerStyle(.segmented)
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section {
                    if visibleGames.isEmpty { Text("no_games").foregroundStyle(.secondary) }
                    ForEach(visibleGames) { g in
                        NavigationLink(value:g.id) {
                            VStack(alignment:.leading,spacing:6) {
                                Text(g.config.players.joined(separator:" · ")).font(.headline)
                                Text("\(g.config.game) · \(tr(g.config.checkout)) · \(g.createdAt.formatted(Date.FormatStyle(date:.abbreviated,time:.shortened).locale(locale)))").font(.caption).foregroundStyle(.secondary)
                                if let s = try? DartRules.replay(g) { Text(s.legs.map(String.init).joined(separator:" – ")).monospacedDigit().foregroundStyle(ClubStyle.lime) }
                                SyncLabel(game:g)
                            }.padding(.vertical,8)
                        }.listRowBackground(ClubStyle.card)
                            .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                                Button(role:.destructive) { deletingGame = g } label: { Label("delete_game",systemImage:"trash") }.tint(ClubStyle.danger).disabled(model.syncing)
                                Button { archive(g) } label: { Label(g.archived == true ? "restore_game" : "archive_game",systemImage:g.archived == true ? "tray.and.arrow.up" : "archivebox") }.tint(ClubStyle.archive)
                            }
                            .contextMenu {
                                Button { archive(g) } label: { Label(g.archived == true ? "restore_game" : "archive_game",systemImage:"archivebox") }
                                Button(role:.destructive) { deletingGame = g } label: { Label("delete_game",systemImage:"trash") }.tint(ClubStyle.danger).disabled(model.syncing)
                            }
                    }
                }
            }.clubScreen().navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .contentMargins(.top,8,for:.scrollContent)
                .navigationSplitViewColumnWidth(min:280,ideal:340,max:400)
                .toolbar(.hidden,for:.navigationBar)
        } detail: {
            if let id = selectedGame {
                GameView(id:id).id(id)
            } else {
                VStack(spacing:24) {
                    Image("Brand").resizable().scaledToFit().frame(width:116,height:116).clipShape(RoundedRectangle(cornerRadius:28)).shadow(color:ClubStyle.lime.opacity(0.12),radius:40).accessibilityHidden(true)
                    Text("choose_match_description").font(.title3).foregroundStyle(ClubStyle.muted).multilineTextAlignment(.center)
                    Button { newGame = true } label: { Label("new_game",systemImage:"play.fill") }.buttonStyle(ClubButton(primary:true)).frame(maxWidth:300).disabled(model.fatalStorage)
                }.padding(32).frame(maxWidth:.infinity,maxHeight:.infinity).background(ClubBackdrop())
            }
        }
        .navigationSplitViewStyle(.balanced).background(ClubStyle.background)
        .confirmationDialog("delete_game",isPresented:Binding(get:{deletingGame != nil},set:{if !$0 { deletingGame = nil }}),titleVisibility:.visible) {
            Button("delete_game",role:.destructive) {
                if let game = deletingGame, model.deleteGame(game.id), selectedGame == game.id { selectedGame = nil; compactColumn = .sidebar }
                deletingGame = nil
            }
            Button("cancel",role:.cancel) { deletingGame = nil }
        } message: {
            Text(deletingGame?.uploadRequested == true ? "delete_uploaded_notice" : "delete_local_notice")
        }
        .onChange(of:showArchived) { _,_ in selectedGame = nil; compactColumn = .sidebar }
        .onChange(of:selectedGame) { _,id in if id != nil { compactColumn = .detail } }
        .sheet(isPresented:$newGame) {
            NewGameView { id in newGame = false; selectedGame = id; compactColumn = .detail }
        }
    }
    private var visibleGames: [LocalGame] { model.games.filter { ($0.archived == true) == showArchived } }
    private func archive(_ game: LocalGame) {
        model.archiveGame(game.id,archived:game.archived != true)
        if selectedGame == game.id { selectedGame = nil; compactColumn = .sidebar }
    }
    private var homeHero: some View {
VStack(alignment:.leading,spacing:14) {
                        HStack(spacing:12) {
                            Image("Wordmark").resizable().scaledToFit().frame(maxWidth:240).frame(height:56,alignment:.leading).accessibilityLabel("YourDartClub")
                            Spacer(minLength:0)
                            Menu { LanguagePicker() } label: { Image(systemName:"globe").frame(minWidth:44,minHeight:44) }.accessibilityLabel(Text("language"))
                        }
                        Text("home_subtitle").font(.subheadline).foregroundStyle(ClubStyle.muted)
                        Button { newGame = true } label: { Label("new_game",systemImage:"play.fill") }.buttonStyle(ClubButton(primary:true)).disabled(model.fatalStorage)
                        HStack { Label("offline_ready",systemImage:"checkmark.shield"); Spacer(); Text("1–4").bold(); Image(systemName:"person.3") }.font(.caption).foregroundStyle(ClubStyle.muted)
                    }.padding(20).background { ClubBackdrop().clipShape(RoundedRectangle(cornerRadius:24)) }
                        .overlay(RoundedRectangle(cornerRadius:24).stroke(ClubStyle.border,lineWidth:1))
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

}
struct SyncLabel: View {
    @Environment(\.locale) private var locale
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
struct AccountView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject var model: AppModel
    private let base = "https://www.yourdartclub.com"
    @State private var login = ""
    @State private var password = ""
    @State private var busy = false
    @State private var logout = false
    @State private var createTeam = false
    @State private var register = false
    @State private var subscriptionTeam: Team?
    @FocusState private var loginField: LoginField?
    private enum LoginField { case name, password }
    var body: some View {
        NavigationStack {
            Form {
                Section("language") { LanguagePicker() }
                if let product = model.pendingStoreProduct {
                    Section {
                        Text(product.displayName).font(.headline)
                        Text("subscription_store_intent").font(.footnote).foregroundStyle(ClubStyle.muted)
                        Button("cancel") { model.pendingStoreProduct = nil }
                    }.listRowBackground(ClubStyle.card)
                }
                if model.loggedIn {
                    Section("team") { ForEach(model.account?.teams ?? []) { team in VStack(alignment:.leading) { Text(team.name).font(.headline); Text(team.active ? "access_active" : "access_required").font(.caption); if team.owner { NavigationLink { TeamSubscriptionView(team:team) } label: { Label("subscription",systemImage:"creditcard") } } } } }
                    if model.account?.canCreateTeam == true {
                        if model.account?.teams.isEmpty == true {
                            Button { createTeam = true } label: { Label("create_team",systemImage:"person.badge.plus") }.buttonStyle(ClubButton(primary:true))
                        } else {
                            DisclosureGroup("team_options") {
                                Button { createTeam = true } label: { Label("create_extra_team",systemImage:"person.badge.plus") }
                                    .foregroundStyle(ClubStyle.muted)
                                Text("extra_team_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                            }
                        }
                    }
                    Button("sync_now") { Task { await model.refresh(force:true) } }.disabled(model.syncing)
                    if model.account?.canCreateTeam == true { NavigationLink { AccountDeletionView() } label: { Label("deletion_title",systemImage:"person.crop.circle.badge.minus").foregroundStyle(ClubStyle.danger) } }
                    Button("logout",role:.destructive) { logout = true }
                } else {
                    Section {
                        VStack(alignment:.leading,spacing:14) {
                            Image("Wordmark").resizable().scaledToFit().frame(height:52).accessibilityLabel("YourDartClub")
                            Text("login_intro").font(.subheadline).foregroundStyle(ClubStyle.muted)
                            Label("yourdartclub.com",systemImage:"lock.shield").font(.caption).foregroundStyle(ClubStyle.lime)
                        }.padding(.vertical,10)
                    }.listRowBackground(ClubStyle.card)
                    Section {
                        VStack(alignment:.leading,spacing:16) {
                            VStack(alignment:.leading,spacing:8) {
                                Text("login_name").font(.caption.bold()).foregroundStyle(ClubStyle.muted)
                                TextField("login_name",text:$login).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .focused($loginField,equals:.name).submitLabel(.next).onSubmit { loginField = .password }
                                    .padding(14).background(ClubStyle.elevated,in:RoundedRectangle(cornerRadius:12))
                            }
                            VStack(alignment:.leading,spacing:8) {
                                Text("password").font(.caption.bold()).foregroundStyle(ClubStyle.muted)
                                SecureField("password",text:$password).textContentType(.password)
                                    .focused($loginField,equals:.password).submitLabel(.go).onSubmit(signIn)
                                    .padding(14).background(ClubStyle.elevated,in:RoundedRectangle(cornerRadius:12))
                            }
                            if let error = model.loginIssue {
                                Label(tr(error),systemImage:"exclamationmark.circle.fill").font(.subheadline).foregroundStyle(.orange)
                                    .fixedSize(horizontal:false,vertical:true).accessibilityAddTraits(.updatesFrequently)
                            }
                            Button(action:signIn) {
                                HStack(spacing:10) {
                                    if busy { ProgressView().tint(ClubStyle.ink) }
                                    else { Image(systemName:"person.crop.circle.badge.checkmark") }
                                    Text(busy ? "logging_in" : "login")
                                }.padding(.vertical,4)
                            }.buttonStyle(ClubButton(primary:true)).disabled(!canSignIn)
                            Button { register = true } label: { Label("register_account",systemImage:"person.badge.plus") }
                                .buttonStyle(ClubButton(primary:false)).disabled(busy)
                        }.padding(.vertical,8)
                    }.listRowBackground(ClubStyle.card)

                }
                Section("legal_information") { LegalLinks() }
                Section { Text("account_notice"); Text("practice_notice") }.font(.footnote).foregroundStyle(.secondary)
            }.clubScreen().navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden,for:.navigationBar)
                .sheet(isPresented:$createTeam) { CreateTeamView() }
                .sheet(isPresented:$register,onDismiss: {
                    if model.loggedIn { subscriptionTeam = model.account?.teams.first(where: { $0.owner && !$0.active }) }
                }) { RegisterAccountView() }
                .sheet(item:$subscriptionTeam) { team in SubscriptionSheet(team:team) }
                .confirmationDialog("logout",isPresented:$logout,titleVisibility:.visible) { Button("logout",role:.destructive) { Task { await model.logout() } } } message: { Text("logout_notice") }
        }
    }
    private var canSignIn: Bool { !busy && !login.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !password.isEmpty }
    private func signIn() {
        guard canSignIn else { return }
        loginField = nil; busy = true
        Task {
            if await model.login(base:base,login:login,password:password) { password = "" }
            busy = false
        }
    }

}
