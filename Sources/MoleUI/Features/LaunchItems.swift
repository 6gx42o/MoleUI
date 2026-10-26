import Foundation
import Security

private let home = NSHomeDirectory()

/// A launchd job — the mechanism almost every piece of Mac adware, updater and
/// background helper uses to start itself. Shared by Malware Removal (which
/// judges them) and Extensions (which lists them all).
struct LaunchItem {
    enum Domain: String { case userAgent = "User agent", agent = "Agent (all users)",
                          daemon = "Daemon (system)" }

    var plist: String
    var label: String
    var program: String?
    var arguments: [String]
    var domain: Domain
    var runAtLoad: Bool
    var signature: Signature

    var needsAdmin: Bool { domain != .userAgent }

    static func scanAll() -> [LaunchItem] {
        let roots: [(String, Domain)] = [
            (home + "/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .agent),
            ("/Library/LaunchDaemons", .daemon),
        ]
        return roots.flatMap { root, domain in
            DiskUsage.children(of: root)
                .filter { $0.hasSuffix(".plist") }
                .compactMap { load($0, domain: domain) }
        }
    }

    /// An empty `<dict/>`. Google and Perplexity leave these on purpose as
    /// tombstones so a retired updater cannot re-register; they run nothing.
    var isPlaceholder: Bool { program == nil && arguments.isEmpty }

    private static func load(_ path: String, domain: Domain) -> LaunchItem? {
        guard let plist = NSDictionary(contentsOfFile: path) else { return nil }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        var program = (plist["Program"] as? String) ?? arguments.first
        // `open /Applications/Foo.app` launches Foo — judge Foo, not /usr/bin/open.
        if let launcher = program, (launcher as NSString).lastPathComponent == "open",
           let app = arguments.first(where: { $0.hasSuffix(".app") }) {
            program = app
        }
        // Bare names resolve the way launchd's default PATH would.
        if let name = program, !name.hasPrefix("/") {
            program = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map { $0 + "/" + name }
                .first(where: FileManager.default.fileExists) ?? name
        }
        return LaunchItem(plist: path,
                          label: plist["Label"] as? String ?? (path as NSString).lastPathComponent,
                          program: program, arguments: arguments, domain: domain,
                          runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                          signature: program.map(Signature.check) ?? .missing)
    }

    /// Unloads the job, then moves its plist to the Trash. Unload first: a
    /// trashed plist whose job is still loaded keeps running until logout,
    /// which is the opposite of what someone clicking "Remove" expects.
    static func remove(_ findings: [Finding]) async -> FindingOutcome {
        var outcome = FindingOutcome(message: "")
        let uid = getuid()
        var userPaths: [Finding] = []
        var adminCommands: [String] = []
        var adminFindings: [Finding] = []

        for finding in findings {
            guard let plist = finding.paths.first else { continue }
            if finding.info["domain"] == Domain.userAgent.rawValue {
                _ = try? await MoleCLI.shared.tool("/bin/launchctl",
                                                   ["bootout", "gui/\(uid)", plist])
                userPaths.append(finding)
            } else {
                adminCommands.append("/bin/launchctl bootout system \(Shell.quote(plist)) 2>/dev/null")
                adminFindings.append(finding)
            }
        }

        if !userPaths.isEmpty {
            let trashed = await FindingOutcome.trash(userPaths.map { finding in
                var copy = finding
                // The program goes too only for suspicious items — see the scan.
                if finding.info["removeProgram"] != "1" {
                    copy.paths = Array(finding.paths.prefix(1))
                }
                return copy
            })
            outcome.succeeded += trashed.succeeded
            outcome.failures += trashed.failures
        }

        if !adminFindings.isEmpty {
            let paths = adminFindings.compactMap(\.paths.first)
                + adminFindings.filter { $0.info["removeProgram"] == "1" }.compactMap { $0.paths.dropFirst().first }
            _ = await Admin.run(adminCommands.joined(separator: " ; ") + " ; true")
            let moved = await Admin.moveToTrash(paths)
            if moved.cancelled {
                outcome.cancelled = true
            } else if moved.ok {
                outcome.succeeded += adminFindings.map(\.id)
            } else {
                outcome.failures += adminFindings.map { ($0.title, moved.output) }
            }
        }

        outcome.message = outcome.cancelled && outcome.succeeded.isEmpty
            ? "Cancelled — nothing was removed."
            : "Removed \(outcome.succeeded.count) background item\(outcome.succeeded.count == 1 ? "" : "s") "
            + "to the Trash" + (outcome.failures.isEmpty ? "." : " · \(outcome.failures.count) failed.")
        return outcome
    }
}

/// What the code signature of a launch job's program says about who made it.
enum Signature: Equatable {
    case apple
    case developer(team: String, name: String?)
    case adHoc                       // signed, but by nobody in particular
    case unsigned
    case invalid                     // signed, and the signature no longer matches
    case missing                     // the program does not exist

    var label: String {
        switch self {
        case .apple:                    return "Apple"
        case let .developer(team, name): return name.map { "\($0) (\(team))" } ?? "Team \(team)"
        case .adHoc:                    return "Ad-hoc signed"
        case .unsigned:                 return "Unsigned"
        case .invalid:                  return "Signature broken"
        case .missing:                  return "Program missing"
        }
    }

    static func check(_ path: String) -> Signature {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        // Judge the enclosing app when the program lives inside one — helpers
        // are often signed as part of the bundle rather than on their own.
        var target = path
        if let range = path.range(of: ".app/") { target = String(path[..<range.lowerBound]) + ".app" }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: target) as CFURL, [], &code) == errSecSuccess,
              let code else { return .unsigned }

        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = info as? [String: Any] ?? [:]
        guard dict[kSecCodeInfoIdentifier as String] != nil else { return .unsigned }

        // Basic validity only (no revocation check over the network), so the
        // scan stays offline and fast.
        if SecStaticCodeCheckValidity(code, [], nil) != errSecSuccess { return .invalid }

        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String {
            let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate]
            let name = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
            return .developer(team: team, name: name.map(cleanCertificateName))
        }
        // Apple's own binaries carry no team identifier but are platform code.
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if let identifier = dict[kSecCodeInfoIdentifier as String] as? String,
           identifier.hasPrefix("com.apple.") && flags & 0x2 == 0 {
            return .apple
        }
        return .adHoc
    }

    /// "Developer ID Application: Google LLC (EQHXZ8M8AV)" → "Google LLC".
    private static func cleanCertificateName(_ name: String) -> String {
        var trimmed = name
        if let colon = trimmed.range(of: ": ") { trimmed = String(trimmed[colon.upperBound...]) }
        if let paren = trimmed.range(of: " (", options: .backwards) { trimmed = String(trimmed[..<paren.lowerBound]) }
        return trimmed
    }
}
