import CryptoKit
import Foundation
import Security
import UIKit

enum CompanionStatus: Equatable {
    case searching, found(String), paired, available, busy, offline, expired, error(String)

    var label: String {
        switch self {
        case .searching: "Searching"
        case .found: "Mac found"
        case .paired: "Paired"
        case .available: "Luna available"
        case .busy: "Working"
        case .offline: "Offline"
        case .expired: "Pairing expired"
        case .error(let message): message
        }
    }
}

private final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let expectedFingerprint: String?
    let allowFirstTrust: Bool
    private(set) var observedFingerprint: String?

    init(expectedFingerprint: String?, allowFirstTrust: Bool = false) {
        self.expectedFingerprint = expectedFingerprint; self.allowFirstTrust = allowFirstTrust
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let data = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        observedFingerprint = fingerprint
        if allowFirstTrust || fingerprint == expectedFingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private final class CompanionDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [ObjectIdentifier: NetService] = [:]
    private let onResolved: (String, Int, String) -> Void

    init(onResolved: @escaping (String, Int, String) -> Void) {
        self.onResolved = onResolved
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_wearwell._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.values.forEach { $0.stop() }
        services.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services[ObjectIdentifier(service)] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostname = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !hostname.isEmpty, sender.port > 0 else { return }
        onResolved(hostname, sender.port, sender.name)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeValue(forKey: ObjectIdentifier(service))
    }
}

