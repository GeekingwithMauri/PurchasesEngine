import Foundation

/// Which world this build runs in, decided the only way that holds across every
/// install path: the name of the App Store receipt.
///
/// Build config cannot answer this. TestFlight and an on-device Release scheme are
/// both Release, so a `#if DEBUG` split calls them production — that exact mistake
/// sent a week of TestFlight sessions to a prod analytics project (2026-07-22).
///
/// Every path, and where it lands:
///   simulator / Xcode dev build     -> sandbox (DEBUG; carries no `receipt` either)
///   Release scheme on device        -> sandbox (`sandboxReceipt`)
///   TestFlight                      -> sandbox (`sandboxReceipt`)
///   App Store download              -> production (`receipt`)
///
/// Route every prod-facing SDK through this one property — analytics project,
/// crash-reporter environment, ad unit IDs.
public enum BuildEnvironment {
    /// True only for a real App Store download. A missing receipt URL counts as
    /// sandbox: a wrong guess must land in dev, never pollute production.
    public static var isRealAppStoreInstall: Bool {
        #if DEBUG
        false
        #else
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "receipt"
        #endif
    }

    /// The crash reporter's `environment` tag. Without it every beta crash lands
    /// in the same issue stream as real users', indistinguishable.
    public static var name: String { isRealAppStoreInstall ? "production" : "sandbox" }
}
