import AppKit
import SwiftUI

struct MyDevicesView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    StatusBanners()

                    if !app.sessions.isEmpty {
                        Text("Connected")
                            .font(Theme.font(15, .semibold))
                            .padding(.horizontal, 6)
                            .padding(.top, 4)
                        ForEach(app.sessions) { session in
                            ConnectedDeviceCard(session: session)
                        }
                    }

                    if app.showNewDevice {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Set up a new device")
                                .font(Theme.font(15, .semibold))
                            Text("Reverse Duet only needs to run on this Mac. The other device just needs a web browser.")
                                .font(Theme.font(13))
                                .foregroundColor(Theme.faintText)
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, 6)
                        NewDeviceCard()
                    } else if app.sessions.isEmpty {
                        EmptyDevicesCard()
                    }
                }
                .padding(18)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("My Devices")
                    .font(Theme.font(20, .semibold))
                Text("Connect to devices on the same network as this Mac")
                    .font(Theme.font(15))
                    .foregroundColor(Theme.text.opacity(0.8))
            }
            Spacer()
            Button {
                app.showNewDevice = true
            } label: {
                Label("New Device", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
        }
        .padding(.leading, 22)
        .padding(.trailing, 18)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }
}

// MARK: - Banners

private struct StatusBanners: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        if !app.screenRecordingGranted {
            Banner(icon: "rectangle.dashed.badge.record", color: Theme.warning,
                   title: "Screen Recording permission needed",
                   message: "macOS needs your approval before Reverse Duet can show this Mac's screen on another device.",
                   action: ("Grant Access", Permissions.requestScreenRecording))
        }
        if !app.settings.wirelessEnabled {
            Banner(icon: "wifi.slash", color: Theme.secondaryText,
                   title: "Duet Air is turned off",
                   message: "Turn on \"Enable Duet Air\" in Settings so devices on your network can connect.",
                   action: ("Open Settings", { app.page = .settings }))
        } else if let error = app.serverError {
            Banner(icon: "exclamationmark.triangle", color: Theme.danger,
                   title: "Couldn't start the connection server", message: error,
                   action: ("Settings", { app.page = .settings }))
        }
        if app.settings.allowRemoteInput, !app.accessibilityGranted, !app.sessions.isEmpty {
            Banner(icon: "hand.tap", color: Theme.accent,
                   title: "Allow touch and keyboard control",
                   message: "Grant Accessibility access so taps, clicks and typing on the other device control this Mac.",
                   action: ("Grant Access", Permissions.requestAccessibility))
        }
    }
}

private struct Banner: View {
    let icon: String
    let color: Color
    let title: String
    let message: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(14, .semibold))
                Text(message)
                    .font(Theme.font(12.5))
                    .foregroundColor(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.25), lineWidth: 1))
    }
}

