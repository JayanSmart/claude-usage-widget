import Foundation
import Security
import SQLite3
import CommonCrypto
import ClaudeUsageCore

typealias UsageResult = ParsedUsage

enum UsageError: LocalizedError {
    case noCookiesFound
    case noOrgFound
    case httpError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noCookiesFound:
            return "No Claude.ai session found. Log in at claude.ai in Safari, Firefox, or Chrome, then click Refresh."
        case .noOrgFound:
            return "Could not determine your organisation ID. Try logging out and back in to claude.ai."
        case .httpError(let code):
            return "HTTP \(code) from claude.ai. Your session may have expired — log in again and click Refresh."
        case .invalidResponse:
            return "Unexpected API response from claude.ai."
        }
    }
}

// MARK: - Client

actor UsageClient {
    private let baseURL = "https://claude.ai"
    private let headers: [String: String] = [
        "anthropic-client-platform": "web_claude_ai",
        "Accept": "application/json",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    ]

    private var cachedOrgId: String?

    func fetchUsage() async throws -> UsageResult {
        let (cookies, source) = try extractCookies()
        let orgId = try await resolveOrgId(cookies: cookies)
        let json = try await get("/api/organizations/\(orgId)/usage", cookies: cookies)
        return parseUsage(json, source: source)
    }

    // MARK: - Org ID

    private func resolveOrgId(cookies: String) async throws -> String {
        if let id = cachedOrgId { return id }
        // UserDefaults is populated either by the login JS interceptor or manual entry
        if let id = UserDefaults.standard.string(forKey: "claudeOrgId"), !id.isEmpty {
            cachedOrgId = id
            return id
        }
        let id = try await fetchOrgId(cookies: cookies)
        UserDefaults.standard.set(id, forKey: "claudeOrgId")
        cachedOrgId = id
        return id
    }

    private func fetchOrgId(cookies: String) async throws -> String {
        // Try /api/organizations list
        if let json = try? await get("/api/organizations", cookies: cookies),
           let orgs = json["organizations"] as? [[String: Any]],
           let first = orgs.first,
           let id = first["id"] as? String {
            return id
        }

        // Try /api/bootstrap (session info envelope)
        if let json = try? await get("/api/bootstrap", cookies: cookies) {
            if let memberships = json["memberships"] as? [[String: Any]] {
                for m in memberships {
                    let org = m["organization"] as? [String: Any] ?? m
                    if let id = org["id"] as? String { return id }
                }
            }
            if let account = json["account"] as? [String: Any],
               let id = account["organization_id"] as? String { return id }
        }

        // Try /api/account
        if let json = try? await get("/api/account", cookies: cookies),
           let id = json["organization_id"] as? String {
            return id
        }

        throw UsageError.noOrgFound
    }

    // MARK: - HTTP

    private func get(_ path: String, cookies: String) async throws -> [String: Any] {
        guard let url = URL(string: baseURL + path) else { throw UsageError.invalidResponse }
        var req = URLRequest(url: url)
        req.setValue(cookies, forHTTPHeaderField: "Cookie")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UsageError.httpError(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        return json
    }

    // MARK: - Parsing

    private func parseUsage(_ json: [String: Any], source: String) -> UsageResult {
        UsageResult.parse(json, source: source)
    }

    // MARK: - Session key (Keychain) + Org ID (UserDefaults)

    func storeSessionKey(_ value: String, orgId: String? = nil) {
        Keychain.write(value)
        if let id = orgId { storeOrgId(id) }
        cachedOrgId = nil
    }

    func storeOrgId(_ id: String) {
        UserDefaults.standard.set(id, forKey: "claudeOrgId")
        cachedOrgId = id
    }

    func clearSessionKey() {
        Keychain.delete()
        cachedOrgId = nil
    }

    // MARK: - Cookie extraction

    private func extractCookies() throws -> (String, String) {
        // Keychain is highest priority — set by the in-app login flow
        if let key = Keychain.read(), !key.isEmpty { return ("sessionKey=\(key)", "Keychain") }
        // Fall back to browser cookie files (Firefox then Chrome; Safari is SIP-protected)
        if let c = firefoxCookies() { return (c, "Firefox") }
        if let c = chromeCookies()  { return (c, "Chrome") }
        throw UsageError.noCookiesFound
    }

    // MARK: Safari

    /// Reads claude.ai cookies from Safari's Cookies.binarycookies file.
    /// The format is proprietary but fully documented and values are stored plaintext.
    private func safariCookies() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Cookies/Cookies.binarycookies")
        guard let data = try? Data(contentsOf: url), data.count > 8 else { return nil }

        // Magic "cook"
        guard data.prefix(4) == Data([0x63, 0x6F, 0x6F, 0x6B]) else { return nil }

        // Number of pages — big-endian uint32 at offset 4
        let numPages = Int(data.readUInt32BE(at: 4))
        guard numPages > 0, 8 + numPages * 4 < data.count else { return nil }

        // Page sizes — big-endian uint32 array at offset 8
        var pageSizes: [Int] = []
        for i in 0..<numPages {
            pageSizes.append(Int(data.readUInt32BE(at: 8 + i * 4)))
        }

        var parts: [String] = []
        var hasSession = false
        var pageStart = 8 + numPages * 4

        for pageSize in pageSizes {
            guard pageStart + pageSize <= data.count, pageSize >= 8 else {
                pageStart += pageSize; continue
            }
            let page = data[pageStart ..< pageStart + pageSize]

            // Within a page, NumCookies is little-endian uint32 at offset 4
            let numCookies = Int(page.readUInt32LE(at: page.startIndex + 4))

            for i in 0..<numCookies {
                // Cookie offsets are little-endian uint32 at offset 8 + i*4 within the page
                let cookieRelOffset = Int(page.readUInt32LE(at: page.startIndex + 8 + i * 4))
                let cookieAbsStart  = pageStart + cookieRelOffset
                guard cookieAbsStart + 56 <= data.count else { continue }

                // Cookie record layout (all little-endian, relative to record start):
                //  0  size          uint32
                //  8  flags         uint32  (1=secure, 4=httpOnly)
                // 16  domain offset uint32
                // 20  name offset   uint32
                // 24  path offset   uint32
                // 28  value offset  uint32
                // 40  expiry date   double  (Mac absolute time, seconds since 2001-01-01)
                // 48  create date   double
                // 56+ null-terminated strings
                let domainOff = Int(data.readUInt32LE(at: cookieAbsStart + 16))
                let nameOff   = Int(data.readUInt32LE(at: cookieAbsStart + 20))
                let valueOff  = Int(data.readUInt32LE(at: cookieAbsStart + 28))

                let domain = data.readCString(at: cookieAbsStart + domainOff)
                let name   = data.readCString(at: cookieAbsStart + nameOff)
                let value  = data.readCString(at: cookieAbsStart + valueOff)

                guard !name.isEmpty, !value.isEmpty,
                      domain.hasSuffix("claude.ai") else { continue }
                if name == "sessionKey" { hasSession = true }
                parts.append("\(name)=\(value)")
            }

            pageStart += pageSize
        }

        return hasSession ? parts.joined(separator: "; ") : nil
    }

    // MARK: Firefox

    private func firefoxCookies() -> String? {
        let fm = FileManager.default
        let profilesPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox/Profiles")
        guard let profiles = try? fm.contentsOfDirectory(at: profilesPath, includingPropertiesForKeys: nil) else { return nil }

        for profile in profiles {
            let db = profile.appendingPathComponent("cookies.sqlite")
            guard fm.fileExists(atPath: db.path) else { continue }
            if let cookies = sqliteCookies(at: db, query: "SELECT name, value FROM moz_cookies WHERE host LIKE '%claude.ai'") {
                return cookies
            }
        }
        return nil
    }

    // MARK: Chrome / Chromium / Brave

    private func chromeCookies() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbs = [
            "Library/Application Support/Google/Chrome/Default/Cookies",
            "Library/Application Support/Google/Chrome/Profile 1/Cookies",
            "Library/Application Support/Chromium/Default/Cookies",
            "Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies",
        ].map { home.appendingPathComponent($0) }

        guard let aesKey = chromeAESKey() else { return nil }

        for db in dbs {
            guard FileManager.default.fileExists(atPath: db.path) else { continue }
            if let cookies = chromeDbCookies(at: db, aesKey: aesKey) { return cookies }
        }
        return nil
    }

    /// Derives the 16-byte AES-CBC key Chrome uses to encrypt cookies on macOS.
    private func chromeAESKey() -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-w", "-s", "Chrome Safe Storage"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let password = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !password.isEmpty else { return nil }
        return pbkdf2SHA1(password: password, salt: "saltysalt", iterations: 1003, keyLength: 16)
    }

    private func pbkdf2SHA1(password: String, salt: String, iterations: Int, keyLength: Int) -> Data? {
        guard let pw = password.data(using: .utf8),
              let s = salt.data(using: .utf8) else { return nil }
        var key = [UInt8](repeating: 0, count: keyLength)
        let result = pw.withUnsafeBytes { pwBytes in
            s.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBytes.baseAddress, pw.count,
                    saltBytes.baseAddress, s.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    UInt32(iterations),
                    &key, keyLength
                )
            }
        }
        return result == kCCSuccess ? Data(key) : nil
    }

    private func chromeDbCookies(at url: URL, aesKey: Data) -> String? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        guard (try? FileManager.default.copyItem(at: url, to: tmp)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let q = "SELECT name, value, encrypted_value FROM cookies WHERE host_key LIKE '%claude.ai'"
        guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var parts: [String] = []
        var hasSession = false

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nameCStr = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: nameCStr)

            var value = ""
            // Prefer plaintext value; fall back to decrypted blob
            if sqlite3_column_bytes(stmt, 1) > 0, let cStr = sqlite3_column_text(stmt, 1) {
                value = String(cString: cStr)
            } else {
                let blobLen = Int(sqlite3_column_bytes(stmt, 2))
                if blobLen > 0, let ptr = sqlite3_column_blob(stmt, 2) {
                    let enc = Data(bytes: ptr, count: blobLen)
                    value = decryptChromeCookie(enc, key: aesKey) ?? ""
                }
            }

            guard !value.isEmpty else { continue }
            if name == "sessionKey" { hasSession = true }
            parts.append("\(name)=\(value)")
        }

        return hasSession ? parts.joined(separator: "; ") : nil
    }

    /// Decrypts a Chrome AES-CBC cookie value (v10/v11 prefix, 16-space IV).
    private func decryptChromeCookie(_ data: Data, key: Data) -> String? {
        // Unencrypted (legacy)
        guard data.count > 3,
              data.prefix(3) == Data([0x76, 0x31, 0x30]) || data.prefix(3) == Data([0x76, 0x31, 0x31])
        else {
            return String(data: data, encoding: .utf8)
        }

        let payload = data.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128) // 16 space chars

        var out = [UInt8](repeating: 0, count: payload.count + kCCBlockSizeAES128)
        var outLen = 0

        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { i in
                payload.withUnsafeBytes { p in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress!, key.count,
                        i.baseAddress!,
                        p.baseAddress!, payload.count,
                        &out, out.count,
                        &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(bytes: out.prefix(outLen), encoding: .utf8)
    }

    // MARK: - SQLite helper (Firefox / plain cookies)

    private func sqliteCookies(at url: URL, query: String) -> String? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        guard (try? FileManager.default.copyItem(at: url, to: tmp)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var parts: [String] = []
        var hasSession = false

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nameCStr = sqlite3_column_text(stmt, 0),
                  let valCStr  = sqlite3_column_text(stmt, 1) else { continue }
            let name  = String(cString: nameCStr)
            let value = String(cString: valCStr)
            if name == "sessionKey" { hasSession = true }
            parts.append("\(name)=\(value)")
        }

        return hasSession ? parts.joined(separator: "; ") : nil
    }
}

