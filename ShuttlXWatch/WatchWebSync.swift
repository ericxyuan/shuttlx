import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import Security
import SwiftUI
import WatchKit
import ShuttlXCore

struct WebWatchConfiguration: Decodable {
    let settings: TrackingSettings
    let layout: WatchLayout
    let speedUnit: String
}
private struct WebWatchCredential: Codable {
    let baseURL: URL
    let deviceID: UUID
    let token: String
}
/// Do not forward device credentials to redirected hosts or browser sign-in pages.
private final class WebRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor @Observable final class WatchWebSync {
    private(set) var isPaired = false
    private(set) var isSyncing = false
    private(set) var status = "Website not connected"
    private(set) var lastError: String?
    private(set) var speedUnit = "km/h"
    private(set) var pairingPayload: String?
    private(set) var pairingExpiresAt: Date?
    @ObservationIgnored private var credential: WebWatchCredential?
    @ObservationIgnored private let network = URLSession(configuration: .ephemeral, delegate: WebRedirectBlocker(), delegateQueue: nil)
    private static let account = "shuttlx-website-device-v1"
    init() {
        var query = Self.keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let saved = try? JSONDecoder().decode(WebWatchCredential.self, from: data) {
            credential = saved; isPaired = true; status = "Website connected"
        }
    }
    func makePairingQR(website: String) throws {
        guard let url = Self.validBaseURL(website) else { throw message("Enter the website's HTTPS address, without a page path.") }
        let expires = Date().addingTimeInterval(600)
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw message("Could not create a secure pairing request.") }
        let nonce = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.scheme = "shuttlx"
        components.host = "website-pair"
        components.queryItems = [
            URLQueryItem(name: "base", value: Self.base64url(url.absoluteString)),
            URLQueryItem(name: "device", value: WKInterfaceDevice.current().identifierForVendor?.uuidString ?? UUID().uuidString),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "name", value: WKInterfaceDevice.current().name),
            URLQueryItem(name: "expires", value: String(Int(expires.timeIntervalSince1970)))
        ]
        guard let payload = components.url?.absoluteString else { throw message("Could not create the pairing QR code.") }
        pairingPayload = payload
        pairingExpiresAt = expires
    }
    func clearPairing() { pairingPayload = nil; pairingExpiresAt = nil }
    func acceptCredential(baseURL: URL, deviceID: UUID, token: String) throws {
        guard Self.validBaseURL(baseURL.absoluteString) != nil, token.count == 64, token.allSatisfy({ $0.isHexDigit }) else { throw message("The website returned an invalid pairing response.") }
        let saved = WebWatchCredential(baseURL: baseURL, deviceID: deviceID, token: token)
        let encoded = try JSONEncoder().encode(saved)
        var result = SecItemUpdate(Self.keychainQuery as CFDictionary, [kSecValueData as String: encoded] as CFDictionary)
        if result == errSecItemNotFound {
            var query = Self.keychainQuery
            query[kSecValueData as String] = encoded
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(query as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw message("Could not securely save pairing. Create a new code and try again.") }
        credential = saved; isPaired = true; lastError = nil; status = "Website connected"; clearPairing()
    }
    func synchronize(_ sessions: [Session], onConfiguration: (WebWatchConfiguration) throws -> Void,
                     onAcknowledged: (UUID) async throws -> Void) async {
        guard let credential, !isSyncing else { return }
        isSyncing = true; lastError = nil; status = "Syncing website"
        defer { isSyncing = false }
        do {
            let configData = try await request(base: credential.baseURL, path: "api/device/configuration", token: credential.token)
            let config = try JSONDecoder().decode(WebWatchConfiguration.self, from: configData)
            try onConfiguration(config)
            speedUnit = config.speedUnit == "mph" ? "mph" : "km/h"
            for session in sessions {
                var summary = session
                for index in summary.shots.indices { summary.shots[index].samples = [] }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let data = try await request(base: credential.baseURL, path: "api/device/sessions", method: "POST",
                                             token: credential.token, body: encoder.encode(summary))
                struct Receipt: Decodable { let accepted: Bool; let sessionID: UUID }
                let receipt = try JSONDecoder().decode(Receipt.self, from: data)
                guard receipt.accepted, receipt.sessionID == session.id else { throw message("The website did not confirm this session. It stays on Watch.") }
                try await onAcknowledged(session.id)
            }
            status = "Website up to date"
        } catch { lastError = error.localizedDescription; status = "Saved on Watch · sync pending" }
    }
    func disconnect() async throws {
        guard let credential, !isSyncing else { return }
        _ = try await request(base: credential.baseURL, path: "api/device/disconnect", method: "POST", token: credential.token)
        let result = SecItemDelete(Self.keychainQuery as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw message("Could not clear the stored pairing.") }
        self.credential = nil; isPaired = false; status = "Website disconnected"
    }
    private func request(base: URL, path: String, method: String = "GET", token: String? = nil, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 45; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw message("The website could not be reached.") }
        if (300...399).contains(http.statusCode) { throw message("Direct Watch access is not enabled on this website yet. Your sessions stay on Watch.") }
        guard (200...299).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw message((try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Website sync failed (\(http.statusCode)). Try again when connected.")
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true else { throw message("The website requires browser sign-in. Enable direct Watch access before pairing.") }
        return data
    }
    private static var keychainQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.shuttlx.website", kSecAttrAccount as String: account] }
    private static func validBaseURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return nil }
        return url
    }
    private static func base64url(_ value: String) -> String {
        Data(value.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func message(_ text: String) -> NSError { NSError(domain: "ShuttlXWeb", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
struct WatchWebsiteView: View {
    @Environment(WatchSessionController.self) private var controller
    @State private var website = "https://shuttlx.ericxyuan.chatgpt.site"
    @State private var error: String?
    @State private var confirmDisconnect = false
    @State private var showingQR = false
    var body: some View {
        Form {
            if controller.web.isPaired {
                Section {
                    Label("Website connected", systemImage: "checkmark.circle")
                    Text(controller.web.status).font(.caption)
                    Button("Sync now") { controller.retrySync() }.disabled(controller.web.isSyncing)
                    Button("Disconnect", role: .destructive) { confirmDisconnect = true }.disabled(controller.web.isSyncing)
                }
            } else {
                Section("Pair with ShuttlX on iPhone") {
                    Text("Enter the website address, then show a full-screen QR code. Scan it from the ShuttlX iPhone app to finish pairing.").font(.caption)
                    TextField("Website address", text: $website).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Show pairing QR", systemImage: "qrcode") {
                        do { try controller.web.makePairingQR(website: website); showingQR = true; error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            if let error = error ?? controller.web.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Saved sessions sync directly over the internet. No iPhone app required.").font(.caption2)
        }.navigationTitle("Website sync")
        .fullScreenCover(isPresented: $showingQR) {
            if let payload = controller.web.pairingPayload {
                WatchPairingQRView(payload: payload, expiresAt: controller.web.pairingExpiresAt ?? .now) { showingQR = false; controller.web.clearPairing() }
            }
        }
        .confirmationDialog("Disconnect website?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { Task { do { try await controller.web.disconnect() } catch { self.error = error.localizedDescription } } }
        } message: { Text("Saved website sessions remain in your account. Pending sessions stay on Watch.") }
    }
}

private struct WatchPairingQRView: View {
    let payload: String
    let expiresAt: Date
    let dismiss: () -> Void
    @State private var now = Date()
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Text("Scan with ShuttlX on iPhone").font(.headline).multilineTextAlignment(.center)
                QRCodeImage(payload: payload)
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Website pairing QR code")
                Text("Expires in (max(0, Int(expiresAt.timeIntervalSince(now))).formatted())s")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Button("Cancel", action: dismiss).buttonStyle(.bordered)
            }.padding(12)
        }
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); now = Date() } }
        .onChange(of: now) { _, value in if value >= expiresAt { dismiss() } }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct QRCodeImage: View {
    let payload: String
    var body: some View {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        let image = filter.outputImage.flatMap { CIContext().createCGImage($0.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: $0.extent) }
        Group { if let image { Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit() } else { Image(systemName: "xmark.circle") } }
            .frame(width: 170, height: 170)
    }
}
