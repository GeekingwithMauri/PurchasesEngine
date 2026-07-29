import Foundation

public enum Entitlement: Equatable, Sendable {
    case free
    case premium(expiry: Date?)

    public var isPremium: Bool {
        if case .premium = self { return true }
        return false
    }
}

/// A purchasable plan as the store describes it.
///
/// `id` is a `String` on purpose. The consuming apps keep "identities are enums,
/// never strings" — but that rule cannot cross the package boundary, because the
/// package cannot know each app's products. So the package speaks `String` and
/// each app maps to its own enum immediately at the edge (see the README).
public struct SubscriptionProduct: Equatable, Sendable, Identifiable {
    /// The store product identifier, verbatim.
    public let id: String
    /// Localized, store-formatted price, e.g. "$1.00".
    public let displayPrice: String
    /// The same price expressed per month, straight from the store's own formatter
    /// so the currency and separators are right in every storefront — never
    /// computed here, and never a hardcoded "$1.67".
    ///
    /// nil for one-time products, which have no subscription period to divide.
    public let pricePerMonth: String?

    public init(
        id: String,
        displayPrice: String,
        pricePerMonth: String? = nil
    ) {
        self.id = id
        self.displayPrice = displayPrice
        self.pricePerMonth = pricePerMonth
    }

    /// Whether a "works out to X a month" caption tells the reader anything new.
    /// False for a monthly plan, where it would just repeat the button.
    public var showsMonthlyEquivalent: Bool {
        guard let pricePerMonth else { return false }
        return pricePerMonth != displayPrice
    }
}

public extension Array where Element == SubscriptionProduct {
    /// Sell order, supplied by the app — never alphabetical. Sorting by any string
    /// property silently anchors the paywall on whatever wins lexicographically
    /// ("…forever" beats "…monthly", so the priciest plan leads). Products the
    /// order doesn't mention sink to the end instead of disappearing.
    func sorted(byIDOrder order: [String]) -> [SubscriptionProduct] {
        sorted {
            (order.firstIndex(of: $0.id) ?? order.count)
                < (order.firstIndex(of: $1.id) ?? order.count)
        }
    }
}

public enum SubscriptionError: Error, Equatable {
    case purchaseCancelled
    case unavailable
}

/// Facade over the payment provider (RevenueCat in production). The rest of the
/// app — paywall, feature gating, rewards — sees only this.
public protocol SubscriptionGateway: Sendable {
    var entitlement: Entitlement { get }
    var entitlementUpdates: AsyncStream<Entitlement> { get }
    func products() async throws -> [SubscriptionProduct]
    func purchase(_ product: SubscriptionProduct) async throws
    func restore() async throws
}

/// Tests, previews and UI-test runs. Purchases succeed instantly.
public final class FakeSubscriptionGateway: SubscriptionGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Entitlement
    private let catalog: [SubscriptionProduct]
    private var continuations: [UUID: AsyncStream<Entitlement>.Continuation] = [:]

    /// `products` is the app's catalog in its real sell order, so previews and UI
    /// tests see exactly what the store would show. No default: an empty paywall
    /// should be an explicit choice, not a forgotten parameter.
    public init(
        entitlement: Entitlement,
        products: [SubscriptionProduct]
    ) {
        current = entitlement
        catalog = products
    }

    public var entitlement: Entitlement {
        lock.withLock { current }
    }

    public var entitlementUpdates: AsyncStream<Entitlement> {
        AsyncStream { continuation in
            let id = UUID()
            // Replay current on subscribe so a late subscriber can't miss the state —
            // matches RevenueCatGateway, whose real contract this stands in for.
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
        catalog
    }

    public func purchase(_ product: SubscriptionProduct) async throws {
        set(.premium(expiry: nil))
    }

    public func restore() async throws {}

    /// Test hook — also how UI-test launch arguments force an entitlement.
    public func set(_ entitlement: Entitlement) {
        let listeners = lock.withLock {
            current = entitlement
            return Array(continuations.values)
        }
        for continuation in listeners {
            continuation.yield(entitlement)
        }
    }
}
