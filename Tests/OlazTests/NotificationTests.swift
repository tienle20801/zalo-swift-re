import Testing
import Foundation
@testable import Olaz

@Suite struct NotificationTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }

    private func date(_ string: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)!
    }

    // MARK: mute expiry

    @Test func muteDurationExpiry() {
        let now = date("2026-10-26T10:15:00+07:00")
        #expect(MuteDuration.oneHour.expiry(from: now, calendar: calendar) == now.addingTimeInterval(3600))
        #expect(MuteDuration.fourHours.expiry(from: now, calendar: calendar) == now.addingTimeInterval(4 * 3600))
        #expect(MuteDuration.untilReopened.expiry(from: now, calendar: calendar) == nil)
        // Past 8:00 → tomorrow 8:00.
        #expect(MuteDuration.until8AM.expiry(from: now, calendar: calendar) == date("2026-10-27T08:00:00+07:00"))
        // Before 8:00 → today 8:00.
        let early = date("2026-10-26T05:30:00+07:00")
        #expect(MuteDuration.until8AM.expiry(from: early, calendar: calendar) == date("2026-10-26T08:00:00+07:00"))
        // Exactly 8:00 → next day (official: `getTime() <= now` rolls over).
        let exact = date("2026-10-26T08:00:00+07:00")
        #expect(MuteDuration.until8AM.expiry(from: exact, calendar: calendar) == date("2026-10-27T08:00:00+07:00"))
    }

    @Test func muteDurationModesMatchOfficialMenu() {
        #expect(MuteDuration.allCases.map(\.rawValue) == [1, 2, 3, 4])
    }

    @Test func muteInfoActivity() {
        let now = date("2026-10-26T10:00:00+07:00")
        let start = now.timeIntervalSince1970
        let timed = MuteInfo(startTime: start - 600, duration: 3600)
        #expect(timed.isActive(at: now))
        #expect(timed.until == Date(timeIntervalSince1970: start + 3000))
        #expect(!MuteInfo(startTime: start - 7200, duration: 3600).isActive(at: now))
        let forever = MuteInfo(startTime: 1_685_096_585, duration: -1)
        #expect(forever.isIndefinite && forever.isActive(at: now) && forever.until == nil)
    }

    @Test func muteDescription() {
        let now = date("2026-10-26T10:00:00+07:00")
        let sameDay = MuteInfo(startTime: now.timeIntervalSince1970, duration: 3600)
        #expect(sameDay.description(now: now, calendar: calendar) == "Cho đến 11:00")
        let nextDay = MuteInfo(startTime: now.timeIntervalSince1970, duration: 22 * 3600)
        #expect(nextDay.description(now: now, calendar: calendar) == "Cho đến 08:00 ngày 27/10")
        #expect(MuteInfo(startTime: 0, duration: -1).description(now: now, calendar: calendar) == "Cho đến khi được mở lại")
    }

    // MARK: settings snapshot

    @Test func settingsSnapshot() {
        var state = NotificationSettingsState()
        #expect(!state.isLoaded)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        state.apply(settings: [
            "kind": "settings", "enabled": false, "sound": true, "hasSoundSetting": true,
            "mutes": [
                ["id": "123", "startTime": 1_799_990_000, "duration": 3600],     // expired
                ["id": "g456", "startTime": 1_799_999_000, "duration": 3600],    // active (timed)
                ["id": "789", "startTime": 1_685_096_585, "duration": -1],       // until reopened
                ["startTime": 1, "duration": 1],                                   // no id → ignored
            ],
        ])
        #expect(state.isLoaded && !state.enabled && state.sound && state.hasSoundSetting)
        #expect(state.mutes.count == 3)
        #expect(!state.isMuted("123", now: now))
        #expect(state.isMuted("g456", now: now))
        #expect(state.isMuted("789", now: now))
        #expect(!state.isMuted("000", now: now))
        #expect(state.activeMutes(now: now).map(\.id) == ["789", "g456"])
    }

    // MARK: IPC payload

    @Test func parsesElectronNotificationArguments() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).base64EncodedString()
        let request = try #require(NativeNotificationRequest.parse([
            "Nhóm Gia đình", ["body": "Mẹ: ăn cơm chưa", "tag": "g12345", "silent": true, "icon": "data:image/png;base64,\(png)"],
        ]))
        #expect(request.title == "Nhóm Gia đình")
        #expect(request.body == "Mẹ: ăn cơm chưa")
        #expect(request.tag == "g12345")
        #expect(request.silent)
        #expect(request.icon == .inline(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])))
    }

    @Test func parsesIconKinds() {
        #expect(NativeNotificationRequest.parseIcon("https://s120-ava-talk.zadn.vn/a/b/c") == .remote(URL(string: "https://s120-ava-talk.zadn.vn/a/b/c")!))
        #expect(NativeNotificationRequest.parseIcon("assets/avatar_stranger_notif.5b53.png?v=1") == .bundled("assets/avatar_stranger_notif.5b53.png"))
        #expect(NativeNotificationRequest.parseIcon("") == nil)
        #expect(NativeNotificationRequest.parseIcon("data:image/png;base64,@@@") == nil)
        #expect(NativeNotificationRequest.parseIcon("file:///etc/passwd") == nil)
    }

    @Test func tagMayBeNumberAndDefaultsAreSafe() throws {
        let numeric = try #require(NativeNotificationRequest.parse(["Tên", ["body": "xin chào", "tag": NSNumber(value: 42)]]))
        #expect(numeric.tag == "42" && !numeric.silent && numeric.icon == nil)
        #expect(NativeNotificationRequest.parse([]) == nil)
        #expect(NativeNotificationRequest.parse(["", [:]]) == nil)
        let titleOnly = NativeNotificationRequest.parse(["Zalo"])
        #expect(titleOnly?.body == "" && titleOnly?.tag == "")
    }

    // MARK: policy

    @Test func previewToggle() {
        #expect(NotificationPolicy.body("Mẹ: xin chào", showsPreview: true) == "Mẹ: xin chào")
        #expect(NotificationPolicy.body("Mẹ: xin chào", showsPreview: false) == "Bạn có tin nhắn mới")
    }

    @Test func suppressesOnlyWhenWatchingThatConversation() {
        func suppress(active: Bool = true, visible: Bool = true, open: String? = "5", tag: String = "5", idle: TimeInterval = 4) -> Bool {
            NotificationPolicy.shouldSuppress(appIsActive: active, mainWindowVisible: visible, openConversation: open, tag: tag, userIdleSeconds: idle)
        }
        #expect(suppress())
        #expect(!suppress(active: false))
        #expect(!suppress(visible: false))
        #expect(!suppress(open: "6"))
        #expect(!suppress(open: nil))
        #expect(!suppress(tag: ""))
        #expect(!suppress(idle: 600))   // user stepped away: official idle rule still notifies
    }

    @Test func attachmentTypeSniffing() {
        #expect(NotificationPolicy.attachmentType(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D]))?.ext == "png")
        #expect(NotificationPolicy.attachmentType(for: Data([0xFF, 0xD8, 0xFF, 0xE0]))?.ext == "jpg")
        #expect(NotificationPolicy.attachmentType(for: Data("GIF89a".utf8))?.ext == "gif")
        #expect(NotificationPolicy.attachmentType(for: Data("RIFF....WEBP".utf8)) == nil)
        #expect(NotificationPolicy.attachmentType(for: Data()) == nil)
    }

    @Test func soundURLAllowList() {
        #expect(NotificationPolicy.isSoundURLAllowed(URL(string: "https://stc-chat.zdn.vn/sound/noti.mp3")!))
        #expect(!NotificationPolicy.isSoundURLAllowed(URL(string: "http://stc-chat.zdn.vn/sound/noti.mp3")!))
        #expect(!NotificationPolicy.isSoundURLAllowed(URL(string: "https://evil.example.com/sound/noti.mp3")!))
        #expect(!NotificationPolicy.isSoundURLAllowed(URL(string: "https://stc-chat.zdn.vn/other.mp3")!))
    }

    @MainActor @Test func markReadAndReplyRefusalPolicy() {
        #expect(NativeNotifier.markReadAction == "app.olaz.message.markRead")
        #expect(NotificationPolicy.refusesReply(hiddenStateKnown: false, conversationLocked: false))
        #expect(NotificationPolicy.refusesReply(hiddenStateKnown: true, conversationLocked: true))
        #expect(!NotificationPolicy.refusesReply(hiddenStateKnown: true, conversationLocked: false))
    }

    @MainActor @Test func avatarLRUCacheAndStaleTempFileCleanup() throws {
        let notifier = NativeNotifier.shared
        let base = "https://s120-ava-talk.zadn.vn/test-lru-"
        for i in 0..<(NativeNotifier.maxCachedAvatars + 4) {
            let url = URL(string: "\(base)\(i).png")!
            notifier.storeAvatarData(Data([UInt8(i & 0xFF)]), for: url)
        }
        // First 4 entries were evicted; accessing entry 4 promotes it in LRU order.
        #expect(notifier.cachedAvatarData(for: URL(string: "\(base)0.png")!) == nil)
        let promoted = URL(string: "\(base)4.png")!
        #expect(notifier.cachedAvatarData(for: promoted) == Data([4]))
        notifier.storeAvatarData(Data([99]), for: URL(string: "\(base)999.png")!)
        #expect(notifier.cachedAvatarData(for: promoted) == Data([4]))
        #expect(notifier.cachedAvatarData(for: URL(string: "\(base)5.png")!) == nil)

        // Temp file cleanup removes only expired files.
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("OlazNotiTest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let oldFile = tempDir.appendingPathComponent("old.png")
        let freshFile = tempDir.appendingPathComponent("fresh.png")
        try Data([1, 2, 3]).write(to: oldFile)
        try Data([4, 5, 6]).write(to: freshFile)
        let now = Date.now
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: oldFile.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-10)], ofItemAtPath: freshFile.path)

        NativeNotifier.cleanStaleTempFiles(in: tempDir, maxAge: 300, now: now)
        #expect(!fm.fileExists(atPath: oldFile.path))
        #expect(fm.fileExists(atPath: freshFile.path))
    }

    @Test func notificationAdapterFocusAndActivitySync() {
        let h = ScriptHarness(prelude: """
        var events = [];
        function EventTarget() {}
        function HTMLMediaElement() {}
        HTMLMediaElement.prototype.play = function () {};
        function Event(type) { this.type = type; }
        window.addEventListener = function () {};
        window.dispatchEvent = function (e) { events.push('win:' + e.type); };
        var document = { dispatchEvent: function (e) { events.push('doc:' + e.type); } };
        window.ifvisible = {
          idle: function () { events.push('ifv:idle'); },
          wakeup: function () { events.push('ifv:wakeup'); }
        };
        window.webkit = { messageHandlers: {} };
        """)
        h.load("notification-adapter.js")
        #expect(h.failures.isEmpty)

        // When focused initially, activity() dispatches touchstart.
        h.ctx.evaluateScript("window.__zaloNotification.activity();")
        // When blurred, setFocused(false) puts ifvisible to idle, dispatches window blur, and blocks activity().
        h.ctx.evaluateScript("window.__zaloNotification.setFocused(false);")
        h.ctx.evaluateScript("window.__zaloNotification.activity();")
        // When refocused, setFocused(true) wakes ifvisible, dispatches window focus, and allows activity() again.
        h.ctx.evaluateScript("window.__zaloNotification.setFocused(true);")
        h.ctx.evaluateScript("window.__zaloNotification.activity();")

        let recorded = h.ctx.evaluateScript("events")?.toArray() as? [String]
        #expect(recorded == [
            "doc:touchstart",
            "ifv:idle",
            "win:blur",
            "ifv:wakeup",
            "win:focus",
            "doc:touchstart",
        ])
    }
}
