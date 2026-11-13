import SwiftUI
import AppKit
@preconcurrency import VisionKit

/// What the media viewer shows: a chat photo (loaded through `RemoteImage`, official resolver fallback and E2EE included)
/// or a video (already on disk or resolved on demand when browsing the gallery), plus who sent it and when.
struct MediaViewerItem: Identifiable, Equatable {
    enum Media: Equatable {
        case photo(url: URL?, width: Int, height: Int, encrypted: Bool)
        /// `size` is the display size when known; it only sizes the window.
        case video(file: URL, size: CGSize?)
        /// A video in a gallery whose playable file will be resolved on demand when navigated to.
        case remoteVideo(url: URL?, thumbnail: URL?, duration: Int, encrypted: Bool)
    }

    let id = UUID()
    var media: Media
    var conversationId: String
    var messageId: String
    var senderName: String
    var date: Date

    /// Pixel size of the media when known (the window takes its aspect ratio).
    var mediaSize: CGSize? {
        switch media {
        case .photo(_, let width, let height, _):
            width > 0 && height > 0 ? CGSize(width: width, height: height) : nil
        case .video(_, let size):
            size
        case .remoteVideo:
            nil
        }
    }

    var isPhoto: Bool {
        if case .photo = media { return true }
        return false
    }

    /// Window title (Window menu, VoiceOver): the sender, or the kind of media when the sender is unknown.
    var windowTitle: String {
        senderName.isEmpty ? (isPhoto ? "Ảnh" : "Video") : senderName
    }

    static func from(message: ChatMessage, conversationId: String) -> MediaViewerItem? {
        guard SharedMediaList.qualifies(message, .images) else { return nil }
        let sender = message.isMine ? "Bạn" : message.senderName
        switch message.kind {
        case .photo(let url, let width, let height):
            guard url != nil else { return nil }
            let encrypted = message.isE2EE || url?.query?.contains("e2esession") == true
            return MediaViewerItem(
                media: .photo(url: url, width: width, height: height, encrypted: encrypted),
                conversationId: conversationId,
                messageId: message.id,
                senderName: sender,
                date: message.date
            )
        case .video(let thumbnail, let duration, let url):
            guard url != nil else { return nil }
            let encrypted = message.isE2EE || url?.query?.contains("e2esession") == true
            return MediaViewerItem(
                media: .remoteVideo(url: url, thumbnail: thumbnail, duration: duration, encrypted: encrypted),
                conversationId: conversationId,
                messageId: message.id,
                senderName: sender,
                date: message.date
            )
        default:
            return nil
        }
    }

    static func gallery(from messages: [ChatMessage], conversationId: String, current: MediaViewerItem) -> (items: [MediaViewerItem], index: Int) {
        var list = messages.compactMap { Self.from(message: $0, conversationId: conversationId) }
        if let idx = list.firstIndex(where: { $0.messageId == current.messageId }) {
            list[idx] = current
            return (list, idx)
        }
        return ([current], 0)
    }
}

/// How big the viewer window opens: as large as the media's aspect ratio allows inside most of the screen.
enum MediaViewerLayout {
    /// Share of the screen's visible area the window may take.
    static let screenShare: CGFloat = 0.85
    static let minimumContent = CGSize(width: 720, height: 520)
    /// Share of the screen for media of unknown size.
    static let unknownShare: CGFloat = 0.7
    /// Band above a photo for the traffic lights and the top bar, which stays up (a video's bars fade over the picture).
    static let photoTopBar: CGFloat = 52

    /// `topInset`: the band above the media, added to the window so the media itself still gets the aspect-fit size.
    static func contentSize(media: CGSize?, available: CGSize, topInset: CGFloat = 0) -> CGSize {
        var size: CGSize
        if let media, media.width > 0, media.height > 0 {
            let scale = min(available.width * screenShare / media.width,
                            (available.height * screenShare - topInset) / media.height)
            size = CGSize(width: media.width * scale, height: media.height * scale + topInset)
        } else {
            size = CGSize(width: available.width * unknownShare, height: available.height * unknownShare)
        }
        // A thin strip or tiny clip still gets a usable window (letterboxed), but never one bigger than the screen.
        size.width = min(max(size.width, minimumContent.width), available.width)
        size.height = min(max(size.height, minimumContent.height), available.height)
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }
}

