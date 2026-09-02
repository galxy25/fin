import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @State private var isPurchasing = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Your Fin trial has ended")
                    .font(.title2.bold())
                Text("Subscribe or buy lifetime access to keep connecting to your servers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: 12) {
                if let yearly = entitlementStore.yearlyProduct {
                    purchaseButton(title: "Subscribe", subtitle: "\(yearly.displayPrice) / year", product: yearly)
                }
                if let lifetime = entitlementStore.lifetimeProduct {
                    purchaseButton(title: "Buy Lifetime", subtitle: "\(lifetime.displayPrice) once", product: lifetime)
                }
                if entitlementStore.yearlyProduct == nil && entitlementStore.lifetimeProduct == nil {
                    ProgressView()
                }
            }
            .padding(.horizontal)

            subscriptionDisclosure

            Button("Restore Purchases") {
                Task {
                    isPurchasing = true
                    await entitlementStore.restorePurchases()
                    isPurchasing = false
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let message = entitlementStore.purchaseErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
        .disabled(isPurchasing)
        .task {
            if entitlementStore.products.isEmpty {
                await entitlementStore.loadProducts()
            }
        }
    }

    /// Guideline 3.1.2 requires the purchase flow itself to state what is being sold, its
    /// length and price, and to link the Terms of Use (EULA) and Privacy Policy — not just
    /// the App Store listing. Rendered from the live `Product` values so the price shown
    /// is always the one the user will actually be charged in their storefront.
    private var subscriptionDisclosure: some View {
        VStack(spacing: 8) {
            if let yearly = entitlementStore.yearlyProduct {
                Text("Fin Pro Annual — \(yearly.displayPrice) per year, billed to your Apple "
                    + "Account. Renews automatically unless canceled at least 24 hours before "
                    + "the end of the current period. Manage or cancel in your Apple Account "
                    + "settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let lifetime = entitlementStore.lifetimeProduct {
                Text("Fin Pro Lifetime — \(lifetime.displayPrice), a one-time purchase that "
                    + "does not renew.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 14) {
                Link("Terms of Use", destination: Self.termsURL)
                Link("Privacy Policy", destination: Self.privacyURL)
            }
            .font(.caption2)
        }
        .padding(.horizontal)
    }

    private static let termsURL = URL(string: "https://fin.africanintellect.ai/terms")!
    private static let privacyURL = URL(string: "https://fin.africanintellect.ai/privacy")!

    @ViewBuilder
    private func purchaseButton(title: String, subtitle: String, product: Product) -> some View {
        Button {
            isPurchasing = true
            Task {
                await entitlementStore.purchase(product)
                isPurchasing = false
            }
        } label: {
            VStack(spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).opacity(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
