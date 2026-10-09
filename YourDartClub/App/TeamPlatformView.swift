import SwiftUI
import WebKit
import CryptoKit

struct PlatformDestination: Identifiable {
    let id = UUID()
    let request: URLRequest
    let team: Int
    var agenda = false
    var cacheScope: String = ""
    var teamName: String = ""
}
struct TeamPlatformView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let destination: PlatformDestination
    @State private var loading = true
    @State private var failed = false
    @State private var attempt = 0
    @State private var closing = false
    @State private var savedAgenda: SavedAgenda?
    var body: some View {
        Group {
            if destination.agenda { platformContent }
            else { NavigationStack { platformContent } }
        }
        .interactiveDismissDisabled(!destination.agenda)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = !destination.agenda; savedAgenda = AgendaCache.read(scope:destination.cacheScope,team:destination.team) }
        .onChange(of:model.online) { _,online in if online && destination.agenda { failed = false; loading = true; attempt += 1 } }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; Task { await model.refresh(force:true) } }
        .onChange(of:model.loggedIn) { _,value in if !value { dismiss() } }
        .onChange(of:model.selectedTeam) { _,value in if value != destination.team { dismiss() } }
    }
    private var platformContent: some View {
            ZStack {
                if destination.agenda && (!model.online || failed) {
                    OfflineAgendaView(saved:savedAgenda) { failed = false; loading = true; attempt += 1 }
                } else {
                    PlatformBrowser(request:destination.request,loading:$loading,failed:$failed,onAgenda: { payload in
                        guard destination.agenda, !payload.unavailable, model.loggedIn, model.agendaCacheScope == destination.cacheScope else { return }
                        let saved = SavedAgenda(team:destination.team,name:destination.teamName,updatedAt:Date(),fixtures:payload.fixtures)
                        if AgendaCache.save(saved,scope:destination.cacheScope) { savedAgenda = saved }
                    }).id(attempt)
                }
                if loading && (!destination.agenda || model.online && !failed) { ProgressView().padding(24).background(ClubStyle.card,in:RoundedRectangle(cornerRadius:16)) }
                if failed && !destination.agenda {
                    ContentUnavailableView {
                        Label("platform_unavailable",systemImage:"wifi.exclamationmark")
                    } description: { Text("platform_retry_notice") } actions: {
                        Button("platform_retry") { failed = false; loading = true; attempt += 1 }.buttonStyle(ClubButton(primary:true))
                    }.background(ClubStyle.background)
                }
            }.navigationTitle(destination.agenda ? tr("team_agenda") : "").navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible,for:.navigationBar)
                .toolbar { if !destination.agenda { ToolbarItem(placement:.cancellationAction) { Button("close_details") { closing = true } } } }
                .confirmationDialog("platform_close",isPresented:$closing,titleVisibility:.visible) {
                    Button("close_details") { dismiss() }
                    Button("cancel",role:.cancel) {}
                } message: { Text("platform_close_notice") }
                .safeAreaInset(edge:.bottom) { if !model.online && !destination.agenda { Text("platform_online_required").font(.caption).padding(8).frame(maxWidth:.infinity).background(ClubStyle.card) } }
    }
}
private struct PlatformBrowser: UIViewRepresentable {
    let request: URLRequest
    @Binding var loading: Bool
    @Binding var failed: Bool
    var onAgenda: (AgendaPayload) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The browser session is isolated from Safari and discarded when this view closes.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator,name:"agendaSnapshot")
        // Capture only successful agenda responses, including refreshes and attendance changes.
        configuration.userContentController.addUserScript(WKUserScript(source:"""
        const agendaFetch = window.fetch;
        window.fetch = async function(...args) {
          const response = await agendaFetch.apply(this,args);
          try {
            const url = new URL(response.url);
            if (response.ok && url.origin === location.origin && url.pathname === '/api/agenda') {
              response.clone().json().then(data => window.webkit.messageHandlers.agendaSnapshot.postMessage(JSON.stringify(data))).catch(()=>{});
            }
          } catch (_) {}
          return response;
        };
        """,injectionTime:.atDocumentStart,forMainFrameOnly:true))
        let web = WKWebView(frame:.zero,configuration:configuration)
        web.isOpaque = false
        web.backgroundColor = UIColor(ClubStyle.background)
        web.navigationDelegate = context.coordinator
        web.load(request)
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { uiView.stopLoading(); uiView.navigationDelegate = nil; uiView.configuration.userContentController.removeScriptMessageHandler(forName:"agendaSnapshot") }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: PlatformBrowser
        init(_ parent: PlatformBrowser) { self.parent = parent }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let origin = parent.request.url,
                  message.frameInfo.securityOrigin.protocol == origin.scheme,
                  message.frameInfo.securityOrigin.host == origin.host,
                  (message.frameInfo.securityOrigin.port == (origin.port ?? 443) || origin.port == nil && message.frameInfo.securityOrigin.port == 0),
                  let value = message.body as? String, value.utf8.count < 2_000_000,
                  let payload = try? JSONDecoder().decode(AgendaPayload.self,from:Data(value.utf8)) else { return }
            parent.onAgenda(payload)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, PlatformExternalLinks.isMaps(url) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel); return
            }
            if let url = action.request.url, url.scheme == "webcal", url.host == parent.request.url?.host,
               url.path.range(of:"^/calendar/team/[A-Za-z0-9]{64}\\.ics$",options:.regularExpression) != nil {
                UIApplication.shared.open(url)
                decisionHandler(.cancel); return
            }
            guard let url = action.request.url, let origin = parent.request.url,
                  url.scheme == "https", url.host == origin.host, url.port == origin.port,
                  action.targetFrame?.isMainFrame == true,
                  (["/mobile/team","/language","/tv/pair"].contains(url.path) || url.path.range(of:"^/tv/displays/[^/]+/(settings|revoke)$",options:.regularExpression) != nil) else {
                if action.targetFrame?.isMainFrame == true, let path = action.request.url?.path,
                   ["/login","/team-login","/billing/start"].contains(path) { parent.loading = false; parent.failed = true }
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let http = response.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                parent.failed = true; parent.loading = false; decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { parent.loading = false; parent.failed = true }
        private func fail(_ error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.loading = false; parent.failed = true }
        }
    }
}

