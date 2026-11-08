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

    @Test func archivedChatsExcludedFromInboxOnColdStart() {
        let inboxConv = ZaloEngine.ConversationSummary(
            id: "inbox-1", isGroup: false, name: "Inbox Chat", avatar: nil,
            pinned: false, members: 2, unread: 0, preview: nil
        )
        let archivedConv = ZaloEngine.ConversationSummary(
            id: "archived-1", isGroup: false, name: "Archived Chat", avatar: nil,
            pinned: false, members: 2, unread: 0, preview: nil
        )

        var actions = ConversationActionsState()
        actions.flags = ["archived-1": ConversationActionFlags.archived]

        let all = [inboxConv, archivedConv]
        let inboxFiltered = all.filter { !actions.flags(for: $0.id).contains(.archived) }
        let otherFiltered = all.filter { actions.flags(for: $0.id).contains(.archived) }

        #expect(inboxFiltered.map(\.id) == ["inbox-1"])
        #expect(otherFiltered.map(\.id) == ["archived-1"])
    }

    @Test func prematureEmptyResetDoesNotWipeCachedConversations() {
        let engine = ZaloEngine()
        let conv = ZaloEngine.ConversationSummary(
            id: "c-1", isGroup: false, name: "Saved Chat", avatar: nil,
            pinned: false, members: 2, unread: 0, preview: nil
        )

        let platform = makePlatform()
        defer { cleanupPlatform(platform) }
        let snapshot = ConversationSnapshot(
            version: 1, userId: "u1", timestamp: Date(),
            conversations: [conv], hiddenIds: [], flags: [:], left: [:],
            hiddenEnabled: false, hasHiddenPIN: false, markUnreadEnabled: false
        )
        ConversationSnapshotStore.save(snapshot, platform: platform)
        engine.restoreConversationSnapshot(platform: platform)
        #expect(engine.conversations.count == 1)

        // Simulate premature empty reset from WebKit
        engine.mergeConversations(["conversations": [], "reset": true, "removed": []])

        // Conversation should NOT be wiped because rows is empty
        #expect(engine.conversations.count == 1)
        #expect(engine.conversations.first?.id == "c-1")
    }

    @Test func v2SnapshotRoundTripAndBackwardsCompatibility() throws {
        let platform = makePlatform()
        defer { cleanupPlatform(platform) }

        let original = ConversationSnapshot(
            version: 2,
            userId: "uid-me",
            timestamp: Date(),
            conversations: [],
            hiddenIds: [],
            flags: [:],
            left: [:],
            hiddenEnabled: true,
            hasHiddenPIN: false,
            markUnreadEnabled: true,
            selfConversationId: "self-cloud-id",
            displayName: "Test User",
            avatar: URL(string: "https://example.com/me.png"),
            archivedEnabled: true,
            listIds: ["c1", "c2"],
            strangerIds: ["s1"],
            strangerFolderIds: ["s1"]
        )

        ConversationSnapshotStore.save(original, platform: platform)
        let loaded = try #require(ConversationSnapshotStore.load(platform: platform))
        #expect(loaded.version == 2)
        #expect(loaded.selfConversationId == "self-cloud-id")
        #expect(loaded.displayName == "Test User")
        #expect(loaded.avatar == URL(string: "https://example.com/me.png"))
        #expect(loaded.archivedEnabled == true)
        #expect(loaded.listIds == ["c1", "c2"])
        #expect(loaded.strangerFolderIds == ["s1"])

        // Backwards compatibility with v1 JSON (no v2 keys)
        let v1JSON = """
        {
            "version": 1,
            "userId": "uid-v1",
            "timestamp": 1700000000,
            "conversations": [],
            "hiddenIds": [],
            "flags": {},
            "left": {},
            "hiddenEnabled": false,
            "hasHiddenPIN": false,
            "markUnreadEnabled": false
        }
        """.data(using: .utf8)!

        let decodedV1 = try JSONDecoder().decode(ConversationSnapshot.self, from: v1JSON)
        #expect(decodedV1.version == 1)
        #expect(decodedV1.selfConversationId == nil)
        #expect(decodedV1.displayName == nil)
        #expect(decodedV1.archivedEnabled == false)
        #expect(decodedV1.listIds.isEmpty)
    }

    @Test func flagsPreservationOnIncompleteWebKitUpdate() {
        var actions = ConversationActionsState()
        let snapshot = ConversationSnapshot(
            version: 2,
            userId: "u1",
            timestamp: Date(),
            conversations: [],
            hiddenIds: [],
            flags: [
                "p1": ConversationActionFlags.pinned.rawValue,
                "a1": ConversationActionFlags.archived.rawValue
            ],
            left: [:],
            hiddenEnabled: true,
            hasHiddenPIN: false,
            markUnreadEnabled: true
        )

        actions.restore(from: snapshot)
        #expect(actions.isPinned("p1"))
        #expect(actions.flags(for: "a1").contains(.archived))

        // WebKit sends premature early flags before loading Pin/Archive store (0 pinned, 0 archived)
        actions.apply(json: [
            "flags": [
                "some-oa": 8 // cannotPin
            ]
        ])

        // Pinned and archived flags must be preserved!
        #expect(actions.isPinned("p1"))
        #expect(actions.flags(for: "a1").contains(.archived))
        #expect(actions.flags(for: "some-oa").contains(.cannotPin))

        // When WebKit actually sends full flags containing pins and archives, it updates
        actions.apply(json: [
            "flags": [
                "p2": ConversationActionFlags.pinned.rawValue,
                "a2": ConversationActionFlags.archived.rawValue
            ]
        ])
        #expect(!actions.isPinned("p1"))
        #expect(actions.isPinned("p2"))
        #expect(!actions.flags(for: "a1").contains(.archived))
        #expect(actions.flags(for: "a2").contains(.archived))
    }

    @Test func engineRestoresExtrasAndProfileFromSnapshot() {
        let engine = ZaloEngine()
        let platform = makePlatform()
        defer { cleanupPlatform(platform) }

        let snapshot = ConversationSnapshot(
            version: 2,
            userId: "user-abc",
            timestamp: Date(),
            conversations: [],
            hiddenIds: [],
            flags: [:],
            left: [:],
            hiddenEnabled: true,
            hasHiddenPIN: false,
            markUnreadEnabled: true,
            selfConversationId: "cloud-conv-id",
            displayName: "Test User",
            avatar: nil,
            archivedEnabled: true,
            listIds: ["conv-focus-1"],
            strangerIds: ["stranger-1"],
            strangerFolderIds: ["stranger-1"]
        )

        ConversationSnapshotStore.save(snapshot, platform: platform)
        engine.restoreConversationSnapshot(platform: platform)

        #expect(engine.selfConversationId == "cloud-conv-id")
        #expect(engine.profile?.displayName == "Test User")
        #expect(engine.conversationExtras.archivedEnabled == true)
        #expect(engine.conversationExtras.listIds == ["conv-focus-1"])
        #expect(engine.conversationExtras.strangerFolderIds == ["stranger-1"])
        #expect(engine.conversationExtras.loaded == true)
    }

    @Test func loginSucceededPreservesReadyPhaseForInstantColdStart() {
        let engine = ZaloEngine()
        engine.phase = .ready

        // WebKit finishes initial auth/handshake and sends .loginSucceeded
        engine.handle(.loginSucceeded)

        // Engine MUST preserve .ready so RootView does not flap to SplashView and cause reload
        #expect(engine.phase == .ready)
    }

    @Test func loginSucceededTransitionsFromLoginToSigningIn() {
        let engine = ZaloEngine()
        engine.phase = .login(ZaloEngine.LoginState())

        // User finishes QR login
        engine.handle(.loginSucceeded)

        // Engine must transition to .signingIn for fresh login setup flow
        #expect(engine.phase == .signingIn)
    }

    @Test func handleConversationExtrasPreservesPopulatedListAgainstPrematureShortList() {
        let engine = ZaloEngine()
        engine.conversationActions.flags = ["c1": .pinned]
        engine.conversationExtras.listIds = ["c1", "c2", "c3", "c4", "c5", "c6"]
        engine.conversationExtras.loaded = true

        // WebKit sends premature update with only 1 pinned item while loading non-pinned rows
        engine.handleConversationExtras(state: [
            "conversationExtras": [
                "listIds": ["c1"]
            ]
        ])

        // Populated list must be preserved against premature truncation
        #expect(engine.conversationExtras.listIds == ["c1", "c2", "c3", "c4", "c5", "c6"])

        // When WebKit actually sends full updated list, it updates
        let fullList = ["c1", "c2", "c3", "c4", "c5", "c6", "c7"]
        engine.handleConversationExtras(state: [
            "conversationExtras": [
                "listIds": fullList
            ]
        ])
        #expect(engine.conversationExtras.listIds == fullList)
    }

    @Test func mergeConversationsDoesNotWipeSnapshotOnPartialReset() {
        let engine = ZaloEngine()
        let convs = (1...10).map { i in
            ZaloEngine.ConversationSummary(
                id: "c-\(i)", isGroup: false, name: "Chat \(i)", avatar: nil,
                pinned: false, members: 2, unread: 0, preview: nil
            )
        }
        let platform = makePlatform()
        defer { cleanupPlatform(platform) }
        let snapshot = ConversationSnapshot(
            version: 2, userId: "u1", timestamp: Date(),
            conversations: convs, hiddenIds: [], flags: [:], left: [:],
            hiddenEnabled: true, hasHiddenPIN: false, markUnreadEnabled: false
        )
        ConversationSnapshotStore.save(snapshot, platform: platform)
        engine.restoreConversationSnapshot(platform: platform)
        #expect(engine.conversations.count == 10)

        // WebKit initial stream only returns first 6 conversations with reset: true
        let partialPayload: [[String: Any]] = (1...6).map { i in
            ["id": "c-\(i)", "name": "Chat \(i)", "isGroup": false]
        }
        engine.mergeConversations(["conversations": partialPayload, "reset": true, "removed": []])

        // The remaining 4 conversations must NOT be wiped!
        #expect(engine.conversations.count == 10)
    }

    @Test func initialLiveSyncHandoverSuppressesAnimationsUntilHydrated() {
        let engine = ZaloEngine()
        #expect(!engine.hasCompletedInitialLiveSync)

        let conv = ZaloEngine.ConversationSummary(
            id: "c-1", isGroup: false, name: "Chat 1", avatar: nil,
            pinned: false, members: 2, unread: 0, preview: nil
        )
        let platform = makePlatform()
        defer { cleanupPlatform(platform) }
        let snapshot = ConversationSnapshot(
            version: 2, userId: "u1", timestamp: Date(),
            conversations: [conv], hiddenIds: [], flags: [:], left: [:],
            hiddenEnabled: true, hasHiddenPIN: false, markUnreadEnabled: false
        )
        ConversationSnapshotStore.save(snapshot, platform: platform)
        engine.restoreConversationSnapshot(platform: platform)

        // WebKit initial sync starts: hasCompletedInitialLiveSync is still false to suppress animations
        #expect(!engine.hasCompletedInitialLiveSync)

        // WebKit completes live extras with populated listIds
        engine.handleConversationExtras(state: [
            "conversationExtras": [
                "listIds": ["c-1"]
            ]
        ])

        // Live sync has completed: animations may safely resume
        #expect(engine.hasCompletedInitialLiveSync)
    }
}