/// The one viewer window. Titled like a document window, but its content runs under the transparent titlebar.
final class MediaViewerWindow: NSWindow {
    init(contentSize: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        titlebarSeparatorStyle = .none
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = NSColor(white: 0.04, alpha: 1)
        isRestorable = false
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        collectionBehavior = [.fullScreenPrimary]
        contentMinSize = NSSize(width: 480, height: 320)
    }

    override func cancelOperation(_ sender: Any?) {
        MediaViewer.shared.escape()
    }
}

/// Where the top bar sits: right of the traffic lights and level with them (read from the real buttons, because their
/// position differs between macOS versions and full screen has none).
struct ViewerTitlebar: Equatable {
    var leading: CGFloat = 84
    var centerY: CGFloat = 22
}

/// What the viewer window currently shows. One instance lives as long as the app; `present` swaps the item or gallery.
@MainActor
@Observable
final class MediaViewerState {
    struct OCRFeedback: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case success, empty, failed }
        let seq: Int
        let kind: Kind
        let text: String
    }

    private(set) var items: [MediaViewerItem] = []
    private(set) var currentIndex: Int = 0
    private(set) var item: MediaViewerItem?
    private(set) var zoom = ZoomController()
    private(set) var playback: VideoPlayback?
    private(set) var isLoadingVideo = false
    private(set) var videoLoadFailed = false
    private(set) var isOCREnabled = false
    private(set) var isAnalyzingOCR = false
    private(set) var isCopyingOCR = false
    private(set) var ocrAnalysis: ImageAnalysis?
    private(set) var ocrFeedback: OCRFeedback?
    var isFullScreen = false
    var titlebar = ViewerTitlebar()
    @ObservationIgnored private var videoResolveTask: Task<Void, Never>?
    @ObservationIgnored private var ocrTask: Task<Void, Never>?
    @ObservationIgnored private var copyOCRTask: Task<Void, Never>?
    @ObservationIgnored private var ocrFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var ocrFeedbackSeq = 0
    @ObservationIgnored weak var engine: ZaloEngine?

    var hasMultipleItems: Bool { items.count > 1 }
    var canGoPrevious: Bool { currentIndex > 0 }
    var canGoNext: Bool { currentIndex + 1 < items.count }
    var positionText: String? {
        items.count > 1 ? "\(currentIndex + 1) / \(items.count)" : nil
    }

    func present(_ item: MediaViewerItem, gallery: [MediaViewerItem] = [], index: Int = 0, engine: ZaloEngine? = nil) {
        self.engine = engine
        if gallery.isEmpty {
            self.items = [item]
            self.currentIndex = 0
        } else {
            self.items = gallery
            self.currentIndex = min(max(index, 0), gallery.count - 1)
        }
        activateCurrentItem(forceRetry: false)
    }

    @discardableResult
    func goPrevious() -> Bool {
        guard canGoPrevious else { return false }
        currentIndex -= 1
        activateCurrentItem(forceRetry: false)
        return true
    }

    @discardableResult
    func goNext() -> Bool {
        guard canGoNext else { return false }
        currentIndex += 1
        activateCurrentItem(forceRetry: false)
        return true
    }

    func retryCurrentVideo() {
        activateCurrentItem(forceRetry: true)
    }

    private func activateCurrentItem(forceRetry: Bool) {
        videoResolveTask?.cancel()
        videoResolveTask = nil
        resetOCRState()
        playback?.stop()
        playback = nil
        isLoadingVideo = false
        videoLoadFailed = false
        guard items.indices.contains(currentIndex) else {
            item = nil
            return
        }
        let current = items[currentIndex]
        self.item = current
        zoom = ZoomController()
        switch current.media {
        case .photo:
            break
        case .video(let file, _):
            playback = VideoPlayback(url: file)
        case .remoteVideo(let url, _, _, let encrypted):
            guard let url, let engine else {
                videoLoadFailed = true
                return
            }
            isLoadingVideo = true
            let targetIndex = currentIndex
            let messageId = current.messageId
            let conversationId = current.conversationId
            videoResolveTask = Task { [weak self] in
                do {
                    let playable = try await VideoThumb.resolvePlayableVideo(
                        url: url, encrypted: encrypted,
                        conversationId: conversationId, messageId: messageId,
                        retry: forceRetry, engine: engine
                    )
                    try Task.checkCancellation()
                    let natural = await VideoPlayback.naturalSize(of: playable)
                    try Task.checkCancellation()
                    guard let self, self.currentIndex == targetIndex,
                          self.items.indices.contains(targetIndex),
                          self.items[targetIndex].messageId == messageId else { return }
                    self.isLoadingVideo = false
                    self.items[targetIndex].media = .video(file: playable, size: natural)
                    self.item = self.items[targetIndex]
                    self.playback = VideoPlayback(url: playable)
                } catch {
                    guard let self, self.currentIndex == targetIndex else { return }
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        return
                    }
                    self.isLoadingVideo = false
                    self.videoLoadFailed = true
                }
            }
        }
    }

    /// Stops the player and lets go of the item (so the full-resolution image and the video are freed).
    func clear() {
        videoResolveTask?.cancel()
        videoResolveTask = nil
        resetOCRState()
        playback?.stop()
        playback = nil
        isLoadingVideo = false
        videoLoadFailed = false
        items = []
        currentIndex = 0
        item = nil
    }

    // MARK: OCR

    func toggleOCR() {
        guard item?.isPhoto == true else { return }
        if isOCREnabled {
            isOCREnabled = false
            ocrTask?.cancel()
            ocrTask = nil
            isAnalyzingOCR = false
            ocrAnalysis = nil
            return
        }
        guard ImageOCRService.isLiveTextSupported else {
            showOCRFeedback(.failed, "Live Text không khả dụng trên máy này")
            return
        }
        isOCREnabled = true
        analyzeCurrentImageIfNeeded()
    }

    func analyzeCurrentImageIfNeeded() {
        guard isOCREnabled,
              item?.isPhoto == true,
              ocrAnalysis == nil,
              !isAnalyzingOCR,
              let image = zoom.currentImage else { return }
        guard !isConversationBlocked() else {
            clear()
            return
        }
        let targetItemId = item?.id
        ocrTask?.cancel()
        isAnalyzingOCR = true
        ocrTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAnalyzingOCR = false }
            do {
                let analysis = try await ImageOCRService.analyzeLiveText(in: image)
                guard !Task.isCancelled, self.item?.id == targetItemId, self.isOCREnabled else { return }
                guard !self.isConversationBlocked() else {
                    self.clear()
                    return
                }
                self.ocrAnalysis = analysis
                if !analysis.hasResults(for: .text) && !analysis.hasResults(for: .machineReadableCode) {
                    self.showOCRFeedback(.empty, "Không tìm thấy chữ trong ảnh")
                }
            } catch {
                guard !Task.isCancelled, self.item?.id == targetItemId else { return }
                self.showOCRFeedback(.failed, "Không quét được chữ trong ảnh")
            }
        }
    }

    func copyRecognizedText() {
        guard !isCopyingOCR else { return }
        copyOCRTask?.cancel()
        copyOCRTask = Task { @MainActor [weak self] in
            await self?.performCopyRecognizedText()
        }
    }

    @discardableResult
    func performCopyRecognizedText(from explicitImage: NSImage? = nil, pasteboard: NSPasteboard = .general) async -> OCRTextResult? {
        guard item?.isPhoto == true, let image = explicitImage ?? zoom.currentImage else { return nil }
        guard !isConversationBlocked() else {
            clear()
            return nil
        }
        let targetItemId = item?.id
        isCopyingOCR = true
        defer { isCopyingOCR = false }
        do {
            let result = try await ImageOCRService.recognizeText(in: image)
            guard !Task.isCancelled, item?.id == targetItemId else { return nil }
            guard !isConversationBlocked() else {
                clear()
                return nil
            }
            if result.isEmpty {
                showOCRFeedback(.empty, "Không tìm thấy chữ trong ảnh")
                return result
            }
            pasteboard.clearContents()
            pasteboard.setString(result.recognizedText, forType: .string)
            showOCRFeedback(.success, "Đã sao chép chữ")
            return result
        } catch {
            guard !Task.isCancelled, item?.id == targetItemId else { return nil }
            showOCRFeedback(.failed, "Không nhận diện được chữ")
            return nil
        }
    }

    private func isConversationBlocked() -> Bool {
        if let engine, let currentItem = item {
            return MediaViewer.mustClose(conversationId: currentItem.conversationId, engine: engine)
        }
        return false
    }

    private func showOCRFeedback(_ kind: OCRFeedback.Kind, _ text: String) {
        ocrFeedbackSeq += 1
        let feedback = OCRFeedback(seq: ocrFeedbackSeq, kind: kind, text: text)
        ocrFeedback = feedback
        ocrFeedbackTask?.cancel()
        ocrFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled, let self, self.ocrFeedback == feedback else { return }
            self.ocrFeedback = nil
        }
    }

    private func resetOCRState() {
        ocrTask?.cancel()
        ocrTask = nil
        copyOCRTask?.cancel()
        copyOCRTask = nil
        ocrFeedbackTask?.cancel()
        ocrFeedbackTask = nil
        isOCREnabled = false
        isAnalyzingOCR = false
        isCopyingOCR = false
        ocrAnalysis = nil
        ocrFeedback = nil
    }
}

