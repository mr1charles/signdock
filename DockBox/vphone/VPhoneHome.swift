//
//  VPhoneHome.swift
//  VPhone: a second phone screen with its own home screen. Tapping an icon runs that app in a window through
//  LiveContainer's Multitask mode. These are real apps sharing this iPhone's iOS, not an emulated iPhone.
//

import SwiftUI

struct VPhoneHomeView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var failure: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
    private var apps: [LCAppModel] { sharedModel.apps }

    var body: some View {
        GeometryReader { screen in
            let width = min(screen.size.width - 24, (screen.size.height - 16) * 0.5)
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .fill(Color.black)
                    .overlay(display.clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous)).padding(8))
                    .frame(width: width, height: min(screen.size.height - 16, width * 2))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Couldn't open app", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var display: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.12, blue: 0.36), Color(red: 0.05, green: 0.36, blue: 0.55)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(context.date, style: .time)
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.top, 14)
                }
                if apps.isEmpty {
                    Spacer()
                    Text("No apps yet. Add some in the Apps tab, and they'll appear here.")
                        .font(.footnote).foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center).padding(24)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(apps, id: \.appInfo.relativeBundlePath) { icon(for: $0) }
                        }
                        .padding(14)
                    }
                }
                HStack(spacing: 28) {
                    dockButton("square.stack.3d.up.fill", "Apps", .apps)
                    dockButton("gearshape.fill", "Settings", .settings)
                }
                .padding(.vertical, 10).padding(.horizontal, 24)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(.bottom, 14)
            }
        }
    }

    private func icon(for app: LCAppModel) -> some View {
        Button {
            Task {
                do { try await app.runApp(multitask: true) }
                catch { failure = error.localizedDescription }
            }
        } label: {
            VStack(spacing: 4) {
                Image(uiImage: app.appInfo.icon(isDarkIcon: colorScheme == .dark))
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(app.appInfo.displayName() ?? "App")
                    .font(.caption2).foregroundColor(.white).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .opacity(app.isAppRunning ? 0.5 : 1)
    }

    private func dockButton(_ symbol: String, _ label: String, _ tab: LCTabIdentifier) -> some View {
        Button { sharedModel.selectedTab = tab } label: {
            Image(systemName: symbol).font(.title3).foregroundColor(.white)
        }
        .accessibilityLabel(label)
    }
}
