import SwiftUI

struct SubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let team: Team
    var body: some View {
        NavigationStack {
            TeamSubscriptionView(team:team)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("done") { dismiss() } } }
        }.tint(ClubStyle.lime)
    }
}
struct RegisterAccountView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var teamName = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var accepted = false
    @State private var busy = false
    @State private var created = false
    @State private var issue: String?
    private var valid: Bool {
        !busy && name.trimmingCharacters(in:.whitespacesAndNewlines).count >= 2 && name.count <= 80 &&
        teamName.trimmingCharacters(in:.whitespacesAndNewlines).count >= 2 && teamName.count <= 80 &&
        email.contains("@") && password.count >= 10 && password.count <= 200 && password == confirmation && accepted
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("register_account",systemImage:"person.badge.plus").font(.headline).foregroundStyle(ClubStyle.lime)
                    Text("register_intro").font(.subheadline).foregroundStyle(ClubStyle.muted)
                }.listRowBackground(ClubStyle.card)
                Section {
                    TextField("register_name",text:$name).textContentType(.name)
                    TextField("register_email",text:$email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("team_name",text:$teamName)
                    SecureField("password",text:$password).textContentType(.newPassword)
                    SecureField("register_password_again",text:$confirmation).textContentType(.newPassword)
                    Text("register_password_hint").font(.footnote).foregroundStyle(ClubStyle.muted)
                }.disabled(busy || created).listRowBackground(ClubStyle.card)
                Section {
                    Toggle("register_accept",isOn:$accepted).disabled(busy || created)
                    LegalLinks()
                }.listRowBackground(ClubStyle.card)
                Section {
                    if let issue { Text(LocalizedStringKey(issue)).foregroundStyle(ClubStyle.danger) }
                    Button { submit() } label: {
                        HStack {
                            if busy { ProgressView() }
                            Label(created ? "login" : "register_continue",systemImage:"person.badge.plus")
                        }
                    }.buttonStyle(ClubButton(primary:true)).disabled(created ? busy : !valid)
                }.listRowBackground(ClubStyle.card)
            }.clubScreen().toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("cancel") { dismiss() }.disabled(busy) }
            }
        }.tint(ClubStyle.lime).interactiveDismissDisabled(busy)
    }
    private func submit() {
        busy = true; issue = nil
        Task {
            defer { busy = false }
            do {
                if !created {
                    try await model.register(name:name.trimmingCharacters(in:.whitespacesAndNewlines),email:email.trimmingCharacters(in:.whitespacesAndNewlines),password:password,confirmation:confirmation,teamName:teamName.trimmingCharacters(in:.whitespacesAndNewlines))
                    created = true
                }
                if await model.login(base:"https://www.yourdartclub.com",login:email,password:password) {
                    password = ""; confirmation = ""; dismiss()
                } else { issue = "register_created_login" }
            } catch {
                switch (error as? APIError)?.status {
                case 422: issue = "register_invalid"
                case 429: issue = "login_rate_limit"
                case 404,405: issue = "login_backend_missing"
                default: issue = "register_failed"
                }
            }
        }
    }
}
