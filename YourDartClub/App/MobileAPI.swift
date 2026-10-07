import Foundation
import Security

struct Team: Codable, Identifiable { let id: Int; let name: String; let owner: Bool; let active: Bool; let paidUntil: String?; let playerLimit: Int? }
struct Account: Codable { let userId: Int; let quickScoreAutoSubmit: Bool; let teams: [Team]; let canCreateTeam: Bool? }
struct APIError: Error { let status: Int }
struct MobileAPI {
    let base: URL
    let token: String?
    var team: Int?
    func request(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard base.scheme == "https" else { throw APIError(status: 0) }
        var components = URLComponents(url:base.appendingPathComponent("api/mobile/v1/" + path),resolvingAgainstBaseURL:false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw APIError(status:0) }
        var request = URLRequest(url:url)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("application/json",forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json",forHTTPHeaderField: "Content-Type") }
        request.setValue(AppLanguage.code,forHTTPHeaderField:"X-App-Language")
        if let token { request.setValue("Bearer \(token)",forHTTPHeaderField: "Authorization") }
        if let team { request.setValue(String(team),forHTTPHeaderField: "X-Team-Id") }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: SameOriginDelegate(origin: base), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data,response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0) }
        guard (200...299).contains(http.statusCode) else { throw APIError(status: http.statusCode) }
        return data
    }
    static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
final class SameOriginDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // No redirects: credentials never leave the configured origin.
        completionHandler(nil)
    }
}
enum Vault {
    static func read(_ key: String) -> Data? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"YourDartClub.mobile",kSecAttrAccount as String:key,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary,&item) == errSecSuccess ? item as? Data : nil
    }
    static func write(_ key: String, _ data: Data) throws {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"YourDartClub.mobile",kSecAttrAccount as String:key]
        let attributes: [String: Any] = [kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary,attributes as CFDictionary)
        if result == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes){_,new in new} as CFDictionary,nil) == errSecSuccess else { throw APIError(status: 0) }
        } else if result != errSecSuccess { throw APIError(status: 0) }
    }
    static func delete(_ key: String) throws {
        let result = SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"YourDartClub.mobile",kSecAttrAccount as String:key] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw APIError(status: 0) }
    }
}
