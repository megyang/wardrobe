import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftData
import UIKit

enum HostedStatus: Equatable {
    case signedOut, connecting, available, busy, offline, inviteRequired, error(String)

    var label: String {
        switch self {
        case .signedOut: "Sign in required"
        case .connecting: "Connecting"
        case .available: "Cloud available"
        case .busy: "Working"
        case .offline: "Offline — cached data available"
        case .inviteRequired: "Invitation required"
        case .error(let message): message
        }
    }
}

enum HostedConfiguration {
    static var apiURL: URL? { configuredURL("WearwellAPIBaseURL") }
    static var supabaseURL: URL? { configuredURL("WearwellSupabaseURL") }
    static var supabaseAnonKey: String { Bundle.main.object(forInfoDictionaryKey: "WearwellSupabaseAnonKey") as? String ?? "" }

    static var isConfigured: Bool { apiURL != nil && supabaseURL != nil && !supabaseAnonKey.isEmpty }

    private static func configuredURL(_ key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$("), let url = URL(string: value) else { return nil }
        return url
    }
}

private enum HostedKeychain {
    private static let service = "com.wearwell.app.hosted-session"

    static func string(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var insert = query; insert[kSecValueData as String] = Data(value.utf8); insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func clear() { set(nil, account: "accessToken"); set(nil, account: "refreshToken"); set(nil, account: "userID") }
}

@MainActor
final class HostedAuthController: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    @Published private(set) var isAuthenticated = HostedKeychain.string("accessToken") != nil
    @Published private(set) var userID = HostedKeychain.string("userID")
    @Published private(set) var message: String?
    private var continuation: CheckedContinuation<Void, Error>?

    func sendEmailLink(to email: String) async throws {
        guard let base = HostedConfiguration.supabaseURL else { throw HostedError.notConfigured }
        var request = URLRequest(url: base.appending(path: "auth/v1/otp")); request.httpMethod = "POST"
        request.setValue(HostedConfiguration.supabaseAnonKey, forHTTPHeaderField: "apikey"); request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(EmailLinkRequest(email: email, createUser: true))
        let (_, response) = try await URLSession.shared.data(for: request); try HostedHTTP.requireSuccess(response)
        message = "Check your email for the Wearwell sign-in link."
    }

    func signInWithApple() async throws {
        let request = ASAuthorizationAppleIDProvider().createRequest(); request.requestedScopes = [.email]
        let controller = ASAuthorizationController(authorizationRequests: [request]); controller.delegate = self; controller.presentationContextProvider = self
        try await withCheckedThrowingContinuation { continuation = $0; controller.performRequests() }
    }

    func handleCallback(_ url: URL) throws {
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fragment = URLComponents(string: "?" + (url.fragment ?? ""))?.queryItems ?? []
        let all = values + fragment
        guard let access = all.first(where: { $0.name == "access_token" })?.value else { throw HostedError.invalidResponse }
        HostedKeychain.set(access, account: "accessToken"); HostedKeychain.set(all.first(where: { $0.name == "refresh_token" })?.value, account: "refreshToken")
        if let subject = HostedJWT.subject(access) { HostedKeychain.set(subject, account: "userID"); userID = subject }
        isAuthenticated = true; message = nil
    }

    func signOut() { HostedKeychain.clear(); isAuthenticated = false; userID = nil; message = nil }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor() }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            do {
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else { throw HostedError.invalidResponse }
                try await exchangeAppleToken(token, nonce: nil); continuation?.resume(); continuation = nil
            } catch { continuation?.resume(throwing: error); continuation = nil }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in continuation?.resume(throwing: error); continuation = nil }
    }

    private func exchangeAppleToken(_ token: String, nonce: String?) async throws {
        guard let base = HostedConfiguration.supabaseURL else { throw HostedError.notConfigured }
        var components = URLComponents(url: base.appending(path: "auth/v1/token"), resolvingAgainstBaseURL: false)!; components.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]
        var request = URLRequest(url: components.url!); request.httpMethod = "POST"; request.setValue(HostedConfiguration.supabaseAnonKey, forHTTPHeaderField: "apikey"); request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(AppleTokenRequest(provider: "apple", idToken: token, nonce: nonce))
        let (data, response) = try await URLSession.shared.data(for: request); try HostedHTTP.requireSuccess(response)
        let session = try HostedHTTP.decoder.decode(AuthSessionResponse.self, from: data)
        HostedKeychain.set(session.accessToken, account: "accessToken"); HostedKeychain.set(session.refreshToken, account: "refreshToken"); HostedKeychain.set(session.user.id, account: "userID")
        userID = session.user.id; isAuthenticated = true
    }
}

