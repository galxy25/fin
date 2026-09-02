import Foundation

/// Stable identity for this install, minted once into UserDefaults. It exists so state
/// that must not travel between devices — the log mirror's per-device day files, an
/// armed monitor's home device — has something durable to bind to, because the synced
/// `Agent` record itself is the same object on every device.
enum DeviceIdentity {
    static let defaultsKey = "fin.device.id"

    /// Lowercased UUID string. `static let` gives once-only minting even under
    /// concurrent first access (the mirror reads this off the main thread).
    static let id: String = {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString.lowercased()
        defaults.set(minted, forKey: defaultsKey)
        return minted
    }()

    /// Filename-sized prefix for the mirror's per-device day files.
    static var short: String { String(id.prefix(8)) }
}
