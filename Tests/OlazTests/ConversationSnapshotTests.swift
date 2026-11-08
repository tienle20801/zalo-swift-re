import Testing
import Foundation
@testable import Olaz

@Suite @MainActor struct ConversationSnapshotTests {
    private func makePlatform() -> ZaloPlatform {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-test-\(UUID().uuidString)", isDirectory: true)
        return ZaloPlatform(appVersion: "26.10.20", userData: tempDir)
    }

    private func cleanupPlatform(_ platform: ZaloPlatform) {
        try? FileManager.default.removeItem(at: platform.userData)
    }

    @Test func roundTripEncryptionAndDecryption() throws {
        let platform = makePlatform()
        defer { cleanupPlatform(platform) }

        let conv1 = ZaloEngine.ConversationSummary(
            id: "conv-1",
            isGroup: false,
            name: "Alice",
            avatar: URL(string: "https://example.com/avatar.jpg"),
            pinned: false,
            members: 2,
            unread: 1,
            preview: .init(text: "Hello!", date: Date(timeIntervalSince1970: 1700000000), fromMe: false)
        )
        let conv2 = ZaloEngine.ConversationSummary(
            id: "conv-2",
            isGroup: true,
            name: "Dev Group",
            avatar: nil,
            pinned: true,
            members: 10,
            unread: 0,
            preview: .init(text: "PR merged", date: Date(timeIntervalSince1970: 1700000100), fromMe: true)
        )

        let original = ConversationSnapshot(
            version: 1,
            userId: "uid-12345",
            timestamp: Date(),
            conversations: [conv1, conv2],
            hiddenIds: ["conv-secret"],
            flags: ["conv-2": ConversationActionFlags.pinned.rawValue],
            left: [:],
            hiddenEnabled: true,
            hasHiddenPIN: true,
            markUnreadEnabled: true
        )

        ConversationSnapshotStore.save(original, platform: platform)

        let snapshotFile = platform.userData.appendingPathComponent("conversations-snapshot.bin")
        #expect(FileManager.default.fileExists(atPath: snapshotFile.path))

        // Verify the file on disk is encrypted (does NOT contain plaintext strings like "Alice" or "Dev Group")
        let rawDiskBytes = try Data(contentsOf: snapshotFile)
        let rawString = String(decoding: rawDiskBytes, as: UTF8.self)
        #expect(!rawString.contains("Alice"))
        #expect(!rawString.contains("Dev Group"))
        #expect(!rawString.contains("conv-secret"))

        // Verify POSIX permissions 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: snapshotFile.path)
        let posix = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(posix == 0o600)

        // Verify decryption round-trip
        let loaded = try #require(ConversationSnapshotStore.load(platform: platform))
        #expect(loaded.version == original.version)
        #expect(loaded.userId == original.userId)
        #expect(loaded.conversations == original.conversations)
        #expect(loaded.hiddenIds == original.hiddenIds)
        #expect(loaded.flags == original.flags)
        #expect(loaded.hiddenEnabled == original.hiddenEnabled)
        #expect(loaded.hasHiddenPIN == original.hasHiddenPIN)
    }

    @Test func instantRestorationAndHiddenPrivacyProtection() throws {
        let platform = makePlatform()
        defer { cleanupPlatform(platform) }

        let publicConv = ZaloEngine.ConversationSummary(
            id: "public-chat",
            isGroup: false,
            name: "Public Friend",
            avatar: nil,
            pinned: false,
            members: 2,
            unread: 0,
            preview: .init(text: "Hi", date: Date(), fromMe: false)
        )
        let secretConv = ZaloEngine.ConversationSummary(
            id: "secret-chat",
            isGroup: false,
            name: "Secret VIP",
            avatar: nil,
            pinned: false,
            members: 2,
            unread: 0,
            preview: .init(text: "Classified", date: Date(), fromMe: false)
        )

        let snapshot = ConversationSnapshot(
            version: 1,
            userId: "uid-me",
            timestamp: Date(),
            conversations: [publicConv, secretConv],
            hiddenIds: ["secret-chat"],
            flags: ["secret-chat": ConversationActionFlags.hidden.rawValue],
            left: [:],
            hiddenEnabled: true,
            hasHiddenPIN: true,
            markUnreadEnabled: true
        )
        ConversationSnapshotStore.save(snapshot, platform: platform)

        let engine = ZaloEngine()
        #expect(engine.conversations.isEmpty)
        #expect(!engine.conversationActions.hiddenKnown)

        // Restore snapshot into engine state
        var restoredActions = ConversationActionsState()
        restoredActions.restore(from: snapshot)
        #expect(restoredActions.hiddenKnown)
        #expect(restoredActions.isHidden("secret-chat"))
        #expect(!restoredActions.isHidden("public-chat"))

        // Simulate engine state after snapshot restoration
        // Only public chat should be visible
        let visible = snapshot.conversations.filter { !restoredActions.isHidden($0.id) }
        #expect(visible.count == 1)
        #expect(visible.first?.id == "public-chat")
        #expect(visible.first?.name == "Public Friend")
    }

    @Test func clearRemovesSnapshotFile() {
        let platform = makePlatform()
        defer { cleanupPlatform(platform) }

        let snapshot = ConversationSnapshot(
            version: 1,
            userId: "uid-test",
            timestamp: Date(),
            conversations: [],
            hiddenIds: [],
            flags: [:],
            left: [:],
            hiddenEnabled: false,
            hasHiddenPIN: false,
            markUnreadEnabled: false
        )
        ConversationSnapshotStore.save(snapshot, platform: platform)
        let file = platform.userData.appendingPathComponent("conversations-snapshot.bin")
        #expect(FileManager.default.fileExists(atPath: file.path))

        ConversationSnapshotStore.clear(platform: platform)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
