import Foundation

/// A host parsed from an import source but NOT yet saved — shown in the preview
/// screen so the user can review/deselect before committing. `groupPath` is a
/// `/`-separated path resolved into the group tree only on commit.
struct ParsedHost: Identifiable {
    enum Kind: String {
        case ssh
        case serial
        case unsupported

        var displayName: String {
            switch self {
            case .ssh: return "SSH"
            case .serial: return "Serial"
            case .unsupported: return "Unsupported"
            }
        }
    }

    let id = UUID()
    var label: String
    var hostname: String
    var port: Int = 22
    var username: String = ""
    var auth: SavedHost.AuthMethod = .agent
    var identityFile: String = ""
    var password: String = ""
    var proxyJump: String = ""
    var groupPath: String = ""
    var tags: [String] = []
    var note: String = ""
    /// The source profile type. Existing importers produce SSH entries.
    var kind: Kind = .ssh
    /// The source profile ID, used to resolve Tabby's jump-host references.
    var sourceID: String = ""
    var jumpHostSourceID: String = ""
    /// Tabby can mark a profile hidden in its own UI. Keep it visible in the
    /// preview, but leave it deselected by default.
    var isBlacklisted = false

    var canImport: Bool { kind == .ssh && !hostname.isEmpty }

    var defaultSelected: Bool { canImport && !isBlacklisted }

    var subtitle: String {
        guard kind == .ssh else {
            let detail = hostname.isEmpty ? "No connection details" : hostname
            return "\(kind.displayName)  ·  \(detail)"
        }
        var s = username.isEmpty ? hostname : "\(username)@\(hostname)"
        if port != 22 { s += ":\(port)" }
        if !groupPath.isEmpty { s += "  ·  \(groupPath)" }
        if isBlacklisted { s += "  ·  Hidden in Tabby" }
        return s
    }

    func toSavedHost() -> SavedHost {
        var h = SavedHost.blank(hostname: hostname)
        h.label = label.isEmpty ? hostname : label
        h.username = username
        h.port = port
        h.authMethod = auth
        h.identityFile = identityFile
        h.password = password
        h.proxyJump = jumpHostSourceID.isEmpty ? proxyJump : ""
        h.tags = tags
        h.note = note
        return h
    }
}

/// Outcome of committing a set of parsed hosts.
struct HostImportResult {
    var imported = 0
    var skipped = 0     // already-saved duplicates
    var unsupported = 0 // selected entries that Sarv cannot import yet
    var unresolvedJumpHosts = 0
    var note: String?

    var summary: String {
        if let note { return note }
        var parts = ["Imported \(imported) host\(imported == 1 ? "" : "s")"]
        if skipped > 0 { parts.append("\(skipped) already saved") }
        if unsupported > 0 {
            parts.append("\(unsupported) unsupported entr\(unsupported == 1 ? "y" : "ies") not imported")
        }
        if unresolvedJumpHosts > 0 {
            parts.append("\(unresolvedJumpHosts) jump host\(unresolvedJumpHosts == 1 ? "" : "s") need review")
        }
        return parts.joined(separator: " · ")
    }
}

/// Parses external sources into `ParsedHost`s and commits the chosen ones into
/// `SavedHostsStore`, deduping by `hostname`+`username` and resolving group paths.
enum HostImporter {
    /// The single CSV layout we support — also what "Save template" writes.
    static let csvHeader = "label,hostname,port,username,auth,identity_file,password,group,tags,note"
    static let csvTemplate = """
    \(csvHeader)
    My Server,192.168.1.10,22,deploy,password,,s3cret,Workspace/Dev,prod;web,Primary app server
    Bastion,bastion.example.com,2222,ubuntu,publicKey,~/.ssh/id_ed25519,,Workspace,jump,Jump host
    Local VM,127.0.0.1,2200,vagrant,agent,,,,,
    """

    // MARK: - Parse (no side effects)

    static func parseSSHConfig() -> [ParsedHost] {
        SSHConfigDiscovery.loadAll().map { h in
            let identity = h.identityFile ?? ""
            return ParsedHost(
                label: h.label,
                hostname: h.hostname ?? h.label,
                port: h.port ?? 22,
                username: h.user ?? "",
                auth: identity.isEmpty ? .agent : .publicKey,
                identityFile: identity,
                proxyJump: h.proxyJump ?? "")
        }
    }

    // MARK: - iTerm2 (profiles with a custom `ssh …` command)