private enum CompanionKeychain {
    private static let service = "com.wearwell.app.companion"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        remove(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class CompanionClient: ObservableObject {
    @Published var status: CompanionStatus = .searching
    @Published var discoveredHost: String?

    private let defaults = UserDefaults.standard
    private var discovery: CompanionDiscovery?
    private var host: String { defaults.string(forKey: "companionHost") ?? discoveredHost ?? "127.0.0.1" }
    private var port: Int { defaults.integer(forKey: "companionPort").nonzero ?? 8791 }
    private var token: String? { CompanionKeychain.string(for: "token") }
    private var fingerprint: String? { CompanionKeychain.string(for: "certificateFingerprint") }
    var isPaired: Bool { token != nil && fingerprint != nil }

    init() { startDiscovery() }

    func startDiscovery() {
        status = .searching
        discovery?.stop()
        let discovery = CompanionDiscovery { [weak self] hostname, port, serviceName in
            Task { @MainActor in
                self?.discoveredHost = hostname
                self?.status = .found(serviceName)
                if self?.defaults.string(forKey: "companionHost") == nil {
                    self?.defaults.set(hostname, forKey: "companionHost")
                    self?.defaults.set(port, forKey: "companionPort")
                }
            }
        }
        discovery.start()
        self.discovery = discovery
    }

    func configure(host: String, port: Int = 8791) {
        defaults.set(host.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "companionHost")
        defaults.set(port, forKey: "companionPort")
    }

    func pair(code: String, deviceName: String = UIDevice.current.name) async throws {
        let delegate = TrustDelegate(expectedFingerprint: nil, allowFirstTrust: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: try CompanionEndpoint.url(host: host, port: port).appending(path: "v1/pair"))
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(["code": code, "deviceName": deviceName])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(urlError.code) {
            throw ClientError.connection("Could not reach the Mac at \(host):\(port). Use the discovered .local hostname or the Mac's Wi-Fi IP, and make sure both devices are on the same network.")
        }
        try requireOK(response, data: data)
        let result = try JSONDecoder().decode(PairResponse.self, from: data)
        guard CompanionKeychain.set(result.token, for: "token"),
              CompanionKeychain.set(delegate.observedFingerprint ?? result.certificateFingerprint, for: "certificateFingerprint") else {
            throw URLError(.cannotCreateFile)
        }
        status = .paired
        await refreshStatus()
    }

    func revoke() {
        CompanionKeychain.remove("token"); CompanionKeychain.remove("certificateFingerprint")
        status = .expired
    }

    func refreshStatus() async {
        guard token != nil, fingerprint != nil else { status = .offline; return }
        do {
            let data = try await send(path: "v1/health", method: "GET", body: Optional<String>.none)
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            if health.model != "gpt-5.6-luna" { status = .error("Unexpected model") }
            else if health.serviceTier != "fast" { status = .error("Restart companion for Fast mode") }
            else { status = .available }
        } catch { status = .offline }
    }

    func analyze(imageData: Data, sourceURL: String? = nil) async throws -> [GarmentAnalysisDTO] {
        status = .busy
        defer { status = .available }
        let payload = AnalyzeRequest(imageBase64: imageData.base64EncodedString(), sourceURL: sourceURL)
        let data = try await send(path: "v1/analyze", body: payload)
        return try JSONDecoder().decode(AnalyzeResponse.self, from: data).items
    }

    func analyzeInspiration(imageData: Data) async throws -> InspirationAnalysisDTO {
        status = .busy
        defer { status = .available }
        let data = try await send(path: "v1/inspiration/analyze", body: InspirationRequest(imageBase64: imageData.base64EncodedString()))
        return try JSONDecoder().decode(InspirationAnalysisDTO.self, from: data)
    }

    func submitAnalysis(imageData: Data, sourceURL: String? = nil) async throws -> AnalysisJobDTO {
        try await submitAnalysis(imageData: [imageData], sourceURL: sourceURL, sameItem: false)
    }

    func submitAnalysis(imageData: [Data], sourceURL: String? = nil, sameItem: Bool) async throws -> AnalysisJobDTO {
        status = .busy
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Queue clothing import")
        defer {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            status = .available
        }
        guard let first = imageData.first else { throw ClientError.invalidResponse }
        let payload = AnalyzeRequest(
            imageBase64: first.base64EncodedString(),
            imageBase64s: imageData.map { $0.base64EncodedString() },
            sameItem: sameItem,
            sourceURL: sourceURL
        )
        let data = try await send(path: "v1/jobs/analyze", body: payload)
        return try JSONDecoder().decode(AnalysisJobDTO.self, from: data)
    }

    func analysisJob(id: String) async throws -> AnalysisJobDTO {
        let data = try await send(path: "v1/jobs/\(id)", method: "GET", body: Optional<String>.none)
        return try JSONDecoder().decode(AnalysisJobDTO.self, from: data)
    }

    func deleteAnalysisJob(id: String) async {
        _ = try? await send(path: "v1/jobs/\(id)", method: "DELETE", body: Optional<String>.none)
    }

    func recommend(garments: [Garment], occasion: String, weather: String, mood: String, anchorID: UUID?, request: String, styleProfile: StyleProfile?, inspirations: [InspirationLook], recentOutfits: [OutfitSuggestionDTO] = [], outfitFeedback: [OutfitFeedbackDTO] = [], savedOutfits: [SavedOutfitExampleDTO] = [], outfitEdits: [OutfitEditFeedbackDTO] = []) async throws -> [OutfitSuggestionDTO] {
        status = .busy; defer { status = .available }
        let summaries = garments.map(GarmentSummary.init)
        let query = [occasion, weather, mood, request].joined(separator: " ")
        let examples = StylePreferenceCache.relevantLooks(inspirations, query: query).compactMap(InspirationExample.init)
        let garmentVisuals = await visualReferences(garments.map { VisualSource(id: $0.id.uuidString, assetName: $0.catalogAssetName.isEmpty ? $0.sourceAssetName : $0.catalogAssetName) }, byteBudget: 11 * 1024 * 1024)
        let relevantIDs = Set(examples.map(\.id))
        let inspirationVisuals = await visualReferences(inspirations.filter { relevantIDs.contains($0.id) }.map { VisualSource(id: $0.id.uuidString, assetName: $0.assetName) }, byteBudget: 2 * 1024 * 1024)
        let payload = StyleRequest(wardrobe: summaries, occasion: occasion, weather: weather, mood: mood, anchorID: anchorID, request: request, styleProfile: styleProfile?.profile, inspirationExamples: examples, recentOutfits: Array(recentOutfits.prefix(18)), outfitFeedback: Array(outfitFeedback.prefix(80)), savedOutfits: Array(savedOutfits.prefix(30)), outfitEdits: Array(outfitEdits.prefix(40)), garmentVisuals: garmentVisuals, inspirationVisuals: inspirationVisuals)
        let data = try await send(path: "v1/style", body: payload)
        let decoded = try JSONDecoder().decode(StyleResponse.self, from: data)
        return OutfitValidator.validateAI(decoded.outfits, garments: garments, anchorID: anchorID)
    }

    func recommendItems(garments: [Garment], selectedGarmentIDs: [UUID], category: GarmentCategory? = nil, subcategory: GarmentSubcategory? = nil) async throws -> ItemRecommendationDTO {
        status = .busy; defer { status = .available }
        let selected = Set(selectedGarmentIDs)
        let matches: (Garment) -> Bool = { (category == nil || $0.category == category) && (subcategory == nil || $0.subcategory == subcategory) }
        let relevant = garments.filter { selected.contains($0.id) || matches($0) }
        let visuals = await visualReferences(relevant.map {
            VisualSource(id: $0.id.uuidString, assetName: $0.catalogAssetName.isEmpty ? $0.sourceAssetName : $0.catalogAssetName)
        }, byteBudget: 11 * 1024 * 1024)
        let payload = ItemRecommendationRequest(
            wardrobe: garments.map(GarmentSummary.init), selectedGarmentIDs: selectedGarmentIDs,
            category: category?.rawValue ?? "", subcategory: subcategory?.rawValue, garmentVisuals: visuals
        )
        let data = try await send(path: "v1/recommend-item", body: payload)
        let result = try JSONDecoder().decode(ItemRecommendationDTO.self, from: data)
        guard !result.garmentIDs.isEmpty, result.garmentIDs.count <= 2,
              Set(result.garmentIDs).count == result.garmentIDs.count,
              result.garmentIDs.allSatisfy({ id in garments.contains { $0.id == id && !selected.contains(id) && matches($0) } })
        else { throw ClientError.invalidResponse }
        return result
    }

    func recommendWardrobeGaps(
        garments: [Garment], selectedGarmentIDs: [UUID], existingNeeds: [PurchaseNeed],
        styleProfile: StyleProfile?, inspirations: [InspirationLook]
    ) async throws -> [WardrobeGapDTO] {
        status = .busy; defer { status = .available }
        let readyInspirations = inspirations.filter { $0.state == "ready" && $0.analysis != nil }
        let relevantIDs = Set(readyInspirations.map(\.id))
        let payload = WardrobeGapRequest(
            wardrobe: garments.map(GarmentSummary.init), selectedGarmentIDs: selectedGarmentIDs,
            existingNeeds: existingNeeds.filter { !$0.isCompleted }.map { $0.title },
            styleProfile: styleProfile?.profile,
            inspirationExamples: readyInspirations.prefix(40).compactMap(InspirationExample.init),
            garmentVisuals: await visualReferences(garments.map {
                VisualSource(id: $0.id.uuidString, assetName: $0.catalogAssetName.isEmpty ? $0.sourceAssetName : $0.catalogAssetName)
            }, byteBudget: 10 * 1024 * 1024),
            inspirationVisuals: await visualReferences(readyInspirations.filter { relevantIDs.contains($0.id) }.map {
                VisualSource(id: $0.id.uuidString, assetName: $0.assetName)
            }, byteBudget: 3 * 1024 * 1024)
        )
        let data = try await send(path: "v1/wardrobe-gaps", body: payload)
        return try JSONDecoder().decode(WardrobeGapResponseDTO.self, from: data).gaps
    }

    func submitStyle(garments: [Garment], occasion: String, weather: String, mood: String, anchorID: UUID?, request: String, styleProfile: StyleProfile?, inspirations: [InspirationLook], recentOutfits: [OutfitSuggestionDTO] = [], outfitFeedback: [OutfitFeedbackDTO] = [], savedOutfits: [SavedOutfitExampleDTO] = [], outfitEdits: [OutfitEditFeedbackDTO] = []) async throws -> StyleJobDTO {
        status = .busy
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Queue outfit recommendations")
        defer {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            status = .available
        }
        let summaries = garments.map(GarmentSummary.init)
        let query = [occasion, weather, mood, request].joined(separator: " ")
        let examples = StylePreferenceCache.relevantLooks(inspirations, query: query).compactMap(InspirationExample.init)
        let garmentVisuals = await visualReferences(garments.map { VisualSource(id: $0.id.uuidString, assetName: $0.catalogAssetName.isEmpty ? $0.sourceAssetName : $0.catalogAssetName) }, byteBudget: 11 * 1024 * 1024)
        let relevantIDs = Set(examples.map(\.id))
        let inspirationVisuals = await visualReferences(inspirations.filter { relevantIDs.contains($0.id) }.map { VisualSource(id: $0.id.uuidString, assetName: $0.assetName) }, byteBudget: 2 * 1024 * 1024)
        let payload = StyleRequest(wardrobe: summaries, occasion: occasion, weather: weather, mood: mood, anchorID: anchorID, request: request, styleProfile: styleProfile?.profile, inspirationExamples: examples, recentOutfits: Array(recentOutfits.prefix(18)), outfitFeedback: Array(outfitFeedback.prefix(80)), savedOutfits: Array(savedOutfits.prefix(30)), outfitEdits: Array(outfitEdits.prefix(40)), garmentVisuals: garmentVisuals, inspirationVisuals: inspirationVisuals)
        let data = try await send(path: "v1/jobs/style", body: payload)
        return try JSONDecoder().decode(StyleJobDTO.self, from: data)
    }

    func styleJob(id: String) async throws -> StyleJobDTO {
        let data = try await send(path: "v1/jobs/\(id)", method: "GET", body: Optional<String>.none)
        return try JSONDecoder().decode(StyleJobDTO.self, from: data)
    }

    func assess(candidate: WishlistItem, garments: [Garment], styleProfile: StyleProfile?, inspirations: [InspirationLook]) async throws -> PurchaseAssessmentDTO {
        status = .busy; defer { status = .available }
        let examples = StylePreferenceCache.relevantLooks(inspirations, query: "\(candidate.label) \(candidate.color) \(candidate.details)").compactMap(InspirationExample.init)
        let relevantIDs = Set(examples.map(\.id))
        let payload = AssessmentRequest(
            candidate: CandidateSummary(id: candidate.id, label: candidate.label, category: candidate.categoryRaw, subcategory: candidate.subcategoryRaw, color: candidate.color, description: candidate.details),
            wardrobe: garments.map(GarmentSummary.init),
            styleProfile: styleProfile?.profile,
            inspirationExamples: examples,
            candidateVisual: await visualReference(VisualSource(id: "__candidate__", assetName: candidate.catalogAssetName.isEmpty ? candidate.sourceAssetName : candidate.catalogAssetName)),
            garmentVisuals: await visualReferences(garments.map { VisualSource(id: $0.id.uuidString, assetName: $0.catalogAssetName.isEmpty ? $0.sourceAssetName : $0.catalogAssetName) }, byteBudget: 10 * 1024 * 1024),
            inspirationVisuals: await visualReferences(inspirations.filter { relevantIDs.contains($0.id) }.map { VisualSource(id: $0.id.uuidString, assetName: $0.assetName) }, byteBudget: 2 * 1024 * 1024)
        )
        let data = try await send(path: "v1/assess", body: payload)
        return OutfitValidator.validatePurchase(try JSONDecoder().decode(PurchaseAssessmentDTO.self, from: data), garments: garments, candidate: candidate)
    }

    func submitAssessment(candidate: WishlistItem, garments: [Garment], styleProfile: StyleProfile?, inspirations: [InspirationLook]) async throws -> AssessmentJobDTO {
        status = .busy
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Queue purchase test")
        defer {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            status = .available
        }
        let examples = StylePreferenceCache.relevantLooks(inspirations, query: "\(candidate.label) \(candidate.color) \(candidate.details)").compactMap(InspirationExample.init)
        let relevantIDs = Set(examples.map(\.id))
        let payload = AssessmentRequest(
            candidate: CandidateSummary(id: candidate.id, label: candidate.label, category: candidate.categoryRaw, subcategory: candidate.subcategoryRaw, color: candidate.color, description: candidate.details),
            wardrobe: garments.map(GarmentSummary.init),
            styleProfile: styleProfile?.profile,
            inspirationExamples: examples,
            candidateVisual: await visualReference(VisualSource(id: "__candidate__", assetName: candidate.catalogAssetName.isEmpty ? candidate.sourceAssetName : candidate.catalogAssetName)),
            garmentVisuals: await visualReferences(garments.map { VisualSource(id: $0.id.uuidString, assetName: $0.catalogAssetName.isEmpty ? $0.sourceAssetName : $0.catalogAssetName) }, byteBudget: 10 * 1024 * 1024),
            inspirationVisuals: await visualReferences(inspirations.filter { relevantIDs.contains($0.id) }.map { VisualSource(id: $0.id.uuidString, assetName: $0.assetName) }, byteBudget: 2 * 1024 * 1024)
        )
        let data = try await send(path: "v1/jobs/assess", body: payload)
        return try JSONDecoder().decode(AssessmentJobDTO.self, from: data)
    }

    func assessmentJob(id: String) async throws -> AssessmentJobDTO {
        let data = try await send(path: "v1/jobs/\(id)", method: "GET", body: Optional<String>.none)
        return try JSONDecoder().decode(AssessmentJobDTO.self, from: data)
    }

    func submitShopDiscovery(
        query: String,
        garments: [Garment],
        styleProfile: StyleProfile?,
        inspirations: [InspirationLook],
        shoppingProfile: ShoppingProfileDTO
    ) async throws -> ShopDiscoveryJobDTO {
        status = .busy
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Queue shop discovery")
        defer {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            status = .available
        }
        let readyInspirations = inspirations.filter { $0.state == "ready" && $0.analysis != nil }
        let payload = ShopDiscoveryRequest(
            query: query,
            retailerDomains: shoppingProfile.retailerDomains,
            preferences: shoppingProfile,
            styleProfile: styleProfile?.profile,
            wardrobe: garments.map(GarmentSummary.init),
            inspirationExamples: readyInspirations.prefix(40).compactMap(InspirationExample.init),
            garmentVisuals: await visualReferences(garments.map {
                VisualSource(id: $0.id.uuidString, assetName: $0.catalogAssetName.isEmpty ? $0.sourceAssetName : $0.catalogAssetName)
            }, byteBudget: 10 * 1024 * 1024),
            inspirationVisuals: await visualReferences(readyInspirations.map {
                VisualSource(id: $0.id.uuidString, assetName: $0.assetName)
            }, byteBudget: 3 * 1024 * 1024)
        )
        let data = try await send(path: "v1/jobs/shop-discovery", body: payload)
        return try JSONDecoder().decode(ShopDiscoveryJobDTO.self, from: data)
    }

    func shopDiscoveryJob(id: String) async throws -> ShopDiscoveryJobDTO {
        let data = try await send(path: "v1/jobs/\(id)", method: "GET", body: Optional<String>.none)
        return try JSONDecoder().decode(ShopDiscoveryJobDTO.self, from: data)
    }

    func render(mode: VisualizationMode, reference: Data, garmentImages: [Data]) async throws -> Data {
        status = .busy; defer { status = .available }
        let payload = RenderRequest(mode: mode.rawValue, referenceBase64: reference.base64EncodedString(), garmentImagesBase64: garmentImages.map { $0.base64EncodedString() })
        let data = try await send(path: "v1/render", body: payload)
        let result = try JSONDecoder().decode(RenderResponse.self, from: data)
        guard let image = Data(base64Encoded: result.imageBase64) else { throw ClientError.invalidResponse }
        return image
    }

    func editCatalog(imageData: Data, instruction: String) async throws -> Data {
        status = .busy; defer { status = .available }
        let payload = CatalogEditRequest(imageBase64: imageData.base64EncodedString(), instruction: instruction)
        let data = try await send(path: "v1/catalog/edit", body: payload)
        let result = try JSONDecoder().decode(RenderResponse.self, from: data)
        guard let image = Data(base64Encoded: result.imageBase64) else { throw ClientError.invalidResponse }
        return image
    }

    func submitCatalogEdit(imageData: Data, instruction: String) async throws -> CatalogEditJobDTO {
        status = .busy
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Queue catalog edit")
        defer {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            status = .available
        }
        let payload = CatalogEditRequest(imageBase64: imageData.base64EncodedString(), instruction: instruction)
        let data = try await send(path: "v1/jobs/catalog/edit", body: payload)
        return try JSONDecoder().decode(CatalogEditJobDTO.self, from: data)
    }

    func catalogEditJob(id: String) async throws -> CatalogEditJobDTO {
        let data = try await send(path: "v1/jobs/\(id)", method: "GET", body: Optional<String>.none)
        return try JSONDecoder().decode(CatalogEditJobDTO.self, from: data)
    }

    func prepareMacBackup(manifestData: Data) async throws -> [String] {
        let request = BackupManifestRequest(manifestBase64: manifestData.base64EncodedString())
        let data = try await send(path: "v1/backups/prepare", body: request)
        return try JSONDecoder().decode(BackupPrepareResponse.self, from: data).missingHashes
    }

    func uploadMacBackupAsset(_ data: Data, asset: WearwellBackupManifest.AssetRecord) async throws {
        let request = BackupAssetRequest(sha256: asset.sha256, byteCount: asset.byteCount, dataBase64: data.base64EncodedString())
        _ = try await send(path: "v1/backups/asset", body: request)
    }

    func commitMacBackup(manifestData: Data) async throws -> MacBackupStatus {
        let request = BackupManifestRequest(manifestBase64: manifestData.base64EncodedString())
        let data = try await send(path: "v1/backups/commit", body: request)
        return try JSONDecoder().decode(MacBackupStatus.self, from: data)
    }

    func macBackupStatus() async throws -> MacBackupStatus {
        let data = try await send(path: "v1/backups/status", method: "GET", body: Optional<String>.none)
        return try JSONDecoder().decode(MacBackupStatus.self, from: data)
    }

    private func visualReference(_ source: VisualSource) async -> VisualReference? {
        guard let data = try? await AssetStore.shared.visualReferenceData(named: source.assetName) else { return nil }
        return VisualReference(id: source.id, imageBase64: data.base64EncodedString())
    }

    private func visualReferences(_ sources: [VisualSource], byteBudget: Int) async -> [VisualReference] {
        var result: [VisualReference] = []
        var used = 0
        for source in sources {
            guard let data = try? await AssetStore.shared.visualReferenceData(named: source.assetName),
                  used + data.count <= byteBudget else { continue }
            result.append(VisualReference(id: source.id, imageBase64: data.base64EncodedString()))
            used += data.count
        }
        return result
    }

    private func send<T: Encodable>(path: String, method: String = "POST", body: T?) async throws -> Data {
        guard isPaired else { throw ClientError.notPaired }
        let delegate = TrustDelegate(expectedFingerprint: fingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: try CompanionEndpoint.url(host: host, port: port).appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 300
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body { request.setValue("application/json", forHTTPHeaderField: "content-type"); request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await session.data(for: request)
        try requireOK(response, data: data)
        return data
    }

    private func requireOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        if http.statusCode == 401 { status = .expired; throw ClientError.expired }
        if http.statusCode == 404 { throw ClientError.jobNotFound }
        guard 200..<300 ~= http.statusCode else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error) ?? "Companion error"
            throw ClientError.server(message)
        }
    }
}

private extension Int { var nonzero: Int? { self == 0 ? nil : self } }
enum ClientError: LocalizedError { case invalidResponse, invalidConfiguration, notPaired, expired, jobNotFound, connection(String), server(String)
    var errorDescription: String? { switch self { case .invalidResponse: "Invalid companion response"; case .invalidConfiguration: "Enter a valid Mac hostname and port"; case .notPaired: "Pair with your Mac companion first"; case .expired: "Pairing expired"; case .jobNotFound: "Job not found or expired"; case .connection(let value), .server(let value): value } }
}

enum CompanionEndpoint {
    static func url(host: String, port: Int) throws -> URL {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, (1...65_535).contains(port) else {
            throw ClientError.invalidConfiguration
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = normalizedHost
        components.port = port
        components.path = "/"
        guard let url = components.url else { throw ClientError.invalidConfiguration }
        return url
    }
}

private struct PairResponse: Codable { let token: String; let certificateFingerprint: String }
private struct HealthResponse: Codable { let status: String; let auth: String; let model: String; let serviceTier: String? }
private struct ErrorResponse: Codable { let error: String }
private struct AnalyzeRequest: Codable {
    let imageBase64: String
    var imageBase64s: [String]? = nil
    var sameItem: Bool? = nil
    let sourceURL: String?
}
private struct InspirationRequest: Codable { let imageBase64: String }
private struct BackupManifestRequest: Codable { let manifestBase64: String }
private struct BackupPrepareResponse: Codable { let missingHashes: [String] }
private struct BackupAssetRequest: Codable { let sha256: String; let byteCount: Int; let dataBase64: String }
struct MacBackupStatus: Codable, Equatable {
    let latestAt: String?
    let snapshotCount: Int
    let dailySnapshots: Int
    let weeklySnapshots: Int
    let retention: Retention

