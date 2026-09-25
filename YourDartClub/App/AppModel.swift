import SwiftUI
import Network
import Security

struct Session: Codable { let base: URL; let token: String; let userID: Int }
struct Evening: Identifiable { let id: String; let name: String; let mode: String; let matches: [Match] }
struct Match: Identifiable { let id: String; let a: String; let b: String; let score: String; let status: String }
@MainActor final class AppModel: ObservableObject {
    @Published var favorites: [FavoritePlayer] = []
    @Published var games: [LocalGame] = []
    @Published var account: Account?
    @Published var selectedTeam: Int = 0
    @Published var evenings: [Evening] = []
    @Published var online = true
    @Published var syncing = false
    @Published var issue: String?
    @Published var fatalStorage = false
    @Published var loggedIn = false
    @Published var quick = (UserDefaults.standard.object(forKey:"quick") as? Bool) ?? true
    private var database: GameDatabase?
    private var session: Session?
    private let monitor = NWPathMonitor()
    private var retryAfter = Date.distantPast
    private var failures = 0
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
    func save(_ game: LocalGame) throws {
        guard let database, !fatalStorage else { throw GameError.database }
        try database.save(game); games = try database.load()
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
    func login(base: String, login: String, password: String) async {
        guard let url = URL(string:base), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { issue = "connection_error"; return }
        do {
            let body = try JSONSerialization.data(withJSONObject:["login":login,"password":password,"deviceId":deviceID,"deviceSecret":deviceSecret])
            let data = try await MobileAPI(base:url,token:nil).request("login",body:body)
            struct Reply: Decodable { let token: String; let userId: Int }
            let reply = try JSONDecoder().decode(Reply.self,from:data)
            let newSession = Session(base:url,token:reply.token,userID:reply.userId)
            try Vault.write("session",JSONEncoder().encode(newSession)); session = newSession; loggedIn = true; issue = nil
            await refresh(force:true)
        } catch { explain(error) }
    }
    func logout() async {
        guard let current = session else { return }
        // Retain every local game and queued event, even if revocation cannot reach the server.
        do { try Vault.delete("session") } catch { issue = "storage_error"; return }
        session = nil; loggedIn = false; account = nil; evenings = []; selectedTeam = 0
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
                let data = try await MobileAPI(base:current.base,token:current.token,team:teamID).request("club")
                guard session?.token == current.token, selectedTeam == teamID else { return }
                let raw = try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
                let players = (raw["players"] as? [[String:Any]] ?? []).reduce(into:[String:String]()) { map,p in if let id = p["id"] as? String { map[id] = p["name"] as? String } }
                evenings = (raw["evenings"] as? [[String:Any]] ?? []).map { e in
                    Evening(id:e["id"] as? String ?? "", name:e["name"] as? String ?? "",mode:e["mode"] as? String ?? "",matches:(e["matches"] as? [[String:Any]] ?? []).map { m in
                        Match(id:m["id"] as? String ?? "",a:players[m["a"] as? String ?? ""] ?? "…",b:players[m["b"] as? String ?? ""] ?? "…",score:"\(m["scoreA"] as? Int ?? 0) – \(m["scoreB"] as? Int ?? 0)",status:m["status"] as? String ?? "")
                    })
                }
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