private struct EmailLinkRequest: Encodable {
    let email: String
    let createUser: Bool

    enum CodingKeys: String, CodingKey {
        case email
        case createUser = "create_user"
    }
}

@MainActor
final class HostedClient: ObservableObject {
    @Published var status: HostedStatus = HostedKeychain.string("accessToken") == nil ? .signedOut : .connecting
    @Published private(set) var lastSyncAt: Date?
    var isAuthenticated: Bool { HostedKeychain.string("accessToken") != nil }

    func refreshStatus() async {
        guard isAuthenticated else { status = .signedOut; return }
        do { _ = try await request(path: "v1/usage", method: "GET", body: Optional<String>.none); status = .available }
        catch HostedError.inviteRequired { status = .inviteRequired }
        catch { status = .offline }
    }

    func redeemInvite(_ code: String) async throws {
        _ = try await request(path: "v1/invites/redeem", body: ["code": code]); await refreshStatus()
    }

    func usage() async throws -> HostedUsage { try HostedHTTP.decoder.decode(HostedUsage.self, from: await request(path: "v1/usage", method: "GET", body: Optional<String>.none)) }

    func submitAnalysis(imageData: Data, sourceURL: String? = nil) async throws -> AnalysisJobDTO { try await submitAnalysis(imageData: [imageData], sourceURL: sourceURL, sameItem: false) }
    func submitAnalysis(imageData: [Data], sourceURL: String? = nil, sameItem: Bool) async throws -> AnalysisJobDTO {
        let ids = try await upload(images: imageData, kind: "source")
        return try await createJob(kind: "analyze", payload: AnalyzeJobPayload(sourceAssetIDs: ids, sourceURL: sourceURL, sameItem: sameItem), as: AnalysisJobDTO.self)
    }
    func analysisJob(id: String) async throws -> AnalysisJobDTO {
        let wire = try await job(id, as: AnalysisJobWire.self)
        var converted: [GarmentAnalysisDTO] = []
        for item in wire.result?.items ?? [] {
            let encoded: String?
            if let assetID = item.catalogAssetID { encoded = try await assetData(assetID).base64EncodedString() }
            else { encoded = nil }
            converted.append(GarmentAnalysisDTO(label: item.label, category: item.category, subcategory: item.subcategory, color: item.color, confidence: item.confidence, description: item.description, observed: item.observed, unknowns: item.unknowns, fingerprint: item.fingerprint, catalogImageBase64: encoded, modelVersion: item.modelVersion))
        }
        return AnalysisJobDTO(id: wire.id, kind: wire.kind, state: wire.state, createdAt: wire.createdAt, updatedAt: wire.updatedAt, stage: wire.stage, progressCompleted: wire.progressCompleted, progressTotal: wire.progressTotal, queuePosition: nil, estimatedSecondsRemaining: nil, processingStartedAt: nil, result: wire.result == nil ? nil : AnalyzeResponse(items: converted), error: wire.error)
    }
    func deleteAnalysisJob(id: String) async { _ = try? await request(path: "v1/jobs/\(id)", method: "DELETE", body: Optional<String>.none) }

    func analyze(imageData: Data, sourceURL: String? = nil) async throws -> [GarmentAnalysisDTO] {
        var value = try await submitAnalysis(imageData: imageData, sourceURL: sourceURL)
        while ["queued", "processing"].contains(value.state) { try await Task.sleep(for: .seconds(2)); value = try await analysisJob(id: value.id) }
        if let error = value.error { throw HostedError.server(error) }; return value.result?.items ?? []
    }

    func analyzeInspiration(imageData: Data) async throws -> InspirationAnalysisDTO {
        let assetID = try await upload(images: [imageData], kind: "inspiration")[0]
        var value: InspirationJobDTO = try await createJob(kind: "inspiration", payload: ["assetID": assetID], as: InspirationJobDTO.self)
        while ["queued", "processing"].contains(value.state) { try await Task.sleep(for: .seconds(2)); value = try await job(value.id, as: InspirationJobDTO.self) }
        guard let result = value.result else { throw HostedError.server(value.error ?? "Inspiration analysis failed.") }; return result
    }