    struct Retention: Codable, Equatable { let daily: Int; let weekly: Int }
}
struct AnalyzeResponse: Codable { let items: [GarmentAnalysisDTO] }
struct AnalysisJobDTO: Codable {
    let id: String
    let kind: String
    let state: String
    let createdAt: String
    let updatedAt: String
    let stage: String?
    let progressCompleted: Int?
    let progressTotal: Int?
    let queuePosition: Int?
    let estimatedSecondsRemaining: Int?
    let processingStartedAt: String?
    let result: AnalyzeResponse?
    let error: String?
}

struct StyleJobDTO: Codable {
    let id: String
    let kind: String
    let state: String
    let createdAt: String
    let updatedAt: String
    let stage: String?
    let queuePosition: Int?
    let estimatedSecondsRemaining: Int?
    let result: StyleResponse?
    let error: String?
}

struct AssessmentJobDTO: Codable {
    let id: String
    let kind: String
    let state: String
    let createdAt: String
    let updatedAt: String
    let stage: String?
    let queuePosition: Int?
    let estimatedSecondsRemaining: Int?
    let result: PurchaseAssessmentDTO?
    let error: String?
}

struct ShopDiscoveryJobDTO: Codable {
    let id: String
    let kind: String
    let state: String
    let createdAt: String
    let updatedAt: String
    let stage: String?
    let queuePosition: Int?
    let estimatedSecondsRemaining: Int?
    let result: ShopFeedDTO?
    let error: String?
}

struct CatalogEditJobDTO: Codable {
    let id: String
    let kind: String
    let state: String
    let createdAt: String
    let updatedAt: String
    let stage: String?
    let queuePosition: Int?
    let estimatedSecondsRemaining: Int?
    let result: RenderResponse?
    let error: String?
}
private struct GarmentSummary: Codable {
    let id: UUID
    let label, category: String
    let subcategory: String?
    let color, description, observed: String
    let unknowns: [String]
    let tags, season, occasion: String
    let confidence: Double