// Scoped to the current login token and team; credentials are never stored in this cache.
enum AgendaCache {
    static let prefix = "offline-agenda."
    static func scope(_ session: Session) -> String { SHA256.hash(data:Data((session.base.absoluteString + "|" + session.token).utf8)).map { String(format:"%02x",$0) }.joined() }
    static func read(scope: String,team: Int) -> SavedAgenda? {
        guard !scope.isEmpty, let data = UserDefaults.standard.data(forKey:prefix + scope + "." + String(team)) else { return nil }
        return try? JSONDecoder().decode(SavedAgenda.self,from:data)
    }
    static func all(scope: String) -> [SavedAgenda] {
        guard !scope.isEmpty else { return [] }
        return UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix + scope + ".") }.compactMap { key in
            UserDefaults.standard.data(forKey:key).flatMap { try? JSONDecoder().decode(SavedAgenda.self,from:$0) }
        }.sorted { $0.name < $1.name }
    }
    static func save(_ agenda: SavedAgenda,scope: String) -> Bool {
        guard !scope.isEmpty, let data = try? JSONEncoder().encode(agenda) else { return false }
        UserDefaults.standard.set(data,forKey:prefix + scope + "." + String(agenda.team)); return true
    }
    static func clear() { for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) { UserDefaults.standard.removeObject(forKey:key) } }
    static func prune(scope: String,teams: [Int]) {
        for agenda in all(scope:scope) where !teams.contains(agenda.team) { UserDefaults.standard.removeObject(forKey:prefix + scope + "." + String(agenda.team)) }
    }
}
private struct OfflineAgendaView: View {
    let saved: SavedAgenda?
    var retry: () -> Void
    private var today: String { let f = DateFormatter(); f.timeZone = TimeZone(identifier:"Europe/Amsterdam"); f.dateFormat = "yyyy-MM-dd"; return f.string(from:Date()) }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Label("agenda_saved_notice",systemImage:"wifi.slash").font(.headline)
                if let saved {
                    Text(saved.name).font(.title2.bold())
                    Text(tr("agenda_updated_at").replacingOccurrences(of:":date",with:saved.updatedAt.formatted(date:.abbreviated,time:.shortened))).font(.caption).foregroundStyle(ClubStyle.muted)
                    Text("agenda_read_only").font(.subheadline).foregroundStyle(ClubStyle.muted)
                    let fixtures = saved.upcoming(today:today)
                    if fixtures.isEmpty { Text("agenda_empty") }
                    ForEach(fixtures) { fixture in
                        VStack(alignment:.leading,spacing:8) {
                            Text((fixture.date ?? "").isEmpty ? (fixture.dateLabel ?? tr("agenda_date_unknown")) : fixture.date!).font(.headline).foregroundStyle(ClubStyle.lime)
                            Text(fixture.displayTitle).font(.headline)
                            if let time = fixture.time, !time.isEmpty { Label(time,systemImage:"clock") }
                            if let venue = fixture.venue, !venue.isEmpty { Label(venue,systemImage:"mappin.and.ellipse") }
                            if let address = fixture.venueAddress, !address.isEmpty { Text(address).font(.caption) }
                            if fixture.cancelled == true { Text("agenda_cancelled").foregroundStyle(.orange) }
                        }.frame(maxWidth:.infinity,alignment:.leading).padding().background(ClubStyle.card,in:RoundedRectangle(cornerRadius:16))
                    }
                } else { Text("agenda_no_saved") }
                Button("platform_retry",action:retry).buttonStyle(ClubButton(primary:true))
            }.padding()
        }.background(ClubStyle.background)
    }
}
