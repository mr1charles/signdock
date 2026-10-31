//
//  DockBoxPairing.swift
//  DockBox: make the pairing file on the phone itself, no computer. iOS 27+.
//  Trimmed from StikDebug 3.2.0's OnDevicePairingService (AGPL-3.0) to the same-device path:
//  DockBox advertises itself as a pairable host, the phone connects to it from Settings,
//  and the resulting file is stored where the built-in JIT reads it.
//

import AVFoundation
import Darwin
import Foundation
import Network
import SwiftUI
import UserNotifications
import idevice

enum DockBoxPairingPhase: Equatable {
    case idle, waiting, confirming
    case pin(String)
    case success(String)
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .waiting, .confirming, .pin: return true
        default: return false
        }
    }
}

@MainActor
final class DockBoxPairing: ObservableObject {
    static let shared = DockBoxPairing()

    @Published private(set) var phase = DockBoxPairingPhase.idle
    private(set) var hostname = "DockBox"

    private let keepAlive = SilentKeepAlive()
    private var netService: NetService?
    private var listenerFD: Int32 = -1
    private var operationID: UUID?

    func start() {
        guard !phase.isRunning else { return }
        let id = UUID()
        operationID = id
        hostname = "DockBox-" + String(UUID().uuidString.prefix(6)).lowercased()
        phase = .waiting
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Settings has to come forward to finish pairing, so stay alive in the background meanwhile.
        keepAlive.start()
        run(id)
    }

    func cancel() {
        operationID = nil
        stopNetworking()
        phase = .idle
    }

    private func stopNetworking() {
        netService?.stop()
        netService = nil
        if listenerFD >= 0 {
            // Wakes the worker blocked in accept().
            Darwin.shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
            listenerFD = -1
        }
        keepAlive.stop()
    }

    private func run(_ id: UUID) {
        let context = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        let hostname = hostname
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = Self.pair(context: context, hostname: hostname, listenerReady: { fd, serviceID, txt in
                DispatchQueue.main.sync {
                    guard self.operationID == id else { return false }
                    self.listenerFD = Darwin.dup(fd)
                    let service = NetService(domain: "", type: "_remotepairing-pairable-host._tcp.",
                                             name: serviceID, port: Int32(Self.port(of: fd)))
                    service.setTXTRecord(NetService.data(fromTXTRecord: txt))
                    service.publish()
                    self.netService = service
                    return true
                }
            }, connected: {
                DispatchQueue.main.sync {
                    guard self.operationID == id else { return false }
                    self.phase = .confirming
                    return true
                }
            })
            DispatchQueue.main.async {
                guard self.operationID == id else { return }
                self.operationID = nil
                self.stopNetworking()
                self.phase = failure.map(DockBoxPairingPhase.failed)
                    ?? .success("Paired. Built-in JIT is ready to use.")
            }
        }
    }

    /// Returns nil on success, or a message for the user.
    nonisolated private static func pair(context: UInt, hostname: String,
                                         listenerReady: (Int32, String, [String: Data]) -> Bool,
                                         connected: () -> Bool) -> String? {
        var host: OpaquePointer?
        var serviceID: UnsafeMutablePointer<CChar>?
        var txtBytes: UnsafeMutablePointer<UInt8>?
        var txtLength: UInt = 0
        var altIRK = [UInt8](repeating: 0, count: 16)
        let prepared = altIRK.withUnsafeMutableBufferPointer { buffer in
            hostname.withCString { name in
                "Mac17,7".withCString { model in
                    pairable_host_prepare(name, model, false, &host, &serviceID, &txtBytes, &txtLength, buffer.baseAddress)
                }
            }
        }
        if let prepared { return message(prepared, "Couldn't prepare pairing") }
        defer {
            pairable_host_free(host)
            idevice_string_free(serviceID)
            idevice_data_free(txtBytes, UInt(txtLength))
        }
        guard let host, let serviceID, let txtBytes,
              let txt = bonjourTXT(Data(bytes: txtBytes, count: Int(txtLength))) else {
            return "Pairing didn't return its network details."
        }

        let listener: Int32
        do { listener = try makeListener() } catch { return "Couldn't start listening: \(error.localizedDescription)" }
        defer { Darwin.close(listener) }
        guard listenerReady(listener, String(cString: serviceID), txt) else { return "Pairing was cancelled." }

        let connection = Darwin.accept(listener, nil, nil)
        guard connection >= 0 else { return "Pairing was cancelled." }
        defer { Darwin.close(connection) }
        // A file made with another device would never work on this one.
        guard isSameDevice(connection) else { return "Another device tried to pair. Start from Settings on this iPhone." }
        guard connected() else { return "Pairing was cancelled." }

        var peer: UnsafeMutablePointer<RpPairingPeerDeviceC>?
        var pairingFile: OpaquePointer?
        if let err = pairable_host_accept_fd(host, connection, pinCallback, UnsafeMutableRawPointer(bitPattern: context), &peer, &pairingFile) {
            return message(err, "Pairing failed")
        }
        defer {
            rp_pairing_file_free(pairingFile)
            rppairing_peer_device_free(peer)
        }
        guard let pairingFile else { return "Pairing finished without a pairing file." }

        // Written beside the target first, so a failed write keeps a working file.
        let staged = DockBoxJIT.pairingURL.appendingPathExtension("new")
        try? FileManager.default.removeItem(at: staged)
        if let err = staged.path.withCString({ rp_pairing_file_write(pairingFile, $0) }) {
            return message(err, "Couldn't save the pairing file")
        }
        do { try DockBoxJIT.installPairingFile(from: staged) }
        catch { return "Couldn't save the pairing file: \(error.localizedDescription)" }
        return nil
    }

    fileprivate func present(pin: String) {
        guard phase.isRunning else { return }
        phase = .pin(pin)
        let content = UNMutableNotificationContent()
        content.title = "DockBox pairing code"
        content.body = "Enter \(pin) to finish pairing."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "dockbox.pairing.pin", content: content, trigger: nil))
    }

    nonisolated private static func isSameDevice(_ connection: Int32) -> Bool {
        var peer = sockaddr_in(), local = sockaddr_in()
        var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size), localLength = peerLength
        let a = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(connection, $0, &peerLength) } }
        let b = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(connection, $0, &localLength) } }
        return a == 0 && b == 0 && peer.sin_addr.s_addr == local.sin_addr.s_addr
    }

    nonisolated private static func makeListener() throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    nonisolated private static func port(of fd: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return result == 0 ? UInt16(bigEndian: address.sin_port) : 0
    }

    nonisolated private static func bonjourTXT(_ data: Data) -> [String: Data]? {
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return dict.reduce(into: [:]) { out, entry in
            if let value = entry.value as? String { out[entry.key] = Data(value.utf8) }
            else if let value = entry.value as? Data { out[entry.key] = value }
            else if let value = entry.value as? NSNumber { out[entry.key] = Data(value.stringValue.utf8) }
        }
    }

    nonisolated private static func message(_ err: UnsafeMutablePointer<IdeviceFfiError>, _ fallback: String) -> String {
        defer { idevice_error_free(err) }
        if let raw = err.pointee.message, let detail = String(validatingUTF8: raw), !detail.isEmpty { return "\(fallback): \(detail)" }
        return fallback
    }
}