    init(_ garment: Garment) {
        id = garment.id
        label = garment.label
        category = garment.categoryRaw
        subcategory = garment.subcategoryRaw
        color = garment.color
        description = garment.details
        observed = garment.observed
        unknowns = garment.unknowns
        tags = garment.tags
        season = garment.season
        occasion = garment.occasion
        confidence = garment.confidence
    }
}
private struct CandidateSummary: Codable { let id: UUID; let label, category: String; let subcategory: String?; let color, description: String }
private struct VisualSource { let id, assetName: String }
private struct VisualReference: Codable { let id, imageBase64: String }
private struct InspirationExample: Codable {
    let id: UUID
    let isFavorite: Bool
    let summary: String
    let aesthetics, palette, silhouettes, layering, details, occasions: [String]
    let outfitFormula, proportions, focalPoints, stylingRules: [String]
    let vector: StyleVectorDTO

    init?(_ look: InspirationLook) {
        guard let analysis = look.analysis else { return nil }
        id = look.id; isFavorite = look.isFavorite; summary = analysis.summary; aesthetics = analysis.aesthetics; palette = analysis.palette
        silhouettes = analysis.silhouettes; layering = analysis.layering; details = analysis.details
        occasions = analysis.occasions; vector = analysis.vector
        outfitFormula = analysis.outfitFormula ?? []; proportions = analysis.proportions ?? []
        focalPoints = analysis.focalPoints ?? []; stylingRules = analysis.stylingRules ?? []
    }
}
struct SavedOutfitExampleDTO: Codable {
    let id: UUID
    let title: String
    let rationale: String
    let origin: String
    let garmentIDs: [UUID]
    let layout: [LayoutItem]
    let updatedAt: Date