    static func parseiTerm2() -> (hosts: [ParsedHost], error: String?) {
        var profiles: [[String: Any]] = []

        // Main preferences (live values, robust to defaults caching).
        if let bookmarks = CFPreferencesCopyAppValue(
            "New Bookmarks" as CFString, "com.googlecode.iterm2" as CFString) as? [[String: Any]] {
            profiles += bookmarks
        }
        // Dynamic profiles (JSON or plist) under Application Support.
        let dynDir = "\(NSHomeDirectory())/Library/Application Support/iTerm2/DynamicProfiles"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dynDir) {
            for file in files {
                let path = "\(dynDir)/\(file)"
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let arr = obj["Profiles"] as? [[String: Any]] {
                    profiles += arr
                } else if let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
                          let arr = dict["Profiles"] as? [[String: Any]] {
                    profiles += arr
                }
            }
        }

        var hosts: [ParsedHost] = []
        for profile in profiles {
            let name = (profile["Name"] as? String) ?? ""
            let custom = (profile["Custom Command"] as? String) ?? "No"
            let command = (profile["Command"] as? String) ?? ""
            guard custom == "Yes", command.range(of: #"\bssh\b"#, options: .regularExpression) != nil,
                  let host = parseSSHCommand(command, label: name) else { continue }
            hosts.append(host)
        }
        return hosts.isEmpty
            ? ([], "No SSH profiles found in iTerm2 (profiles with a custom `ssh …` command).")
            : (hosts, nil)
    }

    /// Parse a raw `ssh …` command line into a host (used by iTerm2 import and
    /// any source that stores connections as commands).
    static func parseSSHCommand(_ command: String, label: String) -> ParsedHost? {
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let sshIdx = tokens.firstIndex(where: { $0 == "ssh" || $0.hasSuffix("/ssh") }) else { return nil }

        var port = 22, user = "", host = "", identity = "", proxyJump = ""
        var i = sshIdx + 1
        while i < tokens.count {
            let t = tokens[i]
            switch t {
            case "-p": i += 1; if i < tokens.count { port = Int(tokens[i]) ?? 22 }
            case "-i": i += 1; if i < tokens.count { identity = tokens[i] }
            case "-J": i += 1; if i < tokens.count { proxyJump = tokens[i] }
            case "-l": i += 1; if i < tokens.count { user = tokens[i] }
            case "-o":
                i += 1
                if i < tokens.count {
                    let kv = tokens[i].split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 {
                        switch kv[0].lowercased() {
                        case "user":         if user.isEmpty { user = kv[1] }
                        case "port":         port = Int(kv[1]) ?? port
                        case "identityfile": if identity.isEmpty { identity = kv[1] }
                        case "proxyjump":    if proxyJump.isEmpty { proxyJump = kv[1] }
                        default: break
                        }
                    }
                }
            default:
                if t.hasPrefix("-") { break }  // unknown flag (no arg we track)
                if host.isEmpty {
                    if let at = t.firstIndex(of: "@") {
                        user = String(t[..<at]); host = String(t[t.index(after: at)...])
                    } else {
                        host = t
                    }
                }
            }
            i += 1
        }
        guard !host.isEmpty else { return nil }
        return ParsedHost(
            label: label.isEmpty ? host : label,
            hostname: host, port: port, username: user,
            auth: identity.isEmpty ? .agent : .publicKey,
            identityFile: identity, proxyJump: proxyJump)
    }

    /// Returns the parsed hosts, or an error note describing why parsing failed.
    static func parseCSV(_ content: String) -> (hosts: [ParsedHost], error: String?) {
        let rows = content.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = rows.first else { return ([], "The CSV file is empty.") }
        let headers = parseRow(headerLine).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ name: String) -> Int? { headers.firstIndex(of: name) }
        guard let hostnameCol = col("hostname") else {
            return ([], "CSV needs a 'hostname' column. Use the template.")
        }
        let labelCol = col("label"), portCol = col("port"), userCol = col("username")
        let authCol = col("auth"), identityCol = col("identity_file"), passwordCol = col("password")
        let groupCol = col("group"), tagsCol = col("tags"), noteCol = col("note")

