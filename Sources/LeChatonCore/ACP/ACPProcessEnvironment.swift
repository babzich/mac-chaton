import Foundation

/// Builds the minimal inherited environment needed by a real ACP agent without
/// handing unrelated parent-process credentials or loader hooks to the agent.
public enum ACPProcessEnvironment {
    private static let inheritedKeys: Set<String> = [
        "HOME",
        "PATH",
        "TMPDIR",
        "USER",
        "LOGNAME",
        "SHELL",
        "LANG",
        "LANGUAGE",
        "TZ",
        "VIBE_HOME",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "REQUESTS_CA_BUNDLE",
        "CURL_CA_BUNDLE",
    ]

    /// Returns an allowlisted snapshot. In particular, this intentionally does
    /// not inherit `DYLD_*`, `LD_*`, `PYTHON*`, cloud/tool credentials, or
    /// `MISTRAL_API_KEY`; explicit app-managed credential injection is a
    /// separate policy decision.
    public static func sanitized(
        inheriting inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = inherited.filter { key, _ in
            inheritedKeys.contains(key) || key.hasPrefix("LC_") || key.hasPrefix("XDG_")
        }

        setFallback(&environment, key: "HOME", value: FileManager.default.homeDirectoryForCurrentUser.path)
        setFallback(&environment, key: "PATH", value: "/usr/bin:/bin:/usr/sbin:/sbin")
        setFallback(&environment, key: "TMPDIR", value: FileManager.default.temporaryDirectory.path)
        setFallback(&environment, key: "USER", value: NSUserName())
        setFallback(&environment, key: "LOGNAME", value: environment["USER"] ?? NSUserName())
        setFallback(&environment, key: "SHELL", value: "/bin/zsh")
        if environment["LANG"]?.isEmpty != false,
           !environment.contains(where: { $0.key.hasPrefix("LC_") && !$0.value.isEmpty }) {
            environment["LANG"] = "en_US.UTF-8"
        }
        return environment
    }

    private static func setFallback(
        _ environment: inout [String: String],
        key: String,
        value: String
    ) {
        guard environment[key]?.isEmpty != false else { return }
        environment[key] = value
    }
}