private let pinCallback: PairableHostPinCb = { pin, context in
    guard let pin, let context else { return }
    let service = Unmanaged<DockBoxPairing>.fromOpaque(context).takeUnretainedValue()
    let value = String(cString: pin)
    DispatchQueue.main.async { service.present(pin: value) }
}

/// Plays silence, mixed with other audio, so iOS keeps the app running while Settings is open.
private final class SilentKeepAlive {
    private var engine: AVAudioEngine?

    func start() {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return }
            buffer.frameLength = buffer.frameCapacity // zero-filled: silence
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            try engine.start()
            player.play()
            self.engine = engine
        } catch {
            NSLog("[DockBox] keep-alive failed: %@", error.localizedDescription)
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct DockBoxPairingView: View {
    @ObservedObject private var pairing = DockBoxPairing.shared
    @Environment(\.dismiss) private var dismiss
    var onPaired: () -> Void = {}

    var body: some View {
        NavigationView {
            Form { content }
                .navigationTitle("Pair this iPhone")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { pairing.cancel(); dismiss() }
                    }
                }
        }
        .onChange(of: pairing.phase) { phase in
            if case .success = phase { onPaired() }
        }
    }

    @ViewBuilder private var content: some View {
        switch pairing.phase {
        case .idle:
            Section {
                Button { pairing.start() } label: { Label("Start pairing", systemImage: "iphone.radiowaves.left.and.right") }
            } footer: {
                Text("Makes the pairing file on this iPhone, with no computer. Needs iOS 27 or later and Wi-Fi. On older iOS, import a file made on a computer instead.")
            }
        case .waiting:
            Section { HStack(spacing: 12) { ProgressView(); Text("Waiting for Settings…").foregroundColor(.secondary) } }
            Section("Now, on this iPhone") {
                step(1, "Open the Settings app.")
                step(2, "Go to Privacy & Security › Developer Mode.")
                step(3, "Tap Pair with \(pairing.hostname).")
                step(4, "Enter the code DockBox sends you as a notification.")
            }
        case .confirming:
            Section { HStack(spacing: 12) { ProgressView(); Text("Confirming…") } }
        case .pin(let pin):
            Section {
                VStack(spacing: 12) {
                    Text("Enter this code in Settings").font(.headline)
                    Text(pin).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        case .success(let message):
            Section { Label(message, systemImage: "checkmark.seal.fill").foregroundColor(.green) }
        case .failed(let message):
            Section { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red) }
            Section { Button("Try again") { pairing.start() } }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.footnote.bold()).frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            Text(text)
        }
    }
}
