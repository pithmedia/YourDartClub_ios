import SwiftUI
import Network
import Security
import StoreKit

struct Session: Codable { let base: URL; let token: String; let userID: Int }
@MainActor final class AppModel: ObservableObject {
    @Published var favorites: [FavoritePlayer] = []
    @Published var games: [LocalGame] = []
    @Published var account: Account?
    @Published var selectedTeam: Int = 0
    @Published var evenings: [Evening] = []
    @Published var teamPlayers: [PlatformPlayer] = []
    @Published var competition: CompetitionOverview?
    @Published var online = true
    @Published var syncing = false
    @Published var issue: String?
    @Published var loginIssue: String?
    @Published var pendingStoreProduct: Product?
    @Published var fatalStorage = false
    @Published var loggedIn = false
    @Published var quick = (UserDefaults.standard.object(forKey:"quick") as? Bool) ?? true
    private var database: GameDatabase?
    private var session: Session?
    private let monitor = NWPathMonitor()
    private var retryAfter = Date.distantPast
    private var failures = 0
    private var platformRequestRunning = false
    private var deviceID = ""
    private var deviceSecret = ""
    init() {
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory,in: .userDomainMask,appropriateFor: nil,create: true).appendingPathComponent("YourDartClub",isDirectory: true)
            try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath: dir.path)
            database = try GameDatabase(path: dir.appendingPathComponent("games.sqlite").path)
            games = try database!.load(); favorites = try database!.favorites()
            if let saved = Vault.read("device"), let value = String(data:saved,encoding:.utf8) { deviceID = value }
            else { deviceID = UUID().uuidString.lowercased(); try Vault.write("device",Data(deviceID.utf8)) }
            if let saved = Vault.read("deviceSecret"), let value = String(data:saved,encoding:.utf8) { deviceSecret = value }
            else { var bytes = [UInt8](repeating:0,count:32); guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw APIError(status:0) }; deviceSecret = bytes.map { String(format:"%02x",$0) }.joined(); try Vault.write("deviceSecret",Data(deviceSecret.utf8)) }
            if let data = Vault.read("session") { let saved = try JSONDecoder().decode(Session.self,from:data); if saved.base.absoluteString == "https://www.yourdartclub.com" { session = saved; loggedIn = true } }
        } catch { fatalStorage = true; issue = "storage_error" }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.online = path.status == .satisfied; if path.status == .satisfied { await self?.refresh(force:true) } }
        }
        monitor.start(queue: DispatchQueue(label: "yourdartclub.network"))
    }
    func isFavorite(_ name: String) -> Bool { favorites.contains { FavoritePlayer.key($0.name) == FavoritePlayer.key(name) } }
    func toggleFavorite(_ name: String) {
        guard let database else { return }
        do {
            if let found = favorites.first(where:{FavoritePlayer.key($0.name) == FavoritePlayer.key(name)}) { try database.removeFavorite(found.id) }
            else { try database.favorite(name) }
            favorites = try database.favorites()
        } catch { issue = "storage_error" }
    }
    func moveFavorites(from offsets: IndexSet, to destination: Int) {
        guard let database else { return }
        var reordered = favorites
        reordered.move(fromOffsets:offsets,toOffset:destination)
        do { try database.reorderFavorites(reordered.map(\.id)); favorites = reordered }
        catch { issue = "storage_error" }
    }
    func removeFavorite(_ id: String) {
        guard let database else { return }
        do { try database.removeFavorite(id); favorites = try database.favorites() }
        catch { issue = "storage_error" }
    }
    func save(_ game: LocalGame) throws {
        guard let database, !fatalStorage else { throw GameError.database }
        try database.save(game); games = try database.load()
    }
    @discardableResult func changeStarter(_ id: String, to side: Int) -> Bool {
        guard var game = games.first(where:{$0.id == id}), game.canChangeStarter else { return false }
        do { try game.changeStarter(to:side); try save(game); return true }
        catch { issue = "storage_error"; return false }
    }
    func archiveGame(_ id: String, archived: Bool) {
        guard var game = games.first(where:{$0.id == id}) else { return }
        game.archived = archived
        do { try save(game) } catch { issue = "storage_error" }
    }
    @discardableResult func deleteGame(_ id: String) -> Bool {
        guard !syncing else { issue = "delete_wait_sync"; return false }
        guard let database, !fatalStorage else { issue = "storage_error"; return false }
        do {
            try database.deleteGame(id)
            games.removeAll { $0.id == id }
            return true
        } catch { issue = "storage_error"; return false }
    }
    func create(_ config: GameConfig) -> String? {
        let game = LocalGame(config:config)
        do { try save(game); return game.id } catch { issue = "storage_error"; return nil }
    }
    @discardableResult func append(_ event: ScoreEvent, to id: String) -> Bool {
        guard var g = games.first(where:{$0.id == id}) else { return false }
        g.events.append(event)
        do { _ = try DartRules.replay(g); try save(g); Task { await refresh() }; return true }
        catch GameError.database { issue = "storage_error"; return false }
        catch { issue = "invalid_score"; return false }
    }
    func requestUpload(_ id: String) {
        guard let session, let team = account?.teams.first(where:{$0.id == selectedTeam}), team.active, var g = games.first(where:{$0.id == id}), !g.uploadRequested else { issue = "login_required"; return }
        guard g.config.players.count == 2 else { issue = "multiplayer_local"; return }
        g.uploadRequested = true; g.teamID = selectedTeam; g.userID = session.userID; g.serverOrigin = session.base.absoluteString
        do { try save(g); Task { await refresh() } } catch { issue = "storage_error" }
    }
    func register(name: String, email: String, password: String, confirmation: String, teamName: String) async throws {
        let url = URL(string:"https://www.yourdartclub.com")!
        let body = try JSONSerialization.data(withJSONObject:["name":name,"email":email,"password":password,"password_confirmation":confirmation,"teamName":teamName,"terms":true,"locale":AppLanguage.code])
        _ = try await MobileAPI(base:url,token:nil).request("register",body:body)
    }
    func login(base: String, login: String, password: String) async -> Bool {
        loginIssue = nil
        guard let url = URL(string:base), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { loginIssue = "login_connection_error"; return false }
        do {
            let body = try JSONSerialization.data(withJSONObject:["login":login.trimmingCharacters(in:.whitespacesAndNewlines),"password":password,"deviceId":deviceID,"deviceSecret":deviceSecret])
            let data = try await MobileAPI(base:url,token:nil).request("login",body:body)
            struct Reply: Decodable { let token: String; let userId: Int }
            let reply = try JSONDecoder().decode(Reply.self,from:data)
            let newSession = Session(base:url,token:reply.token,userID:reply.userId)
            try Vault.write("session",JSONEncoder().encode(newSession)); session = newSession; loggedIn = true; issue = nil
            await refresh(force:true)
            return true
        } catch {
            switch (error as? APIError)?.status {
            case 401: loginIssue = "login_invalid"
            case 404,405: loginIssue = "login_backend_missing"
            case 429: loginIssue = "login_rate_limit"
            case 400,422: loginIssue = "login_check_fields"
            case 409: loginIssue = "login_device_conflict"
            default: loginIssue = "login_connection_error"
            }
            return false
        }
    }
    func platformDestination(event: String? = nil, create: Bool = false, tv: Bool = false) -> PlatformDestination? {
        guard online, let session, account?.teams.contains(where:{$0.id == selectedTeam && $0.active}) == true else {
            issue = online ? "login_required" : "platform_online_required"; return nil
        }
        var request = URLRequest(url:session.base.appendingPathComponent("mobile/team"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.token)",forHTTPHeaderField:"Authorization")
        request.setValue(String(selectedTeam),forHTTPHeaderField:"X-Team-Id")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("text/html",forHTTPHeaderField:"Accept")
        var body: [String:Any] = ["locale":AppLanguage.code,"create":create,"destination":tv ? "tv" : "team"]
        if let event { body["event"] = event }
        request.httpBody = try? JSONSerialization.data(withJSONObject:body)
        return PlatformDestination(request:request,team:selectedTeam)
    }
    func platformRequest(_ path: String, body: [String:Any]? = nil, team: Int) async throws -> Data {
        while platformRequestRunning { try await Task.sleep(for:.milliseconds(50)) }
        try Task.checkCancellation()
        guard online, let current = session, selectedTeam == team else { throw APIError(status:0) }
        platformRequestRunning = true; defer { platformRequestRunning = false }
        let data = try await MobileAPI(base:current.base,token:current.token,team:team).request(path,body:body.map { try JSONSerialization.data(withJSONObject:$0) })
        guard session?.token == current.token, selectedTeam == team else { throw CancellationError() }
        return data
    }
    @discardableResult func platformUpdate(_ body: [String:Any]? = nil, team: Int) async throws -> PlatformSnapshot {
        let snapshot = try JSONDecoder().decode(PlatformSnapshot.self,from:await platformRequest("club",body:body,team:team))
        evenings = snapshot.evenings; teamPlayers = snapshot.players
        return snapshot
    }
    func accountRequest(_ path: String, query: [URLQueryItem] = [], body: [String:Any]? = nil, team: Int? = nil) async throws -> Data {
        guard online, let current = session else { throw APIError(status:0) }
        let data = try await MobileAPI(base:current.base,token:current.token,team:team).request(path,query:query,body:body.map { try JSONSerialization.data(withJSONObject:$0) })
        guard session?.token == current.token else { throw CancellationError() }
        return data
    }
    @discardableResult func loadCompetition(team: Int, language: String) async throws -> CompetitionOverview {
        let data = try await accountRequest("competition",query:[URLQueryItem(name:"locale",value:language)],team:team)
        guard selectedTeam == team else { throw CancellationError() }
        let result = try JSONDecoder().decode(CompetitionOverview.self,from:data)
        competition = result
        return result
    }
    func competitionOptions(team: Int, language: String, season: String, division: String?) async throws -> CompetitionOptions {
        var query = [URLQueryItem(name:"locale",value:language),URLQueryItem(name:"season",value:season)]
        if let division, !division.isEmpty { query.append(URLQueryItem(name:"division",value:division)) }
        let data = try await accountRequest("competition/options",query:query,team:team)
        guard selectedTeam == team else { throw CancellationError() }
        return try JSONDecoder().decode(CompetitionOptions.self,from:data)
    }
    @discardableResult func saveCompetition(team: Int, language: String, enabled: Bool, season: String? = nil, division: String? = nil, teamID: String? = nil) async throws -> CompetitionOverview {
        var body: [String:Any] = ["locale":language,"enabled":enabled]
        if enabled {
            guard let season, let division, let teamID, !season.isEmpty, !division.isEmpty, !teamID.isEmpty else { throw APIError(status:422) }
            body["season"] = season; body["division"] = division; body["teamId"] = teamID
        }
        let data = try await accountRequest("competition",body:body,team:team)
        guard selectedTeam == team else { throw CancellationError() }
        let result = try JSONDecoder().decode(CompetitionOverview.self,from:data)
        competition = result
        return result
    }
    func clearCompetition() { competition = nil }
    func confirmPurchase(_ result: VerificationResult<StoreKit.Transaction>, team: Int) async throws {
        guard case .verified(let transaction) = result else { throw APIError(status:422) }
        struct Reply: Decodable { let verified: Bool }
        let reply = try JSONDecoder().decode(Reply.self,from:await accountRequest("subscription/verify",body:["signedTransaction":result.jwsRepresentation],team:team))
        guard reply.verified else { throw APIError(status:422) }
        await transaction.finish()
        await refresh(force:true)
    }
    func recoverPurchase(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result, let token = transaction.appAccountToken else { return }
        for team in account?.teams.filter({$0.owner}) ?? [] {
            do {
                let options = try JSONDecoder().decode(SubscriptionOptions.self,from:await accountRequest("subscription",team:team.id))
                if options.token == token { try await confirmPurchase(result,team:team.id); return }
            } catch { /* Keep transaction unfinished so recovery can retry. */ }
        }
    }
    func playerName(_ id: String?) -> String { teamPlayers.first { $0.id == id }?.name ?? "—" }
    func logout() async {
        guard let current = session else { return }
        // Retain every local game and queued event, even if revocation cannot reach the server.
        do { try Vault.delete("session") } catch { issue = "storage_error"; return }
        session = nil; loggedIn = false; account = nil; evenings = []; teamPlayers = []; competition = nil; selectedTeam = 0
        _ = try? await MobileAPI(base:current.base,token:current.token).request("logout",body:Data("{\"revoke\":true}".utf8))
    }
    func refresh(force: Bool = false) async {
        guard online, !syncing, let current = session, !fatalStorage, force || Date() >= retryAfter else { return }
        syncing = true; defer { syncing = false }
        do {
            let api = MobileAPI(base:current.base,token:current.token)
            let me = try JSONDecoder().decode(Account.self,from: await api.request("me"))
            guard session?.token == current.token else { return }
            if account == nil && !UserDefaults.standard.bool(forKey:"quickCustomized") { quick = me.quickScoreAutoSubmit; UserDefaults.standard.set(quick,forKey:"quick") }; account = me
            for await result in Transaction.unfinished { await recoverPurchase(result) }
            if !me.teams.contains(where:{$0.id == selectedTeam}) { selectedTeam = me.teams.first?.id ?? 0 }
            for original in games where original.uploadRequested && original.userID == current.userID && original.serverOrigin == current.base.absoluteString && original.syncProblem == nil {
                guard let teamID = original.teamID, me.teams.contains(where:{$0.id == teamID && $0.active}) else { continue }
                let teamAPI = MobileAPI(base:current.base,token:current.token,team:teamID)
                var attempts = 0
                while let game = games.first(where:{$0.id == original.id}), game.pending > 0 || (game.serverConfirmed != true && attempts == 0) {
                    guard session?.token == current.token else { return }
                    attempts += 1
                    let batch = try SyncQueue.batch(game)
                    do {
                        let ack = try JSONDecoder().decode(SyncAck.self,from:await teamAPI.request("sync",body:JSONEncoder().encode(batch)))
                        guard let latest = games.first(where:{$0.id == game.id}) else { return }
                        try save(SyncQueue.acknowledge(ack,batch:batch,latest:latest))
                    } catch {
                        if let status = (error as? APIError)?.status, [400,409,422,423].contains(status), var latest = games.first(where:{$0.id == game.id}) {
                            latest.syncProblem = "conflict"; try save(latest)
                        }
                        throw error
                    }
                    if game.events.isEmpty { break }
                }
            }
            if me.teams.contains(where:{$0.id == selectedTeam && $0.active}) {
                let teamID = selectedTeam
                try await platformUpdate(team:teamID)
            } else { evenings = [] }
            issue = nil; failures = 0; retryAfter = .distantPast
        } catch { failures += 1; retryAfter = Date().addingTimeInterval(min(300,15 * pow(2,Double(min(failures - 1,5))))); explain(error) }
    }
    func setQuick(_ value: Bool) { quick = value; UserDefaults.standard.set(value,forKey:"quick"); UserDefaults.standard.set(true,forKey:"quickCustomized") }
    func explain(_ error: Error) {
        switch (error as? APIError)?.status {
        case 401: issue = "login_required"
        case 402: issue = "access_required"
        case 403: issue = "team_denied"
        case 409,423: issue = "conflict"
        case 400,422: issue = "invalid_score"
        default: issue = "connection_error"
        }
    }
}