/// Quick Look-style viewer for chat photos and videos: one big reusable window that resizes to the media, with zoom for
/// photos, a full player (scrubber, volume) for videos, and left/right gallery navigation across the conversation.
///
/// Privacy: hidden (PIN-locked) chats exist, so the viewer closes itself the moment its conversation is locked, the
/// hidden-chat state is unknown, or the account signs out (see `MediaViewerContent`).
@MainActor
final class MediaViewer: NSObject, NSWindowDelegate {
    static let shared = MediaViewer()

    internal let state = MediaViewerState()
    private var window: MediaViewerWindow?
    private var hosting: NSHostingView<AnyView>?
    private var keyMonitor: Any?
    /// A swap that happened in full screen: the frame to take when leaving it.
    private var pendingFrame: NSRect?

    func show(_ item: MediaViewerItem, gallery: [ChatMessage]? = nil, engine: ZaloEngine, shell: ShellModel) {
        // Privacy: a locked hidden chat must never get as far as ordering the window front, not even for a frame.
        guard !MediaViewer.mustClose(conversationId: item.conversationId, engine: engine) else { return }
        let sourceMessages = gallery ?? (engine.messages[item.conversationId] ?? [])
        let resolvedGallery = MediaViewerItem.gallery(from: sourceMessages, conversationId: item.conversationId, current: item)

        let screen = (window?.isVisible == true ? window?.screen : nil) ?? NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let content = MediaViewerLayout.contentSize(media: item.mediaSize, available: available.size,
                                                    topInset: item.isPhoto ? MediaViewerLayout.photoTopBar : 0)
        let frame = NSRect(x: available.midX - content.width / 2, y: available.midY - content.height / 2,
                           width: content.width, height: content.height)

        let window = self.window ?? makeWindow(size: content)
        hosting?.rootView = AnyView(MediaViewerRoot(state: state, engine: engine, shell: shell))
        state.present(item, gallery: resolvedGallery.items, index: resolvedGallery.index, engine: engine)
        window.title = item.windowTitle

        if window.styleMask.contains(.fullScreen) {
            pendingFrame = frame
        } else {
            if window.isMiniaturized { window.deminiaturize(nil) }
            // Animated only when the window is already up; a fresh one just appears at its size.
            window.setFrame(frame, display: true, animate: window.isVisible)
        }
        installKeyMonitor()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        updateTitlebar()
    }

