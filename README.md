# PurchasesEngine

In-app purchases behind a protocol, RevenueCat behind one file.

Battle-tested through a full App Store submission cycle: the architecture survived
three App Review rejections, sandbox testing on device, TestFlight, and a
server-side entitlement integration without a rewrite.

## Why

Payment SDKs leak. One direct `import RevenueCat` in a view model and suddenly the
test suite needs a network, a simulator, and thirty seconds of dyld time. This
package keeps the SDK in a separate library product so your logic — and your
tests — never touch it:

| Product | Depends on | Holds |
|---|---|---|
| `PurchasesEngineCore` | **nothing** | `SubscriptionGateway` protocol, `Entitlement`, `SubscriptionProduct`, `FakeSubscriptionGateway`, `BuildEnvironment` |
| `PurchasesEngine` | Core + RevenueCat SDK | `RevenueCatGateway` — the only file importing RevenueCat |

`dependencies: []` on Core is the load-bearing invariant. Link only
`PurchasesEngineCore` into logic packages and **test hosts**, and `swift test`
stays offline, SDK-free and sub-second. The `PurchasesEngine` product is for the
app target's composition root alone — linking it into a test host silently
reintroduces the startup cost this split exists to avoid.

## Installation

Swift Package Manager, iOS 18+ / macOS 15+ (macOS is there so `swift test` runs
natively, no simulator):

```swift
dependencies: [
    .package(url: "https://github.com/mchirino89/PurchasesEngine", from: "1.0.0")
]
```

Then link the right product to the right place:

- App target → `PurchasesEngine`
- Logic packages, test targets, test hosts → `PurchasesEngineCore`

## Usage

### 1. The app owns its identity

The package speaks `String` product IDs at the boundary (see below for why).
Keep your own enum and map at the edge:

```swift
enum ProductID: String, CaseIterable {
    case monthly = "myapp.premium.monthly"
    case yearly = "myapp.premium.yearly"
    case lifetime = "myapp.premium.forever"

    /// The paywall ladder: cheapest first, never alphabetical.
    static let paywallOrder: [ProductID] = [.monthly, .yearly, .lifetime]
}

extension SubscriptionProduct {
    /// Recover the enum at the edge; nil for a product this app doesn't know.
    var productID: ProductID? { ProductID(rawValue: id) }
}
```

### 2. Wire the real gateway in the composition root

```swift
import PurchasesEngine // the ONLY file importing this product

let gateway: any SubscriptionGateway = RevenueCatGateway(
    apiKey: secrets.revenueCatPublicKey,
    entitlementID: "premium",
    productOrder: ProductID.paywallOrder.map(\.rawValue),
    amplitudeDeviceId: analytics.deviceId // optional, correlates revenue with usage
)
```

The gateway seeds from RevenueCat's cached `CustomerInfo` and **replays the
current entitlement to every new stream subscriber**. Both behaviours are
load-bearing offline: RevenueCat emits the cached entitlement exactly once at
launch, and a subscriber that attaches late — or a cold launch in airplane
mode — must not read premium as free. Don't "simplify" the stream to
future-only; that bug only shows up offline.

### 3. Everything else sees the protocol

```swift
struct PaywallModel {
    let gateway: any SubscriptionGateway

    func load() async throws -> [SubscriptionProduct] {
        // Store-formatted prices, in YOUR order (unknown products are yours to filter):
        try await gateway.products().filter { $0.productID != nil }
    }

    func buy(_ product: SubscriptionProduct) async throws {
        try await gateway.purchase(product) // throws .purchaseCancelled on user backout
    }
}

// Gating:
if gateway.entitlement.isPremium { unlockEverything() }

// Reacting:
for await entitlement in gateway.entitlementUpdates {
    updateUI(premium: entitlement.isPremium)
}
```

`SubscriptionProduct.showsMonthlyEquivalent` tells you when a "just $1.67 a
month" caption adds information (yearly) versus repeats the button (monthly) —
computed from the store's own formatted strings, no currency parsing.

### 4. Tests, previews and UI tests run on the fake

```swift
let fake = FakeSubscriptionGateway(
    entitlement: .free,
    products: [
        SubscriptionProduct(id: "myapp.premium.monthly", displayPrice: "$2.99", pricePerMonth: "$2.99"),
        SubscriptionProduct(id: "myapp.premium.yearly", displayPrice: "$19.99", pricePerMonth: "$1.67"),
        SubscriptionProduct(id: "myapp.premium.forever", displayPrice: "$29.99"),
    ]
)

try await fake.purchase(products[0]) // instantly premium, stream notified
fake.set(.premium(expiry: nil))      // test hook — also handy for UI-test launch args
```

The catalog is a required parameter on purpose: previews and UI tests should see
the app's real sell order, and an empty paywall should be an explicit choice.

### 5. Route prod-facing SDKs through `BuildEnvironment`

```swift
Analytics.start(key: BuildEnvironment.isRealAppStoreInstall ? prodKey : devKey)
crashReporter.environment = BuildEnvironment.name // "production" | "sandbox"
```

Build configuration cannot answer "is this a real user": **TestFlight is a
Release build**, so `#if DEBUG` splits treat every beta tester as production.
The App Store receipt filename is the only reliable signal (`receipt` for a real
download; simulator, dev, ad-hoc and TestFlight all carry `sandboxReceipt`), and
the unknown case deliberately lands in sandbox — a wrong guess must never
pollute production data.

## Why `SubscriptionProduct.id` is a `String`

You will want to change this back. Don't.

Apps should keep "identities are enums, never strings" — but that rule cannot
cross the package boundary, because the package cannot know each app's products.
An `associatedtype` would keep the enum and cost the existential:
`any SubscriptionGateway` becomes impossible, and the existential is exactly
what composition roots and previews need.

So the package speaks `String` at the boundary, and each app maps to its own
enum immediately at the edge — the same way system singletons get wrapped once
at the edge. The app keeps its enum and its rule; the package stays reusable.