        var parsed: [ParsedHost] = []
        for line in rows.dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let f = parseRow(line)
            func get(_ i: Int?) -> String {
                guard let i, i >= 0, i < f.count else { return "" }
                return f[i].trimmingCharacters(in: .whitespaces)
            }
            let hostname = get(hostnameCol)
            if hostname.isEmpty { continue }
            let label = get(labelCol)
            parsed.append(ParsedHost(
                label: label.isEmpty ? hostname : label,
                hostname: hostname,
                port: Int(get(portCol)) ?? 22,
                username: get(userCol),
                auth: parseAuth(get(authCol)),
                identityFile: get(identityCol),
                password: get(passwordCol),
                groupPath: get(groupCol),
                tags: get(tagsCol).split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                note: get(noteCol)
            ))
        }
        if parsed.isEmpty { return ([], "No host rows found below the header.") }
        return (parsed, nil)
    }

    // MARK: - Tabby (version 8 YAML)

    /// Parses the stable, profile-oriented subset of Tabby's version 8 YAML.
    ///
    /// Tabby stores connection profiles as a small YAML document, but Sarv does
    /// not otherwise need a general-purpose YAML runtime. This parser therefore
    /// deliberately reads only profile/group scalar fields and ignores the
    /// large algorithm/color/scripting sections. It still keeps every profile
    /// in the preview, including serial and unknown types, so the user decides
    /// what to import.
    static func parseTabby(_ content: String) -> (hosts: [ParsedHost], error: String?) {
        enum Section { case none, profiles, groups, blacklist }

        var section: Section = .none
        var profileFields: [String: String] = [:]
        var rawProfiles: [[String: String]] = []
        var groupFields: [String: String] = [:]
        var rawGroups: [[String: String]] = []
        var blacklist = Set<String>()

        func flushProfile() {
            if !profileFields.isEmpty { rawProfiles.append(profileFields) }
            profileFields = [:]
        }

        func flushGroup() {
            if !groupFields.isEmpty { rawGroups.append(groupFields) }
            groupFields = [:]
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count

            if indent == 0 {
                flushProfile()
                flushGroup()
                switch trimmed {
                case "profiles:": section = .profiles
                case "groups:": section = .groups
                case "profileBlacklist:": section = .blacklist
                default: section = .none
                }
                continue
            }

            switch section {
            case .profiles:
                if indent == 2, trimmed.hasPrefix("-") {
                    flushProfile()
                    if let field = parseTabbyField(String(trimmed.dropFirst())) {
                        profileFields["profile.\(field.key)"] = field.value
                    }
                } else if indent == 4, let field = parseTabbyField(trimmed) {
                    profileFields["profile.\(field.key)"] = field.value
                } else if indent == 6, let field = parseTabbyField(trimmed) {
                    profileFields["option.\(field.key)"] = field.value
                }
            case .groups:
                if indent == 2, trimmed.hasPrefix("-") {
                    flushGroup()
                    if let field = parseTabbyField(String(trimmed.dropFirst())) {
                        groupFields[field.key] = field.value
                    }
                } else if indent == 4, let field = parseTabbyField(trimmed) {
                    groupFields[field.key] = field.value
                }
            case .blacklist:
                if indent == 2, trimmed.hasPrefix("-") {
                    let id = parseTabbyScalar(String(trimmed.dropFirst()))
                    if !id.isEmpty { blacklist.insert(id) }
                }
            case .none:
                break
            }
        }
        flushProfile()
        flushGroup()

        guard !rawProfiles.isEmpty else {
            return ([], "No Tabby profiles found. Make sure this is a version 8 YAML export.")
        }

        var groupNames: [String: String] = [:]
        var groupParents: [String: String] = [:]
        for group in rawGroups {
            guard let id = group["id"], !id.isEmpty else { continue }
            groupNames[id] = group["name"] ?? id
            if let parent = group["parent"] ?? group["parentId"], !parent.isEmpty {
                groupParents[id] = parent
            }
        }

        func groupPath(for id: String) -> String {
            guard !id.isEmpty else { return "" }
            var names: [String] = []
            var current = id
            var seen = Set<String>()
            while !current.isEmpty, seen.insert(current).inserted {
                names.insert(groupNames[current] ?? current, at: 0)
                current = groupParents[current] ?? ""
            }
            return names.joined(separator: "/")
        }

        let parsed = rawProfiles.map { fields -> ParsedHost in
            let type = (fields["profile.type"] ?? "unsupported").lowercased()
            let kind: ParsedHost.Kind = type == "ssh" ? .ssh : (type == "serial" ? .serial : .unsupported)
            let name = fields["profile.name"] ?? ""
            let host = fields["option.host"] ?? ""
            let serialPort = fields["option.port"] ?? ""
            let hostname = kind == .serial ? serialPort : host
            let sourceID = fields["profile.id"] ?? ""
            let groupPath = groupPath(for: fields["profile.group"] ?? "")
            let tabbyAuth = parseAuth(fields["option.auth"] ?? "")
            // Tabby's YAML records the authentication method, but not the
            // password. A blank `.password` host would skip Sarv's password
            // prompt and fail silently, so import it as `.ask` until the user
            // saves a password in Sarv's editor.
            let auth = tabbyAuth == .password ? .ask : tabbyAuth
            var parsed = ParsedHost(
                label: name.isEmpty ? (hostname.isEmpty ? type : hostname) : name,
                hostname: hostname,
                port: kind == .ssh ? (Int(fields["option.port"] ?? "") ?? 22) : 0,
                username: fields["option.user"] ?? "",
                auth: auth,
                proxyJump: fields["option.jumpHost"] ?? "",
                groupPath: groupPath,
                kind: kind,
                sourceID: sourceID,
                jumpHostSourceID: fields["option.jumpHost"] ?? "",
                isBlacklisted: !sourceID.isEmpty && blacklist.contains(sourceID))
            if kind == .serial {
                parsed.note = "Tabby serial profile; Sarv currently imports SSH profiles only."
            } else if kind == .unsupported {
                parsed.note = "Tabby profile type '\(type)' is not supported by Sarv yet."
            } else if tabbyAuth == .password {
                parsed.note = "Tabby has no password in this file; Sarv will ask for it when connecting."
            }
            return parsed
        }

        return (parsed, nil)
    }

    private static func parseTabbyField(_ raw: String) -> (key: String, value: String)? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let value = parseTabbyScalar(String(raw[raw.index(after: colon)...]))
        return (key, value)
    }

    private static func parseTabbyScalar(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "" }
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        } else if value.count >= 2, value.first == "'", value.last == "'" {
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        } else if let comment = value.firstIndex(of: "#"), comment > value.startIndex,
                  value[value.index(before: comment)] == " " {
            value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    // MARK: - PuTTY (.reg export of HKCU\…\PuTTY\Sessions)

    static func parsePuTTY(_ content: String) -> (hosts: [ParsedHost], error: String?) {
        var hosts: [ParsedHost] = []
        var name: String?
        var fields: [String: String] = [:]

        func flush() {
            defer { fields = [:]; name = nil }
            guard let name, !name.isEmpty, name.lowercased() != "default settings" else { return }
            let host = fields["hostname"] ?? ""
            let proto = (fields["protocol"] ?? "ssh").lowercased()
            guard !host.isEmpty, proto.isEmpty || proto == "ssh" else { return }
            hosts.append(ParsedHost(label: name, hostname: host,
                                    port: Int(fields["portnumber"] ?? "") ?? 22,
                                    username: fields["username"] ?? ""))
        }

        for raw in content.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                if let r = line.range(of: "\\Sessions\\") {
                    var key = String(line[r.upperBound...])
                    if key.hasSuffix("]") { key = String(key.dropLast()) }
                    name = key.removingPercentEncoding ?? key
                }
            } else if name != nil, let eq = line.firstIndex(of: "=") {
                let key = String(line[..<eq]).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
                var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if val.hasPrefix("dword:") {
                    val = String(Int(val.dropFirst(6), radix: 16) ?? 0)
                } else {
                    val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                fields[key] = val
            }
        }
        flush()
        return hosts.isEmpty ? ([], "No SSH sessions found in the PuTTY export (.reg).") : (hosts, nil)
    }

    // MARK: - MobaXterm (.mxtsessions)

    static func parseMobaXterm(_ content: String) -> (hosts: [ParsedHost], error: String?) {
        var hosts: [ParsedHost] = []
        var groupPath = ""
        for raw in content.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { groupPath = ""; continue }
            if line.hasPrefix("SubRep=") {
                groupPath = String(line.dropFirst("SubRep=".count)).replacingOccurrences(of: "\\", with: "/")
                continue
            }
            guard let eq = line.firstIndex(of: "="), line.contains("#109#") else { continue }  // 109 = SSH
            let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let parts = String(line[line.index(after: eq)...]).components(separatedBy: "%")
            // " #109#0" % host % port % user % …
            guard parts.count >= 2, !parts[1].isEmpty else { continue }
            hosts.append(ParsedHost(
                label: name.isEmpty ? parts[1] : name,
                hostname: parts[1],
                port: parts.count > 2 ? (Int(parts[2]) ?? 22) : 22,
                username: parts.count > 3 ? parts[3] : "",
                groupPath: groupPath))
        }
        return hosts.isEmpty ? ([], "No SSH sessions found in the MobaXterm file.") : (hosts, nil)
    }

    // MARK: - SecureCRT (Session .ini files / Sessions folder)

    static func parseSecureCRT(at url: URL) -> (hosts: [ParsedHost], error: String?) {
        let fm = FileManager.default
        var inis: [(url: URL, rel: String)] = []
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let basePrefix = url.path + "/"
            if let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let file as URL in walker where file.pathExtension.lowercased() == "ini" {
                    let rel = file.deletingPathExtension().path.replacingOccurrences(of: basePrefix, with: "")
                    inis.append((file, rel))
                }
            }
        } else if url.pathExtension.lowercased() == "ini" {
            inis.append((url, url.deletingPathExtension().lastPathComponent))
        }

        var hosts: [ParsedHost] = []
        for item in inis {
            guard let content = try? String(contentsOf: item.url, encoding: .utf8),
                  let host = parseSecureCRTSession(content, relPath: item.rel) else { continue }
            hosts.append(host)
        }
        return hosts.isEmpty ? ([], "No SSH sessions found. Pick your SecureCRT 'Sessions' folder.") : (hosts, nil)
    }

    private static func parseSecureCRTSession(_ content: String, relPath: String) -> ParsedHost? {
        var hostname = "", username = "", proto = ""
        var port = 22
        for raw in content.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let lhs = String(line[..<eq])
            let rhs = String(line[line.index(after: eq)...])
            guard let q1 = lhs.firstIndex(of: "\""), let q2 = lhs.lastIndex(of: "\""), q1 < q2 else { continue }
            let key = String(lhs[lhs.index(after: q1)..<q2])
            switch key {
            case "Hostname":      hostname = rhs
            case "Username":      username = rhs
            case "Protocol Name": proto = rhs.lowercased()
            default:
                if key.contains("Port"), lhs.hasPrefix("D:") { port = Int(rhs, radix: 16) ?? 22 }
            }
        }
        guard !hostname.isEmpty else { return nil }
        if !proto.isEmpty, !proto.contains("ssh") { return nil }   // skip telnet/rlogin/serial
        let comps = relPath.split(separator: "/").map(String.init)
        return ParsedHost(label: comps.last ?? hostname,
                          hostname: hostname, port: port, username: username,
                          groupPath: comps.dropLast().joined(separator: "/"))
    }

    // MARK: - Commit (mutates the stores)

    /// Commit the chosen hosts. `baseGroupID` is the group the user is currently
    /// drilled into when they start the import — imported hosts default there
    /// (instead of the root), and any per-row `group` path is created *beneath*
    /// it. Pass `nil` to import at the root.
    @MainActor
    static func commit(_ hosts: [ParsedHost], into baseGroupID: UUID? = nil) -> HostImportResult {
        var result = HostImportResult()
        var groupCache: [String: UUID] = [:]
        var sourceIDsToSavedIDs: [String: UUID] = [:]
        var pendingJumpHosts: [(savedHostID: UUID, sourceID: String)] = []
        for p in hosts {
            guard p.canImport else {
                result.unsupported += 1
                continue
            }
            if isDuplicate(hostname: p.hostname, username: p.username) { result.skipped += 1; continue }
            var host = p.toSavedHost()
            host.groupID = p.groupPath.isEmpty
                ? baseGroupID
                : resolveGroup(path: p.groupPath, under: baseGroupID, cache: &groupCache)
            SavedHostsStore.shared.upsert(host)
            if !p.sourceID.isEmpty { sourceIDsToSavedIDs[p.sourceID] = host.id }
            if !p.jumpHostSourceID.isEmpty {
                pendingJumpHosts.append((host.id, p.jumpHostSourceID))
            }
            result.imported += 1
        }

        // Tabby stores jumpHost as another profile's source ID. Resolve it only
        // after all selected profiles have been created so the jump connection
        // becomes a first-class Sarv Host reference, not a stale free-form -J.
        for pending in pendingJumpHosts {
            guard let jumpID = sourceIDsToSavedIDs[pending.sourceID],
                  var host = SavedHostsStore.shared.host(withID: pending.savedHostID) else {
                result.unresolvedJumpHosts += 1
                continue
            }
            host.proxyJumpHostID = jumpID
            host.proxyJump = ""
            SavedHostsStore.shared.upsert(host)
        }
        return result
    }

    @MainActor
    static func isDuplicate(hostname: String, username: String) -> Bool {
        SavedHostsStore.shared.hosts.contains {
            $0.hostname.lowercased() == hostname.lowercased()
                && $0.username.lowercased() == username.lowercased()
        }
    }

    // MARK: - Helpers

    private static func parseAuth(_ raw: String) -> SavedHost.AuthMethod {
        switch raw.lowercased().replacingOccurrences(of: " ", with: "") {
        case "password":         return .password
        case "publickey", "key": return .publicKey
        case "ask":              return .ask
        default:                 return .agent
        }
    }

    /// Resolve a `/`-separated group path into a group id, creating groups as
    /// needed. The path is resolved *beneath* `baseGroupID` (the currently
    /// focused group), so e.g. importing `Workspace/Dev` while inside "Prod"
    /// yields `Prod/Workspace/Dev`. An empty path resolves to the base itself.
    @MainActor
    private static func resolveGroup(path: String, under baseGroupID: UUID?, cache: inout [String: UUID]) -> UUID? {
        // Cache per (base, path) so the same path under different bases doesn't collide.
        let cacheKey = "\(baseGroupID?.uuidString ?? "")/\(path.lowercased())"
        if let cached = cache[cacheKey] { return cached }
        let parts = path.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return baseGroupID }
        let store = HostGroupsStore.shared
        var parentID: UUID? = baseGroupID
        for name in parts {
            if let existing = store.children(of: parentID).first(where: {
                $0.displayName.lowercased() == name.lowercased()
            }) {
                parentID = existing.id
            } else {
                var group = HostGroup.blank(parentID: parentID)
                group.name = name
                store.upsert(group)
                parentID = group.id
            }
        }
        cache[cacheKey] = parentID
        return parentID
    }

    /// Minimal RFC-4180-ish single-row CSV parser (quoted fields, `""` escapes).
    static func parseRow(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if inQuotes {
                if c == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" { current.append("\""); i = next }
                    else { inQuotes = false }
                } else { current.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",":  fields.append(current); current = ""
                default:   current.append(c)
                }
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }
}

