import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44) // traffic lights

            accountHeader
                .padding(.horizontal, 18)
                .padding(.bottom, 14)

            Button {
                app.page = .devices
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "display.2")
                        .font(.system(size: 17))
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: 22)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("My Devices")
                                .font(Theme.font(15, .medium))
                                .foregroundColor(Theme.secondaryText)
                            if !app.sessions.isEmpty {
                                Badge(text: "\(app.sessions.count)", color: Theme.accent)
                            }
                        }
                        Text("Connect to devices on the same network as this Mac")
                            .font(Theme.font(11.5))
                            .foregroundColor(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(app.page == .devices ? Theme.sidebarSelected : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 20)

            PromoCard()
                .padding(.horizontal, 8)

            Spacer(minLength: 20)

            Rectangle()
                .fill(Theme.border.opacity(0.7))
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            VStack(spacing: 4) {
                NavRow(icon: "gearshape", title: "Settings", selected: app.page == .settings) {
                    app.page = .settings
                }
                NavRow(icon: "questionmark.circle", title: "FAQ/Help Desk", selected: app.page == .help) {
                    app.page = .help
                }
                NavRow(icon: "envelope", title: "Contact Us", selected: false) {
                    NSWorkspace.shared.open(AppInfo.issuesURL)
                }
            }
            .padding(.horizontal, 12)

            Text("v\(AppInfo.version) RD")
                .font(Theme.font(11))
                .foregroundColor(Theme.secondaryText)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    private var accountHeader: some View {
        Menu {
            Text("Pairing code: \(app.pairingCode)")
            Button("New Pairing Code") { app.regeneratePairingCode() }
            Button("Copy Connection Link") { app.copyLink() }
            Divider()
            Button("Quit Reverse Duet") { NSApp.terminate(nil) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome back,")
                        .font(Theme.font(12))
                        .foregroundColor(Theme.secondaryText)
                    Text(app.userName)
                        .font(Theme.font(14, .medium))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

private struct NavRow: View {
    let icon: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 22)
                Text(title)
                    .font(Theme.font(14, .medium))
                Spacer()
            }
            .foregroundColor(Theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.sidebarSelected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Stands where Duet shows its upsell.
private struct PromoCard: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "star")
                    .font(.system(size: 14, weight: .medium))
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(Theme.warning).frame(width: 5, height: 5).offset(x: 3, y: -1)
                    }
                Text("Everything Unlocked")
                    .font(Theme.font(13, .medium))
            }
            Text("Reverse Duet is free and open source. Extend, mirror and remote control are all included.")
                .font(Theme.font(12))
                .foregroundColor(Theme.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSWorkspace.shared.open(AppInfo.repositoryURL)
            } label: {
                Text("View on GitHub")
                    .font(Theme.font(13, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.promo))
    }
}
