import Foundation

/// UserDefaults and EncryptedPreferences serialize their own mutations. This
/// wrapper makes that boundary explicit to the reconciliation actor.
final class SyncPreferenceWriter: @unchecked Sendable {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
}