// MARK: - Portable Sarv Hosts transfer

/// A portable, password-encrypted snapshot of the Hosts vault. It is separate
/// from the per-build local store so a Debug app and the signed release app can
/// exchange hosts without sharing their device-bound encryption keys.
private struct SarvHostsTransferPayload: Codable {
    var hosts: [SavedHost]
    var groups: [HostGroup]
}

private struct SarvHostsTransferEnvelope: Codable {
    var format: String
    var version: Int
    var iterations: Int
    var salt: String
    var blob: String
}

struct HostTransferResult {
    var imported: Int = 0
    var skipped: Int = 0
    var replaced: Bool = false
    var exported: Bool = false

    var summary: String {
        if exported {
            return "Exported \(imported) host\(imported == 1 ? "" : "s")"
        }
        if replaced {
            return "Replaced Hosts and Groups (\(imported) hosts)"
        }
        var parts = ["Imported \(imported) host\(imported == 1 ? "" : "s")"]
        if skipped > 0 { parts.append("\(skipped) duplicate\(skipped == 1 ? "" : "s") skipped") }
        return parts.joined(separator: " · ")
    }
}

enum HostTransferError: LocalizedError {
    case invalidFile
    case wrongPassword
    case emptyPassword
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "This is not a valid Sarv Hosts archive."
        case .wrongPassword: return "Wrong transfer password, or the archive is damaged."
        case .emptyPassword: return "Enter a transfer password first."
        case .writeFailed: return "Could not write the export file."
        }
    }
}