    @discardableResult
    func goPrevious() -> Bool {
        guard state.goPrevious(), let current = state.item else { return false }
        window?.title = current.windowTitle
        return true
    }

    @discardableResult
    func goNext() -> Bool {
        guard state.goNext(), let current = state.item else { return false }
        window?.title = current.windowTitle
        return true
    }

    func close() {
        window?.close()
    }

    /// The viewer may only stay open while its conversation is readable: not locked (hidden chat without its PIN), hidden
    /// chats known (any conversation could still turn out to be one), and an account signed in.
    nonisolated static func mustClose(locked: Bool, hiddenKnown: Bool, signedIn: Bool) -> Bool {
        locked || !hiddenKnown || !signedIn
    }

    static func mustClose(conversationId: String, engine: ZaloEngine) -> Bool {
        mustClose(locked: engine.isConversationLocked(conversationId),
                  hiddenKnown: engine.conversationActions.hiddenKnown,
                  signedIn: engine.profile != nil && !engine.phase.isLogin)
    }

    /// Esc: leaves full screen first, else closes.
    func escape() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { close() }
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    private func makeWindow(size: CGSize) -> MediaViewerWindow {
        let window = MediaViewerWindow(contentSize: size)
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        // The window decides its size (aspect-fit to the media); the SwiftUI content must not push back.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.delegate = self
        self.window = window
        self.hosting = hosting
        return window
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        pendingFrame = nil
        state.clear()
        state.isFullScreen = false
        // Drop the SwiftUI content too: the player and the decoded photo go with it.
        hosting?.rootView = AnyView(EmptyView())
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        state.isFullScreen = true
        updateTitlebar()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        state.isFullScreen = false
        if let pendingFrame, let window {
            window.setFrame(pendingFrame, display: true, animate: true)
        }
        pendingFrame = nil
        updateTitlebar()
    }