private struct EmptyDevicesCard: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Card(padding: 28) {
            VStack(spacing: 12) {
                Image(systemName: "display.2")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(Theme.faintText)
                Text("No devices connected")
                    .font(Theme.font(16, .semibold))
                Text("Open \(app.primaryURL) in a browser on your other device.")
                    .font(Theme.font(13))
                    .foregroundColor(Theme.secondaryText)
                    .textSelection(.enabled)
                Button {
                    app.showNewDevice = true
                } label: {
                    Label("New Device", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - New device picker

private struct NewDeviceCard: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Please select a device type")
                        .font(Theme.font(17, .semibold))
                    Spacer()
                    Button {
                        if app.selectedDeviceType != nil {
                            app.selectedDeviceType = nil
                        } else {
                            app.showNewDevice = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(Theme.text)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)

                HStack(alignment: .top, spacing: 0) {
                    ForEach(ClientPlatform.pickable) { platform in
                        DeviceTypeTile(platform: platform,
                                       selected: app.selectedDeviceType == platform,
                                       dimmed: app.selectedDeviceType != nil && app.selectedDeviceType != platform) {
                            app.selectedDeviceType = platform
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 20)

                if let platform = app.selectedDeviceType {
                    ConnectInstructions(platform: platform)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 26)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: app.selectedDeviceType)
    }
}

private struct DeviceTypeTile: View {
    let platform: ClientPlatform
    let selected: Bool
    let dimmed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Text(platform.label)
                    .font(Theme.font(13, selected ? .semibold : .regular))
                DeviceIllustration(platform: platform)
                    .frame(width: 100, height: 56)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(selected ? Theme.accent : Theme.text.opacity(0.75), lineWidth: selected ? 2 : 1)
                    )
            }
            .opacity(dimmed ? 0.3 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Line-art device drawings in the style of Duet's picker.
struct DeviceIllustration: View {
    let platform: ClientPlatform

    var body: some View {
        ZStack {
            switch platform {
            case .chromeOS:
                symbol("laptopcomputer", size: 34)
                symbol("circle.circle", size: 11).offset(y: -3)
            case .windows:
                symbol("display", size: 30).offset(x: -12, y: -2)
                symbol("laptopcomputer", size: 26).offset(x: 14, y: 6)
                symbol("square.grid.2x2", size: 7).offset(x: -12, y: -5)
                symbol("square.grid.2x2", size: 6).offset(x: 14, y: 4)
            case .macOS, .linux, .unknown:
                symbol("display", size: 30).offset(x: -12, y: -2)
                symbol("laptopcomputer", size: 26).offset(x: 14, y: 6)
                symbol("applelogo", size: 7).offset(x: -12, y: -5)
                symbol("applelogo", size: 6).offset(x: 14, y: 4)
            case .iOS:
                symbol("ipad", size: 30).offset(x: -8)
                symbol("iphone", size: 22).offset(x: 14, y: 3)
                symbol("applelogo", size: 9).offset(x: -8, y: -1)
            case .android:
                symbol("ipad.landscape", size: 30).offset(x: -8)
                symbol("candybarphone", size: 22).offset(x: 16, y: 3)
                symbol("antenna.radiowaves.left.and.right", size: 8).offset(x: -8, y: -1)
            }
        }
    }

    private func symbol(_ name: String, size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .ultraLight))
            .foregroundColor(Theme.text.opacity(0.8))
    }
}

private struct ConnectInstructions: View {
    @EnvironmentObject private var app: AppState
    let platform: ClientPlatform

    var body: some View {
        VStack(spacing: 14) {
            Text("Open this link in \(platform.recommendedBrowser) on your \(platform.deviceNoun)")
                .font(Theme.font(18, .bold))
                .multilineTextAlignment(.center)

            HStack(alignment: .center, spacing: 28) {
                VStack(spacing: 10) {
                    Text(platform.label)
                        .font(Theme.font(17, .semibold))
                    Text(app.primaryURL)
                        .font(.system(size: 14, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy Link") { app.copyLink() }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                    if let secureURL = app.secureURL, platform != .iOS {
                        VStack(spacing: 4) {
                            Text("Smoother video: open the secure link instead")
                                .font(Theme.font(12, .semibold))
                                .foregroundColor(Theme.secondaryText)
                            HStack(spacing: 8) {
                                Text(secureURL)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                Button("Copy") { app.copyLink(secureURL) }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                            Text("When the browser warns about the certificate, choose Advanced › Proceed.")
                                .font(Theme.font(11))
                                .foregroundColor(Theme.faintText)
                        }
                        .padding(.top, 4)
                    }
                    if app.allURLs.count > 1 {
                        Text("or")
                            .font(Theme.font(12))
                            .foregroundColor(Theme.faintText)
                        ForEach(app.allURLs.dropFirst(), id: \.self) { url in
                            Text(url)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Theme.secondaryText)
                                .textSelection(.enabled)
                        }
                    }
                }

                VStack(spacing: 6) {
                    if let qr = QRCode.image(for: app.primaryURL) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 128, height: 128)
                    }
                    Text("Scan with the device's camera")
                        .font(Theme.font(11))
                        .foregroundColor(Theme.faintText)
                }
            }

            if app.settings.requirePairingCode {
                VStack(spacing: 4) {
                    Text("Pairing code")
                        .font(Theme.font(12, .medium))
                        .foregroundColor(Theme.secondaryText)
                    HStack(spacing: 6) {
                        ForEach(Array(app.pairingCode.enumerated()), id: \.offset) { _, digit in
                            Text(String(digit))
                                .font(.system(size: 26, weight: .semibold, design: .rounded))
                                .frame(width: 38, height: 46)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                        }
                        Button {
                            app.regeneratePairingCode()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(Theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Generate a new code")
                        .padding(.leading, 4)
                    }
                }
                .padding(.top, 4)
            }

            Text(tip)
                .font(Theme.font(12))
                .foregroundColor(Theme.faintText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
    }

    private var tip: String {
        switch platform {
        case .iOS:
            return "Tip: in Safari tap Share › Add to Home Screen to run full screen without browser bars."
        case .android, .chromeOS:
            return "Tip: Chrome's menu › Install app (or Add to Home screen) gives you a full-screen, Duet-like experience."
        case .windows, .macOS, .linux, .unknown:
            return "Both devices must be on the same Wi-Fi or wired network. Press F11 / ⌃⌘F in the browser for full screen."
        }
    }
}

// MARK: - Connected device

private struct ConnectedDeviceCard: View {
    @EnvironmentObject private var app: AppState
    let session: SessionInfo

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    DeviceIllustration(platform: session.platform)
                        .frame(width: 76, height: 46)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(session.name)
                                .font(Theme.font(16, .semibold))
                            stateBadge
                        }
                        Text(detailLine)
                            .font(Theme.font(12))
                            .foregroundColor(Theme.secondaryText)
                        if case .failed(let message) = session.state {
                            Text(message)
                                .font(Theme.font(12, .medium))
                                .foregroundColor(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Button("Disconnect") { app.disconnect(session) }
                        .buttonStyle(SecondaryButtonStyle(tint: Theme.danger))
                }

                HStack(spacing: 18) {
                    control("Display") {
                        Segmented(options: DisplayMode.allCases.map { ($0, $0.label) },
                                  selection: binding(\.mode))
                    }
                    control("Framerate") {
                        Segmented(options: [(30, "30 fps"), (60, "60 fps")], selection: binding(\.fps))
                    }
                    control("Quality") {
                        Segmented(options: StreamQuality.allCases.map { ($0, $0.label) },
                                  selection: binding(\.quality))
                    }
                    control("Retina") {
                        Toggle(isOn: binding(\.retina)) { EmptyView() }
                            .toggleStyle(CheckboxStyle())
                            .padding(.vertical, 6)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var stateBadge: some View {
        switch session.state {
        case .streaming: return Badge(text: "Connected", color: Theme.success)
        case .starting: return Badge(text: "Starting", color: Theme.accent)
        case .awaitingCode: return Badge(text: "Waiting for code", color: Theme.warning)
        case .failed: return Badge(text: "Error", color: Theme.danger)
        }
    }

    private var detailLine: String {
        var parts = [session.address]
        parts.append("\(session.screen.width)×\(session.screen.height) @\(String(format: "%.1f", session.screen.scale))x")
        if session.state == .streaming {
            parts.append("\(session.streamWidth)×\(session.streamHeight) \(session.activeCodec == .h264 ? "H.264" : "JPEG")")
            parts.append("\(Int(session.fps)) fps")
            parts.append(String(format: "%.1f Mbps", session.kbps / 1000))
            if session.rttMs > 0 { parts.append("\(Int(session.rttMs)) ms") }
        }
        return parts.joined(separator: "  ·  ")
    }

    private func control<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Theme.font(11, .medium))
                .foregroundColor(Theme.secondaryText)
            content()
        }
    }

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<StreamParameters, Value>) -> Binding<Value> {
        Binding(
            get: { session.params[keyPath: keyPath] },
            set: { newValue in app.update(session) { $0[keyPath: keyPath] = newValue } }
        )
    }
}
