import XCTest

/// Tests for URL and port validation logic used in PreferencesWindowController.
/// These mirror the validation in `save()` — if that logic changes, update tests here too.
final class URLValidationTests: XCTestCase {

    // Helper: mirrors PreferencesWindowController.save() URL check
    func isValidTargetURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { return false }
        return true
    }

    func testHTTPURLAccepted() {
        XCTAssertTrue(isValidTargetURL("http://localhost:8787"))
        XCTAssertTrue(isValidTargetURL("http://127.0.0.1:8787"))
        XCTAssertTrue(isValidTargetURL("http://my-server.example.com:9000"))
    }

    func testHTTPSURLAccepted() {
        XCTAssertTrue(isValidTargetURL("https://my-server.example.com:8787"))
        XCTAssertTrue(isValidTargetURL("https://localhost:8443"))
    }

    func testJavaScriptURLRejected() {
        XCTAssertFalse(isValidTargetURL("javascript:alert(1)"))
    }

    func testFileURLRejected() {
        XCTAssertFalse(isValidTargetURL("file:///etc/passwd"))
    }

    func testDataURLRejected() {
        XCTAssertFalse(isValidTargetURL("data:text/html,<h1>hi</h1>"))
    }

    func testEmptyStringRejected() {
        XCTAssertFalse(isValidTargetURL(""))
    }

    func testBareHostRejected() {
        // No scheme — URL(string:) may succeed but scheme will be nil
        XCTAssertFalse(isValidTargetURL("localhost:8787"))
    }

    func testFTPURLRejected() {
        XCTAssertFalse(isValidTargetURL("ftp://example.com"))
    }
}

/// Tests for port validation (1–65535 inclusive).
final class PortValidationTests: XCTestCase {

    // Helper: mirrors PreferencesWindowController.save() port check
    func isValidPort(_ raw: String) -> Bool {
        guard let port = Int(raw) else { return false }
        return (1...65535).contains(port)
    }

    func testValidPorts() {
        XCTAssertTrue(isValidPort("1"))
        XCTAssertTrue(isValidPort("80"))
        XCTAssertTrue(isValidPort("443"))
        XCTAssertTrue(isValidPort("8787"))
        XCTAssertTrue(isValidPort("65535"))
    }

    func testPortZeroRejected() {
        XCTAssertFalse(isValidPort("0"))
    }

    func testPortTooHighRejected() {
        XCTAssertFalse(isValidPort("65536"))
        XCTAssertFalse(isValidPort("99999"))
    }

    func testNonNumericRejected() {
        XCTAssertFalse(isValidPort("abc"))
        XCTAssertFalse(isValidPort(""))
        XCTAssertFalse(isValidPort("8787abc"))
    }

    func testNegativeRejected() {
        XCTAssertFalse(isValidPort("-1"))
    }
}

/// Tests for SSH argument array construction — verifies security invariants.
/// These mirror TunnelManager.start() argument array.
final class SSHArgumentTests: XCTestCase {

    // Mirrors the argument array built in TunnelManager.start()
    func buildSSHArgs(user: String, host: String, localPort: Int, remoteHost: String, remotePort: Int) -> [String] {
        return [
            "-N",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "\(localPort):\(remoteHost):\(remotePort)",
            "\(user)@\(host)",
        ]
    }

    func testStrictHostKeyCheckingPresent() {
        let args = buildSSHArgs(user: "hermes", host: "example.com", localPort: 8787, remoteHost: "localhost", remotePort: 8787)
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"), "StrictHostKeyChecking=accept-new must be in SSH args")
    }

    func testExitOnForwardFailurePresent() {
        let args = buildSSHArgs(user: "hermes", host: "example.com", localPort: 8787, remoteHost: "localhost", remotePort: 8787)
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"), "ExitOnForwardFailure=yes must be in SSH args")
    }

    func testNFlagPresent() {
        let args = buildSSHArgs(user: "hermes", host: "example.com", localPort: 8787, remoteHost: "localhost", remotePort: 8787)
        XCTAssertTrue(args.contains("-N"), "-N (no command) flag must be present")
    }

