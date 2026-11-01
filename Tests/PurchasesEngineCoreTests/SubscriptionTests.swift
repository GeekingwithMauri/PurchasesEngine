import Testing
import Foundation
@testable import PurchasesEngineCore

private let catalog = [
    SubscriptionProduct(
        id: "app.premium.monthly",
        displayPrice: "$2.99",
        pricePerMonth: "$2.99"
    ),
    SubscriptionProduct(
        id: "app.premium.yearly",
        displayPrice: "$19.99",
        pricePerMonth: "$1.67"
    ),
    SubscriptionProduct(
        id: "app.premium.forever",
        displayPrice: "$29.99"
    )
]

@Suite struct SellOrderTests {
    /// The bug this pins: a gateway once sorted by `rawValue`, and "…forever" wins
    /// that alphabetically — the most expensive plan anchored the paywall. The
    /// order is the app's, never a string sort.
    @Test func sortsByTheSuppliedOrderNotAlphabetically() {
        let order = ["app.premium.monthly", "app.premium.yearly", "app.premium.forever"]
        let shuffled = [catalog[2], catalog[0], catalog[1]]
        #expect(shuffled.sorted(byIDOrder: order).map(\.id) == order)
    }

    /// A product the order forgot must sink to the end, not disappear or crash.
    @Test func unlistedProductsSinkToTheEnd() {
        let sorted = catalog.sorted(byIDOrder: ["app.premium.yearly"])
        #expect(sorted.first?.id == "app.premium.yearly")
        #expect(sorted.count == catalog.count)
    }
}

@Suite struct MonthlyEquivalentTests {
    /// The caption exists to reframe a big number as a small one. Under the monthly
    /// plan it would just restate the button, so it stays hidden.
    @Test func monthlyDoesNotRepeatItself() {
        #expect(!catalog[0].showsMonthlyEquivalent)
    }

    @Test func yearlyShowsWhatItWorksOutTo() {
        #expect(catalog[1].showsMonthlyEquivalent)
    }

    /// A non-consumable has no subscription period, so the store returns nil for
    /// the per-month price. Nothing to divide, nothing to show.
    @Test func lifetimeHasNoMonthlyEquivalent() {
        #expect(catalog[2].pricePerMonth == nil)
        #expect(!catalog[2].showsMonthlyEquivalent)
    }

    /// Storefronts where the yearly plan isn't actually cheaper per month must not
    /// advertise a saving that doesn't exist — the equality check covers it without
    /// any currency parsing.
    @Test func identicalPricesStaySilent() {
        let oddStorefront = SubscriptionProduct(
            id: "app.premium.yearly",
            displayPrice: "¥3000",
            pricePerMonth: "¥3000"
        )
        #expect(!oddStorefront.showsMonthlyEquivalent)
    }
}

@Suite struct FakeSubscriptionGatewayTests {
    @Test func purchaseFlipsEntitlementAndNotifies() async throws {
        let gateway = FakeSubscriptionGateway(
            entitlement: .free,
            products: catalog
        )
        #expect(gateway.entitlement == .free)

        let updates = gateway.entitlementUpdates
        let product = try await gateway.products().first!
        try await gateway.purchase(product)

        #expect(gateway.entitlement.isPremium)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .free)            // replayed state at subscribe
        #expect(await iterator.next()?.isPremium == true)  // the purchase notification
    }

    /// A subscriber that arrives after the entitlement is already set still receives
    /// it — the fix for premium reading as free offline (RevenueCatGateway emits the
    /// cached entitlement once at launch; a late subscriber must not miss it).
    @Test func subscribingReplaysCurrentState() async {
        let gateway = FakeSubscriptionGateway(
            entitlement: .premium(expiry: nil),
            products: catalog
        )
        var iterator = gateway.entitlementUpdates.makeAsyncIterator()
        #expect(await iterator.next()?.isPremium == true)
    }

    /// The fake serves the app's catalog verbatim, in the order it was given —
    /// previews and UI tests see the real sell order.
    @Test func servesTheSuppliedCatalogInOrder() async throws {
        let gateway = FakeSubscriptionGateway(
            entitlement: .free,
            products: catalog
        )
        #expect(try await gateway.products().map(\.id) == catalog.map(\.id))
    }

    /// Restore is a no-op success — it must never throw, or the fake would make
    /// the paywall's restore path look broken in previews.
    @Test func restoreSucceedsQuietly() async throws {
        let gateway = FakeSubscriptionGateway(
            entitlement: .free,
            products: catalog
        )
        try await gateway.restore()
        #expect(gateway.entitlement == .free)
    }
}

/// Implements only the required members, each flipping a flag, so a default that
/// quietly routes into one of them is caught.
private final class BareGateway: SubscriptionGateway, @unchecked Sendable {
    var touchedRequiredMember = false
    var entitlement: Entitlement { touchedRequiredMember = true; return .free }
    var entitlementUpdates: AsyncStream<Entitlement> {
        touchedRequiredMember = true
        return AsyncStream { $0.finish() }
    }
    func products() async throws -> [SubscriptionProduct] { touchedRequiredMember = true; return [] }
    func purchase(_ product: SubscriptionProduct) async throws { touchedRequiredMember = true }
    func restore() async throws { touchedRequiredMember = true }
}

@Suite struct DefaultImplementationTests {
    @Test func identifyDefaultCompletesWithoutTouchingRequiredMembers() async throws {
        let gateway = BareGateway()
        try await gateway.identify("user-1")
        #expect(!gateway.touchedRequiredMember)
    }

    @Test func oneTimeProductsDefaultIsEmptyWithoutTouchingRequiredMembers() async throws {
        let gateway = BareGateway()
        #expect(try await gateway.purchasedOneTimeProductIDs() == [])
        #expect(!gateway.touchedRequiredMember)
    }
}
