import AppKit
import Combine
import Foundation

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    static let repositoryURL = URL(string: "https://github.com/st45k/reverse-duet")!
    static let releasesURL = URL(string: "https://github.com/st45k/reverse-duet/releases")!
    static let issuesURL = URL(string: "https://github.com/st45k/reverse-duet/issues/new")!
}

/// App-wide state shared by the main window and the menu bar item.
/// Mutated on the main thread only.
final class AppState: ObservableObject, StreamServerDelegate {
    static let shared = AppState()

    enum Page: Hashable {
        case devices
        case settings
        case help
    }

    @Published var page: Page = .devices
    @Published var sessions: [SessionInfo] = []
    @Published var serverRunning = false
    @Published var serverError: String?
    @Published var securePort: Int?
    @Published var pairingCode = AppState.makePairingCode()
    @Published var showNewDevice = true
    @Published var selectedDeviceType: ClientPlatform?
    @Published var screenRecordingGranted = Permissions.screenRecording
    @Published var accessibilityGranted = Permissions.accessibility
    @Published var addresses: [String] = NetworkInfo.ipv4Addresses()
    @Published var hostName: String?
    @Published var notice: String?

    let settings = SettingsStore.shared
    let server = StreamServer()
    let macName = Host.current().localizedName ?? "this Mac"
    let userName = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()

    private let sleepAssertion = SleepAssertion()
    private let awdl = AWDLController()
    private struct ListenerConfig: Equatable {
        var port: Int
        var secure: Bool
    }

    private var listening: ListenerConfig?
    private var appliedOpenAtLogin: Bool?
    private var refreshTimer: Timer?
    private var settingsObserver: AnyCancellable?

    private init() {
        server.delegate = self
        // Views read settings through AppState, so re-render when they change.
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        settings.onChange = { [weak self] in
            DispatchQueue.main.async { self?.applySettings() }
        }
        applySettings()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let name = NetworkInfo.localHostName
            DispatchQueue.main.async { self?.hostName = name }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshEnvironment()
        }
    }

    // MARK: Derived

    var port: Int { settings.port }

    var primaryURL: String {
        "http://\(addresses.first ?? "localhost"):\(port)"
    }

    var secureURL: String? {
        securePort.map { "https://\(addresses.first ?? "localhost"):\($0)" }
    }

    var allURLs: [String] {
        var urls = addresses.map { "http://\($0):\(port)" }
        if let hostName { urls.append("http://\(hostName):\(port)") }
        return urls
    }

    var streamingCount: Int {
        sessions.filter { $0.state == .streaming }.count
    }

    // MARK: Actions

    func regeneratePairingCode() {
        pairingCode = Self.makePairingCode()
        pushConfig()
    }

    func update(_ session: SessionInfo, _ change: (inout StreamParameters) -> Void) {
        var params = session.params
        change(&params)
        guard params != session.params else { return }
        server.update(sessionID: session.id, params: params)
    }

    func disconnect(_ session: SessionInfo) {
        server.disconnect(sessionID: session.id)
    }

    func copyLink(_ url: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url ?? primaryURL, forType: .string)
        flash("Link copied")
    }

    func flash(_ message: String) {
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.notice == message { self?.notice = nil }
        }
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func prepareForTermination() {
        server.disconnectAll()
        sleepAssertion.set(false)
        if awdl.isPaused { awdl.set(paused: false) }
    }

    // MARK: Settings → services

    private func applySettings() {
        let wantedListener = settings.wirelessEnabled ? ListenerConfig(port: settings.port, secure: settings.secureLink) : nil
        if wantedListener != listening {
            listening = wantedListener
            if let wantedListener {
                startServer(wantedListener)
            } else {
                server.stop()
            }
        }

        if appliedOpenAtLogin != nil, appliedOpenAtLogin != settings.openAtLogin,
           let error = LoginItem.set(enabled: settings.openAtLogin) {
            serverError = error
        }
        appliedOpenAtLogin = settings.openAtLogin

        if !settings.screenSharing {
            server.disconnectAll()
        }
        pushConfig()
        updatePowerAndRadio()
    }

    private func startServer(_ listener: ListenerConfig) {
        guard listener.secure else {
            server.start(port: listener.port, identity: nil)
            return
        }
        let addresses = self.addresses
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hostNames = [NetworkInfo.localHostName].compactMap { $0 }
            let identity = TLSIdentity.loadOrCreate(hostNames: hostNames, addresses: addresses)
            DispatchQueue.main.async {
                guard let self, self.listening == listener else { return }
                self.server.start(port: listener.port, identity: identity)
            }
        }
    }

    private func pushConfig() {
        var config = ServerConfig()
        config.macName = macName
        config.pairingCode = pairingCode
        config.requirePairingCode = settings.requirePairingCode
        config.screenSharingEnabled = settings.screenSharing
        config.allowRemoteInput = settings.allowRemoteInput
        config.showCursor = settings.showCursor
        config.defaults = settings.defaultParameters
        server.config = config
    }

    private func updatePowerAndRadio() {
        let active = !sessions.isEmpty
        sleepAssertion.set(active && settings.preventSleep)
        let wantAWDLPaused = active && settings.pauseAWDL
        if wantAWDLPaused != awdl.isPaused { awdl.set(paused: wantAWDLPaused) }
    }

    private func refreshEnvironment() {
        let screen = Permissions.screenRecording
        if screen != screenRecordingGranted { screenRecordingGranted = screen }
        let accessibility = Permissions.accessibility
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        let current = NetworkInfo.ipv4Addresses()
        if current != addresses { addresses = current }
    }

    private static func makePairingCode() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    // MARK: StreamServerDelegate

    func serverDidUpdateSessions(_ sessions: [SessionInfo]) {
        DispatchQueue.main.async { [self] in
            let hadSessions = !self.sessions.isEmpty
            self.sessions = sessions
            if !sessions.isEmpty, !hadSessions { showNewDevice = false }
            updatePowerAndRadio()
        }
    }

    func serverDidChangeState(running: Bool, error: String?) {
        DispatchQueue.main.async { [self] in
            serverRunning = running
            serverError = error
            if !running, error != nil { listening = nil }
        }
    }

    func serverDidChangeSecurePort(_ port: Int?) {
        DispatchQueue.main.async { [self] in securePort = port }
    }
}
