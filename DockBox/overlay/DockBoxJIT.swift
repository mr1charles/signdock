//
//  DockBoxJIT.swift
//  DockBox: built-in JIT provider.
//
//  Ported from StikDebug (AGPL-3.0), Device/JITEnableContext.swift: same idevice FFI calls, trimmed to
//  "attach to a PID, then detach".
//
//  vAttach stops the target until it is detached, so the debugger must NOT be the process being
//  debugged. That makes this provider work only for apps that run in their own process (LiveContainer's
//  Multitask / LiveProcess mode). For same-process launches DockBox falls back to StikDebug.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Darwin
import Network
import idevice

struct DockBoxJITError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

final class DockBoxJIT {
    static let shared = DockBoxJIT()

    static let fallbackKey = "DockBoxFallbackToStikDebug"
    static let targetIPKey = "DockBoxTargetIP"
    static let defaultIP = "10.7.0.1" // LocalDevVPN's loopback address
    static let fallbackPort: UInt16 = 49152
    static let portOverrideKey = "DockBoxRemotePairingPort"

    static var defaults: UserDefaults { LCUtils.appGroupUserDefault }

    static var pairingURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DockBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pairingFile.plist")
    }
    static var hasPairingFile: Bool { FileManager.default.fileExists(atPath: pairingURL.path) }

    private static var targetIP: String {
        let value = (defaults.string(forKey: targetIPKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? defaultIP : value
    }

    /// For launches where the guest runs inside this process. Built-in JIT can't work there, so either
    /// hand over to StikDebug (default) or stop with an explanation.
    static func sameProcessEnabler(for type: JITEnablerType, onServerMessage: ((String) -> Void)?) -> JITEnablerType? {
        guard type == .BuiltIn else { return type }
        if defaults.object(forKey: fallbackKey) as? Bool ?? true {
            onServerMessage?("Built-in JIT needs the app to run in Multitask mode. Using StikDebug for this launch.")
            return .StikJIT
        }
        onServerMessage?("Built-in JIT needs the app to run in Multitask mode. Turn on Multitask for this app, or allow the StikDebug fallback in Settings.")
        return nil
    }

    // MARK: Public

    func enableJIT(pid: Int32) async throws {
        guard pid != getpid() else {
            throw DockBoxJITError("Built-in JIT can't attach to its own process. Run the app in Multitask mode.")
        }
        try await Self.onWorker { try self.attach(pid: pid) }
    }

    /// Opens the tunnel and debug proxy without attaching to anything.
    func testConnection() async throws -> String {
        try await Self.onWorker {
            try self.withDebugProxy { _ in }
            return "Connected to \(PairingPortResolver.lastAttempt): tunnel and debug proxy are working."
        }
    }

    // MARK: Internals

    private static func onWorker<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try work() })
            }
        }
    }

    private func ffiError(_ err: UnsafeMutablePointer<IdeviceFfiError>?, _ fallback: String) -> DockBoxJITError {
        guard let err else { return DockBoxJITError(fallback) }
        defer { idevice_error_free(err) }
        if let msg = err.pointee.message, let detail = String(validatingUTF8: msg), !detail.isEmpty {
            return DockBoxJITError("\(fallback): \(detail)")
        }
        return DockBoxJITError(fallback)
    }

    private func attach(pid: Int32) throws {
        try withDebugProxy { proxy in
            debug_proxy_send_ack(proxy)
            debug_proxy_send_ack(proxy)
            _ = try send("QStartNoAckMode", proxy)
            debug_proxy_set_ack_mode(proxy, 0)
            let attached = try send("vAttach;\(String(UInt32(pid), radix: 16))", proxy)
            NSLog("[DockBox] Attach response: %@", attached ?? "<nil>")
            let detached = try send("D", proxy)
            NSLog("[DockBox] Detach response: %@", detached ?? "<nil>")
        }
    }

    private func send(_ command: String, _ proxy: OpaquePointer) throws -> String? {
        guard let handle = debugserver_command_new(command, nil, 0) else {
            throw DockBoxJITError("Failed to create debugserver command: \(command)")
        }
        var response: UnsafeMutablePointer<CChar>?
        let err = debug_proxy_send_command(proxy, handle, &response)
        debugserver_command_free(handle)
        defer { if let response { idevice_string_free(response) } }
        if let err { throw ffiError(err, "Debugserver command failed: \(command)") }
        return response.map { String(cString: $0) }
    }

    private func withDebugProxy(_ body: (OpaquePointer) throws -> Void) throws {
        guard Self.hasPairingFile else {
            throw DockBoxJITError("No pairing file. Import one in Settings → JIT.")
        }
        var pairing: OpaquePointer?
        if let err = Self.pairingURL.path.withCString({ rp_pairing_file_read($0, &pairing) }) {
            throw ffiError(err, "Failed to read pairing file")
        }
        guard let pairing else { throw DockBoxJITError("Failed to read pairing file") }
        defer { rp_pairing_file_free(pairing) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        let port = PairingPortResolver.resolve()
        PairingPortResolver.record(Self.targetIP, port)
        addr.sin_port = in_port_t(port).bigEndian
        guard Self.targetIP.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw DockBoxJITError("Target IP \"\(Self.targetIP)\" isn't a valid IPv4 address.")
        }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        let tunnelErr = "DockBox".withCString { host in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.stride), host, pairing,
                                            nil, nil, &adapter, &handshake)
                }
            }
        }
        if let tunnelErr {
            throw ffiError(tunnelErr, "Couldn't open the device tunnel at \(PairingPortResolver.lastAttempt). Make sure Wi-Fi is connected or Cellular Data is off and LocalDevVPN is on. If it keeps failing, restart the device or generate a fresh pairing file")
        }
        guard let adapter, let handshake else { throw DockBoxJITError("Tunnel was created without valid handles") }
        defer { rsd_handshake_free(handshake); adapter_free(adapter) }

        var proxy: OpaquePointer?
        if let err = debug_proxy_connect_rsd(adapter, handshake, &proxy) {
            throw ffiError(err, "Failed to connect to the debug proxy")
        }
        guard let proxy else { throw DockBoxJITError("Debug proxy handle was not created") }
        defer { debug_proxy_free(proxy) }

        try body(proxy)
    }
}