    func testPortForwardingArgFormat() {
        let args = buildSSHArgs(user: "hermes", host: "example.com", localPort: 9000, remoteHost: "localhost", remotePort: 8787)
        XCTAssertTrue(args.contains("9000:localhost:8787"), "Port forwarding arg must be localPort:remoteHost:remotePort")
    }

    func testUserAtHostFormat() {
        let args = buildSSHArgs(user: "alice", host: "server.example.com", localPort: 8787, remoteHost: "localhost", remotePort: 8787)
        XCTAssertTrue(args.contains("alice@server.example.com"), "SSH target must be user@host")
    }

    func testShellMetacharactersAreInertBecauseArgsArray() {
        // Process.arguments bypasses shell — metacharacters are literal.
        // This test documents and verifies the design: even adversarial input
        // produces a valid argument array (no injection because execve is used directly).
        let args = buildSSHArgs(
            user: "user; rm -rf /",
            host: "host$(whoami)",
            localPort: 8787,
            remoteHost: "localhost",
            remotePort: 8787
        )
        // The arguments array contains the literal strings — no shell expansion
        XCTAssertTrue(args.last == "user; rm -rf /@host$(whoami)",
                      "Metacharacters must be literal in the args array (no shell expansion)")
    }

    func testArgumentCount() {
        let args = buildSSHArgs(user: "hermes", host: "example.com", localPort: 8787, remoteHost: "localhost", remotePort: 8787)
        // Expected: ["-N", "-o", "StrictHostKeyChecking=accept-new", "-o", "ExitOnForwardFailure=yes", "-L", "8787:localhost:8787", "hermes@example.com"]
        XCTAssertEqual(args.count, 8, "SSH args array should have exactly 8 elements")
    }
}


/// Tests for the effective-URL rule (SSH tunnel bypass fix).
/// Mirrors `AppDelegate.effectiveTargetURL()` — in SSH mode the browser must
/// load the local tunnel entrance, never the configured Target URL. Loading
/// the remote URL directly is exactly the bug this guards against: the
/// ssh -L forward came up, was probed once, and then sat unused while the
/// WKWebView connected straight to the remote host.
final class EffectiveTargetURLTests: XCTestCase {

    // Mirrors AppDelegate.effectiveTargetURL()
    func effectiveURL(mode: String, targetURL: String, localPort: Int) -> String {
        return mode == "ssh" ? "http://127.0.0.1:\(localPort)" : targetURL
    }

    func testSSHModeAlwaysLoadsTunnelEntrance() {
        // Even with a remote Target URL configured, SSH mode must go through
        // the tunnel — the remote URL is irrelevant to what the web view loads.
        XCTAssertEqual(
            effectiveURL(mode: "ssh", targetURL: "http://hermes.example.ts.net:8787", localPort: 8787),
            "http://127.0.0.1:8787")
        XCTAssertEqual(
            effectiveURL(mode: "ssh", targetURL: "http://localhost:8787", localPort: 9000),
            "http://127.0.0.1:9000")
    }

    func testDirectModePassesTargetURLThrough() {
        XCTAssertEqual(
            effectiveURL(mode: "direct", targetURL: "http://hermes.example.ts.net:8787", localPort: 8787),
            "http://hermes.example.ts.net:8787")
        XCTAssertEqual(
            effectiveURL(mode: "direct", targetURL: "http://localhost:8787", localPort: 9000),
            "http://localhost:8787")
    }
}

/// Tests for the reachability probe's host/port derivation.
/// Mirrors `ReachabilityProbe.probe(urlString:)` — the ATS-free TCP probe
/// that replaced URLSession in preflight / Test Connection / health ping so
/// direct mode works with non-localhost plain-http URLs.
final class ProbeEndpointDerivationTests: XCTestCase {

    // Mirrors the URL → (host, port) derivation in ReachabilityProbe
    func derivedEndpoint(_ raw: String) -> (host: String, port: Int)? {
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty
        else { return nil }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return (host, port)
    }

    func testExplicitPortPreserved() {
        let ep = derivedEndpoint("http://hermes.example.ts.net:8787/")
        XCTAssertEqual(ep?.host, "hermes.example.ts.net")
        XCTAssertEqual(ep?.port, 8787)
    }

