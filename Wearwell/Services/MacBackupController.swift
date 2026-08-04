import SwiftData
import SwiftUI
import UIKit

@MainActor
final class MacBackupController: ObservableObject {
    @Published private(set) var isBackingUp = false
    @Published private(set) var progressText: String?
    @Published private(set) var lastError: String?
    @Published private(set) var remoteStatus: MacBackupStatus?

    private let defaults = UserDefaults.standard
    private let interval: TimeInterval = 24 * 60 * 60
    private var activeTask: Task<Void, Never>?

    var automaticEnabled: Bool {
        get { defaults.object(forKey: "automaticMacBackups") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "automaticMacBackups"); objectWillChange.send() }
    }

    var lastBackupAt: Date? {
        let value = defaults.double(forKey: "lastAutomaticMacBackup")
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    func backupIfDue(context: ModelContext, companion: CompanionClient, force: Bool = false) async {
        guard automaticEnabled || force else { return }
        guard companion.isPaired else {
            if force { lastError = ClientError.notPaired.localizedDescription }
            return
        }
        if !force, let lastBackupAt, Date.now.timeIntervalSince(lastBackupAt) < interval {
            await refreshStatus(companion: companion)
            return
        }
        await performBackup(context: context, companion: companion)
    }

    func performBackup(context: ModelContext, companion: CompanionClient) async {
        guard activeTask == nil else { return }
        guard companion.isPaired else {
            lastError = ClientError.notPaired.localizedDescription
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            isBackingUp = true; lastError = nil; progressText = "Preparing encrypted snapshot…"
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Back up Wearwell to Mac")
            defer {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                isBackingUp = false; activeTask = nil
            }
            do {
                let plan = try await BackupService.makeMacBackupPlan(context: context)
                let missing = Set(try await companion.prepareMacBackup(manifestData: plan.manifestData))
                let uniqueAssets = Dictionary(grouping: plan.manifest.assets, by: \.sha256).compactMap { $0.value.first }
                let needed = uniqueAssets.filter { missing.contains($0.sha256) }
                for (index, asset) in needed.enumerated() {
                    progressText = "Protecting image \(index + 1) of \(needed.count)…"
                    let data = try await BackupService.data(for: asset, context: context)
                    try await companion.uploadMacBackupAsset(data, asset: asset)
                }
                progressText = "Saving restore point…"
                remoteStatus = try await companion.commitMacBackup(manifestData: plan.manifestData)
                defaults.set(Date.now.timeIntervalSince1970, forKey: "lastAutomaticMacBackup")
                progressText = "Backed up securely to your Mac."
            } catch {
                lastError = error.localizedDescription
                progressText = nil
            }
        }
        activeTask = task
        await task.value
    }

    func refreshStatus(companion: CompanionClient) async {
        guard !isBackingUp, companion.isPaired else { return }
        do { remoteStatus = try await companion.macBackupStatus() }
        catch { /* Offline is expected; the next connection retries. */ }
    }
}
