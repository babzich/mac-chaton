import Testing
@testable import LeChatonCore

@Suite("ACP process environment")
struct ACPProcessEnvironmentTests {
    @Test("Provider secrets are injected only after sanitizing inherited credentials")
    func providerSecretInjection() {
        let environment = ACPProcessEnvironment.sanitized(
            inheriting: [
                "HOME": "/Users/tester",
                "PATH": "/usr/bin:/bin",
                "UNRELATED_API_KEY": "must-not-survive",
                "MISTRAL_API_KEY": "must-not-survive",
            ],
            injecting: .init(name: "LECHATON_PROVIDER_TEST_KEY", secret: "provider-secret")
        )

        #expect(environment["LECHATON_PROVIDER_TEST_KEY"] == "provider-secret")
        #expect(environment["UNRELATED_API_KEY"] == nil)
        #expect(environment["MISTRAL_API_KEY"] == nil)
        #expect(environment["HOME"] == "/Users/tester")
    }

    @Test("Required Vibe runtime and corporate-network values are inherited")
    func inheritsRequiredValues() {
        let source = [
            "HOME": "/Users/tester",
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "TMPDIR": "/private/tmp/tester",
            "USER": "tester",
            "LOGNAME": "tester",
            "SHELL": "/bin/zsh",
            "LC_CTYPE": "en_US.UTF-8",
            "XDG_CONFIG_HOME": "/Users/tester/.config",
            "VIBE_HOME": "/Users/tester/.vibe-other",
            "HTTPS_PROXY": "http://proxy.invalid:8080",
            "NO_PROXY": "localhost,127.0.0.1",
            "SSL_CERT_FILE": "/certificates/company.pem",
        ]

        let environment = ACPProcessEnvironment.sanitized(inheriting: source)
        for (key, value) in source {
            #expect(environment[key] == value)
        }
    }

    @Test("Loader hooks, language injection, and unrelated secrets are excluded")
    func stripsUnsafeAndUnrelatedValues() {
        let environment = ACPProcessEnvironment.sanitized(inheriting: [
            "HOME": "/Users/tester",
            "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
            "LD_PRELOAD": "/tmp/inject.so",
            "PYTHONPATH": "/tmp/python",
            "PYTHONINSPECT": "1",
            "AWS_SECRET_ACCESS_KEY": "secret",
            "GH_TOKEN": "secret",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/google.json",
            "MISTRAL_API_KEY": "secret",
        ])

        #expect(environment["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(environment["LD_PRELOAD"] == nil)
        #expect(environment["PYTHONPATH"] == nil)
        #expect(environment["PYTHONINSPECT"] == nil)
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(environment["GH_TOKEN"] == nil)
        #expect(environment["GOOGLE_APPLICATION_CREDENTIALS"] == nil)
        #expect(environment["MISTRAL_API_KEY"] == nil)
    }

    @Test("Required process basics receive nonempty fallbacks")
    func requiredFallbacks() {
        let environment = ACPProcessEnvironment.sanitized(inheriting: [:])
        for key in ["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG"] {
            #expect(environment[key]?.isEmpty == false)
        }
    }
}