    func submitStyle(garments: [Garment], occasion: String, weather: String, mood: String, anchorID: UUID?, request prompt: String, styleProfile: StyleProfile?, inspirations: [InspirationLook], recentOutfits: [OutfitSuggestionDTO] = [], outfitFeedback: [OutfitFeedbackDTO] = [], savedOutfits: [SavedOutfitExampleDTO] = [], outfitEdits: [OutfitEditFeedbackDTO] = []) async throws -> StyleJobDTO {
        let payload = try await stylePayload(garments: garments, occasion: occasion, weather: weather, mood: mood, anchorID: anchorID, request: prompt, styleProfile: styleProfile, inspirations: inspirations, recentOutfits: recentOutfits, outfitFeedback: outfitFeedback, savedOutfits: savedOutfits, outfitEdits: outfitEdits)
        return try await createJob(kind: "style", payload: payload, as: StyleJobDTO.self)
    }
    func styleJob(id: String) async throws -> StyleJobDTO { try await job(id, as: StyleJobDTO.self) }

    func submitAssessment(candidate: WishlistItem, garments: [Garment], styleProfile: StyleProfile?, inspirations: [InspirationLook]) async throws -> AssessmentJobDTO {
        let visualNames = [candidate.catalogAssetName.isEmpty ? candidate.sourceAssetName : candidate.catalogAssetName] + garments.map { $0.catalogAssetName.isEmpty ? $0.sourceAssetName : $0.catalogAssetName }
        let visualAssetIDs = try await uploadLocalAssets(names: visualNames)
        let payload = AssessmentPayload(candidate: CandidatePayload(candidate), wardrobe: garments.map(GarmentPayload.init), styleProfile: styleProfile?.profile, inspirationExamples: inspirations.compactMap(InspirationPayload.init), visualAssetIDs: visualAssetIDs)
        return try await createJob(kind: "assess", payload: payload, as: AssessmentJobDTO.self)
    }
    func assessmentJob(id: String) async throws -> AssessmentJobDTO { try await job(id, as: AssessmentJobDTO.self) }

    func submitCatalogEdit(imageData: Data, instruction: String) async throws -> CatalogEditJobDTO {
        let assetID = try await upload(images: [imageData], kind: "catalog")[0]
        return try await createJob(kind: "catalog-edit", payload: ["assetID": assetID, "instruction": instruction], as: CatalogEditJobDTO.self)
    }
    func catalogEditJob(id: String) async throws -> CatalogEditJobDTO {
        let wire = try await job(id, as: AssetJobWire.self)
        let result: RenderResponse? = if let assetID = wire.result?.assetID { RenderResponse(imageBase64: try await assetData(assetID).base64EncodedString()) } else { nil }
        return CatalogEditJobDTO(id: wire.id, kind: wire.kind, state: wire.state, createdAt: wire.createdAt, updatedAt: wire.updatedAt, stage: wire.stage, queuePosition: nil, estimatedSecondsRemaining: nil, result: result, error: wire.error)
    }
    func editCatalog(imageData: Data, instruction: String) async throws -> Data {
        var value = try await submitCatalogEdit(imageData: imageData, instruction: instruction)
        while ["queued", "processing"].contains(value.state) { try await Task.sleep(for: .seconds(2)); value = try await catalogEditJob(id: value.id) }
        guard let encoded = value.result?.imageBase64, let data = Data(base64Encoded: encoded) else { throw HostedError.server(value.error ?? "Image edit failed.") }; return data
    }

    func render(mode: VisualizationMode, reference: Data, garmentImages: [Data]) async throws -> Data {
        let ids = try await upload(images: [reference] + garmentImages, kind: "render-input")
        let created: AssetJobWire = try await createJob(kind: "render", payload: RenderJobPayload(mode: mode.rawValue, assetIDs: ids), as: AssetJobWire.self)
        var value = try await catalogEditJob(id: created.id)
        while ["queued", "processing"].contains(value.state) { try await Task.sleep(for: .seconds(2)); value = try await job(value.id, as: CatalogEditJobDTO.self) }
        guard let encoded = value.result?.imageBase64, let data = Data(base64Encoded: encoded) else { throw HostedError.server(value.error ?? "Visualization failed.") }; return data
    }

