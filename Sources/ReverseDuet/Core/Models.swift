import Foundation

/// Whether the remote browser shows a copy of this Mac's screen or acts as an
/// additional (virtual) monitor.
enum DisplayMode: String, CaseIterable, Identifiable {
    case extend
    case mirror

    var id: String { rawValue }
    var label: String { self == .extend ? "Extend" : "Mirror" }
}

enum StreamQuality: String, CaseIterable, Identifiable {
    case normal
    case high
    case pixelPerfect

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .high: return "High"
        case .pixelPerfect: return "Pixel Perfect"
        }
    }

    /// Target H.264 bits per pixel per frame.
    var bitsPerPixel: Double {
        switch self {
        case .normal: return 0.06
        case .high: return 0.12
        case .pixelPerfect: return 0.25
        }
    }

    var jpegQuality: Double {
        switch self {
        case .normal: return 0.55
        case .high: return 0.75
        case .pixelPerfect: return 0.92
        }
    }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264
    case jpeg

    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264: return "H.264 (hardware)"
        case .jpeg: return "JPEG (compatibility)"
        }
    }

    /// First byte of every binary frame sent to the browser.
    var wireType: UInt8 { self == .h264 ? 1 : 2 }
}

enum ClientPlatform: String, CaseIterable, Identifiable {
    case chromeOS
    case windows
    case macOS
    case iOS
    case android
    case linux
    case unknown

    var id: String { rawValue }

    /// The five device types offered in the "New Device" picker.
    static let pickable: [ClientPlatform] = [.chromeOS, .windows, .macOS, .iOS, .android]

    var label: String {
        switch self {
        case .chromeOS: return "ChromeOS"
        case .windows: return "Windows"
        case .macOS: return "macOS"
        case .iOS: return "iOS"
        case .android: return "Android"
        case .linux: return "Linux"
        case .unknown: return "Browser"
        }
    }

    var deviceNoun: String {
        switch self {
        case .chromeOS: return "Chromebook"
        case .windows: return "Windows PC"
        case .macOS: return "Mac"
        case .iOS: return "iPad or iPhone"
        case .android: return "Android tablet or phone"
        case .linux: return "Linux computer"
        case .unknown: return "device"
        }
    }

    var recommendedBrowser: String {
        switch self {
        case .chromeOS, .android, .linux, .unknown: return "Chrome"
        case .windows: return "Chrome or Edge"
        case .macOS: return "Chrome or Safari"
        case .iOS: return "Safari"
        }
    }

    var symbol: String {
        switch self {
        case .chromeOS: return "laptopcomputer"
        case .windows: return "pc"
        case .macOS: return "desktopcomputer"
        case .iOS: return "ipad.and.iphone"
        case .android: return "candybarphone"
        case .linux: return "laptopcomputer"
        case .unknown: return "globe"
        }
    }

    static func detect(userAgent: String, touchPoints: Int) -> ClientPlatform {
        let ua = userAgent.lowercased()
        if ua.contains("cros") { return .chromeOS }
        if ua.contains("android") { return .android }
        if ua.contains("iphone") || ua.contains("ipad") { return .iOS }
        if ua.contains("windows") { return .windows }
        // iPadOS Safari pretends to be a Mac; touch support gives it away.
        if ua.contains("macintosh") || ua.contains("mac os x") { return touchPoints > 1 ? .iOS : .macOS }
        if ua.contains("linux") { return .linux }
        return .unknown
    }

    static func browserName(userAgent: String) -> String {
        if userAgent.contains("Edg/") { return "Edge" }
        if userAgent.contains("OPR/") { return "Opera" }
        if userAgent.contains("Firefox/") || userAgent.contains("FxiOS") { return "Firefox" }
        if userAgent.contains("Chrome/") || userAgent.contains("CriOS") { return "Chrome" }
        if userAgent.contains("Safari/") { return "Safari" }
        return "Browser"
    }
}

/// Size of the remote screen in CSS pixels plus its device pixel ratio.
struct ClientScreen: Equatable {
    var width: Int
    var height: Int
    var scale: Double

    var pixelWidth: Int { Int((Double(width) * scale).rounded()) }
    var pixelHeight: Int { Int((Double(height) * scale).rounded()) }
}

struct StreamParameters: Equatable {
    var mode: DisplayMode
    var fps: Int
    var quality: StreamQuality
    var retina: Bool
    var codec: VideoCodec
}

enum SessionState: Equatable {
    case awaitingCode
    case starting
    case streaming
    case failed(String)

    var label: String {
        switch self {
        case .awaitingCode: return "Waiting for pairing code"
        case .starting: return "Starting…"
        case .streaming: return "Connected"
        case .failed(let message): return message
        }
    }
}

/// Snapshot of a browser connection, published to the UI.
struct SessionInfo: Identifiable, Equatable {
    let id: UUID
    var name: String
    var platform: ClientPlatform
    var address: String
    var screen: ClientScreen
    var params: StreamParameters
    var activeCodec: VideoCodec
    var streamWidth: Int = 0
    var streamHeight: Int = 0
    var state: SessionState = .awaitingCode
    var fps: Double = 0
    var kbps: Double = 0
    var rttMs: Double = 0
}

/// Settings the networking side needs. Snapshotted from `SettingsStore`.
struct ServerConfig {
    var macName: String = Host.current().localizedName ?? "Mac"
    var pairingCode: String = "0000"
    var requirePairingCode = true
    var screenSharingEnabled = true
    var allowRemoteInput = true
    var showCursor = true
    var defaults = StreamParameters(mode: .extend, fps: 60, quality: .high, retina: true, codec: .h264)
}
