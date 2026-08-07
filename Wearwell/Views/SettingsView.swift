import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var hosted: HostedClient
    @EnvironmentObject private var auth: HostedAuthController
    @EnvironmentObject private var protection: DataProtectionController
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var inviteCode = ""
    @State private var working = false
    @State private var error: String?
    @State private var message: String?
    @State private var usage: HostedUsage?
    @State private var backupDocument: WearwellBackupDocument?
    @State private var exportingBackup = false
    @State private var importingBackup = false
    @State private var confirmingDeletion = false

    var body: some View {
        Form {
            Section {
                EditorialHeader(
                    eyebrow: "Private cloud wardrobe",
                    title: "Wearwell account",
                    subtitle: "Your OpenAI key is never stored in this app. AI requests run through Wearwell's hosted service."
                )
            }

            Section("Account") {
                LabeledContent("Status") { StatusPill(text: hosted.status.label, color: hosted.status == .available ? WearwellTheme.sage : WearwellTheme.coral) }
                if !auth.isAuthenticated {
                    Button { Task { await appleSignIn() } } label: { Label("Continue with Apple", systemImage: "apple.logo") }
                    TextField("Email", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    Button("Email me a sign-in link") { Task { await emailSignIn() } }.disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let authMessage = auth.message { Text(authMessage).font(.caption).foregroundStyle(.secondary) }
                } else {
                    if hosted.status == .inviteRequired {
                        TextField("Invitation code", text: $inviteCode).textInputAutocapitalization(.characters)
                        Button("Activate beta access") { Task { await redeemInvite() } }.disabled(inviteCode.count < 6)
                    }
                    Button("Sign out") { Task { await signOut() } }
                }
                if !HostedConfiguration.isConfigured { Text("Add hosted environment values to the active xcconfig before signing in.").font(.caption).foregroundStyle(.orange) }
            }

            if let usage {
                Section("Monthly usage") {
                    usageRow("Garment analyses", usage.analysisUsed, usage.analysisLimit)
                    usageRow("Styling and purchase tests", usage.styleUsed, usage.styleLimit)
                    usageRow("Generated images", usage.imageUsed, usage.imageLimit)
                    LabeledContent("Private image storage") { Text(ByteCountFormatter.string(fromByteCount: Int64(usage.storageUsed), countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: Int64(usage.storageLimit), countStyle: .file)) }
                }
            }

            if auth.isAuthenticated, hosted.status == .available {
                Section("Private sharing") {
                    NavigationLink {
                        FriendsView()
                    } label: {
                        Label("Friends, shares, and activity", systemImage: "person.2")
                    }
                    Text("Everything stays private unless you explicitly share one flattened outfit preview with an accepted friend.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Offline cache") {
                LabeledContent("Status") { StatusPill(text: protection.storageState.title, color: protection.storageState == .available ? WearwellTheme.sage : WearwellTheme.coral) }
                Text("Previously synced wardrobe records and pictures remain readable offline. Changes, uploads, imports, and AI actions require a connection.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Backup and migration") {
                Button { Task { await prepareBackup() } } label: { Label(working ? "Preparing…" : "Export Wearwell backup", systemImage: "square.and.arrow.up") }.disabled(working)
                Button { importingBackup = true } label: { Label("Import Wearwell backup", systemImage: "arrow.down.doc") }.disabled(working || hosted.status != .available)
                Text("Import merges records by ID. Existing unrelated cloud records are not erased.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Only images selected for Wearwell features are uploaded. Records and images are private to your account. Generated images are approximations, not proof of fit or garment accuracy.")
                if auth.isAuthenticated { Button("Delete account and cloud data", role: .destructive) { confirmingDeletion = true } }
            }

            if let message { Text(message).foregroundStyle(WearwellTheme.sage) }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Settings")
        .toolbar { Button("Done") { dismiss() } }
        .task { await refresh() }
        .onChange(of: auth.isAuthenticated) { _, authenticated in
            if authenticated { Task { await refresh(); try? await hosted.synchronizeCache(context: context, force: true) } }
        }
        .alert("Delete your Wearwell account?", isPresented: $confirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await deleteAccount() } }
        } message: { Text("Access stops immediately. Wearwell permanently purges your cloud records and images within seven days.") }
        .fileExporter(isPresented: $exportingBackup, document: backupDocument, contentType: WearwellBackupDocument.contentType, defaultFilename: "Wearwell-\(Date.now.formatted(.iso8601.year().month().day())).wearwellbackup") { result in
            if case .failure(let value) = result { error = value.localizedDescription }
            backupDocument = nil
        }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [WearwellBackupDocument.contentType], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { if case .failure(let value) = result { error = value.localizedDescription }; return }
            Task { await restoreBackup(at: url) }
        }
    }

    private func usageRow(_ title: String, _ used: Int, _ limit: Int) -> some View { LabeledContent(title) { Text("\(used) / \(limit)") } }

    private func refresh() async { await hosted.refreshStatus(); usage = try? await hosted.usage() }
    private func appleSignIn() async { working = true; defer { working = false }; do { try await auth.signInWithApple(); await refresh() } catch { self.error = error.localizedDescription } }
    private func emailSignIn() async { working = true; defer { working = false }; do { try await auth.sendEmailLink(to: email); message = "Sign-in link sent." } catch { self.error = error.localizedDescription } }
    private func redeemInvite() async { working = true; defer { working = false }; do { try await hosted.redeemInvite(inviteCode); inviteCode = ""; await refresh() } catch { self.error = error.localizedDescription } }
    private func signOut() async {
        await hosted.clearLocalCache(context: context)
        auth.signOut()
        hosted.status = .signedOut
    }

    private func deleteAccount() async {
        working = true; defer { working = false }
        do {
            try await hosted.deleteAccount()
            await hosted.clearLocalCache(context: context)
            auth.signOut()
            message = "Account locked. Cloud deletion is scheduled."
        } catch { self.error = error.localizedDescription }
    }

    private func prepareBackup() async {
        working = true; defer { working = false }
        do { backupDocument = try await BackupService.makeDocument(context: context); exportingBackup = true }
        catch { self.error = error.localizedDescription }
    }

    private func restoreBackup(at url: URL) async {
        working = true; defer { working = false }
        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let document = try WearwellBackupDocument(fileWrapper: FileWrapper(url: url, options: .immediate))
            let result = try await BackupService.restore(document, context: context)
            try await hosted.importBackup(document)
            message = result.summary + " Cloud migration queued."
        } catch { self.error = error.localizedDescription }
    }
}
