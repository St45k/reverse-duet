import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

enum NetworkInfo {
    /// IPv4 addresses of the Mac's Wi-Fi / Ethernet interfaces, en0 first.
    static func ipv4Addresses() -> [String] {
        var found: [(name: String, address: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            // Skip VPN tunnels, AWDL, etc. — a browser on the LAN can't reach those.
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.append((name, String(cString: host)))
            }
        }
        return found.sorted { $0.name < $1.name }.map(\.address)
    }

    /// Bonjour host name, e.g. "Stas-MacBook-Air.local".
    static var localHostName: String? {
        guard let name = Host.current().names.first(where: { $0.hasSuffix(".local") }) else { return nil }
        return name
    }
}

/// Keeps the display awake while a device is connected.
final class SleepAssertion {
    private var assertionID: IOPMAssertionID = 0
    private var active = false

    func set(_ enabled: Bool) {
        if enabled, !active {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Reverse Duet is streaming to another device" as CFString,
                &assertionID
            )
            active = result == kIOReturnSuccess
        } else if !enabled, active {
            IOPMAssertionRelease(assertionID)
            active = false
        }
    }
}

/// Apple Wireless Direct Link (AirDrop / Handoff) periodically hops Wi-Fi
/// channels, which shows up as stutter in wireless streaming. Turning it off
/// needs admin rights, so macOS prompts for a password.
final class AWDLController {
    private(set) var isPaused = false

    func set(paused: Bool) {
        guard paused != isPaused else { return }
        let command = paused ? "/sbin/ifconfig awdl0 down" : "/sbin/ifconfig awdl0 up"
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")?
            .executeAndReturnError(&error)
        if error == nil { isPaused = paused }
    }
}

enum LoginItem {
    static func set(enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Couldn't update the login item: \(error.localizedDescription). Run the app from its .app bundle."
        }
    }
}

enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

/// The browser client (HTML/JS/CSS) served to remote devices.
enum WebAssets {
    private static let files: [String: String] = [
        "index.html": "text/html; charset=utf-8",
        "app.js": "text/javascript; charset=utf-8",
        "style.css": "text/css; charset=utf-8",
        "logo.svg": "image/svg+xml",
        "manifest.webmanifest": "application/manifest+json",
    ]

    private static let directory: URL? = {
        // Inside the .app bundle the build script copies the folder to Contents/Resources/Web.
        if let url = Bundle.main.url(forResource: "Web", withExtension: nil) { return url }
        return Bundle.module.url(forResource: "Web", withExtension: nil)
    }()

    static func file(named name: String) -> (data: Data, contentType: String)? {
        guard let type = files[name], let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return (data, type)
    }
}
