import SwiftUI

struct AccountView: View {
    @EnvironmentObject var cloud: Cloud
    @EnvironmentObject var store: AppStore
    @AppStorage("backupIPAs") private var backupIPAs = true

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var passphrase = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Section {
            if let session = cloud.session {
                LabeledContent("Signed in", value: session.email)
                vaultRows
                Toggle("Back up IPA files", isOn: $backupIPAs)
                Button {
                    Task { await cloud.syncNow(store: store, backupIPAs: backupIPAs) }
                } label: {
                    HStack { Text("Sync now"); if cloud.busy { Spacer(); ProgressView() } }
                }.disabled(cloud.busy)
                if !cloud.status.isEmpty { Text(cloud.status).font(.footnote).foregroundStyle(.secondary) }
                Button("Sign out", role: .destructive) { cloud.signOut() }
            } else {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                    .disabled(codeSent)
                if codeSent {
                    TextField("Code from the email", text: $code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    Button("Verify and sign in") { run { try await cloud.verify(email: email, code: code.trimmingCharacters(in: .whitespaces))
                        await cloud.syncNow(store: store, backupIPAs: backupIPAs) } }
                        .disabled(code.count < 6 || working)
                    Button("Use a different email") { codeSent = false; code = "" }
                } else {
                    Button("Email me a code") { run { try await cloud.sendCode(to: email); codeSent = true } }
                        .disabled(!email.contains("@") || working)
                }
            }
            if working { ProgressView() }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: { Text("Cloud backup") }
        footer: {
            Text("Sign in on a new install to get your library, history and certificates back. Certificates are encrypted on this device with your vault passphrase before upload; the server can't read them.")
        }
    }

    @ViewBuilder private var vaultRows: some View {
        switch cloud.vault {
        case .needsSetup:
            SecureField("Create a vault passphrase", text: $passphrase)
            Button("Create vault") { run { try await cloud.setUpVault(passphrase: passphrase); passphrase = ""
                await cloud.syncNow(store: store, backupIPAs: backupIPAs) } }
                .disabled(passphrase.count < 8 || working)
            Text("At least 8 characters. If you forget it, certificates can't be recovered; you'd re-add them.")
                .font(.footnote).foregroundStyle(.secondary)
        case .locked:
            SecureField("Vault passphrase", text: $passphrase)
            Button("Unlock vault") { run { try await cloud.unlock(passphrase: passphrase); passphrase = ""
                await cloud.syncNow(store: store, backupIPAs: backupIPAs) } }
                .disabled(passphrase.isEmpty || working)
        case .ready:
            LabeledContent("Certificate vault", value: "Unlocked")
        case .unknown:
            EmptyView()
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true; error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