    func testHTTPDefaultsTo80() {
        XCTAssertEqual(derivedEndpoint("http://example.com/")?.port, 80)
    }

    func testHTTPSDefaultsTo443() {
        XCTAssertEqual(derivedEndpoint("https://example.com/")?.port, 443)
    }

    func testHostlessURLRejected() {
        XCTAssertNil(derivedEndpoint(""))
        XCTAssertNil(derivedEndpoint("http://"))
    }

    // Mirrors the request-path derivation in ReachabilityProbe.probeHealth:
    // the percent-ENCODED path must be used, since URL.path decodes and
    // would let encoded CR/LF reshape the hand-rolled HTTP request.
    func testEncodedCRLFStaysEncodedInProbePath() {
        let url = URL(string: "http://host:8787/%0D%0AX-Evil:1")!
        let base = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath
        XCTAssertFalse(base.contains("\r"))
        XCTAssertFalse(base.contains("\n"))
        XCTAssertTrue(base.contains("%0D%0A"))
    }
}

/// Tests for the /health response classifier.
/// Mirrors `ReachabilityProbe.classifyHealthResponse(_:)` — the tri-state
/// that distinguishes a verified hermes server (2xx + `"status": "ok"` body)
/// from "something answered but it's not a healthy hermes" (reverse proxy in
/// front of a dead backend, other service on the port, non-2xx).
final class HealthResponseClassificationTests: XCTestCase {

    enum Result { case healthy, reachable }

    // Mirrors ReachabilityProbe.classifyHealthResponse
    func classify(_ raw: String) -> Result {
        let text = raw
        guard let statusLineEnd = text.range(of: "\r\n") else { return .reachable }
        let statusParts = text[..<statusLineEnd.lowerBound].split(separator: " ")
        guard statusParts.count >= 2,
            statusParts[0].hasPrefix("HTTP/"),
            let code = Int(statusParts[1]),
            (200...299).contains(code),
            let headerEnd = text.range(of: "\r\n\r\n")
        else { return .reachable }
        let body = text[headerEnd.upperBound...]
        return body.contains("\"status\"") && body.contains("\"ok\"")
            ? .healthy : .reachable
    }

    func testRealHermesHealthResponseIsHealthy() {
        // Body shape captured from a live hermes server's /health.
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
            + #"{"status": "ok", "sessions": 5, "active_streams": 0, "uptime_seconds": 25012.3}"#
        XCTAssertEqual(classify(response), .healthy)
    }

    func testChunkedHermesResponseStillHealthy() {
        // Chunk-size markers interleave with the body; the substring check
        // must survive them.
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "10\r\n{\"status\": \"ok\"\r\n1\r\n}\r\n0\r\n\r\n"
        XCTAssertEqual(classify(response), .healthy)
    }

    func testNon2xxIsOnlyReachable() {
        // Reverse proxy up, hermes down — the classic 502.
        let response = "HTTP/1.1 502 Bad Gateway\r\n\r\n<html>nginx</html>"
        XCTAssertEqual(classify(response), .reachable)
    }

    func test2xxWithoutHermesBodyIsOnlyReachable() {
        // Some other service answering 200 on the port is not a hermes.
        let response = "HTTP/1.1 200 OK\r\n\r\n<html>hello</html>"
        XCTAssertEqual(classify(response), .reachable)
    }

    func testGarbageIsOnlyReachable() {
        XCTAssertEqual(classify("SSH-2.0-OpenSSH_9.6\r\n"), .reachable)
        XCTAssertEqual(classify("not http at all"), .reachable)
    }
}

/// Tests for the ssh user/host field validation.
/// Mirrors `TunnelManager.isValidSSHIdentifier(_:)` — ssh parses any argument
/// beginning with "-" as an option, so an unvalidated username like
/// "-oProxyCommand=…" smuggles options (and ProxyCommand runs shell commands)
/// into the args array even though Process bypasses the shell.
final class SSHIdentifierValidationTests: XCTestCase {