    func recommendItem(garments: [Garment], selectedGarmentIDs: [UUID], category: GarmentCategory, subcategory: GarmentSubcategory?) async throws -> ItemRecommendationDTO {
        let selected = Set(selectedGarmentIDs)
        let eligible = garments.filter {
            !selected.contains($0.id) && $0.category == category && (subcategory == nil || $0.subcategory == subcategory)
        }
        guard !eligible.isEmpty else { throw HostedError.server("No eligible wardrobe item is available.") }
        let eligibleIDs = Set(eligible.map(\.id))
        let relevant = garments.filter { selected.contains($0.id) || eligibleIDs.contains($0.id) }
        let visualNames = relevant.map { $0.catalogAssetName.isEmpty ? $0.sourceAssetName : $0.catalogAssetName }
        let payload = ItemRecommendationPayload(
            wardrobe: garments.map(GarmentPayload.init), selectedGarmentIDs: selectedGarmentIDs,
            category: category.rawValue, subcategory: subcategory?.rawValue,
            visualAssetIDs: try await uploadLocalAssets(names: visualNames)
        )
        var value: ItemRecommendationJobWire = try await createJob(kind: "recommend-item", payload: payload, as: ItemRecommendationJobWire.self)
        while ["queued", "processing"].contains(value.state) {
            try await Task.sleep(for: .seconds(2))
            value = try await job(value.id, as: ItemRecommendationJobWire.self)
        }
        guard let result = value.result, eligibleIDs.contains(result.garmentID) else {
            throw HostedError.server(value.error ?? "Luna could not recommend a matching item.")
        }
        return result
    }

    func deleteAccount() async throws { _ = try await request(path: "v1/account", method: "DELETE", body: Optional<String>.none); HostedKeychain.clear(); status = .signedOut }

    func importBackup(_ document: WearwellBackupDocument) async throws {
        var mapping: [String: String] = [:]
        for asset in document.archive.manifest.assets {
            guard let data = document.archive.assets[asset.name] else { throw BackupError.missingAsset(asset.name) }
            mapping[asset.name] = try await upload(images: [data], kind: "backup-import")[0]
        }
        _ = try await request(path: "v1/backups/import", body: CloudBackupImport(manifest: document.archive.manifest, assetIDs: mapping))
    }

    func synchronizeCache(context: ModelContext, force: Bool = false) async throws {
        guard status == .available else { throw HostedError.offlineWrite }
        if !force, let lastSyncAt, Date.now.timeIntervalSince(lastSyncAt) < 20 { return }
        guard let owner = HostedKeychain.string("userID") else { throw HostedError.signedOut }
        let defaults = UserDefaults.standard
        if let cachedOwner = defaults.string(forKey: "hostedCacheOwner"), cachedOwner != owner {
            await BackupService.clearCache(context: context)
        }
        defaults.set(owner, forKey: "hostedCacheOwner")

        let cloud = try HostedHTTP.decoder.decode(CloudBackupExport.self, from: await request(path: "v1/backups/export", method: "GET", body: Optional<String>.none))
        if cloud.hasRecords {
            var values: [String: Data] = [:]
            for asset in cloud.manifest.assets {
                guard let download = cloud.downloads.first(where: { $0.name == asset.name }), let url = URL(string: download.url) else { throw BackupError.missingAsset(asset.name) }
                let data = try await URLSession.shared.data(from: url).0
                guard data.count == asset.byteCount, BackupService.sha256(data) == asset.sha256 else { throw BackupError.invalidPackage("A cloud image failed checksum validation.") }
                values[asset.name] = data
            }
            _ = try await BackupService.restore(WearwellBackupDocument(archive: .init(manifest: cloud.manifest, assets: values)), context: context)
        }
        let merged = try await BackupService.makeDocument(context: context)
        try await importBackup(merged)
        lastSyncAt = .now
    }

    func clearLocalCache(context: ModelContext) async {
        await BackupService.clearCache(context: context)
        UserDefaults.standard.removeObject(forKey: "hostedCacheOwner")
        lastSyncAt = nil
    }

