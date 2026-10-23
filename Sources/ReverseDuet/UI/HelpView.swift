import AppKit
import SwiftUI

struct HelpView: View {
    private let faqs: [(String, String)] = [
        ("How does it work?",
         "Reverse Duet runs a small web server on this Mac. Open the link from My Devices in a browser on your other device, enter the pairing code, and the Mac's screen streams to it as H.264 video (decoded by the browser's WebCodecs) or JPEG frames. Taps, clicks and key presses are sent back and replayed on the Mac."),
        ("What's the difference between Extend and Mirror?",
         "Extend creates a virtual display sized to your device's screen, so it behaves like a second monitor: drag windows onto it and arrange it in System Settings › Displays. Mirror shows a copy of your main display."),
        ("Which browsers work?",
         "Any recent Chrome, Edge or Safari. Chrome on ChromeOS, Android, Windows and macOS uses hardware H.264 decoding. Browsers without WebCodecs fall back to JPEG automatically."),
        ("Why is there a pairing code?",
         "Anyone on your network could otherwise open the link and see your screen. The code changes every time the app starts; you can also generate a new one from the account menu."),
        ("It stutters or lags. What can I do?",
         "Use 5 GHz Wi-Fi or Ethernet, switch the device to 30 fps or Normal quality, turn off Retina, and try \"Pause Apple Wireless Direct Link\" in Settings."),
        ("Taps and typing don't do anything.",
         "Grant Accessibility access in System Settings › Privacy & Security › Accessibility, and make sure \"Allow Touch, Mouse and Keyboard Control\" is on."),
        ("The other device says it can't connect.",
         "Both devices must be on the same network, and some guest or office networks block devices from talking to each other. Check that macOS's firewall allows incoming connections for Reverse Duet."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("FAQ / Help Desk")
                    .font(Theme.font(34, .bold))
                    .padding(.top, 26)
                    .padding(.bottom, 4)
                ForEach(faqs.indices, id: \.self) { index in
                    FAQItem(question: faqs[index].0, answer: faqs[index].1)
                }
                HStack {
                    Text("Still stuck?")
                        .font(Theme.font(14, .medium))
                    Button("Open an issue on GitHub") { NSWorkspace.shared.open(AppInfo.issuesURL) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 22)
        }
    }
}

private struct FAQItem: View {
    let question: String
    let answer: String
    @State private var expanded = false

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack {
                        Text(question).font(Theme.font(15.5, .semibold))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundColor(Theme.secondaryText)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    Text(answer)
                        .font(Theme.font(13.5))
                        .lineSpacing(5)
                        .foregroundColor(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: expanded)
    }
}
