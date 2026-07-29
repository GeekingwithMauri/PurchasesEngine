import Foundation
import RevenueCat
import PurchasesEngineCore

/// The only file that touches the RevenueCat SDK.
public final class RevenueCatGateway: SubscriptionGateway, @unchecked Sendable {
    private let lock = NSLock()
    private let entitlementID: String
    private let productOrder: [String]
    private var current: Entitlement = .free
    private var continuations: [UUID: AsyncStream<Entitlement>.Continuation] = [:]
    private var packagesByProduct: [String: Package] = [:]

    /// - Parameters:
    ///   - apiKey: the app's public RevenueCat SDK key.
    ///   - entitlementID: the RevenueCat entitlement that means "premium" for this app.
    ///   - productOrder: store product identifiers in the app's sell order —
    ///     `products()` returns them in this order, never alphabetical.
    ///   - amplitudeDeviceId: reserved attribution key per RevenueCat's Amplitude
    ///     integration docs (verified 2026-07-18) — lets revenue events correlate
    ///     with the anonymous Amplitude device.
    public init(
        apiKey: String,
        entitlementID: String,
        productOrder: [String],
        amplitudeDeviceId: String? = nil
    ) {
        self.entitlementID = entitlementID
        self.productOrder = productOrder
        Purchases.configure(withAPIKey: apiKey)
        if let amplitudeDeviceId {
            Purchases.shared.attribution.setAttributes(["$amplitudeDeviceId": amplitudeDeviceId])
        }
        // Seed from the cached CustomerInfo first. customerInfoStream only emits on
        // a network-driven fetch, which never lands in airplane mode — so without
        // this, an offline cold launch leaves `current` stuck at .free and premium
        // reads as free until the device is back online. customerInfo() returns the
        // cached value offline (no network required).
        Task { [weak self] in
            if let info = try? await Purchases.shared.customerInfo() {
                self?.update(from: info)
            }
        }
        Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                self?.update(from: info)
            }
        }
    }

    public var entitlement: Entitlement {
        lock.withLock { current }
    }

    public var entitlementUpdates: AsyncStream<Entitlement> {
        AsyncStream { continuation in
            let id = UUID()
            // Replay current on subscribe, under the lock, so a subscriber can't miss
            // an update that lands between reading `entitlement` and registering here.
            // Offline this matters: customerInfoStream emits the cached entitlement
            // exactly once at launch, and nothing re-emits without a network refresh —
            // miss it and premium silently reads as free (airplane-mode relaunch bug).
            lock.withLock {
                continuation.yield(current)
                continuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func products() async throws -> [SubscriptionProduct] {
        guard let offering = try await Purchases.shared.offerings().current else {
            throw SubscriptionError.unavailable
        }
        var products: [SubscriptionProduct] = []
        for package in offering.availablePackages {
            let id = package.storeProduct.productIdentifier
            lock.withLock { packagesByProduct[id] = package }
            products.append(SubscriptionProduct(
                id: id,
                displayPrice: package.storeProduct.localizedPriceString,
                pricePerMonth: package.storeProduct.localizedPricePerMonth
            ))
        }
        guard !products.isEmpty else { throw SubscriptionError.unavailable }
        return products.sorted(byIDOrder: productOrder)
    }

    public func purchase(_ product: SubscriptionProduct) async throws {
        guard let package = lock.withLock({ packagesByProduct[product.id] }) else {
            throw SubscriptionError.unavailable
        }
        let result = try await Purchases.shared.purchase(package: package)
        if result.userCancelled { throw SubscriptionError.purchaseCancelled }
        update(from: result.customerInfo)
    }

    public func restore() async throws {
        update(from: try await Purchases.shared.restorePurchases())
    }

    private func update(from info: CustomerInfo) {
        let entitlement: Entitlement
        if let active = info.entitlements[entitlementID], active.isActive {
            entitlement = .premium(expiry: active.expirationDate)
        } else {
            entitlement = .free
        }
        let listeners = lock.withLock {
            current = entitlement
            return Array(continuations.values)
        }
        for continuation in listeners {
            continuation.yield(entitlement)
        }
    }
}