    func windowDidResize(_ notification: Notification) {
        updateTitlebar()
    }

    /// Reads where the traffic lights are so the top bar lines up with them.
    private func updateTitlebar() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            state.titlebar = ViewerTitlebar(leading: 20, centerY: 40)
            return
        }
        guard let button = window.standardWindowButton(.zoomButton), let container = button.superview else { return }
        let frame = container.convert(button.frame, to: nil)
        guard frame.width > 0, window.frame.height > 0 else { return }
        let metrics = ViewerTitlebar(leading: frame.maxX + 14, centerY: window.frame.height - frame.midY)
        if metrics != state.titlebar { state.titlebar = metrics }
    }

    // MARK: Keys

    /// A local monitor, because the key view is the scroll view or the player and both would take arrows and space.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window is MediaViewerWindow else { return event }
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// True when the key was ours.
    internal func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return handleKey(keyCode: event.keyCode, characters: key, modifiers: flags, isRepeat: event.isARepeat)
    }

    internal func handleKey(keyCode: UInt16, characters key: String, modifiers flags: NSEvent.ModifierFlags, isRepeat: Bool = false) -> Bool {
        guard let item = state.item else { return false }
        if flags.isEmpty {
            if keyCode == 53 { escape(); return true }
            if key == "f" {
                if !isRepeat { toggleFullScreen() }
                return true
            }
            if key == "o", item.isPhoto {
                if !isRepeat { state.toggleOCR() }
                return true
            }
            // Left / Right arrows navigate between gallery items when multiple items exist;
            // only fall back to ±5s video seek when viewing a single standalone video.
            if keyCode == 123 {
                if state.hasMultipleItems {
                    _ = goPrevious()
                    return true
                } else if let playback = state.playback {
                    playback.skip(by: -5)
                    return true
                }
                return false
            }
            if keyCode == 124 {
                if state.hasMultipleItems {
                    _ = goNext()
                    return true
                } else if let playback = state.playback {
                    playback.skip(by: 5)
                    return true
                }
                return false
            }
            guard let playback = state.playback else { return false }
            switch keyCode {
            case 49: if !isRepeat { playback.togglePlay() }
            case 126: playback.adjustVolume(by: 0.1)
            case 125: playback.adjustVolume(by: -0.1)
            default:
                if key == "j" { playback.skip(by: -5); return true }
                if key == "l" { playback.skip(by: 5); return true }
                guard key == "m" else { return false }
                if !isRepeat { playback.toggleMute() }
            }
            return true
        }
        // Option+Arrow or Shift+Arrow skips video by ±5s even inside a multi-item gallery.
        if flags == [.option] || flags == [.shift], let playback = state.playback {
            switch keyCode {
            case 123: playback.skip(by: -5); return true
            case 124: playback.skip(by: 5); return true
            default: break
            }
        }
        // Preview's zoom shortcuts (⌘+ comes as ⌘⇧= on most layouts).
        guard item.isPhoto, flags.contains(.command), flags.isSubset(of: [.command, .shift]) else { return false }
        switch key {
        case "+", "=": state.zoom.zoomIn()
        case "-", "_": state.zoom.zoomOut()
        case "0": state.zoom.actualSize()
        case "9": state.zoom.fit()
        default: return false
        }
        return true
    }
}