    // Mirrors TunnelManager.isValidSSHIdentifier
    func isValid(_ value: String) -> Bool {
        return !value.isEmpty
            && !value.hasPrefix("-")
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    func testNormalValuesAccepted() {
        XCTAssertTrue(isValid("hermes"))
        XCTAssertTrue(isValid("server.example.com"))
        XCTAssertTrue(isValid("192.168.1.20"))
        XCTAssertTrue(isValid("box.tail1234.ts.net"))
    }

    func testOptionSmugglingRejected() {
        XCTAssertFalse(isValid("-oProxyCommand=touch /tmp/pwned"))
        XCTAssertFalse(isValid("-v"))
    }

    func testWhitespaceRejected() {
        XCTAssertFalse(isValid("user name"))
        XCTAssertFalse(isValid("host\nname"))
        XCTAssertFalse(isValid(" hermes"))
    }

    func testEmptyRejected() {
        XCTAssertFalse(isValid(""))
    }
}

/// Tests for the SSH auth-test classification.
/// Mirrors `TunnelManager.classifyAuthAttempt(exitStatus:stderr:)` — the rule
/// behind Test Connection's SSH verdicts. Exit 0 means a full login round
/// trip (what the tunnel needs). "Permission denied" on stderr means the
/// transport worked and only the key was refused — actionable (ssh-copy-id)
/// and distinct from "nothing usable at host:22".
final class SSHAuthClassificationTests: XCTestCase {

    enum Result { case authenticated, authFailed, unreachable }

    // Mirrors TunnelManager.classifyAuthAttempt
    func classify(exitStatus: Int32, stderr: String) -> Result {
        if exitStatus == 0 { return .authenticated }
        if stderr.contains("Permission denied") { return .authFailed }
        return .unreachable
    }

    func testCleanExitIsAuthenticated() {
        XCTAssertEqual(classify(exitStatus: 0, stderr: ""), .authenticated)
        // Warnings on stderr (e.g. accept-new adding a host key) don't matter
        // if the login itself succeeded.
        XCTAssertEqual(
            classify(exitStatus: 0, stderr: "Warning: Permanently added 'host' to known hosts."),
            .authenticated)
    }

    func testPermissionDeniedIsAuthFailure() {
        XCTAssertEqual(
            classify(exitStatus: 255, stderr: "user@host: Permission denied (publickey)."),
            .authFailed)
    }

    func testTransportFailuresAreUnreachable() {
        XCTAssertEqual(
            classify(exitStatus: 255, stderr: "ssh: connect to host x port 22: Connection refused"),
            .unreachable)
        XCTAssertEqual(
            classify(exitStatus: 255, stderr: "ssh: connect to host x port 22: Operation timed out"),
            .unreachable)
        XCTAssertEqual(
            classify(exitStatus: 255, stderr: "ssh: Could not resolve hostname x"),
            .unreachable)
        // Watchdog kill (terminated, no informative stderr)
        XCTAssertEqual(classify(exitStatus: 15, stderr: ""), .unreachable)
    }

    // Mirrors the died-early classification in TunnelManager.testForward:
    // "Address already in use" on stderr means the local bind lost the race
    // (ExitOnForwardFailure kills ssh); anything else is a generic forward
    // failure.
    func testForwardDeathClassification() {
        func classify(_ stderr: String) -> String {
            return stderr.contains("Address already in use") ? "localPortBusy" : "forwardFailed"
        }
        XCTAssertEqual(
            classify("bind [127.0.0.1]:8787: Address already in use"), "localPortBusy")
        XCTAssertEqual(classify("Could not request local forwarding."), "forwardFailed")
        XCTAssertEqual(classify(""), "forwardFailed")
    }

    // Mirrors the argument array built in TunnelManager.testAuth — BatchMode
    // is the security-relevant invariant: without it, ssh can stall forever
    // on an interactive password prompt the user can't see.
    func testAuthProbeArgsAreNonInteractive() {
        let args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=6",
            "-o", "StrictHostKeyChecking=accept-new",
            "hermes@example.com",
            "exit",
        ]
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertEqual(args.last, "exit", "must run a no-op command and disconnect")
    }
}