    init?(_ outfit: Outfit) {
        guard outfit.belongsInOutfitLibrary else { return nil }
        var seen = Set<UUID>()
        let ids = outfit.layout.compactMap(\.garmentID).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return nil }
        id = outfit.id; title = outfit.title; rationale = outfit.rationale; origin = outfit.originRaw
        garmentIDs = ids; layout = outfit.layout; updatedAt = outfit.updatedAt
    }
}
private struct StyleRequest: Codable {
    let wardrobe: [GarmentSummary]
    let occasion, weather, mood: String
    let anchorID: UUID?
    let request: String
    let styleProfile: StyleProfileDTO?
    let inspirationExamples: [InspirationExample]
    let recentOutfits: [OutfitSuggestionDTO]
    let outfitFeedback: [OutfitFeedbackDTO]
    let savedOutfits: [SavedOutfitExampleDTO]
    let outfitEdits: [OutfitEditFeedbackDTO]
    let garmentVisuals, inspirationVisuals: [VisualReference]
}
private struct ItemRecommendationRequest: Codable {
    let wardrobe: [GarmentSummary]
    let selectedGarmentIDs: [UUID]
    let category: String
    let subcategory: String?
    let garmentVisuals: [VisualReference]
}
struct ItemRecommendationDTO: Codable, Equatable {
    let garmentIDs: [UUID]
    let rationale: String
}
struct StyleResponse: Codable { let outfits: [OutfitSuggestionDTO] }
private struct AssessmentRequest: Codable {
    let candidate: CandidateSummary
    let wardrobe: [GarmentSummary]
    let styleProfile: StyleProfileDTO?
    let inspirationExamples: [InspirationExample]
    let candidateVisual: VisualReference?
    let garmentVisuals, inspirationVisuals: [VisualReference]
}
private struct ShopDiscoveryRequest: Codable {
    let query: String
    let retailerDomains: [String]
    let preferences: ShoppingProfileDTO
    let styleProfile: StyleProfileDTO?
    let wardrobe: [GarmentSummary]
    let inspirationExamples: [InspirationExample]
    let garmentVisuals, inspirationVisuals: [VisualReference]
}
private struct WardrobeGapRequest: Codable {
    let wardrobe: [GarmentSummary]
    let selectedGarmentIDs: [UUID]
    let existingNeeds: [String]
    let styleProfile: StyleProfileDTO?
    let inspirationExamples: [InspirationExample]
    let garmentVisuals, inspirationVisuals: [VisualReference]
}
private struct RenderRequest: Codable { let mode, referenceBase64: String; let garmentImagesBase64: [String] }
struct RenderResponse: Codable { let imageBase64: String }
private struct CatalogEditRequest: Codable { let imageBase64, instruction: String }
