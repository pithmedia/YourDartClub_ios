import SwiftUI
import WebKit

struct PlatformDestination: Identifiable {
    let id = UUID()
    let request: URLRequest
    let team: Int
}
struct TeamPlatformView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let destination: PlatformDestination
    @State private var loading = true
    @State private var failed = false
    @State private var attempt = 0
    @State private var closing = false
    var body: some View {
        NavigationStack {
            ZStack {
                PlatformBrowser(request:destination.request,loading:$loading,failed:$failed).id(attempt)
                if loading { ProgressView().padding(24).background(ClubStyle.card,in:RoundedRectangle(cornerRadius:16)) }
                if failed {
                    ContentUnavailableView {
                        Label("platform_unavailable",systemImage:"wifi.exclamationmark")
                    } description: { Text("platform_retry_notice") } actions: {
                        Button("platform_retry") { failed = false; loading = true; attempt += 1 }.buttonStyle(ClubButton(primary:true))
                    }.background(ClubStyle.background)
                }
            }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("close_details") { closing = true } } }
                .confirmationDialog("platform_close",isPresented:$closing,titleVisibility:.visible) {
                    Button("close_details") { dismiss() }
                    Button("cancel",role:.cancel) {}
                } message: { Text("platform_close_notice") }
                .safeAreaInset(edge:.bottom) { if !model.online { Text("platform_online_required").font(.caption).padding(8).frame(maxWidth:.infinity).background(ClubStyle.card) } }
        }
        .interactiveDismissDisabled()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; Task { await model.refresh(force:true) } }
        .onChange(of:model.loggedIn) { _,value in if !value { dismiss() } }
        .onChange(of:model.selectedTeam) { _,value in if value != destination.team { dismiss() } }
    }
}
private struct PlatformBrowser: UIViewRepresentable {
    let request: URLRequest
    @Binding var loading: Bool
    @Binding var failed: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The browser session is isolated from Safari and discarded when this view closes.
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame:.zero,configuration:configuration)
        web.isOpaque = false
        web.backgroundColor = UIColor(ClubStyle.background)
        web.navigationDelegate = context.coordinator
        web.load(request)
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { uiView.stopLoading(); uiView.navigationDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PlatformBrowser
        init(_ parent: PlatformBrowser) { self.parent = parent }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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
