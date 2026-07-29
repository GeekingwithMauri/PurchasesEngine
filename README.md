# PurchasesEngine

Payments behind a protocol, RevenueCat behind one file. Extracted from Breath after
its first full submission cycle; the history and pitfall catalogue live in Breath's
`docs/plans/2026-07-29-ios-payments-runbook.md`.

| Product | Depends on | Holds |
|---|---|---|
| `PurchasesEngineCore` | **nothing** | `SubscriptionGateway` protocol, `Entitlement`, `SubscriptionProduct`, `FakeSubscriptionGateway`, `BuildEnvironment` |
| `PurchasesEngine` | Core + RevenueCat SDK | `RevenueCatGateway` — the only file importing RevenueCat |

`dependencies: []` on Core is the load-bearing invariant: link only
`PurchasesEngineCore` into logic packages and test hosts, and their tests never
load an SDK. The `PurchasesEngine` product is for the app target's composition
root alone.

## Why `SubscriptionProduct.id` is a `String`

You will want to change this back. Don't.

The consuming apps keep the rule "identities are enums, never strings" — but that
rule cannot cross the package boundary, because the package cannot know each app's
products. An `associatedtype` would keep the enum and cost the existential:
`any SubscriptionGateway` becomes impossible, and that existential is used
throughout the apps' composition roots.

So the package speaks `String` at the boundary, and each app maps to its own enum
immediately at the edge (`ProductID(rawValue:)` on receipt) — exactly as system
singletons are wrapped once at the edge. The app keeps its enum and its rule; the
package stays reusable.

## Wiring

```swift
// Composition root — the app supplies identity, order and secrets:
RevenueCatGateway(
    apiKey: secrets.revenueCatKey,
    entitlementID: "premium",
    productOrder: ProductID.paywallOrder.map(\.rawValue)
)

// Tests, previews, UI-test worlds:
FakeSubscriptionGateway(entitlement: .free, products: myCatalog)
```

`BuildEnvironment.isRealAppStoreInstall` is the receipt-name rule (§3.5 of the
runbook): route every prod-facing SDK through it — analytics project, crash
reporter environment, ad units. TestFlight is Release; `#if DEBUG` cannot tell a
beta tester from a customer.