// MARK: - Keychain

private enum Keychain {
    static let service = "com.jayansmart.claude-usage"
    static let account = "sessionKey"

    static func read() -> String? {
        let q: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData:  kCFBooleanTrue!,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        let data = Data(value.utf8)
        let search: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if SecItemCopyMatching(search as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(search as CFDictionary, [kSecValueData: data] as CFDictionary)
        } else {
            var add = search
            add[kSecValueData] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete() {
        let q: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Data helpers for binarycookies parsing (unused — kept for future Safari support)

private extension Data {
    /// Read a big-endian UInt32 at an absolute byte offset.
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return self[offset ..< offset + 4]
            .withUnsafeBytes { $0.load(as: UInt32.self) }
            .bigEndian
    }

    /// Read a little-endian UInt32 at an absolute byte index (supports slices).
    func readUInt32LE(at index: Index) -> UInt32 {
        guard index + 4 <= endIndex else { return 0 }
        return self[index ..< index + 4]
            .withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    /// Read a null-terminated UTF-8 string at an absolute byte offset.
    func readCString(at offset: Int) -> String {
        guard offset < count else { return "" }
        var end = offset
        while end < count && self[end] != 0 { end += 1 }
        return String(bytes: self[offset ..< end], encoding: .utf8) ?? ""
    }
}