/// Tests for the "probe through the live tunnel" match rule.
/// Mirrors the guard in PreferencesWindowController.testConnection: the
/// already-running tunnel may only vouch for the fields when EVERY setting
/// that shapes the forward matches. Regression: remotePort was originally
/// missing from the match, so editing it to a dead port (8788) still probed
/// the live tunnel's old forward (8787) and reported "✓ Hermes OK" for a
/// configuration that was never tested.
final class LiveTunnelMatchTests: XCTestCase {

    struct Settings: Equatable {
        var mode = "ssh"
        var host = "hermes.example.ts.net"
        var user = "hermes"
        var localPort = "8787"
        var remotePort = "8787"
    }

    // Mirrors the testConnection guard
    func liveTunnelVouches(saved: Settings, fields: Settings, tunnelUp: Bool) -> Bool {
        return tunnelUp && saved.mode == "ssh" && saved == fields
    }

    func testExactMatchVouches() {
        XCTAssertTrue(liveTunnelVouches(saved: Settings(), fields: Settings(), tunnelUp: true))
    }

    func testNoTunnelNeverVouches() {
        XCTAssertFalse(liveTunnelVouches(saved: Settings(), fields: Settings(), tunnelUp: false))
    }

    func testRemotePortMismatchDoesNotVouch() {
        // The reported bug: remote port edited to 8788 (nothing listening
        // there) must NOT be verified via the live tunnel's remote 8787.
        var fields = Settings()
        fields.remotePort = "8788"
        XCTAssertFalse(liveTunnelVouches(saved: Settings(), fields: fields, tunnelUp: true))
    }

    func testAnySingleFieldMismatchDoesNotVouch() {
        var host = Settings(); host.host = "other.example.com"
        var user = Settings(); user.user = "someone"
        var local = Settings(); local.localPort = "9000"
        for fields in [host, user, local] {
            XCTAssertFalse(liveTunnelVouches(saved: Settings(), fields: fields, tunnelUp: true))
        }
    }
}

/// Tests for the plaintext-HTTP acknowledgment rule.
/// Mirrors the guard in `PreferencesWindowController.save()` — plain http to
/// a non-loopback host requires a one-time per-host acknowledgment that
/// credentials and session data will cross the network unencrypted.
final class PlaintextWarningRuleTests: XCTestCase {

    // Mirrors PreferencesWindowController.isLoopbackHost + the save() guard
    func needsWarning(scheme: String, host: String, acknowledged: [String]) -> Bool {
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        return scheme == "http" && !loopback && !acknowledged.contains(host)
    }

    func testRemotePlainHTTPWarns() {
        XCTAssertTrue(needsWarning(scheme: "http", host: "hermes.example.ts.net", acknowledged: []))
        XCTAssertTrue(needsWarning(scheme: "http", host: "192.168.1.20", acknowledged: []))
    }

    func testLoopbackNeverWarns() {
        // Nothing leaves the machine — also keeps the SSH tunnel entrance
        // (127.0.0.1) and the default localhost setup prompt-free.
        XCTAssertFalse(needsWarning(scheme: "http", host: "localhost", acknowledged: []))
        XCTAssertFalse(needsWarning(scheme: "http", host: "127.0.0.1", acknowledged: []))
        XCTAssertFalse(needsWarning(scheme: "http", host: "::1", acknowledged: []))
    }

    func testHTTPSNeverWarns() {
        XCTAssertFalse(needsWarning(scheme: "https", host: "hermes.example.ts.net", acknowledged: []))
    }

    func testAcknowledgedHostDoesNotWarnAgain() {
        XCTAssertFalse(needsWarning(
            scheme: "http", host: "hermes.example.ts.net",
            acknowledged: ["hermes.example.ts.net"]))
    }
}

/// Tests for the dark-biased appearance threshold (issue #70).
/// Mirrors `AppDelegate.appearanceForLuminance(_:)` — the rule that decides
/// whether a sampled page background is "light enough" to flip the chrome
/// to .aqua. Default-dark unless the sample is genuinely near-white.
final class AppearanceThresholdTests: XCTestCase {

    // Mirrors AppDelegate.appearanceForLuminance — returns true if the
    // luminance is high enough to flip to .aqua, false otherwise (.darkAqua).
    func isLight(_ luminance: Double) -> Bool {
        return luminance > 0.85
    }

