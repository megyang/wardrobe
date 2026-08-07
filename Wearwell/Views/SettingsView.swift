import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var companion: CompanionClient
    @EnvironmentObject private var protection: DataProtectionController
    @EnvironmentObject private var macBackups: MacBackupController
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var host = UserDefaults.standard.string(forKey: "companionHost") ?? ""
    @State private var port = "8791"
    @State private var code = ""
    @State private var pairing = false
    @State private var error: String?
    @State private var backupDocument: WearwellBackupDocument?
    @State private var exportingBackup = false
    @State private var importingBackup = false
    @State private var backupWorking = false
    @State private var backupMessage: String?
    @State private var confirmingRecovery = false

    var body: some View {
        Form {
            Section {
                EditorialHeader(eyebrow: "Private local AI", title: "Mac companion", subtitle: "Luna uses your Mac's ChatGPT-backed Codex login. There is no API key in the app.", compact: true)
                LabeledContent("Connection") {
                    StatusPill(text: companion.status.label, color: companion.status == .available ? WearwellTheme.sage : WearwellTheme.coral)
                }
            }
            Section("Local data protection") {
                LabeledContent("Status") {
                    StatusPill(
                        text: protection.storageState.title,
                        color: protection.storageState == .available ? WearwellTheme.sage : WearwellTheme.coral
                    )
                }
                Text(protection.storageState.detail).font(.caption).foregroundStyle(.secondary)
                if protection.isMigrating {
                    ProgressView(
                        "Protecting existing pictures…",
                        value: Double(protection.migrationCurrent),
                        total: Double(max(1, protection.migrationTotal))
                    )
                } else if protection.migrationComplete {
                    Label("Existing pictures are protected locally", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(WearwellTheme.sage)
                }
                if let migrationError = protection.migrationError {
                    Text("Picture migration will retry next launch: \(migrationError)").font(.caption).foregroundStyle(.red)
                }
                Button("Check storage again") { protection.refreshStorageStatus() }
                Text("This development build keeps wardrobe data on this iPhone. Use Backup and Restore below to move or recover it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backup and restore") {
                Toggle("Automatic Mac backups", isOn: Binding(
                    get: { macBackups.automaticEnabled },
                    set: { macBackups.automaticEnabled = $0 }
                ))
                Button {
                    Task { await macBackups.backupIfDue(context: context, companion: companion, force: true) }
                } label: {
                    Label(macBackups.isBackingUp ? (macBackups.progressText ?? "Backing up…") : "Back up to Mac now", systemImage: "externaldrive.badge.icloud")
                }.disabled(macBackups.isBackingUp)
                if let lastBackup = macBackups.lastBackupAt {
                    LabeledContent("Last Mac backup") { Text(lastBackup, style: .relative) }
                }
                if let status = macBackups.remoteStatus {
                    Text("Mac has \(status.snapshotCount) restore points. Wearwell retains up to \(status.retention.daily) daily and \(status.retention.weekly) weekly snapshots.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let backupError = macBackups.lastError {
                    Text("Mac backup will retry when connected: \(backupError)").font(.caption).foregroundStyle(.orange)
                }
                Button {
                    confirmingRecovery = true
                } label: {
                    Label("Recover saved clothing images", systemImage: "photo.stack")
                }.disabled(backupWorking)
                Button {
                    Task { await prepareBackup() }
                } label: {
                    Label(backupWorking ? "Preparing backup…" : "Export Wearwell backup", systemImage: "square.and.arrow.up")
                }.disabled(backupWorking)
                Button {
                    importingBackup = true
                } label: {
                    Label("Restore Wearwell backup", systemImage: "arrow.clockwise.icloud")
                }.disabled(backupWorking)
                Text("Restore merges by record ID and never erases unrelated items already in your wardrobe.")
                    .font(.caption).foregroundStyle(.secondary)
                if let backupMessage { Text(backupMessage).font(.caption).foregroundStyle(WearwellTheme.sage) }
            }
            Section("Wardrobe organization") {
                NavigationLink {
                    SubcategorySettingsView()
                } label: {
                    Label("My subcategories", systemImage: "tag")
                }
                Text("Create, rename, and remove the types that appear in your wardrobe. These are stored only with your personal Wearwell data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connection") {
                LabeledContent("Status") { StatusPill(text: companion.status.label, color: companion.status == .available ? WearwellTheme.sage : WearwellTheme.coral) }
                if let found = companion.discoveredHost {
                    LabeledContent("Discovered") { Text(found) }
                    if host != found {
                        Button("Use discovered Mac") { host = found }
                    }
                }
                TextField("Mac hostname or IP", text: $host).textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("Port", text: $port).keyboardType(.numberPad)
                TextField("Six-digit pairing code", text: $code).keyboardType(.numberPad)
                Button { Task { await pair() } } label: { HStack { Spacer(); if pairing { ProgressView() } else { Label("Pair securely", systemImage: "lock.shield") }; Spacer() } }.disabled(host.isEmpty || code.count != 6 || pairing)
                if let error { Text(error).foregroundStyle(.red) }
            }
            if !companion.isPaired {
                Section("How to connect") { connectionInstructions }.font(.caption)
            } else {
                Section("Connection help") {
                    DisclosureGroup("Show setup instructions") { connectionInstructions }
                }.font(.caption)
            }
            Section("Privacy") {
                Text("Only images you explicitly select are sent for an AI action. The companion deletes request uploads after each job. Generated images are approximate.")
                Button("Revoke this pairing", role: .destructive) { companion.revoke() }
            }
        }
        .navigationTitle("Settings")
        .toolbar { Button("Done") { dismiss() } }
        .task { await macBackups.refreshStatus(companion: companion) }
        .onChange(of: companion.discoveredHost) { _, discoveredHost in
            if host.isEmpty, let discoveredHost { host = discoveredHost }
        }
        .alert("Recover saved clothing images?", isPresented: $confirmingRecovery) {
            Button("Cancel", role: .cancel) {}
            Button("Recover") { recoverOrphanedImages() }
        } message: {
            Text("Wearwell will recreate missing wardrobe entries from catalog images still stored on this iPhone. Existing wardrobe items and images will not be changed.")
        }
        .fileExporter(
            isPresented: $exportingBackup,
            document: backupDocument,
            contentType: WearwellBackupDocument.contentType,
            defaultFilename: "Wearwell-\(Date.now.formatted(.iso8601.year().month().day())).wearwellbackup"
        ) { result in
            switch result {
            case .success: backupMessage = "Backup exported successfully."
            case .failure(let error): self.error = error.localizedDescription
            }
            backupDocument = nil
        }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [WearwellBackupDocument.contentType], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await restoreBackup(at: url) }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var connectionInstructions: some View {
        Text("1. On the Mac, run `codex login` and choose ChatGPT sign-in.")
        Text("2. In the Companion folder, run `npm install` and `npm start`.")
        Text("3. Enter the printed code here. The app pins that Mac's local certificate.")
    }
    private func pair() async {
        pairing = true; error = nil; companion.configure(host: host, port: Int(port) ?? 8791)
        do { try await companion.pair(code: code); code = "" } catch { self.error = error.localizedDescription }
        pairing = false
    }

    @MainActor
    private func recoverOrphanedImages() {
        do {
            let count = try protection.recoverOrphanedCatalogItems()
            backupMessage = count == 0 ? "No orphaned catalog images were found." : "Recovered \(count) wardrobe items. Review their names and categories when convenient."
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func prepareBackup() async {
        backupWorking = true; backupMessage = nil; error = nil
        defer { backupWorking = false }
        do {
            backupDocument = try await BackupService.makeDocument(context: context)
            exportingBackup = true
        } catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func restoreBackup(at url: URL) async {
        backupWorking = true; backupMessage = nil; error = nil
        defer { backupWorking = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let wrapper = try FileWrapper(url: url, options: .immediate)
            let document = try WearwellBackupDocument(fileWrapper: wrapper)
            let result = try await BackupService.restore(document, context: context)
            backupMessage = result.summary
        } catch { self.error = error.localizedDescription }
    }
}

struct SubcategorySettingsView: View {
    @Query(sort: [SortDescriptor(\WardrobeSubcategory.categoryRaw), SortDescriptor(\WardrobeSubcategory.sortOrder)])
    private var subcategories: [WardrobeSubcategory]
    @Query private var garments: [Garment]
    @Query private var wishlistItems: [WishlistItem]
    @Query private var purchaseNeeds: [PurchaseNeed]
    @Environment(\.modelContext) private var context
    @State private var showingAdd = false
    @State private var editing: WardrobeSubcategory?
    @State private var pendingDelete: WardrobeSubcategory?
    @State private var draggedSubcategoryID: UUID?

    var body: some View {
        List {
            ForEach(GarmentCategory.allCases) { category in
                let values = subcategories.options(for: category)
                Section(category.title) {
                    if values.isEmpty {
                        Text("No subcategories").foregroundStyle(.secondary)
                    } else {
                        ForEach(values) { item in
                            HStack {
                                Button { editing = item } label: {
                                    Text(item.name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "pencil").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) { pendingDelete = item } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete \(item.name)")
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDelete = item
                                }
                            }
                            .onDrag {
                                draggedSubcategoryID = item.id
                                return NSItemProvider(object: item.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: DirectReorderDropDelegate(
                                    targetID: item.id,
                                    draggedID: $draggedSubcategoryID,
                                    move: { source, target in move(category: category, sourceID: source, targetID: target) }
                                )
                            )
                            .opacity(draggedSubcategoryID == item.id ? 0.62 : 1)
                        }
                    }
                }
            }
        }
        .navigationTitle("My subcategories")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingAdd = true } label: { Label("Add subcategory", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack { SubcategoryEditorView() }
                .keyboardDismissToolbar()
        }
        .sheet(item: $editing) { item in
            NavigationStack { SubcategoryEditorView(subcategory: item) }
                .keyboardDismissToolbar()
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "this subcategory")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete subcategory", role: .destructive) {
                if let pendingDelete { delete(pendingDelete) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        guard let value = pendingDelete?.value else { return "" }
        let count = garments.filter { $0.subcategoryRaw == value }.count
            + wishlistItems.filter { $0.subcategoryRaw == value }.count
            + purchaseNeeds.filter { $0.subcategoryRaw == value }.count
        return count == 0
            ? "This removes it from your personal list."
            : "This also marks \(count) item\(count == 1 ? "" : "s") as having no subcategory. The items themselves will not be deleted."
    }

    private func delete(_ subcategory: WardrobeSubcategory) {
        let value = subcategory.value
        garments.filter { $0.subcategoryRaw == value }.forEach { $0.subcategoryRaw = nil }
        wishlistItems.filter { $0.subcategoryRaw == value }.forEach { $0.subcategoryRaw = nil }
        purchaseNeeds.filter { $0.subcategoryRaw == value }.forEach { $0.subcategoryRaw = nil }
        context.delete(subcategory)
        try? context.save()
        pendingDelete = nil
    }

    private func move(category: GarmentCategory, sourceID: UUID, targetID: UUID) {
        var values = subcategories.options(for: category)
        guard let source = values.firstIndex(where: { $0.id == sourceID }),
              let target = values.firstIndex(where: { $0.id == targetID }),
              source != target else { return }
        withAnimation(.snappy) {
            values.move(fromOffsets: IndexSet(integer: source), toOffset: target > source ? target + 1 : target)
            for (index, item) in values.enumerated() { item.sortOrder = index }
        }
        try? context.save()
    }
}

private struct SubcategoryEditorView: View {
    let subcategory: WardrobeSubcategory?
    @Query private var allSubcategories: [WardrobeSubcategory]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var category: GarmentCategory

    init(subcategory: WardrobeSubcategory? = nil) {
        self.subcategory = subcategory
        _name = State(initialValue: subcategory?.name ?? "")
        _category = State(initialValue: subcategory?.category ?? .tops)
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool {
        allSubcategories.contains {
            $0.id != subcategory?.id && $0.categoryRaw == category.rawValue &&
            $0.name.compare(cleanName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                Picker("Category", selection: $category) {
                    ForEach(GarmentCategory.allCases) { Text($0.title).tag($0) }
                }
                .disabled(subcategory != nil)
            } footer: {
                if subcategory != nil { Text("The category stays fixed so existing clothing assignments remain valid.") }
                if isDuplicate { Text("That subcategory already exists in this category.").foregroundStyle(.red) }
            }
        }
        .navigationTitle(subcategory == nil ? "New subcategory" : "Edit subcategory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(cleanName.isEmpty || isDuplicate)
            }
        }
    }

    private func save() {
        if let subcategory {
            subcategory.name = cleanName
        } else {
            let order = (allSubcategories.options(for: category).map(\.sortOrder).max() ?? -1) + 1
            context.insert(WardrobeSubcategory(name: cleanName, category: category, sortOrder: order))
        }
        try? context.save()
        dismiss()
    }
}
