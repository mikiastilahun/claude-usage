import Foundation
import Security

/// State of the last attempt to read plan limits, so the UI can explain itself.
enum PlanUsageState: Sendable, Equatable {
    case ok
    case noCredentials
    case unauthorized
    case rateLimited
    case failed(String)
}

/// Fetches plan usage limits from the same endpoint Claude Code's `/usage` uses.
///
/// The OAuth token is read fresh from the Keychain on every call. Claude Code owns that
/// credential and refreshes it; this app deliberately never writes it back, so the two
/// can't fight over the same Keychain item.
actor PlanUsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    /// The endpoint is itself rate limited, so back off hard on 429.
    private var nextAllowedFetch = Date.distantPast
    private(set) var state: PlanUsageState = .ok

    func fetch() async -> (usage: PlanUsage?, state: PlanUsageState) {
        guard Date() >= nextAllowedFetch else {
            return (nil, state)
        }
        guard let token = Self.accessToken() else {
            state = .noCredentials
            return (nil, state)
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                let usage = try PlanUsage.decode(data)
                state = .ok
                nextAllowedFetch = Date()
                return (usage, state)
            case 401, 403:
                // Claude Code refreshes the token when it next runs.
                state = .unauthorized
                nextAllowedFetch = Date().addingTimeInterval(120)
            case 429:
                state = .rateLimited
                nextAllowedFetch = Date().addingTimeInterval(900)
            default:
                state = .failed("HTTP \(code)")
                nextAllowedFetch = Date().addingTimeInterval(300)
            }
        } catch {
            state = .failed(error.localizedDescription)
            nextAllowedFetch = Date().addingTimeInterval(120)
        }
        return (nil, state)
    }

    /// Reads Claude Code's OAuth access token from the login Keychain.
    private static func accessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let token = parseToken(data) {
            return token
        }
        // Falls back to the system `security` tool, whose Keychain access is already
        // trusted on machines where this app's ad-hoc signature is not.
        return securityCLIToken()
    }

    private static func parseToken(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }

    private static func securityCLIToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return parseToken(data)
        } catch {
            return nil
        }
    }
}
