import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var settings: SettingsStore
    @State private var portText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Settings")
                    .font(Theme.font(34, .bold))
                    .padding(.top, 26)
                    .padding(.bottom, 4)

                SettingRow(isOn: $settings.autoUpdate, title: "Auto Update App",
                           description: ["We recommend enabling this setting so you hear about important fixes."]) {
                    Button("Check for Updates") { NSWorkspace.shared.open(AppInfo.releasesURL) }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                }
                SettingRow(isOn: $settings.openAtLogin, title: "Open App at Login",
                           description: ["We recommend enabling this setting so that you can just open the link on your other device and get started. When idle, Reverse Duet uses almost no resources."])
                SettingRow(isOn: $settings.secureRemoteLogin, title: "Enable Secure Remote Login",
                           description: ["Lets Reverse Duet run as a Mac service and accept connections while you're signed out of your Mac account."],
                           enabled: false, badge: "Coming soon")
                SettingRow(isOn: $settings.pauseAWDL, title: "Pause Apple Wireless Direct Link",
                           description: ["Pause AWDL (used by AirDrop and Handoff) while a device is connected. AWDL can cause stutters in wireless streaming. macOS will ask for your password."])
                SettingRow(isOn: $settings.wirelessEnabled, title: "Enable Duet Air",
                           description: ["Check this box if you want devices on your network to be able to connect wirelessly through their browser."]) {
                    serverStatus
                }
                SettingRow(isOn: $settings.androidUSB, title: "Enable Android USB Support",
                           description: ["Wired connections to Android devices. For now, connect any Android device over Wi-Fi using its browser."],
                           enabled: false, badge: "Coming soon")
                SettingRow(isOn: $settings.screenSharing, title: "Screen Sharing Enabled", description: [])
                SettingRow(isOn: $settings.audioSharing, title: "Audio Sharing Enabled",
                           description: ["Play this Mac's audio on the connected device."],
                           enabled: false, badge: "Coming soon")
                SettingRow(isOn: $settings.preventSleep, title: "Prevent System Sleep",
                           description: ["Prevent your Mac from going to sleep while a device is connected."])

                sectionTitle("Streaming")

                SettingRow(isOn: $settings.requirePairingCode, title: "Require Pairing Code",
                           description: ["Devices must enter the 4-digit code shown in My Devices before they can see this Mac's screen. Strongly recommended on shared networks."]) {
                    Text(app.pairingCode)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
                }
                SettingRow(isOn: $settings.allowRemoteInput, title: "Allow Touch, Mouse and Keyboard Control",
                           description: ["Taps, clicks, scrolling and typing on the connected device control this Mac. Needs the Accessibility permission."]) {
                    permissionButton(granted: app.accessibilityGranted, action: Permissions.requestAccessibility)
                }
                SettingRow(isOn: $settings.secureLink, title: "Secure Link (HTTPS)",
                           description: ["Also serve an https:// link on the next port up. Browsers only allow hardware H.264 decoding, keep-awake and full keyboard capture on secure pages. The other device shows a one-time certificate warning because the certificate is made by this Mac."]) {
                    if let secureURL = app.secureURL {
                        Text(secureURL)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.secondaryText)
                            .textSelection(.enabled)
                    }
                }
                SettingRow(isOn: $settings.showCursor, title: "Show Cursor", description: ["Draw the Mac's pointer into the stream."])
                SettingRow(isOn: $settings.defaultRetina, title: "Retina by Default",
                           description: ["New devices with high-density screens get a 2x (HiDPI) display. Uses more bandwidth and battery."])

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        pickerRow("Default display mode", "Extend turns the device into a second screen. Mirror shows a copy of your main screen.") {
                            Segmented(options: DisplayMode.allCases.map { ($0, $0.label) }, selection: $settings.defaultMode)
                        }
                        pickerRow("Default framerate", "60 fps feels smoother; 30 fps saves battery and bandwidth.") {
                            Segmented(options: [(30, "30 fps"), (60, "60 fps")], selection: $settings.defaultFPS)
                        }
                        pickerRow("Default quality", "Higher quality shows fewer compression artifacts but needs a faster network.") {
                            Segmented(options: StreamQuality.allCases.map { ($0, $0.label) }, selection: $settings.defaultQuality)
                        }
                        pickerRow("Video codec", "H.264 uses the hardware encoder and WebCodecs. JPEG works in any browser.") {
                            Segmented(options: VideoCodec.allCases.map { ($0, $0 == .h264 ? "H.264" : "JPEG") }, selection: $settings.codec)
                        }
                        pickerRow("Port", "Devices connect to http://<this Mac>:<port>; the secure link uses the next port.") {
                            HStack(spacing: 8) {
                                TextField("7280", text: $portText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                    .onSubmit(applyPort)
                                Button("Apply", action: applyPort)
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                }

                sectionTitle("Permissions")

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        permissionRow("Screen Recording", "Required to capture this Mac's screen.",
                                      granted: app.screenRecordingGranted, action: Permissions.requestScreenRecording)
                        permissionRow("Accessibility", "Required for touch, mouse and keyboard control from the other device.",
                                      granted: app.accessibilityGranted, action: Permissions.requestAccessibility)
                    }
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 22)
        }
        .onAppear { portText = String(settings.port) }
    }

    private var serverStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(app.serverRunning ? Theme.success : Theme.faintText)
                .frame(width: 8, height: 8)
            Text(app.serverRunning ? "Listening on port \(settings.port)" : "Off")
                .font(Theme.font(12, .medium))
                .foregroundColor(Theme.secondaryText)
        }
    }

    private func applyPort() {
        guard let value = Int(portText), (1024...65534).contains(value) else {
            portText = String(settings.port)
            app.flash("Choose a port between 1024 and 65534")
            return
        }
        settings.port = value
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(20, .semibold))
            .padding(.top, 18)
            .padding(.bottom, 2)
    }

    private func pickerRow<Control: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(15, .semibold))
                Text(detail).font(Theme.font(13)).foregroundColor(Theme.text.opacity(0.85))
            }
            Spacer()
            control()
        }
    }

    private func permissionRow(_ title: String, _ detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(granted ? Theme.success : Theme.warning)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(15, .semibold))
                Text(detail).font(Theme.font(13)).foregroundColor(Theme.text.opacity(0.85))
            }
            Spacer()
            permissionButton(granted: granted, action: action)
        }
    }

    @ViewBuilder
    private func permissionButton(granted: Bool, action: @escaping () -> Void) -> some View {
        if granted {
            Badge(text: "Granted", color: Theme.success)
        } else {
            Button("Grant Access", action: action)
                .buttonStyle(SecondaryButtonStyle())
        }
    }
}

/// One white card with a checkbox, in the layout of Duet's settings page.
struct SettingRow<Trailing: View>: View {
    @Binding var isOn: Bool
    let title: String
    let description: [String]
    var enabled = true
    var badge: String?
    let trailing: Trailing

    init(isOn: Binding<Bool>, title: String, description: [String], enabled: Bool = true, badge: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        _isOn = isOn
        self.title = title
        self.description = description
        self.enabled = enabled
        self.badge = badge
        self.trailing = trailing()
    }

    var body: some View {
        Card(padding: 0) {
            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    Toggle(isOn: $isOn) { EmptyView() }
                        .toggleStyle(CheckboxStyle())
                        .disabled(!enabled)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(title).font(Theme.font(15.5, .semibold))
                            if let badge { Badge(text: badge) }
                        }
                        ForEach(description, id: \.self) { line in
                            Text(line)
                                .font(Theme.font(13.5))
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .opacity(enabled ? 1 : 0.55)
        }
    }
}

extension SettingRow where Trailing == EmptyView {
    init(isOn: Binding<Bool>, title: String, description: [String], enabled: Bool = true, badge: String? = nil) {
        self.init(isOn: isOn, title: title, description: description, enabled: enabled, badge: badge) { EmptyView() }
    }
}
