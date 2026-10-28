import SwiftUI

struct SignSheet: View {
    let items: [LibraryItem]
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var signer = BatchSigner()
    @State private var certID: UUID?
    @State private var suffix = ""
    @State private var requireMoreMemory = false

    private var cert: CertificateProfile? {
        store.certs.first { $0.id == (certID ?? store.selectedCert?.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if signer.jobs.isEmpty {
                    Section("Certificate") {
                        if store.certs.isEmpty {
                            Text("Add a certificate in the Certificates tab first.").foregroundStyle(.secondary)
                        } else {
                            Picker("Certificate", selection: Binding(get: { cert?.id }, set: { certID = $0 })) {
                                ForEach(store.certs) { c in
                                    Text((c.account.map { "\($0) · " } ?? "") + c.name + (c.revoked ? " (revoked)" : c.isExpired ? " (expired)" : "")).tag(Optional(c.id))
                                }
                            }
                        }
                    }
                    Section {
                        Toggle("Require increased memory limit", isOn: $requireMoreMemory)
                    } footer: {
                        Text(cert?.grantsMoreMemory == true
                             ? "This certificate's profile grants it, so every app signed with it gets the higher limit."
                             : "This certificate's profile doesn't grant it. Apps run with normal limits; with this on, signing will stop with an error.")
                    }
                    Section {
                        TextField("e.g. mine  →  com.app.mine", text: $suffix)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Bundle ID suffix (optional)") }
                    footer: { Text("Leave empty to keep each app's bundle ID. The provisioning profile must allow the resulting ID.") }
                }
                Section(signer.jobs.isEmpty ? "\(items.count) apps" : "Progress") {
                    if signer.jobs.isEmpty {
                        ForEach(items) { Text($0.name) }
                    } else {
                        ForEach(signer.jobs) { job in JobRow(job: job) }
                    }
                }
            }
            .navigationTitle("Sign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(signer.finished ? "Done" : "Close") { dismiss() }.disabled(signer.running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if signer.jobs.isEmpty {
                        Button("Start") {
                            guard let cert else { return }
                            Task { await signer.run(items: items, cert: cert, bundleSuffix: suffix, requireMoreMemory: requireMoreMemory, store: store) }
                        }.disabled(cert == nil || cert?.revoked == true || cert?.isExpired == true)
                    }
                }
            }
        }
        .interactiveDismissDisabled(signer.running)
    }
}

struct JobRow: View {
    let job: BatchSigner.Job
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.item.name)
                Spacer()
                switch job.state {
                case .queued: Text("Queued").foregroundStyle(.secondary)
                case .working: ProgressView()
                case .done:
                    if let url = job.output { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } }
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            if case .failed(let message) = job.state {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