/// Finds the device's remote-pairing port over Bonjour, preferring the loopback service LocalDevVPN exposes.
/// A port set in Settings wins; otherwise falls back to the usual default.
private final class PairingPortResolver {
    private static let lock = NSLock()
    private static var attempted = "no attempt yet"

    static var lastAttempt: String {
        lock.lock(); defer { lock.unlock() }
        return attempted
    }

    static func record(_ ip: String, _ port: UInt16) {
        lock.lock(); defer { lock.unlock() }
        attempted = "\(ip):\(port)"
    }

    private let queue = DispatchQueue(label: "DockBox.remotePairingDiscovery")
    private let done = DispatchSemaphore(value: 0)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var service: NWEndpoint?
    private var serviceIsLoopback = false
    private var port: UInt16?
    private var finished = false

    static func resolve(timeout: TimeInterval = 5) -> UInt16 {
        let manual = (DockBoxJIT.defaults.string(forKey: DockBoxJIT.portOverrideKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = UInt16(manual), port != 0 { return port }

        let worker = PairingPortResolver()
        worker.queue.async { worker.start() }
        _ = worker.done.wait(timeout: .now() + timeout)
        return worker.queue.sync {
            worker.finish()
            return worker.port ?? DockBoxJIT.fallbackPort
        }
    }

    private func start() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.finished else { return }
            let found = results.compactMap { result -> (endpoint: NWEndpoint, loopback: Bool)? in
                guard case .service = result.endpoint else { return nil }
                return (result.endpoint, result.interfaces.contains { $0.name.hasPrefix("lo") })
            }
            guard let pick = found.first(where: { $0.loopback }) ?? found.first,
                  self.service == nil || (!self.serviceIsLoopback && pick.loopback) else { return }
            self.service = pick.endpoint
            self.serviceIsLoopback = pick.loopback
            self.connect(to: pick.endpoint, using: parameters)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
        }
        browser.start(queue: queue)
    }

    /// Bonjour results carry no port; connecting to the service reveals the host and port behind it.
    private func connect(to endpoint: NWEndpoint, using parameters: NWParameters) {
        connection?.cancel()
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.pathUpdateHandler = { [weak self, weak connection] path in
            guard let self, let connection, self.connection === connection, path.status == .satisfied else { return }
            self.recordPort(from: connection)
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready, .waiting: self.recordPort(from: connection)
            case .failed: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func recordPort(from connection: NWConnection) {
        guard !finished, case .hostPort(_, let found) = connection.currentPath?.remoteEndpoint,
              found.rawValue != 0 else { return }
        port = found.rawValue
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        browser?.cancel()
        connection?.cancel()
        done.signal()
    }
}

// MARK: - Settings UI

struct DockBoxJITSettingsSection: View {
    @AppStorage(DockBoxJIT.targetIPKey, store: LCUtils.appGroupUserDefault) private var targetIP = DockBoxJIT.defaultIP
    @AppStorage(DockBoxJIT.portOverrideKey, store: LCUtils.appGroupUserDefault) private var manualPort = ""
    @AppStorage(DockBoxJIT.fallbackKey, store: LCUtils.appGroupUserDefault) private var fallback = true
    @State private var importing = false
    @State private var hasPairing = DockBoxJIT.hasPairingFile
    @State private var status = ""
    @State private var testing = false

    var body: some View {
        Group {
            HStack {
                Text("Pairing file")
                Spacer()
                Text(hasPairing ? "Imported" : "Missing").foregroundColor(hasPairing ? .green : .secondary)
            }
            Button(hasPairing ? "Replace pairing file…" : "Import pairing file…") { importing = true }
            HStack {
                Text("Device IP")
                Spacer()
                TextField(DockBoxJIT.defaultIP, text: $targetIP)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
            }
            HStack {
                Text("Pairing port")
                Spacer()
                TextField("Automatic", text: $manualPort)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
            }
            Toggle("Use StikDebug when the app isn't in Multitask", isOn: $fallback)
            Button {
                testing = true; status = ""
                Task {
                    do { status = try await DockBoxJIT.shared.testConnection() }
                    catch { status = error.localizedDescription }
                    testing = false
                }
            } label: {
                HStack { Text("Test connection"); if testing { Spacer(); ProgressView() } }
            }.disabled(testing)
            if !status.isEmpty { Text(status).font(.footnote).foregroundColor(.secondary) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // Copy first so a failed import keeps the working pairing file.
                let staged = DockBoxJIT.pairingURL.appendingPathExtension("import")
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.copyItem(at: url, to: staged)
                _ = try FileManager.default.replaceItemAt(DockBoxJIT.pairingURL, withItemAt: staged)
                hasPairing = true
                status = "Pairing file imported."
            } catch { status = "Import failed: \(error.localizedDescription)" }
        }
    }
}
