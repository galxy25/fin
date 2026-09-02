import Foundation
import StoreKit
import SwiftUI
#if os(visionOS)
import UIKit
#endif

@MainActor
final class EntitlementStore: ObservableObject {
    static let yearlyProductID = "dev.levischoen.fin.pro.yearly"
    static let lifetimeProductID = "dev.levischoen.fin.pro.lifetime"

    private static let trialDuration: TimeInterval = 14 * 24 * 60 * 60

    @Published private(set) var products: [Product] = []
    @Published private(set) var isSubscribed = false
    @Published private(set) var ownsLifetime = false
    @Published var purchaseErrorMessage: String?

    @AppStorage("trialStartedAt") private var trialStartedAtRaw: Double = 0

    private var transactionUpdatesTask: Task<Void, Never>?

    init() {
        if trialStartedAtRaw == 0 {
            trialStartedAtRaw = Date().timeIntervalSince1970
        }
        transactionUpdatesTask = Task { [weak self] in
            await self?.observeTransactionUpdates()
        }
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshEntitlements()
        }
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    var isTrialActive: Bool {
        Date().timeIntervalSince1970 - trialStartedAtRaw < Self.trialDuration
    }

    var trialDaysRemaining: Int {
        let remaining = Self.trialDuration - (Date().timeIntervalSince1970 - trialStartedAtRaw)
        guard remaining > 0 else { return 0 }
        return Int((remaining / (24 * 60 * 60)).rounded(.up))
    }

    var isUnlocked: Bool {
        isSubscribed || ownsLifetime || isTrialActive
    }

    var yearlyProduct: Product? { products.first(where: { $0.id == Self.yearlyProductID }) }
    var lifetimeProduct: Product? { products.first(where: { $0.id == Self.lifetimeProductID }) }

    func loadProducts() async {
        do {
            products = try await Product.products(for: [Self.yearlyProductID, Self.lifetimeProductID])
        } catch {
            purchaseErrorMessage = error.localizedDescription
        }
    }

    func purchase(_ product: Product) async {
        do {
            // visionOS has no sceneless purchase(); StoreKit needs a scene to anchor
            // the confirmation sheet in space.
            #if os(visionOS)
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first else {
                purchaseErrorMessage = "No active scene available for purchase."
                return
            }
            let result = try await product.purchase(confirmIn: scene)
            #else
            let result = try await product.purchase()
            #endif
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlements()
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseErrorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            purchaseErrorMessage = error.localizedDescription
        }
    }

    private func observeTransactionUpdates() async {
        for await update in Transaction.updates {
            if case .verified(let transaction) = update {
                await transaction.finish()
            }
            await refreshEntitlements()
        }
    }

    private func refreshEntitlements() async {
        var subscribed = false
        var lifetime = false
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            if transaction.productID == Self.yearlyProductID {
                subscribed = transaction.revocationDate == nil
            } else if transaction.productID == Self.lifetimeProductID {
                lifetime = transaction.revocationDate == nil
            }
        }
        isSubscribed = subscribed
        ownsLifetime = lifetime
    }
}
