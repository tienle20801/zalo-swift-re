import AppKit
import Observation
import SwiftUI
import os

private let engineLog = Logger(subsystem: "app.olaz", category: "engine")

/// The one object SwiftUI binds to. It boots the official Zalo client runtime
/// (`OfficialClientHost` + `ZaloMainProcess`) and turns its state into
/// view-friendly values. All protocol work happens in the official code.
@MainActor
@Observable
final class ZaloEngine {
    enum Phase: Equatable {
        case starting
        /// Installing the official Zalo code Olaz runs (first launch, or the runtime folder was removed).
        case preparing(RuntimeSetup)
        case login(LoginState)
        /// QR confirmed; the main client is loading and syncing.
        case signingIn
        case ready
    }

    struct RuntimeSetup: Equatable {
        var step: ZaloRuntimeInstaller.Step = .looking
        /// Why the last attempt failed; the window offers to try again.
        var failure: String?
    }

    struct LoginState: Equatable {
        enum Step: Equatable {
            case generating
            case waitingScan
            /// Phone scanned; waiting for "Đăng nhập" on the phone.
            case waitingConfirm(name: String, avatar: URL?)
            case expired
            case failed(String)
        }
        var step: Step = .generating
        var qrPNG: Data?
        /// The server asked for a second scan (`error_code -20`, multi-layer QR for device linking): the QR on screen
        /// is QR2, which the phone must scan before the login can be confirmed.
        var isSecondQR = false
    }

    struct Profile: Equatable {
        var userId: String
        var displayName: String
        var avatar: URL?
        var phone: String?
    }

    /// A conversation as the official client knows it (conv-info-manager + profiles).
    struct ConversationSummary: Identifiable, Equatable, Codable, Sendable {
        struct Preview: Equatable, Codable, Sendable {
            var text: String
            var date: Date?
            var fromMe: Bool
        }
        var id: String
        var isGroup: Bool
        var name: String
        var avatar: URL?
        var pinned: Bool
        var members: Int
        var unread: Int
        var preview: Preview?

        var displayName: String { name.isEmpty ? (isGroup ? "Nhóm" : "Người dùng Zalo") : name }
    }

    internal(set) var phase: Phase = .starting
    private(set) var conversations: [ConversationSummary] = []
    /// `conversations` by id: the adapter posts only the rows that changed (`reset` replaces everything).
    @ObservationIgnored private var conversationIndex: [String: ConversationSummary] = [:]
    private(set) var conversationsById: [String: ConversationSummary] = [:]
    private(set) var profile: Profile?
    /// Why the session ended, shown on the login screen (e.g. kicked by another PC login).
    private(set) var signOutNotice: String?
    private(set) var clientVersion: String?
    /// Last renderer diagnostics (shown in Settings ▸ Engine).
    private(set) var recentLog: [String] = []
    /// Marks whether background WebKit has completed its initial live conversation hydration.
    internal(set) var hasCompletedInitialLiveSync = false

    // Chat state (see ChatModels.swift for the JS contract; logic in ZaloEngine+Chat.swift).
    /// The conversation currently opened in the official client.
    internal(set) var openConversationId: String?
    /// Texts the official client refused to send, kept per conversation until its composer takes them back.
    var failedDrafts = FailedDraftStore()
    /// Messages per conversation, oldest first.
    internal(set) var messages: [String: [ChatMessage]] = [:]
    /// Whether older history can be loaded per conversation.
    internal(set) var hasMoreHistory: [String: Bool] = [:]
    /// Bumped when an older page arrived whose messages are all hidden cards (nothing else in `messages` changes), so the list can ask for the next page.
    internal(set) var historyTicks: [String: Int] = [:]
    /// Who is typing per conversation (display name), cleared after a few seconds.
    internal(set) var typing: [String: String] = [:]
    /// Phone → PC message transfer, nil when none is in progress / offered.
    internal(set) var transfer: MessageTransferState?
    /// Whether a manual phone → PC sync can start now (official `canSync` guards).
    internal(set) var canStartTransfer = false
    /// Official reason the sync can't start (e.g. `WORKER_NOT_READY`), nil when it can.
    internal(set) var transferStartBlockedReason: String?

