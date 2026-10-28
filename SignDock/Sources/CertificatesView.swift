import SwiftUI
import UniformTypeIdentifiers

struct CertificatesView: View {
    @EnvironmentObject var store: AppStore
    @State private var adding = false

    private var accounts: [String] {
        var seen: [String] = []
        for c in store.certs { let a = c.account ?? "No account"; if !seen.contains(a) { seen.append(a) } }
        return seen
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(accounts, id: \.self) { account in
                Section(account) {
                ForEach(store.certs.filter { ($0.account ?? "No account") == account }) { cert in
                    Button { store.selectedCertID = cert.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cert.name).font(.headline).foregroundStyle(.primary)
                                Text("Team \(cert.teamID) · \(cert.profileName)").font(.caption).foregroundStyle(.secondary)
                                if let exp = cert.expires {
                                    Text("Expires \(exp.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2).foregroundStyle(cert.isExpired ? .red : .secondary)
                                }
                                Text(cert.grantsMoreMemory == true ? "Increased memory limit ✓" : "No increased memory limit")
                                    .font(.caption2).foregroundStyle(cert.grantsMoreMemory == true ? .green : .secondary)
                                if cert.revoked { Text("Revoked").font(.caption.bold()).foregroundStyle(.red) }
                            }
                            Spacer()
                            if store.selectedCert?.id == cert.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.remove(cert) } label: { Label("Delete", systemImage: "trash") }
                        Button { Task { await store.refreshStatus(cert) } } label: { Label("Check", systemImage: "arrow.triangle.2.circlepath") }.tint(.orange)
                    }
                }
                }
                }
            }
            .overlay { if store.certs.isEmpty { ContentUnavailableLike(title: "No certificates", message: "Add a .p12 and its .mobileprovision.") } }
            .navigationTitle("Certificates")
            .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $adding) { AddCertificateView() }
        }
    }
}

struct AddCertificateView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var account = ""
    @State private var p12: URL?
    @State private var profile: URL?
    @State private var password = ""
    @State private var picking: Kind?
    @State private var busy = false
    @State private var error: String?

    enum Kind: Identifiable { case p12, profile; var id: Self { self } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Apple ID / account (e.g. dev1@icloud.com)", text: $account)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Name (optional)", text: $name)
                    Button { picking = .p12 } label: { fileRow("Certificate (.p12)", p12) }
                    Button { picking = .profile } label: { fileRow("Profile (.mobileprovision)", profile) }
                    SecureField("p12 password", text: $password)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Add certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Add") { add() }.disabled(p12 == nil || profile == nil)
                    }
                }
            }
            .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                          allowedContentTypes: picking == .p12
                            ? [UTType(filenameExtension: "p12") ?? .data]
                            : [UTType(filenameExtension: "mobileprovision") ?? .data, .data]) { result in
                guard case .success(let url) = result else { return }
                if picking == .p12 { p12 = url } else { profile = url }
            }
        }
    }

    private func fileRow(_ title: String, _ url: URL?) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text(url?.lastPathComponent ?? "Choose").foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func add() {
        guard let p12, let profile else { return }
        busy = true; error = nil
        Task {
            do { try await store.addCertificate(name: name, account: account.trimmingCharacters(in: .whitespaces), p12: p12, profile: profile, password: password); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
