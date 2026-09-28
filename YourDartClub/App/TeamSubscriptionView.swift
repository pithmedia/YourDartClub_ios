import SwiftUI
import StoreKit

struct SubscriptionOptions: Decodable {
    struct Offer: Decodable { let id: String; let period: String }
    let available: Bool
    let products: [Offer]
    let token: UUID?
    let canPurchase: Bool
}
struct CreateTeamView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var failed = false
    @State private var requestID = UUID().uuidString
    @State private var submittedName: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("create_team",systemImage:"person.3.fill").font(.headline).foregroundStyle(ClubStyle.lime)
                    TextField("team_name",text:$name).disabled(busy || submittedName != nil)
                    Text("create_team_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                    if failed { Text("create_team_failed").foregroundStyle(ClubStyle.danger) }
                    Button { create() } label: { Label(busy ? "team_creating" : "create_team",systemImage:"plus.circle.fill") }
                        .buttonStyle(ClubButton(primary:true)).disabled(busy || name.trimmingCharacters(in:.whitespacesAndNewlines).count < 2 || name.count > 80)
                }.listRowBackground(ClubStyle.card)
            }.clubScreen().toolbar { ToolbarItem(placement:.cancellationAction) { Button("cancel") { dismiss() }.disabled(busy) } }
        }.tint(ClubStyle.lime).interactiveDismissDisabled(busy)
    }
    private func create() {
        let clean = submittedName ?? name.trimmingCharacters(in:.whitespacesAndNewlines)
        submittedName = clean; busy = true; failed = false
        Task { defer { busy = false }; do {
            struct Reply: Decodable { let teamId: Int }
            let response = try JSONDecoder().decode(Reply.self,from:await model.accountRequest("teams",body:["name":clean,"requestId":requestID]))
            await model.refresh(force:true); model.selectedTeam = response.teamId; dismiss()
        } catch { failed = true } }
    }
}
struct TeamSubscriptionView: View {
    @EnvironmentObject var model: AppModel
    let team: Team
    @State private var options: SubscriptionOptions?
    @State private var products: [Product] = []
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Text(team.name).font(.headline)
                Text("subscription_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                Text("subscription_binding_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                if let message { Text(LocalizedStringKey(message)).foregroundStyle(ClubStyle.lime) }
                if let options {
                    if !options.available { Text("subscription_unavailable") }
                    else if !options.canPurchase { Text("subscription_existing") }
                    else {
                        ForEach(products) { product in
                            Button { purchase(product) } label: {
                                VStack(alignment:.leading,spacing:6) {
                                    Text(LocalizedStringKey(options.products.first { $0.id == product.id }?.period == "yearly" ? "subscription_yearly" : "subscription_monthly")).font(.headline)
                                    Text(product.displayPrice).font(ClubStyle.numberFont(26))
                                    if model.pendingStoreProduct?.id == product.id {
                                        Text("subscription_store_selected").font(.caption)
                                    }
                                }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,6)
                            }.buttonStyle(ClubButton(primary:true)).disabled(busy)
                        }
                        if products.isEmpty { Text("subscription_unavailable") }
                    }
                } else { ProgressView() }
            }.listRowBackground(ClubStyle.card)
            Section {
                Button("subscription_restore") { restore() }.disabled(busy || options?.available != true)
                YourDartClubSubscriptionManagement(groupID:products.first?.subscription?.subscriptionGroupID).disabled(busy)
                Button("subscription_reload") { Task { await load() } }.disabled(busy)
            }.listRowBackground(ClubStyle.card)
            Section {
                Text("subscription_renewal_notice").font(.footnote)
                LegalLinks()
                Link("subscription_refund",destination:URL(string:"https://reportaproblem.apple.com/")!)
            }.foregroundStyle(ClubStyle.muted)
        }.clubScreen().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar)
            .task { await load() }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            options = try JSONDecoder().decode(SubscriptionOptions.self,from:await model.accountRequest("subscription",team:team.id))
            products = try await Product.products(for:options?.products.map(\.id) ?? []).filter { $0.type == .autoRenewable }.sorted { $0.price < $1.price }
        } catch { message = "subscription_failed"; options = SubscriptionOptions(available:false,products:[],token:nil,canPurchase:false) }
    }
    private func purchase(_ product: Product) {
        guard let token = options?.token, options?.canPurchase == true else { return }
        busy = true; message = nil
        Task { defer { busy = false }; do {
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result, options?.products.contains(where:{$0.id == transaction.productID}) == true {
                    message = transaction.appAccountToken == token ? "subscription_existing" : "subscription_other_team"; return
                }
            }
            switch try await product.purchase(options:[.appAccountToken(token)]) {
            case .success(let result):
                try await model.confirmPurchase(result,team:team.id)
                model.pendingStoreProduct = nil
                message = "subscription_confirmed"; await load()
            case .pending: message = "subscription_pending"
            case .userCancelled: break
            @unknown default: message = "subscription_failed"
            }
        } catch { message = "subscription_verify_failed" } }
    }
    private func restore() {
        busy = true; message = nil
        Task { defer { busy = false }; do {
            try await AppStore.sync()
            var restored = false
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result, transaction.appAccountToken == options?.token {
                    try await model.confirmPurchase(result,team:team.id); restored = true
                }
            }
            message = restored ? "subscription_confirmed" : "subscription_no_purchase"
            await load()
        } catch { message = "subscription_verify_failed" } }
    }
}

// Never open the global Apple subscription list: it may show unrelated sandbox apps.
struct YourDartClubSubscriptionManagement: View {
    var groupID: String? = nil
    @State private var historicalGroupID: String?
    @State private var manage = false
    var body: some View {
        Group {
            if let id = groupID ?? historicalGroupID {
                Button("subscription_manage") { manage = true }
                    .manageSubscriptionsSheet(isPresented:$manage,subscriptionGroupID:id)
            }
        }.task {
            guard groupID == nil else { return }
            for await result in Transaction.all {
                if case .verified(let transaction) = result,
                   transaction.appBundleID == "com.yourdartclub.iphone",
                   transaction.productType == .autoRenewable,
                   let id = transaction.subscriptionGroupID {
                    historicalGroupID = id
                    break
                }
            }
        }
    }
}