enum HostTransfer {
    private static let format = "sarvterminal-hosts"
    private static let version = 1

    static var currentHostCount: Int { SavedHostsStore.shared.hosts.count }
    static var currentGroupCount: Int { HostGroupsStore.shared.groups.count }

    static func export(to url: URL, password: String) throws {
        guard !password.isEmpty else { throw HostTransferError.emptyPassword }
        let payload = SarvHostsTransferPayload(
            hosts: SavedHostsStore.shared.hosts,
            groups: HostGroupsStore.shared.groups)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(payload)
        let salt = SyncCrypto.newSalt()
        let key = try SyncCrypto.deriveKey(
            password: password, salt: salt, iterations: SyncCrypto.pbkdf2Iterations)
        let blob = try SyncCrypto.encrypt(plain, key: key)
        let envelope = SarvHostsTransferEnvelope(
            format: format,
            version: version,
            iterations: SyncCrypto.pbkdf2Iterations,
            salt: salt.base64EncodedString(),
            blob: blob.base64EncodedString())
        let output = try JSONEncoder().encode(envelope)
        do {
            try output.write(to: url, options: .atomic)
        } catch {
            throw HostTransferError.writeFailed
        }
    }

    @MainActor
    static func importArchive(from url: URL, password: String, replace: Bool) throws -> HostTransferResult {
        guard !password.isEmpty else { throw HostTransferError.emptyPassword }
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(SarvHostsTransferEnvelope.self, from: data),
              envelope.format == format,
              envelope.version == version,
              let salt = Data(base64Encoded: envelope.salt),
              let blob = Data(base64Encoded: envelope.blob) else {
            throw HostTransferError.invalidFile
        }

        let key = try SyncCrypto.deriveKey(password: password, salt: salt, iterations: envelope.iterations)
        guard let plain = try? SyncCrypto.decrypt(blob, key: key),
              let payload = try? decodePayload(plain) else {
            throw HostTransferError.wrongPassword
        }

        if replace {
            HostGroupsStore.shared.replaceAll(payload.groups)
            SavedHostsStore.shared.replaceAll(payload.hosts)
            return HostTransferResult(imported: payload.hosts.count, replaced: true)
        }
        return merge(payload)
    }