    // Feature state — each fed by its own host script, logic in ZaloEngine+<Feature>.swift.
    /// My Documents / "Cloud của tôi" conversation id (official `sendToMeId`).
    internal(set) var selfConversationId: String?
    /// Set by any view (contacts, notifications…) to ask the shell to show a conversation.
    var navigationRequest: String?
    /// Conversation labels ("Phân loại") and list filters/folders (ZaloEngine+Conversations.swift).
    internal(set) var conversationExtras = ConversationExtras()
    /// Context-menu actions of conversations: flags, pin board, hidden chats (ZaloEngine+ConversationActions.swift).
    internal(set) var conversationActions = ConversationActionsState()
    /// Toast, removals and the unlocked hidden chat of those actions (observed separately from the snapshot).
    let conversationUI = ConversationActionUI()
    /// Dialog / sheet a conversation action asks the shell to show (delete confirm, full pin board, hidden-chat PIN).
    var conversationPrompt: ConversationPrompt?
    /// Friends, groups, friend requests (ZaloEngine+Contacts.swift).
    internal(set) var contacts = ContactsState()
    /// Notification preferences mirrored from the official client (ZaloEngine+Notifications.swift).
    internal(set) var notificationSettings = NotificationSettingsState()
    /// zCloud: plan, quota / usage, conversations with cloud data, settings (ZaloEngine+Cloud.swift).
    internal(set) var cloud = CloudState()
    /// Voice / video calls: renderer support, native helper status, incoming call (ZaloEngine+CallHook.swift).
    internal(set) var call = CallState()
    /// Group polls read from the official poll service, by poll id (ZaloEngine+Poll.swift).
    internal(set) var polls = PollStore()
    /// Composer "+" actions (ZaloEngine+Composer.swift): an official confirm asked during a send, a screenshot to share, the
    /// screen-recording notice.
    var composerConfirm: ComposerConfirm?
    /// Confirms asked while another is on screen, shown one after the other.
    @ObservationIgnored internal var queuedComposerConfirms: [ComposerConfirm] = []
    var screenshotShare: ScreenshotShare?
    var screenCaptureNeedsPermission = false
    @ObservationIgnored internal var screenCaptureTool: ScreenCapture?
    /// Images pasted with ⌘V, staged in the conversation's composer tray before sending.
    var stagedImages: [String: [StagedImage]] = [:]
    /// Message context-menu actions (ZaloEngine+MessageActions.swift): the "Chia sẻ" picker, a confirm they ask, the undo of the last
    /// "Xóa chỉ ở phía tôi", the pinned list of the open conversation.
    var forwardRequest: ForwardRequest?
    var messageConfirm: MessageActionConfirm?
    var deleteUndo: DeleteUndo?
    internal(set) var pins: [String: PinnedList] = [:]
    /// Reminder message IDs deleted in the current session (ZaloEngine+CardActions.swift).
    var deletedReminderIds: Set<String> = []
    /// Message actions in flight ("conv|msg|action"): a second click while one runs is ignored.
    @ObservationIgnored internal var messageActionsBusy: Set<String> = []

    @ObservationIgnored internal var host: OfficialClientHost?
    /// Dedupes/throttles `resolveMedia` (ZaloEngine+Media.swift).
    @ObservationIgnored internal let mediaResolver = MediaResolver()
    @ObservationIgnored private var mainProcess: ZaloMainProcess?
    @ObservationIgnored private var platform: ZaloPlatform?
    @ObservationIgnored private var loginTimeout: Task<Void, Never>?
    @ObservationIgnored private var runtimeInstall: Task<Void, Never>?
    @ObservationIgnored private var snapshotSaveTask: Task<Void, Never>?

    var isDebugRendererVisible = false {
        didSet { if isDebugRendererVisible { host?.showDebugWindow() } }
    }

    // MARK: Lifecycle

    func start() {
        guard host == nil, runtimeInstall == nil else { return }
        ZaloRuntime.prepareForLaunch()
        guard ZaloRuntime.isComplete(ZaloRuntime.current), let install = try? OfficialZaloInstall.locate() else {
            installRuntime()
            return
        }
        boot(install)
        upgradeRuntimeIfOutdated(installed: install.version)
    }

