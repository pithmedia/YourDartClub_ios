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
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var model: AppModel
    let team: Team
    @State private var options: SubscriptionOptions?
    @State private var products: [Product] = []
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                VStack(alignment:.leading,spacing:12) {
                    Label(team.name,systemImage:"person.3.fill").font(.headline).foregroundStyle(ClubStyle.lime)
                    Text("subscription_heading").font(.title2.bold())
                    Text("subscription_notice").font(.subheadline).foregroundStyle(ClubStyle.muted)
                    Label("subscription_events",systemImage:"trophy").font(.subheadline)
                    Label("subscription_live",systemImage:"tv").font(.subheadline)
                    Label("subscription_stats",systemImage:"chart.bar").font(.subheadline)
                }.frame(maxWidth:.infinity,alignment:.leading).clubCard()
                if let message { Text(LocalizedStringKey(message)).foregroundStyle(ClubStyle.lime) }
                if let options {
                    if !options.available { Text("subscription_unavailable") }
                    else if !options.canPurchase { Text("subscription_existing") }
                    else {
                        ForEach(products) { product in priceCard(product) }
                        if products.isEmpty { Text("subscription_unavailable") }
                        if products.contains(where: { $0.priceFormatStyle.currencyCode != "EUR" }) {
                            Text("subscription_currency_notice").font(.footnote).foregroundStyle(ClubStyle.muted)
                        }
                    }
                } else { ProgressView().frame(maxWidth:.infinity) }
                VStack(alignment:.leading,spacing:16) {
                    Button("subscription_restore") { restore() }.disabled(busy || options?.available != true)
                    YourDartClubSubscriptionManagement(groupID:products.first?.subscription?.subscriptionGroupID).disabled(busy)
                    Button("subscription_reload") { Task { await load() } }.disabled(busy)
                }.frame(maxWidth:.infinity,alignment:.leading).clubCard()
                VStack(alignment:.leading,spacing:12) {
                    Text("subscription_binding_notice")
                    Text("subscription_renewal_notice")
                    LegalLinks()
                    Link("subscription_refund",destination:URL(string:"https://reportaproblem.apple.com/")!)
                }.font(.footnote).foregroundStyle(ClubStyle.muted)
            }.padding(20).frame(maxWidth:620).frame(maxWidth:.infinity)
        }.background(ClubStyle.background).tint(ClubStyle.lime)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar)
            .task { await load() }
            .task {
                for await _ in Storefront.updates {
                    if !busy { await load() }
                }
            }
            .onChange(of:scenePhase) { _, phase in
                if phase == .active && !busy { Task { await load() } }
            }
    }
    private func priceCard(_ product: Product) -> some View {
        let yearly = options?.products.first { $0.id == product.id }?.period == "yearly"
        let monthly = products.first { item in options?.products.first { $0.id == item.id }?.period == "monthly" }
        let saving: Decimal? = yearly && monthly?.priceFormatStyle.currencyCode == product.priceFormatStyle.currencyCode
            ? monthly.map { $0.price * 12 - product.price } : nil
        return VStack(alignment:.leading,spacing:16) {
            if let saving, saving > 0 {
                Text(textFormat("subscription_save_year",saving.formatted(product.priceFormatStyle)))
                    .font(.subheadline.bold()).foregroundStyle(ClubStyle.ink)
                    .padding(.horizontal,12).padding(.vertical,8)
                    .background(ClubStyle.lime,in:Capsule())
            }
            Text(LocalizedStringKey(yearly ? "subscription_yearly" : "subscription_monthly"))
                .font(.headline).foregroundStyle(yearly ? ClubStyle.lime : ClubStyle.text)
            ViewThatFits(in:.horizontal) {
                HStack(alignment:.firstTextBaseline,spacing:8) { priceLabel(product); periodLabel(yearly) }
                VStack(alignment:.leading,spacing:4) { priceLabel(product); periodLabel(yearly) }
            }
            if yearly {
                Text(textFormat("subscription_month_equivalent",(product.price / 12).formatted(product.priceFormatStyle)))
                    .font(.subheadline).foregroundStyle(ClubStyle.muted)
            }
            Text("subscription_team_limit").font(.subheadline).foregroundStyle(ClubStyle.muted)
            Button { purchase(product) } label: {
                Label(yearly ? "subscription_choose_year" : "subscription_choose_month",systemImage:"checkmark.circle")
            }.buttonStyle(ClubButton(primary:yearly)).disabled(busy)
            if model.pendingStoreProduct?.id == product.id { Text("subscription_store_selected").font(.caption) }
        }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
            .background(yearly ? ClubStyle.elevated : ClubStyle.card,in:RoundedRectangle(cornerRadius:24))
            .overlay(RoundedRectangle(cornerRadius:24).stroke(yearly ? ClubStyle.lime : ClubStyle.border,lineWidth:1))
    }
    private func priceLabel(_ product: Product) -> some View {
        Text(product.displayPrice).font(ClubStyle.numberFont(40)).foregroundStyle(ClubStyle.text)
    }
    private func periodLabel(_ yearly: Bool) -> some View {
        Text(LocalizedStringKey(yearly ? "subscription_per_year" : "subscription_per_month"))
            .font(.subheadline).foregroundStyle(ClubStyle.muted)
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
