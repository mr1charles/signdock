//
//  DockBoxModes.swift
//  DockBox: per-app mode presets. A mode only sets LiveContainer's existing per-app options in one tap.
//

import SwiftUI

enum DockBoxMode: String, CaseIterable, Identifiable {
    case standard, game, compatibility
    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .game: return "Game"
        case .compatibility: return "Compatibility"
        }
    }
    var summary: String {
        switch self {
        case .standard: return "Default behavior, no JIT."
        case .game: return "JIT on, landscape lock, Multitask when using built-in JIT."
        case .compatibility: return "No JIT, no Multitask, file picker and notification fixes on."
        }
    }

    private static func key(_ path: String) -> String { "DockBoxMode.\(path)" }
    static func saved(for path: String) -> DockBoxMode {
        DockBoxJIT.defaults.string(forKey: key(path)).flatMap(DockBoxMode.init) ?? .standard
    }
    static func save(_ mode: DockBoxMode, for path: String) {
        DockBoxJIT.defaults.set(mode.rawValue, forKey: key(path))
    }

    @MainActor
    func apply(to model: LCAppModel) {
        let builtIn = JITEnablerType(rawValue: DockBoxJIT.defaults.integer(forKey: "LCJITEnablerType")) == .BuiltIn
        switch self {
        case .standard:
            model.uiIsJITNeeded = false
            model.uiOrientationLock = .Disabled
            model.uiIsMultitaskModeSpecificed = .default
        case .game:
            model.uiIsJITNeeded = true
            model.uiOrientationLock = .Landscape
            model.uiIsMultitaskModeSpecificed = builtIn ? .yes : .default
        case .compatibility:
            model.uiIsJITNeeded = false
            model.uiOrientationLock = .Disabled
            model.uiIsMultitaskModeSpecificed = .no
            model.uiFixFilePickerNew = true
            model.uiFixLocalNotification = true
        }
    }
}

struct DockBoxModeSection: View {
    @ObservedObject var model: LCAppModel
    @State private var mode: DockBoxMode

    init(model: LCAppModel) {
        self.model = model
        _mode = State(initialValue: DockBoxMode.saved(for: model.appInfo.relativeBundlePath ?? ""))
    }

    var body: some View {
        Section {
            Picker("Mode", selection: $mode) {
                ForEach(DockBoxMode.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: mode) { newValue in
                DockBoxMode.save(newValue, for: model.appInfo.relativeBundlePath ?? "")
                newValue.apply(to: model)
            }
        } header: {
            Text("DockBox mode")
        } footer: {
            Text(mode.summary)
        }
    }
}
