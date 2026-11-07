import Testing
import Foundation
@testable import Olaz

/// The Zalo runtime Olaz installs into its own folder instead of needing Zalo PC (ZaloRuntimeInstaller.swift).
@Suite struct ZaloRuntimeTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-runtime-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The files `ZaloRuntime.isComplete` looks for.
    private func makeRuntime(at dir: URL, version: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try (["CFBundleShortVersionString": version] as NSDictionary).write(to: dir.appendingPathComponent("Contents/Info.plist"))
        try Data("asar".utf8).write(to: dir.appendingPathComponent("Contents/Resources/app.asar"))
        let helper = ZaloRuntime.helper("ZaloCall", in: dir)
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    }

    @Test func readsVersionFromInstallerName() {
        #expect(ZaloRuntime.version(fromInstallerName: "ZaloSetup-universal-26.10.20.dmg") == "26.10.20")
        #expect(ZaloRuntime.version(fromInstallerName: "ZaloSetup-universal-26.10.20-RC4.zip") == nil)
        #expect(ZaloRuntime.version(fromInstallerName: "Zalo-3.2.64.dmg") == nil)
        #expect(ZaloRuntime.version(fromInstallerName: ZaloRuntime.pinned.url.lastPathComponent) == ZaloRuntime.pinned.version)
    }

    @Test func comparesVersionsNumerically() {
        #expect(ZaloRuntime.isNewer("26.10.20", than: "26.9.10"))
        #expect(ZaloRuntime.isNewer("27.1.5", than: "26.12.31"))
        #expect(!ZaloRuntime.isNewer("26.10.20", than: "26.10.20"))
        #expect(!ZaloRuntime.isNewer("26.10", than: "26.10.0"))
        #expect(!ZaloRuntime.isNewer("26.9.10", than: "26.10.20"))
    }

    @Test func launchSwapsInPreparedUpgrade() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRuntime(at: root.appendingPathComponent("current"), version: "26.9.10")
        try makeRuntime(at: root.appendingPathComponent("pending"), version: "26.10.20")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work/staging-x"), withIntermediateDirectories: true)

        ZaloRuntime.prepareForLaunch(root: root)

        #expect(ZaloRuntime.version(of: root.appendingPathComponent("current")) == "26.10.20")
        #expect(ZaloRuntime.isComplete(root.appendingPathComponent("current")))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pending").path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("work").path)) ?? [] == [])
    }

    @Test func launchDropsIncompleteUpgrade() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRuntime(at: root.appendingPathComponent("current"), version: "26.9.10")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pending/Contents"), withIntermediateDirectories: true)

        ZaloRuntime.prepareForLaunch(root: root)

        #expect(ZaloRuntime.version(of: root.appendingPathComponent("current")) == "26.9.10")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pending").path))
    }

    @Test func refusesAppsNotSignedByVNG() {
        #expect(throws: ZaloRuntimeInstaller.Failure.self) {
            try ZaloRuntimeInstaller.verifySignature(of: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        }
    }

    @Test func installedZaloPassesSignatureWhenPresent() throws {
        let app = URL(fileURLWithPath: "/Applications/Zalo.app")
        guard FileManager.default.fileExists(atPath: app.path) else { return }
        try ZaloRuntimeInstaller.verifySignature(of: app)
    }

    /// The whole DMG path (download, checksum, mount, signature, copy) against the official DMG, a downloaded copy or the
    /// pinned link: `OLAZ_ZALO_DMG=/path/to/ZaloSetup-universal-<pinned>.dmg swift test --filter ZaloRuntimeTests`
    /// (or `OLAZ_ZALO_DMG=pinned`).
    @Test func installsFromOfficialDiskImage() async throws {
        guard let path = ProcessInfo.processInfo.environment["OLAZ_ZALO_DMG"] else { return }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var release = ZaloRuntime.pinned
        release.version = "0-test"                       // no installed Zalo.app matches: the DMG is used
        if path != "pinned" { release.url = URL(fileURLWithPath: path) }
        let steps = StepLog()
        let installer = ZaloRuntimeInstaller(release: release, allowsLatest: false,
                                             work: root.appendingPathComponent("work"), progress: { steps.append($0) })
        let destination = root.appendingPathComponent("current")

        let version = try await installer.install(into: destination)

        #expect(version == ZaloRuntime.pinned.version)
        #expect(ZaloRuntime.isComplete(destination))
        #expect(try OfficialZaloInstall.locate(appURL: destination).asar.contains("pc-dist/index.html"))
        try CallHelperSignature.verify(executable: ZaloRuntime.helper("ZaloCall", in: destination))
        #expect(FileManager.default.isExecutableFile(atPath: ZaloRuntime.helper("ZaloCap", in: destination).path))
        #expect(steps.all.contains(.verifying) && steps.all.contains(.installing))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("work").path)
        #expect(leftovers.isEmpty)
    }

    /// `OLAZ_NETWORK_TESTS=1`: zalo.me still redirects a Mac to a DMG whose name carries the version.
    @Test func zaloMeOffersMacInstaller() async throws {
        guard ProcessInfo.processInfo.environment["OLAZ_NETWORK_TESTS"] != nil else { return }
        let latest = try await ZaloRuntimeInstaller.latestRelease()
        #expect(latest.url.pathExtension == "dmg")
        #expect(!ZaloRuntime.isNewer(ZaloRuntime.pinned.version, than: latest.version))
    }
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ZaloRuntimeInstaller.Step] = []
    func append(_ step: ZaloRuntimeInstaller.Step) { lock.lock(); steps.append(step); lock.unlock() }
    var all: [ZaloRuntimeInstaller.Step] { lock.lock(); defer { lock.unlock() }; return steps }
}

