import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 228)
            Rectangle()
                .fill(Theme.border.opacity(0.6))
                .frame(width: 1)
            Group {
                switch app.page {
                case .devices:
                    MyDevicesView()
                case .settings:
                    SettingsView(settings: app.settings)
                case .help:
                    HelpView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .overlay(alignment: .bottom) {
            if let notice = app.notice {
                Text(notice)
                    .font(Theme.font(13, .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.text.opacity(0.85)))
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.notice)
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 600)
        .foregroundColor(Theme.text)
        .preferredColorScheme(.light)
    }
}