    private static func decodePayload(_ data: Data) throws -> SarvHostsTransferPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SarvHostsTransferPayload.self, from: data)
    }

    @MainActor
    private static func merge(_ payload: SarvHostsTransferPayload) -> HostTransferResult {
        let existingGroups = HostGroupsStore.shared.groups
        var groupIDs: [UUID: UUID] = [:]
        var incomingGroups = Dictionary(uniqueKeysWithValues: payload.groups.map { ($0.id, $0) })

        func mapGroup(_ id: UUID?) -> UUID? {
            guard let id else { return nil }
            if let mapped = groupIDs[id] { return mapped }
            guard var group = incomingGroups[id] else {
                return existingGroups.contains(where: { $0.id == id }) ? id : nil
            }

            let parent = mapGroup(group.parentID)
            let sameID = existingGroups.first(where: { $0.id == id })
            let targetID: UUID
            if let sameID, sameID.name == group.name, sameID.parentID == parent {
                targetID = sameID.id
            } else if sameID != nil {
                targetID = UUID()
            } else {
                targetID = id
            }
            group.id = targetID
            group.parentID = parent
            groupIDs[id] = targetID
            HostGroupsStore.shared.upsert(group)
            incomingGroups.removeValue(forKey: id)
            return targetID
        }

        for group in payload.groups { _ = mapGroup(group.id) }

        let existingHosts = SavedHostsStore.shared.hosts
        var hostIDs: [UUID: UUID] = [:]
        var staged: [(source: SavedHost, target: SavedHost)] = []
        var skipped = 0

        for source in payload.hosts {
            if let duplicate = existingHosts.first(where: {
                $0.hostname.caseInsensitiveCompare(source.hostname) == .orderedSame
                    && $0.username.caseInsensitiveCompare(source.username) == .orderedSame
                    && $0.port == source.port
            }) {
                hostIDs[source.id] = duplicate.id
                skipped += 1
                continue
            }

            var target = source
            if existingHosts.contains(where: { $0.id == source.id }) {
                target.id = UUID()
                target.createdAt = Date()
                target.updatedAt = target.createdAt
            }
            target.groupID = mapGroup(source.groupID)
            hostIDs[source.id] = target.id
            staged.append((source, target))
        }

        for item in staged {
            var target = item.target
            if let sourceJump = item.source.proxyJumpHostID {
                target.proxyJumpHostID = hostIDs[sourceJump]
                if target.proxyJumpHostID == nil { target.proxyJump = item.source.proxyJump }
            }
            SavedHostsStore.shared.upsert(target)
        }

        return HostTransferResult(imported: staged.count, skipped: skipped)
    }
}