    func testCanonicalDarkThemesStayDark() {
        // hermes-webui dark-theme `--bg` luminances:
        //   #1A1A1A (Default dark)  ≈ 0.10
        //   #1F1E1C (Sienna dark)   ≈ 0.12
        //   #0D1117 (Sisyphus dark) ≈ 0.05
        XCTAssertFalse(isLight(0.10))
        XCTAssertFalse(isLight(0.12))
        XCTAssertFalse(isLight(0.05))
    }

    func testCanonicalLightThemesGoLight() {
        // hermes-webui light-theme `--bg` luminances:
        //   #FEFCF7 (Default light) ≈ 0.99
        //   #FAF9F5 (Sienna light)  ≈ 0.98
        XCTAssertTrue(isLight(0.99))
        XCTAssertTrue(isLight(0.98))
    }

    func testMurkyMiddleStaysDark() {
        // Anything in the 0.5…0.85 range is almost certainly an overlay
        // (modal dim layer, partial mount paint, half-translucent panel).
        // Default-dark unless we have strong evidence of a near-white page.
        // This is the core regression guard for issue #70.
        XCTAssertFalse(isLight(0.50))
        XCTAssertFalse(isLight(0.65))
        XCTAssertFalse(isLight(0.80))
        XCTAssertFalse(isLight(0.85))  // Boundary: 0.85 itself stays dark
    }

    func testJustAboveThresholdGoesLight() {
        // > 0.85 — strongly light. Threshold is strict (>), not >=.
        XCTAssertTrue(isLight(0.851))
        XCTAssertTrue(isLight(0.90))
    }

    func testEdgeCases() {
        XCTAssertFalse(isLight(0.0))
        XCTAssertTrue(isLight(1.0))
    }
}

/// Tests for the /api/* navigation guard (issue #76).
/// Mirrors the path-prefix check in BrowserWindowController.webView(_:decidePolicyFor:).
/// Ordinary API endpoints should never become full-page navigations, while
/// Hermes artifact endpoints must remain reachable so WKWebView can turn an
/// attachment response into a native download.
final class APINavigationGuardTests: XCTestCase {
    // Mirrors BrowserWindowController.webView(_:decidePolicyFor:) check
    func shouldCancelAsAPINav(_ urlString: String, shouldPerformDownload: Bool = false) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        if shouldPerformDownload && url.scheme?.lowercased() != "file" { return false }
        let downloadAPIPaths = ["/api/media", "/api/file/raw", "/api/folder/download"]
        return url.path.hasPrefix("/api/") && !downloadAPIPaths.contains(url.path)
    }

    // Mirrors the download fast-path's file:// exclusion: a download-attributed
    // file:// link gets no WKDownload — it falls through to the scheme guard
    // that cancels all file:// navigation.
    func downloadFastPathApplies(_ urlString: String, shouldPerformDownload: Bool) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return shouldPerformDownload && url.scheme?.lowercased() != "file"
    }

    func testDownloadFastPathExcludesFileScheme() {
        XCTAssertTrue(downloadFastPathApplies(
            "http://localhost:8787/api/media", shouldPerformDownload: true))
        XCTAssertTrue(downloadFastPathApplies(
            "blob:http://localhost:8787/some-uuid", shouldPerformDownload: true))
        XCTAssertFalse(downloadFastPathApplies(
            "file:///etc/passwd", shouldPerformDownload: true))
        XCTAssertFalse(downloadFastPathApplies(
            "http://localhost:8787/api/media", shouldPerformDownload: false))
    }

    func testApiPathsAreCancelled() {
        XCTAssertTrue(shouldCancelAsAPINav("http://localhost:8787/api/sessions"))
        XCTAssertTrue(shouldCancelAsAPINav("http://localhost:8787/api/updates/apply"))
        XCTAssertTrue(shouldCancelAsAPINav("http://localhost:8787/api/chat/stream"))
        XCTAssertTrue(shouldCancelAsAPINav("https://my-server.example.com/api/anything"))
    }

    func testArtifactDownloadsAreNotCancelled() {
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/api/media"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/api/file/raw"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/api/folder/download"))
        XCTAssertFalse(shouldCancelAsAPINav(
            "http://localhost:8787/api/anything",
            shouldPerformDownload: true
        ))
    }

    func testNonApiPathsAreAllowed() {
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/login"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/static/style.css"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/manifest.json"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/sw.js"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/health"))
    }

    func testApiPrefixIsExact() {
        // /api-docs and similar should NOT match — the prefix must be /api/
        // (with the trailing slash) so we don't false-positive on routes
        // that happen to start with the letters "api".
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/api-docs"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/apidocs"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/apipreview"))
    }

    func testApiAtRootEdge() {
        // /api alone (no trailing slash) is ambiguous — we choose to allow it
        // because the WebUI doesn't have a bare /api endpoint and a future
        // /api landing page (docs?) shouldn't be silently blocked.
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/api"))
    }
}

