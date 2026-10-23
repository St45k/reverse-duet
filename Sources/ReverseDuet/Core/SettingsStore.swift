import Foundation

/// Persisted user settings (UserDefaults backed).
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// Called after any setting changes.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    // General — mirrors the rows of Duet's settings page.
    @Published var autoUpdate: Bool { didSet { save("autoUpdate", autoUpdate) } }
    @Published var openAtLogin: Bool { didSet { save("openAtLogin", openAtLogin) } }
    @Published var secureRemoteLogin: Bool { didSet { save("secureRemoteLogin", secureRemoteLogin) } }
    @Published var pauseAWDL: Bool { didSet { save("pauseAWDL", pauseAWDL) } }
    @Published var wirelessEnabled: Bool { didSet { save("wirelessEnabled", wirelessEnabled) } }
    @Published var androidUSB: Bool { didSet { save("androidUSB", androidUSB) } }
    @Published var screenSharing: Bool { didSet { save("screenSharing", screenSharing) } }
    @Published var audioSharing: Bool { didSet { save("audioSharing", audioSharing) } }
    @Published var preventSleep: Bool { didSet { save("preventSleep", preventSleep) } }

    // Streaming
    @Published var requirePairingCode: Bool { didSet { save("requirePairingCode", requirePairingCode) } }
    @Published var allowRemoteInput: Bool { didSet { save("allowRemoteInput", allowRemoteInput) } }
    @Published var showCursor: Bool { didSet { save("showCursor", showCursor) } }
    @Published var defaultMode: DisplayMode { didSet { save("defaultMode", defaultMode.rawValue) } }
    @Published var defaultFPS: Int { didSet { save("defaultFPS", defaultFPS) } }
    @Published var defaultQuality: StreamQuality { didSet { save("defaultQuality", defaultQuality.rawValue) } }
    @Published var defaultRetina: Bool { didSet { save("defaultRetina", defaultRetina) } }
    @Published var codec: VideoCodec { didSet { save("codec", codec.rawValue) } }
    @Published var port: Int { didSet { save("port", port) } }
    @Published var secureLink: Bool { didSet { save("secureLink", secureLink) } }

    private init() {
        defaults.register(defaults: [
            "autoUpdate": true,
            "openAtLogin": false,
            "secureRemoteLogin": false,
            "pauseAWDL": false,
            "wirelessEnabled": true,
            "androidUSB": false,
            "screenSharing": true,
            "audioSharing": false,
            "preventSleep": true,
            "requirePairingCode": true,
            "allowRemoteInput": true,
            "showCursor": true,
            "defaultMode": DisplayMode.extend.rawValue,
            "defaultFPS": 60,
            "defaultQuality": StreamQuality.high.rawValue,
            "defaultRetina": true,
            "codec": VideoCodec.h264.rawValue,
            "port": 7280,
            "secureLink": true,
        ])
        autoUpdate = defaults.bool(forKey: "autoUpdate")
        openAtLogin = defaults.bool(forKey: "openAtLogin")
        secureRemoteLogin = defaults.bool(forKey: "secureRemoteLogin")
        pauseAWDL = defaults.bool(forKey: "pauseAWDL")
        wirelessEnabled = defaults.bool(forKey: "wirelessEnabled")
        androidUSB = defaults.bool(forKey: "androidUSB")
        screenSharing = defaults.bool(forKey: "screenSharing")
        audioSharing = defaults.bool(forKey: "audioSharing")
        preventSleep = defaults.bool(forKey: "preventSleep")
        requirePairingCode = defaults.bool(forKey: "requirePairingCode")
        allowRemoteInput = defaults.bool(forKey: "allowRemoteInput")
        showCursor = defaults.bool(forKey: "showCursor")
        defaultMode = DisplayMode(rawValue: defaults.string(forKey: "defaultMode") ?? "") ?? .extend
        defaultFPS = defaults.integer(forKey: "defaultFPS") == 30 ? 30 : 60
        defaultQuality = StreamQuality(rawValue: defaults.string(forKey: "defaultQuality") ?? "") ?? .high
        defaultRetina = defaults.bool(forKey: "defaultRetina")
        codec = VideoCodec(rawValue: defaults.string(forKey: "codec") ?? "") ?? .h264
        let storedPort = defaults.integer(forKey: "port")
        port = (1024...65534).contains(storedPort) ? storedPort : 7280
        secureLink = defaults.bool(forKey: "secureLink")
    }

    var defaultParameters: StreamParameters {
        StreamParameters(mode: defaultMode, fps: defaultFPS, quality: defaultQuality, retina: defaultRetina, codec: codec)
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}