@MainActor
@Suite struct QRLoginTests {
    private static let sampleSVG1 = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2640\" height=\"2640\" viewBox=\"0 0 2640 2640\"><rect width=\"100%\" height=\"100%\" fill=\"white\"/><rect x=\"48\" y=\"48\" width=\"48\" height=\"48\" fill=\"black\"/></svg>"
    private static let sampleSVG2 = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2640\" height=\"2640\" viewBox=\"0 0 2640 2640\"><rect width=\"100%\" height=\"100%\" fill=\"white\"/><rect x=\"96\" y=\"96\" width=\"48\" height=\"48\" fill=\"black\"/></svg>"
    private static let spinnerSVG = "<svg width=\"42\" height=\"42\" viewBox=\"0 0 42 42\"><animateTransform attributeName=\"transform\" type=\"rotate\"/></svg>"

    private static var qr1DataURL: String {
        "data:image/svg+xml;utf8," + (sampleSVG1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }
    private static var qr2DataURL: String {
        "data:image/svg+xml;utf8," + (sampleSVG2.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }
    private static var spinnerDataURL: String {
        "data:image/svg+xml;base64," + Data(spinnerSVG.utf8).base64EncodedString()
    }

    @Test func decodesUTF8SVGAndBase64QRWhileRejectingSpinner() {
        let svgData = ZaloEngine.decodeDataURL(Self.qr1DataURL)
        #expect(svgData == Data(Self.sampleSVG1.utf8))

        let pngPayload = Data([0x89, 0x50, 0x4E, 0x47])
        let pngData = ZaloEngine.decodeDataURL("data:image/png;base64," + pngPayload.base64EncodedString())
        #expect(pngData == pngPayload)

        // The 42x42 loading spinner SVG (`Pe` in login.html) must be rejected.
        #expect(ZaloEngine.decodeDataURL(Self.spinnerDataURL) == nil)
    }

    @Test func handlesMultiLayerQR2AndDOMSnapshotTransitions() throws {
        let engine = ZaloEngine()
        engine.phase = .login(ZaloEngine.LoginState())

        // 1. Initial DOM snapshot (even without `event: "qr"`) transitions `.generating` -> `.waitingScan`.
        engine.applyLoginState(["page": "login", "qr": Self.qr1DataURL, "invalid": false])
        guard case .login(let s1) = engine.phase else { Issue.record("Expected login phase"); return }
        #expect(s1.step == .waitingScan)
        #expect(s1.qrPNG == Data(Self.sampleSVG1.utf8))

        // 2. Phone scans QR1 -> poll returns display_name -> `.waitingConfirm`.
        let scanBody = try JSONSerialization.data(withJSONObject: [
            "error_code": 0,
            "data": ["display_name": "Test User", "avatar": "https://s120.ava.talk.zdn.vn/a.jpg"]
        ])
        engine.observe(url: URL(string: "https://qr-id.zaloapp.com/polling/qr/wait-scan")!, status: 200, body: scanBody)
        guard case .login(let s2) = engine.phase else { Issue.record("Expected login phase"); return }
        #expect(s2.step == .waitingConfirm(name: "Test User", avatar: URL(string: "https://s120.ava.talk.zdn.vn/a.jpg")))

        // 3. Trusted-Device requires 2nd QR (`event: "qr2"` or `error_code: -20`) -> must return to `.waitingScan` with QR2!
        engine.applyLoginState(["page": "login", "event": "qr2", "qr": Self.qr2DataURL])
        guard case .login(let s3) = engine.phase else { Issue.record("Expected login phase"); return }
        #expect(s3.step == .waitingScan)
        #expect(s3.qrPNG == Data(Self.sampleSVG2.utf8))
    }

    @Test func ignoresIntermediatePollTimeoutsAndHonorsRejectionOrDOMExpiry() throws {
        let engine = ZaloEngine()
        engine.phase = .login(ZaloEngine.LoginState())
        engine.applyLoginState(["page": "login", "event": "qr", "qr": Self.qr1DataURL])

        // 1. Intermediate long-poll tick timeout (e.g. 408) must NOT clobber `.waitingScan` into `.failed`.
        let tickTimeout = try JSONSerialization.data(withJSONObject: [
            "error_code": 408,
            "error_message": "Request timeout"
        ])
        engine.observe(url: URL(string: "https://qr-id.zaloapp.com/polling/qr/wait-scan")!, status: 200, body: tickTimeout)
        guard case .login(let s1) = engine.phase else { Issue.record("Expected login phase"); return }
        #expect(s1.step == .waitingScan)

        // 2. Mobile user rejects login (18010) -> transitions to `.expired`.
        let rejected = try JSONSerialization.data(withJSONObject: [
            "error_code": 18010,
            "error_message": "User rejected"
        ])
        engine.observe(url: URL(string: "https://qr-id.zaloapp.com/polling/qr/wait-cfirm")!, status: 200, body: rejected)
        guard case .login(let s2) = engine.phase else { Issue.record("Expected login phase"); return }
        #expect(s2.step == .expired)

        // 3. Regenerating a new QR in DOM (`invalid: false`) recovers from `.expired` -> `.waitingScan`.
        engine.applyLoginState(["page": "login", "qr": Self.qr2DataURL, "invalid": false])
        guard case .login(let s3) = engine.phase else { Issue.record("Expected login phase"); return }
        #expect(s3.step == .waitingScan)
        #expect(s3.qrPNG == Data(Self.sampleSVG2.utf8))

        // 4. DOM `.mask:not(.mask--none)` (`invalid: true`) marks QR as `.expired`.
        engine.applyLoginState(["page": "login", "invalid": true])
        guard case .login(let s4) = engine.phase else { Issue.record("Expected login phase"); return }
        #expect(s4.step == .expired)
    }
}
