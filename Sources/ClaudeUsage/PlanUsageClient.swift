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
/// The OAuth token is read from the Keychain only when needed: on first use, once the cached
/// token's `expiresAt` has passed, or after the API rejects it. Every Keychain read can raise
/// a macOS permission dialog for an ad-hoc signed app, so reading on every 60 s poll would
/// nag the user constantly. Claude Code owns that credential and refreshes it; this app
/// deliberately never writes it back, so the two can't fight over the same Keychain item.
actor PlanUsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    private struct Credential {
        let token: String
        /// From the credentials JSON; nil if Claude Code didn't record one.
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            // Treat a token that expires within a minute as already expired.
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    private enum KeychainResult {
        case found(Credential)
        case missing
        case denied
    }

    /// The endpoint is itself rate limited, so back off hard on 429.
    private var nextAllowedFetch = Date.distantPast
    /// Earliest time we'll touch the Keychain again. Keeps a stale-but-not-refreshed token
    /// (Claude Code only refreshes when it next runs) from causing a read every poll.
    private var nextKeychainRead = Date.distantPast
    private var cached: Credential?
    private(set) var state: PlanUsageState = .ok

    func fetch() async -> (usage: PlanUsage?, state: PlanUsageState) {
        guard Date() >= nextAllowedFetch else {
            return (nil, state)
        }
        guard let token = currentToken() else {
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
                // Claude Code refreshes the token when it next runs; drop ours so the
                // next fetch re-reads the Keychain.
                cached = nil
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

    /// Returns the cached token, re-reading the Keychain only when it's absent or expired.
    private func currentToken() -> String? {
        if let cached, !cached.isExpired {
            return cached.token
        }
        guard Date() >= nextKeychainRead else {
            return cached?.token
        }

        switch Self.readKeychain() {
        case .found(let credential):
            cached = credential
            // Even a fresh read shouldn't repeat sooner than this: if Claude Code hasn't
            // refreshed an expired token yet, keep re-checking to every couple of minutes.
            nextKeychainRead = Date().addingTimeInterval(120)
            return credential.token
        case .missing:
            nextKeychainRead = Date().addingTimeInterval(120)
            return nil
        case .denied:
            // The user dismissed the permission dialog. Don't ask again for a while.
            nextKeychainRead = Date().addingTimeInterval(15 * 60)
            return nil
        }
    }

    /// Reads Claude Code's OAuth credential from the login Keychain.
    private static func readKeychain() -> KeychainResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            if let data = item as? Data, let credential = parseCredential(data) {
                return .found(credential)
            }
            return .missing
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            // The user clicked "Deny" (or the dialog couldn't be shown). Don't fall back
            // to the `security` tool here — that would just raise a second dialog.
            return .denied
        default:
            // Falls back to the system `security` tool, whose Keychain access is already
            // trusted on machines where this app's ad-hoc signature is not.
            if let credential = securityCLICredential() {
                return .found(credential)
            }
            return .missing
        }
    }

    private static func parseCredential(_ data: Data) -> Credential? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }
        // Claude Code stores `expiresAt` as milliseconds since the epoch.
        var expiresAt: Date?
        if let millis = oauth["expiresAt"] as? Double, millis > 0 {
            expiresAt = Date(timeIntervalSince1970: millis / 1000)
        }
        return Credential(token: token, expiresAt: expiresAt)
    }

    private static func securityCLICredential() -> Credential? {
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
            return parseCredential(data)
        } catch {
            return nil
        }
    }
}