    /// After a failed runtime install.
    func retryRuntimeSetup() {
        guard case .preparing(let setup) = phase, setup.failure != nil else { return }
        installRuntime()
    }

    /// First launch: puts the official Zalo code into `ZaloRuntime.current`, then boots from it.
    private func installRuntime() {
        phase = .preparing(RuntimeSetup())
        let installer = ZaloRuntimeInstaller { [weak self] step in
            // In order, and never over a later step or a failure.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, case .preparing(var setup) = self.phase, setup.failure == nil else { return }
                    setup.step = step
                    self.phase = .preparing(setup)
                }
            }
        }
        runtimeInstall = Task { [weak self] in
            let result: Result<OfficialZaloInstall.Info, Error>
            do {
                let version = try await installer.install(into: ZaloRuntime.current)
                EngineLog.shared.write("runtime: installed Zalo \(version)")
                result = .success(try OfficialZaloInstall.locate())
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.runtimeInstall = nil
            switch result {
            case .success(let install):
                self.boot(install)
            case .failure(let error):
                EngineLog.shared.write("runtime: install failed — \(error.localizedDescription)")
                guard case .preparing(var setup) = self.phase else { return }
                setup.failure = error.localizedDescription
                self.phase = .preparing(setup)
            }
        }
    }

    /// A runtime older than the Zalo version this build pins is upgraded quietly; the new one is used from the next launch.
    private func upgradeRuntimeIfOutdated(installed: String) {
        let pinned = ZaloRuntime.pinned.version
        guard ZaloRuntime.isNewer(pinned, than: installed) else { return }
        Task(priority: .utility) {
            do {
                let version = try await ZaloRuntimeInstaller(allowsLatest: false).install(into: ZaloRuntime.pending)
                EngineLog.shared.write("runtime: Zalo \(version) ready, used from the next launch (now \(installed))")
            } catch {
                EngineLog.shared.write("runtime: upgrade to Zalo \(pinned) failed — \(error.localizedDescription)")
            }
        }
    }

    private func boot(_ install: OfficialZaloInstall.Info) {
        // Chromium-fingerprint network stack: ready before the renderer's first requests.
        FingerprintProxy.shared.warmUp()
        clientVersion = install.version
        // Everything that talks to Zalo (User-Agent, page query, media fetches) reports the
        // runtime's own API version, exactly as the official main process of that build would.
        ClientFingerprint.clientVersion = install.clientVersion

        let platform = ZaloPlatform(appVersion: install.version, clientVersion: install.clientVersion)
        let mainProcess = ZaloMainProcess(platform: platform)
        let ua = OfficialClientHost.userAgent(clientType: platform.identity.clientType,
                                              clientVersion: platform.identity.clientVersion)
        let host = OfficialClientHost(install: install, userAgent: ua) { bridge in
            BridgeImplementation.install(on: bridge, platform: platform, mainProcess: mainProcess)
        }
        mainProcess.host = host
        mainProcess.onEvent = { [weak self] event in self?.handle(event) }
        installCallHooks(mainProcess)
        host.onPageEvent = { [weak self] event in self?.handle(event) }
        host.onState = { [weak self] state in self?.handle(state: state) }
        let log = EngineLog.shared
        MediaDiagnostics.setSink { line in Task { @MainActor in EngineLog.shared.write(line) } }
        log.write("engine start — Zalo \(install.version), session cookie: \(mainProcess.hasSession)")
        host.onConsole = { [weak self] line in
            self?.log(line)
            // Official `log`/`info` lines can carry message payloads: only warnings, errors and
            // Olaz's own adapter diagnostics reach the on-disk log, truncated.
            let official = line.hasPrefix("[log]") || line.hasPrefix("[info]")
            if !official || line.contains("[adapter]") || line.contains("[chat]") || line.contains("[transfer]") || line.contains("[zcloud]") {
                log.write("console " + String(line.prefix(300)))
            }
        }
        host.bridge.trace = { key, args in
            guard !key.contains("ZLog"), !key.hasPrefix("$zelectron.store"), !key.hasPrefix("$znode.sqliteHost") else { return }
            log.write("bridge \(key)\(EngineLog.shape(args))")
        }
        host.bridge.onHandlerError = { key, error in log.write("bridge-error \(key): \(error.localizedDescription)") }
        host.network.onRequestCompleted = { method, url, status in
            log.write("net \(status) \(method) \(url.host() ?? "")\(url.path())")
        }
        host.network.socketTrace = { log.write($0) }
        host.network.responseObserver = { [weak self] url, status, body in
            self?.observe(url: url, status: status, body: body)
        }

        self.platform = platform
        self.mainProcess = mainProcess
        self.host = host
        startDevEvalIfEnabled()
        if mainProcess.hasSession {
            restoreConversationSnapshot()
        }
        let hasInstantUI = !conversations.isEmpty && conversationActions.hiddenKnown
        phase = mainProcess.hasSession ? (hasInstantUI ? .ready : .signingIn) : .login(LoginState())
        mainProcess.start()
    }

    /// Fresh QR (the official page regenerates on load).
    func refreshQR() {
        loginTimeout?.cancel()
        guard let host, let mainProcess else { return }
        phase = .login(LoginState())
        host.load(.login, query: mainProcess.pageQuery())
    }

    /// Where the official client keeps its databases (Settings ▸ Engine).
    var storageBackend: ZaloMainProcess.StorageBackend? { mainProcess?.storage }

    /// Moves this install to the native SQLite backend: the account is logged out and starts over on SQLite at the
    /// next login (history comes back with the phone → PC sync).
    func switchToSQLite() {
        mainProcess?.switchStorage(.sqlite)
        logOut()
    }

    /// Clears the session cookies and local client data, then shows a fresh QR.
    func logOut() {
        ZaloMainProcess.clearCookies()
        mainProcess?.resetAccountState()
        if let platform {
            ConversationSnapshotStore.clear(platform: platform)
        }
        profile = nil
        conversations = []
        conversationIndex = [:]
        conversationsById = [:]
        resetConversationActions()
        resetCloud()
        resetPolls()
        resetStickers()
        resetComposer()
        resetMessageActions()
        failedDrafts = FailedDraftStore()   // unsent text of the previous account must not show up in the next one
        refreshQR()
    }

    // MARK: Events from the runtime

    internal func handle(_ event: ZaloMainProcess.Event) {
        EngineLog.shared.write("main-process \(event)")
        switch event {
        case .loginSucceeded:
            loginTimeout?.cancel()
            signOutNotice = nil
            // If the instant snapshot already transitioned the engine to .ready,
            // preserve .ready so RootView does not flap back to SplashView and cause an unnecessary reload.
            if case .ready = phase {
                EngineLog.shared.write("loginSucceeded: preserving .ready phase for instant cold-start UI")
                refreshCloud()
                break
            }
            phase = .signingIn
        case .loggedOut:
            hasCompletedInitialLiveSync = false
            profile = nil
            CardActionCenter.shared.reset()
            resetCardState()
            resetConversationActions()
            resetCloud()
            resetPolls()
            resetStickers()
            resetComposer()
            resetMessageActions()
            failedDrafts = FailedDraftStore()
            phase = .login(LoginState())
        case .badge:
            break
        }
    }

    private func handle(_ event: OfficialClientHost.PageEvent) {
        EngineLog.shared.write("page \(event)")
        switch event {
        case .startedLoading:
            mainProcess?.pageDidStartLoading()
            // The page that asked is gone: its confirms can no longer be answered.
            dropComposerConfirms()
        case .finishedLoading(let page):
            mainProcess?.pageDidFinishLoading(page)
            if page == .main { rewatchPolls(); republishConversationActions(); rewatchPins(); refreshCloud() }
            if page == .main, case .signingIn = phase {
                // The main client is up; conversations stream in as it syncs.
                phase = .ready
                refreshCloud()
            }
        case .failed(let error):
            log("[navigation] \(error.localizedDescription)")
        }
    }

    private func handle(state: [String: Any]) {
        EngineLog.shared.write("state page=\(state["page"] ?? "-") event=\(state["event"] ?? "-") keys=\(state.keys.sorted())")
        switch state["page"] as? String {
        case "login":
            applyLoginState(state)
        case "main" where state["convActions"] != nil:
            handleConversationActions(state: state)
            scheduleSnapshotSave()
        case "main" where state["conversationExtras"] != nil:
            handleConversationExtras(state: state)
            scheduleSnapshotSave()
        case "main" where state["zcloud"] != nil:
            handleCloud(state: state)
        case "main" where state["poll"] != nil:
            handlePoll(state: state)
        case "main" where state["compose"] != nil:
            handleCompose(state: state)
        case "main" where state["pins"] != nil:
            handlePins(state: state)
        case "main" where state["contacts"] != nil:
            handleContacts(state: state)
        case "main" where state["notification"] != nil:
            handleNotification(state: state)
        case "main" where state["call"] != nil:
            handleCall(state: state)
        case "main" where state["transfer"] != nil:
            handleTransfer(state: state)
        case "main" where state["transferAvailable"] != nil:
            handleTransferAvailability(state: state)
        case "main" where state["chat"] != nil || state["typing"] != nil:
            handleChat(state: state)
        case "main" where state["conversations"] != nil:
            mergeConversations(state)
            scheduleSnapshotSave()
        case "main":
            if let user = state["user"] as? [String: Any], let id = user["userId"] as? String, !id.isEmpty {
                profile = Profile(
                    userId: id,
                    displayName: user["displayName"] as? String ?? user["zaloName"] as? String ?? "",
                    avatar: (user["avatar"] as? String).flatMap(URL.init(string:)),
                    phone: user["phoneNumber"] as? String
                )
                scheduleSnapshotSave()
            }
        default:
            break
        }
    }

    /// Applies login state events from `state-adapter.js` (`genFirstQR`/`genSecondQR` hooks and DOM snapshots).
    internal func applyLoginState(_ state: [String: Any]) {
        guard case .login(var login) = phase else { return }
        let event = state["event"] as? String
        let isInvalid = (state["invalid"] as? NSNumber)?.boolValue ?? (state["invalid"] as? Bool) ?? false

        if event == "qr" || event == "qr2" {
            if let qr = state["qr"] as? String, let png = Self.decodeDataURL(qr) {
                login.qrPNG = png
                login.step = .waitingScan
                phase = .login(login)
                scheduleExpiry()
            }
            return
        }

        if let name = (state["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            loginTimeout?.cancel()
            let avatar = (state["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            login.step = .waitingConfirm(name: name, avatar: avatar)
            phase = .login(login)
            return
        }

        if isInvalid {
            loginTimeout?.cancel()
            if login.qrPNG != nil {
                login.step = .expired
            } else {
                login.step = .failed("Mã QR đã hết hạn.")
            }
            phase = .login(login)
            return
        }

        if let qr = state["qr"] as? String, let png = Self.decodeDataURL(qr) {
            let isNewQR = login.qrPNG != png
            login.qrPNG = png
            switch login.step {
            case .generating:
                login.step = .waitingScan
                scheduleExpiry()
            case .expired, .failed, .waitingConfirm where isNewQR:
                login.step = .waitingScan
                scheduleExpiry()
            case .waitingScan where isNewQR:
                scheduleExpiry()
            default:
                break
            }
            phase = .login(login)
        }
    }

    /// The QR login long-polls (`qr-id.zaloapp.com/polling/qr/*`) pass through
    /// Swift's proxy; the official client handles them, we just mirror progress.
    internal func observe(url: URL, status: Int, body: Data) {
        if url.path().hasSuffix("/api/session/kickout-info") {
            // The server signed this session out — Zalo allows one desktop (PC) session per account.
            EngineLog.shared.write("session kicked by server")
            signOutNotice = "Tài khoản của bạn vừa đăng nhập trên một Zalo PC khác, nên phiên này đã bị đăng xuất. Zalo chỉ cho phép một phiên máy tính cho mỗi tài khoản."
            return
        }
        guard url.host()?.hasPrefix("qr-id.") == true, case .login(var login) = phase else { return }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        let data = json["data"] as? [String: Any] ?? json
        let code = (json["error_code"] as? NSNumber)?.intValue ?? 0
        EngineLog.shared.write("qr-poll \(url.path()) error_code=\(code) data.keys=\(data.keys.sorted())")
        // -20 is not an error: the first scan succeeded, but this account logs in with a second QR (device linking,
        // "multi layer QR login mode"). The official poller turns `data` into QR2 via `genSecondQR` and keeps waiting
        // for a scan; the page adapter forwards it as `event: "qr2"`. Its `error_message` ("Vui lòng thử lại QR mới.")
        // must not be shown as a failure.
        if code == Self.secondQRRequiredCode {
            login.isSecondQR = true
            if let base64 = data["base64_qr"] as? String, !base64.isEmpty,
               let png = Self.decodeDataURL(base64.hasPrefix("data:") ? base64 : "data:image/png;base64,\(base64)") {
                login.qrPNG = png
            }
            login.step = .waitingScan
            phase = .login(login)
            scheduleExpiry()
            return
        }
        if code == 0, let name = data["display_name"] as? String, !name.isEmpty {
            loginTimeout?.cancel()
            login.step = .waitingConfirm(name: name, avatar: (data["avatar"] as? String).flatMap(URL.init(string:)))
            phase = .login(login)
        } else if code == 18010 || code == -21 {
            // 18010: mobile user rejected login; -21: QR2 relink failed.
            loginTimeout?.cancel()
            login.step = .expired
            phase = .login(login)
        }
        // Other non-zero codes on `qr-id.*` (e.g. 408 per-request long-poll tick timeout) are retried
        // automatically by the official client's `Dr(url, qrTimeout, qrRetry)` loop; never clobber UI here.
    }

    /// `qr-id` poll result meaning "scanned once; show the second (device-linking) QR" — see `Dr`/`genSecondQR` in the
    /// official `login-startup` chunk.
    static let secondQRRequiredCode = -20

    /// The server sets `qr_timeout`; mirror the official page's expiry UI as a fallback if DOM `invalid` has not fired yet (~150 s).
    private func scheduleExpiry() {
        loginTimeout?.cancel()
        loginTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(150))
            guard !Task.isCancelled, let self, case .login(var login) = self.phase,
                  case .waitingScan = login.step else { return }
            login.step = .expired
            self.phase = .login(login)
        }
    }

    // MARK: Developer evaluation channel (off unless `defaults write app.olaz.mac OlazDevEval -bool YES`)

    /// Runs `<data>/dev/eval.js` in the renderer whenever it changes and writes the
    /// JSON result to `eval.out.json`. Used to map the official client's services.
    private func startDevEvalIfEnabled() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "OlazDevEval") else { return }
        let dir = ZaloPlatform.defaultUserData.deletingLastPathComponent().appendingPathComponent("dev", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("eval.js"), output = dir.appendingPathComponent("eval.out.json")
        Task { [weak self] in
            var lastModified = Date.distantPast
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                // Dev aid: `<data>/dev/open-conv.txt` holding a conversation id opens it in the UI (once).
                let openFile = dir.appendingPathComponent("open-conv.txt")
                if let id = try? String(contentsOf: openFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                    try? FileManager.default.removeItem(at: openFile)
                    self.navigationRequest = id
                }
                // Dev aid: `<data>/dev/compose.json` {"method", "args", "files"} runs one composer action with those files as the
                // pick (once); the outcome goes to `compose.out.txt`.
                let composeFile = dir.appendingPathComponent("compose.json")
                if let data = try? Data(contentsOf: composeFile),
                   let job = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let method = job["method"] as? String {
                    try? FileManager.default.removeItem(at: composeFile)
                    let files = (job["files"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
                    let outcome = await self.devCompose(method, job["args"] as? [Any] ?? [], files: files)
                    try? outcome.write(to: dir.appendingPathComponent("compose.out.txt"), atomically: true, encoding: .utf8)
                }
                guard let date = (try? FileManager.default.attributesOfItem(atPath: input.path))?[.modificationDate] as? Date,
                      date > lastModified, let source = try? String(contentsOf: input, encoding: .utf8) else { continue }
                lastModified = date
                let wrapped = "try { const __r = await (async () => { \(source) })(); return JSON.stringify({ok: true, value: __r}, (k, v) => typeof v === 'bigint' ? String(v) : v, 1); } catch (e) { return JSON.stringify({ok: false, error: String(e && e.stack || e)}); }"
                let result = await self.host?.evaluate(wrapped) as? String ?? "{\"ok\":false,\"error\":\"no result\"}"
                try? result.write(to: output, atomically: true, encoding: .utf8)
            }
        }
        #endif
    }

    private func log(_ line: String) {
        recentLog.append(line)
        if recentLog.count > 200 { recentLog.removeFirst(recentLog.count - 200) }
    }

    /// The conversation list arrives as deltas (state-adapter.js): `conversations` holds the rows that changed since the
    /// last post, `removed` the ids that left the official index, `reset` (or the legacy full-list shape without it) replaces
    /// the whole list. A large account has thousands of rows and some preview changes every tick: merging by id keeps the
    /// bridge payload and the SwiftUI invalidation proportional to what changed.
    internal func mergeConversations(_ state: [String: Any]) {
        let rows = (state["conversations"] as? [[String: Any]] ?? []).compactMap(Self.conversation)
        let reset = state["reset"] as? Bool ?? (state["removed"] == nil)
        let removed = state["removed"] as? [String] ?? []
        // Non-destructive merge: if WebKit sends reset: true but rows is only a partial chunk while the engine holds cached
        // conversations from snapshot, do not wipe the index!
        let shouldReset = reset && !rows.isEmpty && (conversationIndex.isEmpty || rows.count >= conversationIndex.count)
        if reset && !shouldReset && !conversationIndex.isEmpty {
            EngineLog.shared.write("mergeConversations: ignored partial reset (\(rows.count) rows) while holding \(conversationIndex.count) cached conversations; merging non-destructively")
        }
        var index = shouldReset ? [:] : conversationIndex
        for id in removed { index.removeValue(forKey: id) }
        for row in rows { index[row.id] = row }
        guard shouldReset || index != conversationIndex else { return }
        conversationIndex = index
        let sorted = index.values.sorted(by: Self.listOrder)
        var transaction = Transaction(animation: nil)
        if !hasCompletedInitialLiveSync { transaction.disablesAnimations = true }
        withTransaction(transaction) {
            if sorted != conversations { conversations = sorted }
            conversationsById = index
        }
    }

    private static func conversation(_ row: [String: Any]) -> ConversationSummary? {
        guard let id = row["id"] as? String else { return nil }
        let preview = (row["preview"] as? [String: Any]).map { p -> ConversationSummary.Preview in
            let ts = (p["ts"] as? NSNumber)?.doubleValue ?? 0
            return .init(text: p["text"] as? String ?? "",
                         date: ts > 0 ? Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts) : nil,
                         fromMe: (p["fromMe"] as? NSNumber)?.boolValue ?? false)
        }
        return ConversationSummary(
            id: id,
            isGroup: (row["isGroup"] as? NSNumber)?.boolValue ?? false,
            name: row["name"] as? String ?? "",
            avatar: (row["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
            pinned: (row["pinned"] as? NSNumber)?.boolValue ?? false,
            members: (row["members"] as? NSNumber)?.intValue ?? 0,
            unread: (row["unread"] as? NSNumber)?.intValue ?? 0,
            preview: preview
        )
    }

    /// Pinned first, then most recent activity, then name.
    private static func listOrder(_ a: ConversationSummary, _ b: ConversationSummary) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        let da = a.preview?.date ?? .distantPast, db = b.preview?.date ?? .distantPast
        if da != db { return da > db }
        return a.displayName.localizedCompare(b.displayName) == .orderedAscending
    }

    // MARK: Instant Cold-Start Snapshot

    func scheduleSnapshotSave() {
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, let platform = self.platform else { return }
            guard !self.conversations.isEmpty, self.conversationActions.hiddenKnown else { return }
            var flagBits: [String: Int] = [:]
            for (id, flags) in self.conversationActions.flags {
                if flags.rawValue != 0 { flagBits[id] = flags.rawValue }
            }
            var leftStrings: [String: String] = [:]
            for (id, leave) in self.conversationActions.left {
                leftStrings[id] = leave.rawValue
            }
            let snapshot = ConversationSnapshot(
                version: ConversationSnapshot.currentVersion,
                userId: self.profile?.userId,
                timestamp: Date(),
                conversations: Array(self.conversations.prefix(300)),
                hiddenIds: Array(self.conversationActions.hiddenIds),
                flags: flagBits,
                left: leftStrings,
                hiddenEnabled: self.conversationActions.hiddenEnabled,
                hasHiddenPIN: self.conversationActions.hasHiddenPIN,
                markUnreadEnabled: self.conversationActions.markUnreadEnabled,
                selfConversationId: self.selfConversationId,
                displayName: self.profile?.displayName,
                avatar: self.profile?.avatar,
                archivedEnabled: self.conversationExtras.archivedEnabled,
                listIds: self.conversationExtras.listIds,
                strangerIds: Array(self.conversationExtras.strangerIds),
                strangerFolderIds: self.conversationExtras.strangerFolderIds,
                cloudPlan: self.cloud.plan
            )
            ConversationSnapshotStore.save(snapshot, platform: platform)
        }
    }

    internal func restoreConversationSnapshot(platform: ZaloPlatform? = nil) {
        let p = platform ?? self.platform
        guard let p else { return }
        guard let snapshot = ConversationSnapshotStore.load(platform: p) else { return }
        if let currentUid = profile?.userId, let snapUid = snapshot.userId, currentUid != snapUid {
            return
        }
        // 1. Restore hidden state and flags first so protected chats never leak to UI
        conversationActions.restore(from: snapshot)
        // 2. Restore conversations & index
        var index: [String: ConversationSummary] = [:]
        for c in snapshot.conversations { index[c.id] = c }
        conversationIndex = index
        conversationsById = index
        conversations = snapshot.conversations

        // 3. Restore self conversation ID & profile
        if let selfId = snapshot.selfConversationId, !selfId.isEmpty {
            selfConversationId = selfId
        }
        if let name = snapshot.displayName, !name.isEmpty {
            profile = Profile(userId: snapshot.userId ?? "", displayName: name, avatar: snapshot.avatar, phone: nil)
        }

        // 4. Restore extras (archivedEnabled, listIds, strangerFolderIds)
        if snapshot.archivedEnabled || !snapshot.listIds.isEmpty {
            conversationExtras.archivedEnabled = snapshot.archivedEnabled
            conversationExtras.listIds = snapshot.listIds
            conversationExtras.strangerIds = Set(snapshot.strangerIds)
            conversationExtras.strangerFolderIds = snapshot.strangerFolderIds
            conversationExtras.loaded = true
        }

        // 5. Restore cloud plan for instant storage bar display
        if let plan = snapshot.cloudPlan {
            cloud.plan = plan
        }

        EngineLog.shared.write("snapshot: restored \(snapshot.conversations.count) conversations, \(snapshot.hiddenIds.count) hidden, \(snapshot.flags.count) flags, archived=\(snapshot.archivedEnabled), listIds=\(snapshot.listIds.count)")
    }

    static func decodeDataURL(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[..<comma].lowercased()
        let payload = String(url[url.index(after: comma)...])
        guard !payload.isEmpty else { return nil }
        let data: Data?
        if header.contains(";base64") {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            let decoded = payload.removingPercentEncoding ?? payload
            data = decoded.data(using: .utf8)
        }
        guard let data, !data.isEmpty else { return nil }
        // Reject the 42x42 loading spinner SVG (`Pe` in login.html) so it is never mistaken for a QR code.
        if header.contains("svg"), let svg = String(data: data, encoding: .utf8),
           svg.contains("animateTransform") || svg.contains("viewBox=\"0 0 42 42\"") {
            return nil
        }
        return data
    }
}