// MARK: - SwiftUI

/// Dark, tinted, Vietnamese root of the viewer window (the window itself is always dark, whatever the app's appearance).
private struct MediaViewerRoot: View {
    let state: MediaViewerState
    let engine: ZaloEngine
    let shell: ShellModel
    @AppStorage(OlazPrefs.accent) private var accent = OlazAccent.blue

    private var mustClose: Bool {
        state.item.map { MediaViewer.mustClose(conversationId: $0.conversationId, engine: engine) } ?? false
    }

    var body: some View {
        ZStack {
            Color(white: 0.04)
            // Privacy: while the chat is not readable nothing of it is rendered, not even for the frame before the window closes.
            if let item = state.item, !mustClose {
                MediaViewerContent(state: state, item: item).id(item.id)
            }
        }
        .onChange(of: mustClose, initial: true) { _, mustClose in
            if mustClose {
                state.clear()
                Task { @MainActor in MediaViewer.shared.close() }
            }
        }
        .ignoresSafeArea()
        .environment(engine)
        .environment(shell)
        .environment(\.locale, Locale(identifier: "vi_VN"))
        .environment(\.colorScheme, .dark)
        .tint(accent.color)
    }
}

private struct MediaViewerContent: View {
    let state: MediaViewerState
    let item: MediaViewerItem
    @Environment(ZaloEngine.self) private var engine

    /// The player's bars and the top bar fade together; photos keep the top bar.
    private var barsVisible: Bool { state.playback?.barsVisible ?? true }

