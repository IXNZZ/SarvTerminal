import Foundation

/// Feeds SSH passwords to `ssh` out-of-band via an `SSH_ASKPASS` helper, so ssh
/// never prompts for the password on the terminal (no "password:" line, no echo).
///
/// The helper is a tiny one-shot script: it prints a per-connection password
/// file's contents to stdout, then deletes the file. We set `SSH_ASKPASS` +
/// `SSH_ASKPASS_REQUIRE=force` (OpenSSH 8.4+, which macOS ships) on the ssh
/// surface's environment so ssh calls the helper instead of the TTY.
enum SSHAskpass {
    /// Path to the helper script, (re)created on first access.
    private static let helperPath: String? = {
        guard let dir = supportDirectory() else { return nil }
        let url = dir.appendingPathComponent("sarv-askpass.sh")
        // Print the password file's contents. ssh may call askpass more than once
        // (e.g. password + keyboard-interactive), so we do NOT delete the file
        // here — the app removes it on connect / close / relaunch.
        let script = """
        #!/bin/sh
        role="${SARV_ASKPASS_ROLE:-target}"
        if [ "$role" = "jump" ] && [ -n "$SARV_ASKPASS_JUMP_FILE" ]; then
            cat "$SARV_ASKPASS_JUMP_FILE"
        elif [ -n "$SARV_ASKPASS_TARGET_FILE" ]; then
            cat "$SARV_ASKPASS_TARGET_FILE"
        else
            cat "$SARV_ASKPASS_FILE"
        fi
        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }()

    private static func supportDirectory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(AppIdentity.bundleID, isDirectory: true)
    }

    /// Environment variables to set on an ssh surface so it reads `password`
    /// from the askpass helper. Returns an empty dict for an empty password (key
    /// / agent auth — ssh should not be forced through askpass then).
    static func env(forPassword password: String) -> [String: String] {
        guard !password.isEmpty, let helper = helperPath else { return [:] }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarv-ssh-\(UUID().uuidString)")
        do {
            // Newline-terminated; ssh strips the trailing newline.
            try (password + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            return [:]
        }
        return [
            "SSH_ASKPASS": helper,
            "SSH_ASKPASS_REQUIRE": "force",
            "SARV_ASKPASS_FILE": fileURL.path,
        ]
    }

    /// Environment and one cleanup directory for a target plus an optional
    /// saved jump Host. The nested ProxyCommand marks itself as `jump`, so the
    /// two ssh processes never consume each other's password.
    static func environment(targetPassword: String, jumpPassword: String?)
        -> (environment: [String: String], cleanupPath: String?) {
        guard let helper = helperPath,
              !targetPassword.isEmpty || !(jumpPassword ?? "").isEmpty else {
            return ([:], nil)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarv-ssh-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var environment: [String: String] = [
                "SSH_ASKPASS": helper,
                "SSH_ASKPASS_REQUIRE": "force",
                "SARV_ASKPASS_ROLE": "target",
            ]
            if !targetPassword.isEmpty {
                let targetURL = directory.appendingPathComponent("target")
                try (targetPassword + "\n").write(to: targetURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
                environment["SARV_ASKPASS_TARGET_FILE"] = targetURL.path
            }
            if let jumpPassword, !jumpPassword.isEmpty {
                let jumpURL = directory.appendingPathComponent("jump")
                try (jumpPassword + "\n").write(to: jumpURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jumpURL.path)
                environment["SARV_ASKPASS_JUMP_FILE"] = jumpURL.path
            }
            return (environment, directory.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return ([:], nil)
        }
    }
}
