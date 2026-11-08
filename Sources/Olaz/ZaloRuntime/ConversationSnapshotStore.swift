import Foundation
import CryptoKit
import Security

/// Snapshot payload stored on disk, encrypted via AES-GCM with a device-bound key.
struct ConversationSnapshot: Codable, Sendable, Equatable {
    var version: Int = 1
    var userId: String?
    var timestamp: Date
    var conversations: [ZaloEngine.ConversationSummary]
    var hiddenIds: [String]
    var flags: [String: Int]
    var left: [String: String]
    var hiddenEnabled: Bool
    var hasHiddenPIN: Bool
    var markUnreadEnabled: Bool
}

/// Manages atomic read/write of encrypted conversation snapshots for instant cold-start.
@MainActor
enum ConversationSnapshotStore {
    private static let fileName = "conversations-snapshot.bin"
    private static let keyAccount = "olaz.conversations.snapshot"
    private static let vaultKey = "olaz_conversations_snapshot_key"

    /// Loads the decrypted snapshot from disk if present and valid.
    static func load(platform: ZaloPlatform) -> ConversationSnapshot? {
        let fileURL = platform.userData.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let combined = try Data(contentsOf: fileURL)
            guard let key = encryptionKey(platform: platform) else { return nil }
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealed, using: key)
            let snapshot = try JSONDecoder().decode(ConversationSnapshot.self, from: plaintext)
            guard snapshot.version == 1 else { return nil }
            return snapshot
        } catch {
            EngineLog.shared.write("snapshot: failed to load or decrypt — \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves the snapshot encrypted to disk atomically with 0600 permissions.
    static func save(_ snapshot: ConversationSnapshot, platform: ZaloPlatform) {
        guard let key = encryptionKey(platform: platform) else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined else { return }
            let fileURL = platform.userData.appendingPathComponent(fileName)
            try combined.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            EngineLog.shared.write("snapshot: failed to save — \(error.localizedDescription)")
        }
    }

    /// Clears the snapshot from disk (e.g. on logout).
    static func clear(platform: ZaloPlatform) {
        let fileURL = platform.userData.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Symmetric key retrieved from Keychain or SafeStorage, generated on first use.
    private static func encryptionKey(platform: ZaloPlatform) -> SymmetricKey? {
        let vault = SafeStorage(platform: platform)
        if let b64 = (try? vault.execute("get", [vaultKey])) as? String,
           let cached = Data(base64Encoded: b64), cached.count == 32 {
            return SymmetricKey(data: cached)
        }
        switch Keychain.read(account: keyAccount) {
        case .found(let existing) where existing.count == 32:
            _ = try? vault.execute("set", [vaultKey, existing.base64EncodedString()])
            return SymmetricKey(data: existing)
        case .found, .notFound, .failed:
            break
        }
        var raw = Data(count: 32)
        let status = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { return nil }
        _ = try? vault.execute("set", [vaultKey, raw.base64EncodedString()])
        try? Keychain.write(account: keyAccount, data: raw)
        return SymmetricKey(data: raw)
    }
}
