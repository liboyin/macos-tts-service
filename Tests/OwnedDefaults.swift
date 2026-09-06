import Foundation
import XCTest
@testable import ClipboardTTSApp

/// `UserDefaults` storage that belongs to one test, backed by memory instead of a suite or domain.
///
/// WHY: the unit-test bundle is hosted inside the app, so `UserDefaults.standard` in a test *is*
/// the installed app's own defaults domain. A test that reads it inherits whatever the developer
/// configured, and a test that writes it reconfigures their app. A disk-backed
/// `UserDefaults(suiteName:)` is no better: `removePersistentDomain` empties a suite without
/// deleting it, and `cfprefsd` writes the suite's plist into `~/Library/Preferences` when the
/// hosted process exits. Memory owned by the test is the only storage with neither problem.
///
/// Overrides the three primitive accessors that `UserDefaults` derives its typed accessors from.
/// A path under test that needs an accessor built on something else must override it here too;
/// `testStartupRegressionSettingsStayInTheStorageTheTestOwns` and
/// `testOwnedSettingsStorageIsPrivateToItsOwnerAndIsNotTheAppDomain` share that responsibility: the
/// first reads its own seed back through the typed accessors, the second proves the aggregate view
/// holds only what its owner set.
///
/// The change notifications matter as much as the storage. `@AppStorage` observes its store through
/// KVO, and a subclass that replaces `set(_:forKey:)` without announcing the change leaves the
/// property reading a stale value: a hosted form would silently ignore every settings write made
/// from outside it, including the provider switch `HostedSettings.selectProvider` performs. A probe
/// on Xcode 26.6 (17F113) confirmed both halves — without these calls a hosted `@AppStorage` never
/// saw an external write, and with them it saw it on the next main-queue turn, matching a real
/// suite.
final class InMemoryDefaults: UserDefaults {
    /// Deliberately carries no default value.
    ///
    /// WHY: a stored property without one forces this class to declare its own designated
    /// initializer rather than inheriting `UserDefaults.init()`, which Foundation documents as
    /// `init(suiteName: nil)` — the default search list, headed in the hosted test process by the
    /// installed app's own domain. Deleting the initializer below then fails to compile instead of
    /// silently reconnecting that domain while every test and lint rule stays green.
    private var storage: [String: Any]

    /// Builds the superclass against a suite of this instance's own rather than the process's.
    ///
    /// WHY: `UserDefaults.init()` is documented as `init(suiteName: nil)`, which searches the
    /// default search list — headed, in the hosted test process, by the installed app's own domain.
    /// A unique suite moves anything the superclass would *write* somewhere private.
    ///
    /// That much is measured, on Xcode 26.6 (17F113): a value present only in the app's own domain
    /// was absent from a uniquely named suite through both keyed lookup and the aggregate view, and
    /// a value written through one instance's own domain was absent from another's. So the suite
    /// does exclude the installed app's settings from what this receiver resolves.
    ///
    /// What it does not exclude is the shared state reached some other way, which is what the
    /// members below are for: the aggregate view still spans global state — the same probe measured
    /// the inherited `dictionaryRepresentation()` returning 98 keys including `NSGlobalDomain`'s
    /// `AppleLanguages` — the registration and volatile domains are shared process-wide, a volatile
    /// domain set through one instance was readable through another, forced values come from
    /// machine configuration, and any member taking a domain *name* will answer for whichever
    /// domain it is handed, the app's own included. Anything not overridden below still resolves
    /// that way, which is why `Sources/` and `Tests/` are linted for the routes into it.
    ///
    /// Nothing is ever written through the suite either, because the accessors below keep every
    /// value in memory, so it materializes no file. No test asserts that by listing the developer's
    /// preferences directory: reading their state to prove it was left alone is the access this
    /// storage exists to remove, and an asynchronously written plist would defeat the check anyway.
    /// What is asserted instead is that owned storage reads back exactly what its owner set and
    /// nothing else — `testOwnedSettingsStorageIsPrivateToItsOwnerAndIsNotTheAppDomain`.
    init() {
        storage = [:]
        // The one superclass suite construction in the suite: a unique, non-optional name. Every
        // other spelling is refused, because `super.init(suiteName: someOptional)` reaches the
        // default search list — the installed app's own — without ever writing `nil`.
        // swiftlint:disable:next test_owned_settings_storage
        super.init(suiteName: "com.clipboardtts.owned-defaults.\(UUID().uuidString)")!
    }

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        willChangeValue(forKey: defaultName)
        storage[defaultName] = value
        didChangeValue(forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        willChangeValue(forKey: defaultName)
        storage.removeValue(forKey: defaultName)
        didChangeValue(forKey: defaultName)
    }

