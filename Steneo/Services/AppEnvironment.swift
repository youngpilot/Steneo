import Foundation

/// Facts about how this process was started.
enum AppEnvironment {
    /// True when the app is merely the host process of the unit tests.
    ///
    /// The test host is the whole app, launched on the developer's own Mac while
    /// they are working. It must not grab the global shortcut or play a sound —
    /// a second Steneo answering F5 next to the installed one is precisely the
    /// kind of interference a test run may never cause.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