    private func stylePayload(garments: [Garment], occasion: String, weather: String, mood: String, anchorID: UUID?, request: String, styleProfile: StyleProfile?, inspirations: [InspirationLook], recentOutfits: [OutfitSuggestionDTO], outfitFeedback: [OutfitFeedbackDTO], savedOutfits: [SavedOutfitExampleDTO], outfitEdits: [OutfitEditFeedbackDTO]) async throws -> StylePayload {
        let names = garments.map { $0.catalogAssetName.isEmpty ? $0.sourceAssetName : $0.catalogAssetName } + inspirations.map(\.assetName)
        return StylePayload(wardrobe: garments.map(GarmentPayload.init), occasion: occasion, weather: weather, mood: mood, anchorID: anchorID, request: request, styleProfile: styleProfile?.profile, inspirationExamples: inspirations.compactMap(InspirationPayload.init), recentOutfits: recentOutfits, outfitFeedback: outfitFeedback, savedOutfits: savedOutfits, outfitEdits: outfitEdits, visualAssetIDs: try await uploadLocalAssets(names: names))
    }

    private func uploadLocalAssets(names: [String]) async throws -> [String] {
        var values: [Data] = []
        for name in names where !name.isEmpty { if let data = try? await AssetStore.shared.visualReferenceData(named: name) { values.append(data) } }
        return try await upload(images: values, kind: "visual-reference")
    }

    private func upload(images: [Data], kind: String) async throws -> [String] {
        var ids: [String] = []
        for image in images {
            let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
            let declaration = UploadDeclaration(mimeType: "image/jpeg", byteCount: image.count, sha256: digest, kind: kind)
            let created = try HostedHTTP.decoder.decode(UploadResponse.self, from: await request(path: "v1/assets/upload", body: declaration))
            if !created.alreadyUploaded {
                guard let signedURL = created.signedURL, let url = URL(string: signedURL) else { throw HostedError.invalidResponse }
                var upload = URLRequest(url: url); upload.httpMethod = "PUT"; upload.setValue("image/jpeg", forHTTPHeaderField: "content-type"); upload.httpBody = image
                let (_, response) = try await URLSession.shared.data(for: upload); try HostedHTTP.requireSuccess(response)
                _ = try await request(path: "v1/assets/finalize", body: ["assetID": created.assetID])
            }
            ids.append(created.assetID)
        }
        return ids
    }

    private func assetData(_ id: String) async throws -> Data {
        let response = try HostedHTTP.decoder.decode(SignedDownload.self, from: await request(path: "v1/assets/\(id)", method: "GET", body: Optional<String>.none))
        guard let url = URL(string: response.url) else { throw HostedError.invalidResponse }; return try await URLSession.shared.data(from: url).0
    }

    private func createJob<T: Encodable, R: Decodable>(kind: String, payload: T, as: R.Type) async throws -> R {
        let key = UUID().uuidString; return try HostedHTTP.decoder.decode(R.self, from: await request(path: "v1/jobs/\(kind)", body: payload, headers: ["Idempotency-Key": key]))
    }
    private func job<R: Decodable>(_ id: String, as: R.Type) async throws -> R { try HostedHTTP.decoder.decode(R.self, from: await request(path: "v1/jobs/\(id)", method: "GET", body: Optional<String>.none)) }