    var body: some View {
        ZStack(alignment: .top) {
            media
            if state.hasMultipleItems {
                navigationButtons
            }
            WindowDragArea().frame(height: 36)
            topBar
        }
        .overlay(alignment: .bottom) {
            if let feedback = state.ocrFeedback {
                HStack(spacing: 8) {
                    switch feedback.kind {
                    case .success:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                    case .empty:
                        Image(systemName: "text.magnifyingglass").foregroundStyle(Color.secondary)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                    }
                    Text(feedback.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.snappy, value: state.ocrFeedback)
        .onChange(of: state.zoom.hasContent) { _, hasContent in
            if hasContent, state.isOCREnabled {
                state.analyzeCurrentImageIfNeeded()
            }
        }
    }

    // MARK: Media

    @ViewBuilder private var media: some View {
        switch item.media {
        case .photo(let url, _, _, let encrypted):
            RemoteImage(url: url, contentMode: .fit, maxPixelSize: 6144) { ProgressView().controlSize(.large) }
                // A full-size decode must not push the chat's thumbnails out of the shared cache; it lives as long as the viewer.
                .uncached()
                .resolvingWith(first: encrypted) { force in
                    await engine.resolveMedia(conversationId: item.conversationId, messageId: item.messageId, kind: .photo, force: force)
                }
                .onFailure { reason, retry in
                    MediaFailureView(failure: reason, retry: retry)
                        .frame(width: 340, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .rendering { image in
                    ZoomableImageView(
                        image: image,
                        zoom: state.zoom,
                        ocrEnabled: state.isOCREnabled,
                        ocrAnalysis: state.ocrAnalysis
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The top bar gets its own band instead of covering the top of the photo.
                .padding(.top, MediaViewerLayout.photoTopBar)
        case .video:
            if let playback = state.playback {
                VideoPlayerView(playback: playback, fullScreen: FullScreenControl(isOn: state.isFullScreen) {
                    MediaViewer.shared.toggleFullScreen()
                })
            }
        case .remoteVideo(_, let thumbnail, _, _):
            ZStack {
                if let thumbnail {
                    RemoteImage(url: thumbnail, contentMode: .fit, maxPixelSize: 1600) {
                        Color.clear
                    }
                    .resolvingWith { force in
                        await engine.resolveMedia(conversationId: item.conversationId, messageId: item.messageId, kind: .videoThumb, force: force)
                    }
                    .opacity(0.45)
                }
                if state.videoLoadFailed {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text(VideoPlayback.failureMessage)
                            .font(.system(size: 13, weight: .medium))
                        Button("Thử lại") { state.retryCurrentVideo() }
                            .buttonStyle(.glassProminent)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .padding(20)
                        .background(.regularMaterial, in: Circle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Gallery Navigation

    private var navigationButtons: some View {
        HStack {
            navButton(symbol: "chevron.left", label: "Ảnh/video trước (←)", enabled: state.canGoPrevious) {
                MediaViewer.shared.goPrevious()
            }
            Spacer(minLength: 0)
            navButton(symbol: "chevron.right", label: "Ảnh/video tiếp theo (→)", enabled: state.canGoNext) {
                MediaViewer.shared.goNext()
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .opacity(barsVisible ? 1 : 0)
        .allowsHitTesting(barsVisible)
        .animation(.easeOut(duration: 0.2), value: barsVisible)
    }

    private func navButton(symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CenteredSymbol(symbol, size: 16, weight: .semibold, box: 24)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(label)
        .accessibilityLabel(label)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0)
        .allowsHitTesting(enabled)
        .onHover { state.playback?.setPointerOver(symbol, $0) }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            info
                .onHover { state.playback?.setPointerOver("top", $0) }
            if let position = state.positionText {
                Text(position)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .onHover { state.playback?.setPointerOver("pos", $0) }
            }
            Spacer(minLength: 12)
            if item.isPhoto {
                ocrControls
                ZoomControls(zoom: state.zoom)
            }
        }
        .padding(.leading, state.titlebar.leading)
        .padding(.trailing, 16)
        .padding(.top, max(8, state.titlebar.centerY - 22))
        .opacity(barsVisible ? 1 : 0)
        .allowsHitTesting(barsVisible)
        .animation(.easeOut(duration: 0.2), value: barsVisible)
    }

    private var ocrControls: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                toggleOCRButton
                Button { state.copyRecognizedText() } label: {
                    HStack(spacing: 5) {
                        Group {
                            if state.isCopyingOCR {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .frame(width: 14, height: 14)
                        Text("Chép chữ")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.glass)
                .help("Chép toàn bộ chữ trong ảnh")
                .accessibilityLabel("Chép chữ")
                .disabled(state.isCopyingOCR)
            }
        }
        .fixedSize()
        .disabled(!state.zoom.hasContent)
    }

    @ViewBuilder private var toggleOCRButton: some View {
        let label = HStack(spacing: 5) {
            Group {
                if state.isAnalyzingOCR {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 12.5, weight: .semibold))
                }
            }
            .frame(width: 14, height: 14)
            Text("Quét chữ")
                .font(.system(size: 12, weight: .medium))
        }
        if state.isOCREnabled {
            Button { state.toggleOCR() } label: { label }
                .buttonStyle(.glassProminent)
                .help("Tắt Live Text (O)")
                .accessibilityLabel("Quét chữ")
                .accessibilityValue("Đang bật")
        } else {
            Button { state.toggleOCR() } label: { label }
                .buttonStyle(.glass)
                .help("Quét chữ / Live Text (O)")
                .accessibilityLabel("Quét chữ")
                .accessibilityValue("Đang tắt")
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.windowTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    /// "Hôm nay · 14:32", plus the group's name when it differs from the sender (in a 1-1 chat it is the same person).
    private var subtitle: String {
        var parts = ["\(ChatFormat.daySeparator(item.date)) · \(ChatFormat.time(item.date))"]
        // Through `ConversationDetail.summary` so the self conversation reads "Cloud của tôi", not the official "My Documents".
        if let name = ConversationDetail.summary(for: item.conversationId, engine: engine)?.displayName, name != item.senderName {
            parts.append(name)
        }
        return parts.joined(separator: " · ")
    }
}

/// A strip that drags the window (the titlebar is under the content, so nothing else would).
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}
