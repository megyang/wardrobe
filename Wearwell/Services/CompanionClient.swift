import CryptoKit
import Foundation
import Network
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
    private var browser: NWBrowser?
    private var host: String { defaults.string(forKey: "companionHost") ?? discoveredHost ?? "127.0.0.1" }
    private var port: Int { defaults.integer(forKey: "companionPort").nonzero ?? 8791 }
    private var token: String? { CompanionKeychain.string(for: "token") }
    private var fingerprint: String? { CompanionKeychain.string(for: "certificateFingerprint") }
    var isPaired: Bool { token != nil && fingerprint != nil }

    init() { startDiscovery() }

    func startDiscovery() {
        status = .searching
        let browser = NWBrowser(for: .bonjour(type: "_wearwell._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { _ in }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let endpoint = results.first?.endpoint else { return }
            Task { @MainActor in
                guard case let .service(name, _, _, interface) = endpoint else { return }
                self?.discoveredHost = name
                self?.status = .found(interface?.name ?? name)
            }
        }
        browser.start(queue: DispatchQueue(label: "wearwell.discovery"))
        self.browser = browser
    }

    func configure(host: String, port: Int = 8791) {
        defaults.set(host.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "companionHost")
        defaults.set(port, forKey: "companionPort")
    }

    func pair(code: String, deviceName: String = UIDevice.current.name) async throws {
        let delegate = TrustDelegate(expectedFingerprint: nil, allowFirstTrust: true)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: try CompanionEndpoint.url(host: host, port: port).appending(path: "v1/pair"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(["code": code, "deviceName": deviceName])
        let (data, response) = try await session.data(for: request)
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
        status = .busy
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Queue clothing import")
        defer {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            status = .available
        }
        let payload = AnalyzeRequest(imageBase64: imageData.base64EncodedString(), sourceURL: sourceURL)
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

    func recommend(garments: [Garment], occasion: String, weather: String, mood: String, anchorID: UUID?, request: String, styleProfile: StyleProfile?, inspirations: [InspirationLook]) async throws -> [OutfitSuggestionDTO] {
        status = .busy; defer { status = .available }
        let summaries = garments.map(GarmentSummary.init)
        let query = [occasion, weather, mood, request].joined(separator: " ")
        let examples = StylePreferenceCache.relevantLooks(inspirations, query: query).compactMap(InspirationExample.init)
        let payload = StyleRequest(wardrobe: summaries, occasion: occasion, weather: weather, mood: mood, anchorID: anchorID, request: request, styleProfile: styleProfile?.profile, inspirationExamples: examples)
        let data = try await send(path: "v1/style", body: payload)
        let decoded = try JSONDecoder().decode(StyleResponse.self, from: data)
        return OutfitValidator.validateAI(decoded.outfits, garments: garments, anchorID: anchorID)
    }

    func submitStyle(garments: [Garment], occasion: String, weather: String, mood: String, anchorID: UUID?, request: String, styleProfile: StyleProfile?, inspirations: [InspirationLook]) async throws -> StyleJobDTO {
        status = .busy
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Queue outfit recommendations")
        defer {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            status = .available
        }
        let summaries = garments.map(GarmentSummary.init)
        let query = [occasion, weather, mood, request].joined(separator: " ")
        let examples = StylePreferenceCache.relevantLooks(inspirations, query: query).compactMap(InspirationExample.init)
        let payload = StyleRequest(wardrobe: summaries, occasion: occasion, weather: weather, mood: mood, anchorID: anchorID, request: request, styleProfile: styleProfile?.profile, inspirationExamples: examples)
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
        let payload = AssessmentRequest(
            candidate: CandidateSummary(id: candidate.id, label: candidate.label, category: candidate.categoryRaw, subcategory: candidate.subcategoryRaw, color: candidate.color, description: candidate.details),
            wardrobe: garments.map(GarmentSummary.init),
            styleProfile: styleProfile?.profile,
            inspirationExamples: examples
        )
        let data = try await send(path: "v1/assess", body: payload)
        return OutfitValidator.validatePurchase(try JSONDecoder().decode(PurchaseAssessmentDTO.self, from: data), garments: garments, candidateCategory: candidate.category)
    }

    func submitAssessment(candidate: WishlistItem, garments: [Garment], styleProfile: StyleProfile?, inspirations: [InspirationLook]) async throws -> AssessmentJobDTO {
        status = .busy
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Queue purchase test")
        defer {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            status = .available
        }
        let examples = StylePreferenceCache.relevantLooks(inspirations, query: "\(candidate.label) \(candidate.color) \(candidate.details)").compactMap(InspirationExample.init)
        let payload = AssessmentRequest(
            candidate: CandidateSummary(id: candidate.id, label: candidate.label, category: candidate.categoryRaw, subcategory: candidate.subcategoryRaw, color: candidate.color, description: candidate.details),
            wardrobe: garments.map(GarmentSummary.init),
            styleProfile: styleProfile?.profile,
            inspirationExamples: examples
        )
        let data = try await send(path: "v1/jobs/assess", body: payload)
        return try JSONDecoder().decode(AssessmentJobDTO.self, from: data)
    }

    func assessmentJob(id: String) async throws -> AssessmentJobDTO {
        let data = try await send(path: "v1/jobs/\(id)", method: "GET", body: Optional<String>.none)
        return try JSONDecoder().decode(AssessmentJobDTO.self, from: data)
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
enum ClientError: LocalizedError { case invalidResponse, invalidConfiguration, notPaired, expired, jobNotFound, server(String)
    var errorDescription: String? { switch self { case .invalidResponse: "Invalid companion response"; case .invalidConfiguration: "Enter a valid Mac hostname and port"; case .notPaired: "Pair with your Mac companion first"; case .expired: "Pairing expired"; case .jobNotFound: "Job not found or expired"; case .server(let value): value } }
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
private struct AnalyzeRequest: Codable { let imageBase64: String; let sourceURL: String? }
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
private struct InspirationExample: Codable {
    let id: UUID
    let summary: String
    let aesthetics, palette, silhouettes, layering, details, occasions: [String]
    let outfitFormula, proportions, focalPoints, stylingRules: [String]
    let vector: StyleVectorDTO

    init?(_ look: InspirationLook) {
        guard let analysis = look.analysis else { return nil }
        id = look.id; summary = analysis.summary; aesthetics = analysis.aesthetics; palette = analysis.palette
        silhouettes = analysis.silhouettes; layering = analysis.layering; details = analysis.details
        occasions = analysis.occasions; vector = analysis.vector
        outfitFormula = analysis.outfitFormula ?? []; proportions = analysis.proportions ?? []
        focalPoints = analysis.focalPoints ?? []; stylingRules = analysis.stylingRules ?? []
    }
}
private struct StyleRequest: Codable {
    let wardrobe: [GarmentSummary]
    let occasion, weather, mood: String
    let anchorID: UUID?
    let request: String
    let styleProfile: StyleProfileDTO?
    let inspirationExamples: [InspirationExample]
}
struct StyleResponse: Codable { let outfits: [OutfitSuggestionDTO] }
private struct AssessmentRequest: Codable {
    let candidate: CandidateSummary
    let wardrobe: [GarmentSummary]
    let styleProfile: StyleProfileDTO?
    let inspirationExamples: [InspirationExample]
}
private struct RenderRequest: Codable { let mode, referenceBase64: String; let garmentImagesBase64: [String] }
struct RenderResponse: Codable { let imageBase64: String }
private struct CatalogEditRequest: Codable { let imageBase64, instruction: String }