    private func request<T: Encodable>(path: String, method: String = "POST", body: T?, headers: [String: String] = [:]) async throws -> Data {
        guard let base = HostedConfiguration.apiURL else { throw HostedError.notConfigured }
        guard let token = HostedKeychain.string("accessToken") else { status = .signedOut; throw HostedError.signedOut }
        let encodedBody = try body.map { try HostedHTTP.encoder.encode($0) }
        func makeRequest(token: String) -> URLRequest {
            var value = URLRequest(url: base.appending(path: path)); value.httpMethod = method; value.timeoutInterval = 300
            value.setValue("Bearer \(token)", forHTTPHeaderField: "authorization"); value.setValue("application/json", forHTTPHeaderField: "content-type")
            headers.forEach { value.setValue($0.value, forHTTPHeaderField: $0.key) }; value.httpBody = encodedBody
            return value
        }
        do {
            var (data, response) = try await URLSession.shared.data(for: makeRequest(token: token))
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                let renewed = try await refreshAccessToken()
                (data, response) = try await URLSession.shared.data(for: makeRequest(token: renewed))
            }
            try HostedHTTP.requireSuccess(response, data: data)
            return data
        } catch let error as HostedError { throw error }
        catch { status = .offline; throw error }
    }

    private func refreshAccessToken() async throws -> String {
        guard let base = HostedConfiguration.supabaseURL,
              let refreshToken = HostedKeychain.string("refreshToken") else {
            HostedKeychain.clear(); status = .signedOut; throw HostedError.signedOut
        }
        var components = URLComponents(url: base.appending(path: "auth/v1/token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        var request = URLRequest(url: components.url!); request.httpMethod = "POST"
        request.setValue(HostedConfiguration.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try HostedHTTP.encoder.encode(RefreshTokenRequest(refreshToken: refreshToken))
        let (data, response) = try await URLSession.shared.data(for: request)
        do {
            try HostedHTTP.requireSuccess(response, data: data)
            let session = try HostedHTTP.decoder.decode(AuthSessionResponse.self, from: data)
            HostedKeychain.set(session.accessToken, account: "accessToken")
            HostedKeychain.set(session.refreshToken, account: "refreshToken")
            HostedKeychain.set(session.user.id, account: "userID")
            return session.accessToken
        } catch {
            HostedKeychain.clear(); status = .signedOut; throw HostedError.signedOut
        }
    }
}

enum HostedError: LocalizedError {
    case notConfigured, signedOut, inviteRequired, offlineWrite, invalidResponse, conflict, jobNotFound, server(String)
    var errorDescription: String? { switch self { case .notConfigured: "Hosted Wearwell is not configured."; case .signedOut: "Sign in to continue."; case .inviteRequired: "Redeem a Wearwell invitation first."; case .offlineWrite: "Connect to Wearwell before making changes."; case .invalidResponse: "The server returned an invalid response."; case .conflict: "This item changed elsewhere. Sync and retry."; case .jobNotFound: "Job not found or expired."; case .server(let message): message } }
}

private enum HostedHTTP {
    static let encoder: JSONEncoder = { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }()
    static let decoder: JSONDecoder = { let value = JSONDecoder(); value.keyDecodingStrategy = .convertFromSnakeCase; value.dateDecodingStrategy = .iso8601; return value }()
    static func requireSuccess(_ response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw HostedError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 401 { throw HostedError.signedOut }; if http.statusCode == 403 { throw HostedError.inviteRequired }; if http.statusCode == 404 { throw HostedError.jobNotFound }; if http.statusCode == 409 { throw HostedError.conflict }
            let body = try? decoder.decode(ErrorEnvelope.self, from: data); throw HostedError.server(body?.error ?? "Request failed (\(http.statusCode)).")
        }
    }
}

private enum HostedJWT { static func subject(_ token: String) -> String? { let values = token.split(separator: "."); guard values.count > 1 else { return nil }; var base = String(values[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); base += String(repeating: "=", count: (4 - base.count % 4) % 4); guard let data = Data(base64Encoded: base), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }; return object["sub"] as? String } }

private struct AppleTokenRequest: Codable { let provider: String; let idToken: String; let nonce: String? }
private struct RefreshTokenRequest: Codable {
    let refreshToken: String
    enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
}
private struct AuthSessionResponse: Codable { let accessToken, refreshToken: String; let user: AuthUser }
private struct AuthUser: Codable { let id: String }
private struct ErrorEnvelope: Codable { let error: String }
private struct UploadDeclaration: Codable { let mimeType: String; let byteCount: Int; let sha256, kind: String }
private struct UploadResponse: Codable {
    let assetID, path: String
    let signedURL: String?
    let alreadyUploaded: Bool
    enum CodingKeys: String, CodingKey { case assetID, path, alreadyUploaded; case signedURL = "signedUrl" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try values.decode(String.self, forKey: .assetID)
        path = try values.decode(String.self, forKey: .path)
        signedURL = try values.decodeIfPresent(String.self, forKey: .signedURL)
        alreadyUploaded = try values.decodeIfPresent(Bool.self, forKey: .alreadyUploaded) ?? false
    }
}
private struct SignedDownload: Codable { let url: String; let expiresIn: Int }
private struct AnalyzeJobPayload: Codable { let sourceAssetIDs: [String]; let sourceURL: String?; let sameItem: Bool }
private struct RenderJobPayload: Codable { let mode: String; let assetIDs: [String] }
private struct InspirationJobDTO: Codable { let id, kind, state: String; let result: InspirationAnalysisDTO?; let error: String? }
private struct AnalysisJobWire: Codable { let id,kind,state,createdAt,updatedAt:String; let stage:String?; let progressCompleted,progressTotal:Int?; let result:AnalyzeWireResponse?; let error:String? }
private struct AnalyzeWireResponse: Codable { let items:[GarmentAnalysisWire] }
private struct GarmentAnalysisWire: Codable { let label,category:String; let subcategory:String?; let color:String; let confidence:Double; let description,observed:String; let unknowns:[String]; let fingerprint:String; let catalogAssetID:String?; let modelVersion:String }
private struct AssetJobWire: Codable { let id,kind,state,createdAt,updatedAt:String; let stage:String?; let result:AssetResult?; let error:String? }
private struct AssetResult: Codable { let assetID:String }

struct HostedUsage: Codable, Equatable { let analysisUsed, analysisLimit, styleUsed, styleLimit, imageUsed, imageLimit, storageUsed, storageLimit: Int }

private struct GarmentPayload: Codable {
    let id: UUID; let label, category: String; let subcategory: String?; let color, description, observed: String; let unknowns: [String]; let tags, season, occasion: String; let confidence: Double
    init(_ value: Garment) { id=value.id; label=value.label; category=value.categoryRaw; subcategory=value.subcategoryRaw; color=value.color; description=value.details; observed=value.observed; unknowns=value.unknowns; tags=value.tags; season=value.season; occasion=value.occasion; confidence=value.confidence }
}
private struct CandidatePayload: Codable { let id: UUID; let label, category: String; let subcategory: String?; let color, description: String; init(_ value: WishlistItem) { id=value.id; label=value.label; category=value.categoryRaw; subcategory=value.subcategoryRaw; color=value.color; description=value.details } }
private struct InspirationPayload: Codable { let id: UUID; let summary: String; let aesthetics,palette,silhouettes,layering,details,occasions,outfitFormula,proportions,focalPoints,stylingRules:[String]; let vector: StyleVectorDTO; init?(_ look: InspirationLook) { guard let value=look.analysis else{return nil}; id=look.id; summary=value.summary; aesthetics=value.aesthetics; palette=value.palette; silhouettes=value.silhouettes; layering=value.layering; details=value.details; occasions=value.occasions; outfitFormula=value.outfitFormula ?? []; proportions=value.proportions ?? []; focalPoints=value.focalPoints ?? []; stylingRules=value.stylingRules ?? []; vector=value.vector } }
private struct StylePayload: Codable { let wardrobe:[GarmentPayload]; let occasion,weather,mood:String; let anchorID:UUID?; let request:String; let styleProfile:StyleProfileDTO?; let inspirationExamples:[InspirationPayload]; let recentOutfits:[OutfitSuggestionDTO]; let outfitFeedback:[OutfitFeedbackDTO]; let savedOutfits:[SavedOutfitExampleDTO]; let outfitEdits:[OutfitEditFeedbackDTO]; let visualAssetIDs:[String] }
private struct AssessmentPayload: Codable { let candidate:CandidatePayload; let wardrobe:[GarmentPayload]; let styleProfile:StyleProfileDTO?; let inspirationExamples:[InspirationPayload]; let visualAssetIDs:[String] }
private struct ItemRecommendationPayload: Codable { let wardrobe:[GarmentPayload]; let selectedGarmentIDs:[UUID]; let category:String; let subcategory:String?; let visualAssetIDs:[String] }
private struct ItemRecommendationJobWire: Codable { let id,kind,state,createdAt,updatedAt:String; let stage:String?; let result:ItemRecommendationDTO?; let error:String? }
private struct CloudBackupImport: Codable { let manifest: WearwellBackupManifest; let assetIDs: [String: String] }
private struct CloudBackupExport: Codable {
    let manifest: WearwellBackupManifest
    let downloads: [CloudAssetDownload]
    var hasRecords: Bool {
        !manifest.garments.isEmpty || !manifest.wishlistItems.isEmpty || !manifest.outfits.isEmpty ||
        !manifest.visualizations.isEmpty || !manifest.referencePhotos.isEmpty || !manifest.inspirationLooks.isEmpty || !manifest.styleProfiles.isEmpty
    }
}
private struct CloudAssetDownload: Codable { let name, url: String }
