//
//  DockBoxMemory.swift
//  DockBox: memory headroom, pressure handling and the memory status screen.
//  iOS sets each process's ceiling and an app can't remove it. What an app can do is ask for the higher
//  ceiling (the entitlement), use less, and back off before iOS kills it. That's what lives here.
//

import SwiftUI
import os

enum DockBoxMemory {
    /// Below this, signing waits before starting the next app.
    static let signingFloor: UInt64 = 200 * 1024 * 1024

    static var available: UInt64 { UInt64(os_proc_available_memory()) }
    static var availableText: String {
        // 0 means iOS didn't report a limit, e.g. in a process with none.
        available == 0 ? "Unknown" : ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .memory)
    }

    enum Grant { case active, notGranted, unknown }
    /// Whether the profile this copy of DockBox was signed with grants the Increased Memory Limit.
    /// Containers inherit DockBox's limit, so this decides what guest apps get too.
    static let grant: Grant = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url), let info = ProvisionParser.parse(data) else { return .unknown }
        return info.grantsMoreMemory ? .active : .notGranted
    }()

    private static var pressureSource: DispatchSourceMemoryPressure?

    /// Drops what can be rebuilt as soon as iOS warns about memory.
    static func startWatching() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { URLCache.shared.removeAllCachedResponses() }
        source.resume()
        pressureSource = source
    }

    /// Gives iOS and other apps a moment to free memory before heavy work. Gives up after `timeout`, because
    /// the work may still fit and a stalled queue is worse.
    static func waitForHeadroom(timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while available != 0, available < signingFloor, Date() < deadline {
            URLCache.shared.removeAllCachedResponses()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Clears work folders left behind if signing was killed part-way.
    static func sweepStaleWork() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("sign-") {
            try? fm.removeItem(at: tmp.appendingPathComponent(name))
        }
    }
}

struct DockBoxMemoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var available = DockBoxMemory.availableText
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack { Text("Available to DockBox now"); Spacer(); Text(available).monospacedDigit().foregroundColor(.secondary) }
                    HStack { Text("Increased memory limit"); Spacer(); status }
                } footer: { Text(explanation) }
                Section("What DockBox does for you") {
                    Label("Signs one app at a time and frees memory between apps", systemImage: "square.stack.3d.up")
                    Label("Waits for memory to free up before the next app", systemImage: "hourglass")
                    Label("Clears caches as soon as iOS warns about memory", systemImage: "wind")
                }
                Section {
                    Text("iOS sets the ceiling for every app, and no app can remove it. A game that needs more than your iPhone allows can still be closed by iOS. Close other apps first, and use one container at a time for the most room.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onReceive(timer) { _ in available = DockBoxMemory.availableText }
        }
    }

    @ViewBuilder private var status: some View {
        switch DockBoxMemory.grant {
        case .active: Text("Active").foregroundColor(.green)
        case .notGranted: Text("Not granted").foregroundColor(.orange)
        case .unknown: Text("Unknown").foregroundColor(.secondary)
        }
    }

    private var explanation: String {
        switch DockBoxMemory.grant {
        case .active: return "Your signing profile grants the higher limit, so DockBox and the apps in its containers can use it."
        case .notGranted: return "DockBox asks for the higher limit, but the profile it was installed with doesn't grant it, so normal limits apply. Reinstall with an account or tool whose profile includes Increased Memory Limit."
        case .unknown: return "DockBox couldn't read the profile it was installed with, so it can't tell which limit applies."
        }
    }
}