final class NotificationBridgeTests: XCTestCase {
    // Mirrors BrowserWindowController's pure notification policy helpers.
    func shouldSendNativeNotification(nativePreferenceEnabled: Bool, force: Bool) -> Bool {
        force || nativePreferenceEnabled
    }

    func notificationIdentifier(
        title: String, sessionID: String?, fallbackID: String = "fallback"
    ) -> String {
        let normalizedTitle = title.lowercased()
        let kind: String
        if normalizedTitle.contains("approval") {
            kind = "approval"
        } else if normalizedTitle.contains("clarification") {
            kind = "clarification"
        } else if normalizedTitle.contains("response") {
            kind = "response"
        } else {
            kind = "message"
        }
        let scope = sessionID.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackID
        return "hermes.\(kind).\(scope)"
    }

    func shouldSendFromWebUI(
        webPreferenceEnabled: Bool, force: Bool, forceHidden: Bool,
        documentHidden: Bool, nativeBackgrounded: Bool
    ) -> Bool {
        if !force && !webPreferenceEnabled { return false }
        if !force && !forceHidden && !documentHidden && !nativeBackgrounded { return false }
        return true
    }

    func testNativePreferenceBlocksOrdinaryNotifications() {
        XCTAssertFalse(shouldSendNativeNotification(
            nativePreferenceEnabled: false, force: false))
        XCTAssertTrue(shouldSendNativeNotification(
            nativePreferenceEnabled: true, force: false))
    }

    func testForcedTestNotificationBypassesNativePreference() {
        XCTAssertTrue(shouldSendNativeNotification(
            nativePreferenceEnabled: false, force: true))
    }

    func testWebNotificationPreservesPreferenceAndBackgroundContract() {
        XCTAssertFalse(shouldSendFromWebUI(
            webPreferenceEnabled: false, force: false, forceHidden: false,
            documentHidden: true, nativeBackgrounded: true))
        XCTAssertFalse(shouldSendFromWebUI(
            webPreferenceEnabled: true, force: false, forceHidden: false,
            documentHidden: false, nativeBackgrounded: false))
        XCTAssertTrue(shouldSendFromWebUI(
            webPreferenceEnabled: true, force: false, forceHidden: false,
            documentHidden: false, nativeBackgrounded: true))
        XCTAssertTrue(shouldSendFromWebUI(
            webPreferenceEnabled: true, force: false, forceHidden: true,
            documentHidden: false, nativeBackgrounded: false))
        XCTAssertTrue(shouldSendFromWebUI(
            webPreferenceEnabled: false, force: true, forceHidden: false,
            documentHidden: false, nativeBackgrounded: false))
    }

    func testNotificationIdentifiersSeparateSessionsAndEventKinds() {
        let responseA = notificationIdentifier(
            title: "Response complete", sessionID: "session-a")
        let responseB = notificationIdentifier(
            title: "Response complete", sessionID: "session-b")
        let approvalA = notificationIdentifier(
            title: "Approval required", sessionID: "session-a")

        XCTAssertNotEqual(responseA, responseB)
        XCTAssertNotEqual(responseA, approvalA)
        XCTAssertEqual(responseA, "hermes.response.session-a")
    }

    func testNotificationIdentifierHasDeterministicFallbackForTesting() {
        XCTAssertEqual(
            notificationIdentifier(
                title: "Hermes test", sessionID: nil, fallbackID: "fallback"),
            "hermes.message.fallback"
        )
    }
}