    /// Reports what this owner stored, rather than the process's whole search list.
    ///
    /// WHY: the inherited implementation answers from the whole search list the superclass was
    /// built against. The unique suite keeps the app's own domain out of that list, but not the
    /// global and shared state beside it: a probe on Xcode 26.6 (17F113) measured 98 keys there,
    /// including `NSGlobalDomain`'s `AppleLanguages`, and none of this owner's own values. Left
    /// inherited, it is simply the wrong answer about owned storage.
    override func dictionaryRepresentation() -> [String: Any] {
        storage
    }

    /// Does nothing, successfully: there is no persistent domain behind this storage to flush.
    ///
    /// WHY: the inherited implementation flushes the domain the superclass was initialized
    /// against. A test that reaches for it — as a startup regression did, to make "no preference
    /// file appeared" non-vacuous — would be asking the app's own defaults machinery to write.
    override func synchronize() -> Bool {
        true
    }

    /// Drops registration rather than applying it process-wide.
    ///
    /// WHY: the SDK documents registration as adding to the last item in *every* search list, so
    /// the inherited member is the one place where a value stated through owned storage becomes
    /// visible to every other owner. A probe confirmed a registration made through one unique
    /// suite was readable through another.
    override func register(defaults registrationDictionary: [String: Any]) {}

    /// Answers for this owner alone, because these members address a domain by *name*.
    ///
    /// WHY: an argument naming the installed app's bundle identifier would otherwise read, replace,
    /// or delete the developer's real settings through a receiver a test believes it owns — the
    /// exact loss this storage exists to prevent, reached by a different door. Suite mutation is
    /// refused for the same reason: it would put another domain back into this receiver's search
    /// list. Tests have no use for any of them; the lint rule over `Tests/` says so out loud.
    override func persistentDomain(forName domainName: String) -> [String: Any]? { nil }
    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {}
    override func removePersistentDomain(forName domainName: String) {}
    override func addSuite(named suiteName: String) {}
    override func removeSuite(named suiteName: String) {}

    /// Keeps the volatile domains to this owner, because Foundation shares them across the process.
    ///
    /// WHY: a probe confirmed a volatile domain set through one instance was readable through
    /// another, and that `NSRegistrationDomain` is listed among them — which is the route by which
    /// a registration made anywhere becomes visible everywhere. Owning these is what lets
    /// `testOwnedStorageRefusesToShareRegisteredOrVolatileValues` observe that at all.
    override var volatileDomainNames: [String] { [] }
    override func volatileDomain(forName domainName: String) -> [String: Any] { [:] }
    override func setVolatileDomain(_ domain: [String: Any], forName domainName: String) {}
    override func removeVolatileDomain(forName domainName: String) {}

    /// Reports nothing as managed, rather than consulting the machine's configuration profiles.
    override func objectIsForced(forKey key: String) -> Bool { false }
    override func objectIsForced(forKey key: String, inDomain domain: String) -> Bool { false }
}

extension XCTestCase {
    /// Creates settings storage this test owns outright, optionally holding `seed` to begin with.
    ///
    /// Every component a test points at the returned store — the manager, the hosted form, startup
    /// migration — then reads and writes the same test-owned domain, so nothing has to be cleared
    /// beforehand or restored afterwards: the storage is discarded with the test that made it.
    func makeOwnedDefaults(_ seed: [String: Any] = [:]) -> UserDefaults {
        let defaults = InMemoryDefaults()
        for (key, value) in seed {
            defaults.set(value, forKey: key)
        }
        return defaults
    }
}
