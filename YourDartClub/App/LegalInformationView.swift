import SwiftUI
import StoreKit

enum LegalURL {
    static func page(_ path: String) -> URL {
        let prefix = AppLanguage.code == "en" ? "" : "/" + AppLanguage.code
        return URL(string:"https://yourdartclub.com" + prefix + path)!
    }
}
struct LegalLinks: View {
    var body: some View {
        Link(destination:LegalURL.page("/terms")) { Label("subscription_terms",systemImage:"doc.text") }
        Link(destination:LegalURL.page("/privacy")) { Label("subscription_privacy",systemImage:"hand.raised") }
        Link(destination:LegalURL.page("/cancellation")) { Label("legal_cancellation",systemImage:"creditcard") }
        Link(destination:LegalURL.page("/contact")) { Label("legal_contact",systemImage:"envelope") }
        Link("legal_apple_eula",destination:URL(string:"https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
    }
}
struct AccountDeletionView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var confirm = false
    @State private var busy = false
    @State private var requested = false
    @State private var issue = false
    private struct Status: Decodable { let requested: Bool }
    var body: some View {
        Form {
            Section {
                Label("deletion_title",systemImage:"person.crop.circle.badge.minus").font(.headline)
                Text("deletion_notice").font(.subheadline)
                Text("deletion_billing_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                YourDartClubSubscriptionManagement()
                Link("legal_cancellation",destination:LegalURL.page("/cancellation"))
            }.listRowBackground(ClubStyle.card)
            if requested {
                Section { Label("deletion_received",systemImage:"checkmark.circle").foregroundStyle(ClubStyle.lime) }.listRowBackground(ClubStyle.card)
            } else {
                Section {
                    SecureField("password",text:$password).textContentType(.password)
                    Toggle("deletion_confirm",isOn:$confirm)
                    if issue { Text("deletion_failed").foregroundStyle(ClubStyle.danger) }
                    Button(role:.destructive) { submit() } label: {
                        if busy { ProgressView() } else { Label("deletion_submit",systemImage:"trash") }
                    }.disabled(busy || !confirm || password.isEmpty).foregroundStyle(ClubStyle.danger)
                }.listRowBackground(ClubStyle.card)
            }
        }.clubScreen().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar)
            .task { do { requested = try JSONDecoder().decode(Status.self,from:await model.accountRequest("account-deletion")).requested } catch { issue = true } }
    }
    private func submit() {
        busy = true; issue = false
        Task { defer { busy = false; password = "" }; do {
            requested = try JSONDecoder().decode(Status.self,from:await model.accountRequest("account-deletion",body:["password":password,"confirm":true,"locale":AppLanguage.code])).requested
        } catch { issue = true } }
    }
}
