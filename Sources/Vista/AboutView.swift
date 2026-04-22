// AboutView.swift — Small about window with author + project links.
//
// Shown via the "About Vista" menu bar item. Uses the same Window scene
// + activation-policy flip as Preferences, so it reliably comes to the
// front even from an accessory-policy state.

import SwiftUI
import AppKit

@MainActor
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            // App icon pulled from the bundle. NSImage(named: "AppIcon")
            // works for both bundled .app (Resources/AppIcon.icns) and
            // swift-run builds once the PNG is in the bundle-less path.
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            } else {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 96, height: 96)
            }

            VStack(spacing: 4) {
                Text("Vista")
                    .font(.title).bold()
                // Full build badge: version + commit when available. Clickable
                // so users can jump straight to the release notes for the
                // build they're running.
                Button {
                    if let url = BuildInfo.releaseOrCommitURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(BuildInfo.footerBadge).monospaced()
                        Image(systemName: "arrow.up.forward.square").imageScale(.small)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                // The About window has no other focusable controls, so
                // SwiftUI draws its default focus ring around this button
                // when the window is key. Opt out so the badge sits flat
                // with the rest of the text.
                .focusEffectDisabled()
                .help("Open release notes on GitHub")

                Text("Search your screenshots by text, name, or date.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            Divider()
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 10) {
                linkRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    label: "Source",
                    subtitle: "github.com/gordonbeeming/vista",
                    url: "https://github.com/gordonbeeming/vista"
                )
                linkRow(
                    icon: "exclamationmark.bubble",
                    label: "Report an issue",
                    subtitle: "github.com/gordonbeeming/vista/issues",
                    url: "https://github.com/gordonbeeming/vista/issues"
                )
                linkRow(
                    icon: "person.crop.circle",
                    label: "Author",
                    subtitle: "gordonbeeming.com",
                    url: "https://gordonbeeming.com"
                )
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 4)

            Text("FSL-1.1-MIT · © 2026 Gordon Beeming")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 28)
        .frame(width: 420, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        // Same activation treatment as Preferences — a regular Window
        // scene in an agent app won't take focus unless we explicitly
        // raise it after the policy flip settles.
        .onAppear {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == WindowID.about }) {
                    window.orderFrontRegardless()
                    window.makeKeyAndOrderFront(nil)
                    PreferencesActivation.didOpen(window)
                }
            }
        }
    }

    private func linkRow(icon: String, label: String, subtitle: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).bold()
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}
