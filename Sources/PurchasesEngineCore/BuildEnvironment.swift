import Foundation

/// Which world this build runs in, decided the only way that holds across every
/// install path: the name of the App Store receipt.
///
/// Build config cannot answer this. TestFlight and an on-device Release scheme are
/// both Release, so a `#if DEBUG` split calls them production — that exact mistake
/// sent a week of TestFlight sessions to a prod analytics project (2026-07-22).
///
/// Every path, and where it lands:
///   simulator (any configuration)   -> sandbox (guarded explicitly, see below)
///   Xcode dev build on device       -> sandbox (DEBUG)
///   Release scheme on device        -> sandbox (`sandboxReceipt`)
///   TestFlight                      -> sandbox (`sandboxReceipt`)
///   App Store download              -> production (`receipt`)
///
/// Route every prod-facing SDK through this one property — analytics project,
/// crash-reporter environment, ad unit IDs.
public enum BuildEnvironment {
    /// True only for a real App Store download. A missing receipt URL counts as
    /// sandbox: a wrong guess must land in dev, never pollute production.
    ///
    /// The simulator needs its own guard, not just DEBUG: a Release scheme run in
    /// the simulator has a receipt URL ending in plain `receipt` (only physical
    /// devices get `sandboxReceipt`), so the receipt rule alone calls it a real
    /// App Store install. That routed a Release-scheme simulator session to the
    /// prod analytics project and read prod feature flags (found 2026-08-01) —
    /// and no simulator can ever be a store install by definition.
    public static var isRealAppStoreInstall: Bool {
        #if DEBUG || targetEnvironment(simulator)
        false
        #else
        receiptURL?.lastPathComponent == "receipt"
        #endif
    }

    /// `Bundle.appStoreReceiptURL` through Key-Value Coding: the Swift symbol is
    /// deprecated since iOS 18 for StoreKit 2's `AppTransaction`, which is `async`,
    /// and this answer is needed synchronously at launch. Same getter, same value,
    /// no deprecation warning in consumers that build with warnings as errors.
    // ponytail: KVC bridge over a deprecated getter, replaced by a StoreKit 2 migration
    static var receiptURL: URL? { Bundle.main.value(forKey: "appStoreReceiptURL") as? URL }

    /// The crash reporter's `environment` tag. Without it every beta crash lands
    /// in the same issue stream as real users', indistinguishable.
    public static var name: String { isRealAppStoreInstall ? "production" : "sandbox" }
}
