import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Termius-style import flow:
///   1. pick a format,
///   2. (CSV) see the format + choose a file,
///   3. review/deselect the parsed hosts,
///   4. import → result.
struct ImportHostsView: View {
    @Environment(\.dismiss) private var dismiss

    /// The group the user is currently drilled into. Imported hosts default
    /// here (per-row `group` paths are created beneath it); `nil` = root.
    var targetGroupID: UUID? = nil

    private enum Screen { case formats, csvIntro, preview, done }
    @State private var screen: Screen = .formats

    @State private var candidates: [ParsedHost] = []
    @State private var selected: Set<UUID> = []
    @State private var filter = ""
    @State private var title = "Add hosts to your vault"
    @State private var note: String?       // inline error / hint
    @State private var savedTemplateURL: URL?   // green "saved" confirmation on the CSV step
    @State private var result: HostImportResult?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch screen {
                case .formats: formatsScreen
                case .csvIntro: csvIntroScreen
                case .preview: previewScreen
                case .done: doneScreen
                }
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 560)
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.square.stack")
                .font(.system(size: 34)).foregroundStyle(.tint)
            Text(title).font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22).padding(.bottom, 16)
    }

    // MARK: - 1. Formats

    private var formatsScreen: some View {
        VStack(spacing: 16) {
            Text("Transfer your saved connections, groups, and tags. Select a source to start.")
                .font(.callout).foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 14)], spacing: 16) {
                formatCard("~/.ssh/config", "terminal", enabled: true) { startSSH() }
                formatCard("iTerm2", "macwindow.on.rectangle", enabled: true) { startiTerm2() }
                formatCard("Tabby YAML", "doc.text", enabled: true) { chooseTabby() }
                formatCard("CSV", "tablecells", enabled: true) { title = "Import from CSV"; note = nil; screen = .csvIntro }
                formatCard("PuTTY", "pc", enabled: true) { startPuTTY() }
                formatCard("MobaXterm", "macwindow", enabled: true) { startMobaXterm() }
                formatCard("SecureCRT", "lock.laptopcomputer", enabled: true) { startSecureCRT() }
            }
            .frame(maxWidth: 480)
            if let note { noteLabel(note) }
            Spacer()
        }
        .padding(24)
    }

    private func formatCard(_ label: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 26))
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.12)))
                Text(label).font(.callout).lineLimit(1)
                if !enabled {
                    Text("Soon").font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.22)))
                        .foregroundStyle(.secondaryText)
                }
            }
            .frame(width: 100).contentShape(Rectangle()).opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .help(enabled ? "Import from \(label)" : "\(label) import is coming soon")
    }

    // MARK: - 2. CSV intro (format + choose file)

    private var csvIntroScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your CSV must use this header row. Only `hostname` is required.")
                .font(.callout).foregroundStyle(.secondaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(HostImporter.csvHeader)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))

            VStack(alignment: .leading, spacing: 6) {
                bullet("`group` accepts a path like `Workspace/Dev` — groups are created automatically.")
                bullet("`tags` are separated by `;` (e.g. `prod;web`).")
                bullet("`auth` is one of password / publicKey / agent / ask.")
            }
            .font(.caption).foregroundStyle(.secondaryText)

            HStack(spacing: 12) {
                Button("Choose CSV file…") { chooseCSV() }.controlSize(.large)
                Button("Save template…") { saveTemplate() }
            }
            .padding(.top, 4)

            if let savedTemplateURL { savedTemplateLabel(savedTemplateURL) }
            if let note { noteLabel(note) }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•"); Text(.init(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 3. Preview (review + select)

    private var filtered: [ParsedHost] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter { $0.label.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    private var previewScreen: some View {
        VStack(spacing: 0) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)

            // Profile header with select-all.
            HStack(spacing: 10) {
                Image(systemName: "server.rack").foregroundStyle(.secondaryText)
                Text("Profiles").font(.headline)
                Spacer()
                Text("\(selected.count) of \(candidates.count)").font(.caption).foregroundStyle(.secondaryText)
                Button { toggleAll() } label: {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(allSelected ? .blue : .secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 24).padding(.vertical, 6)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { host in
                        HStack(spacing: 10) {
                            Button { toggle(host.id) } label: {
                                Image(systemName: selected.contains(host.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(host.id) ? .blue : .secondary)
                                    .frame(width: 18)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 3) {
                                TextField("Profile name", text: binding(for: host.id))
                                    .textFieldStyle(.plain)
                                    .font(.body)
                                HStack(spacing: 6) {
                                    Text(host.kind.displayName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(host.canImport ? .secondaryText : .orange)
                                    Text(host.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondaryText)
                                        .lineLimit(1)
                                }
                                if let note = host.note.isEmpty ? nil : host.note {
                                    Text(note).font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 24).padding(.vertical, 8)
                        Divider().padding(.leading, 24)
                    }
                }
            }
        }
    }

    private var importableIDs: Set<UUID> {
        Set(candidates.filter(\.canImport).map(\.id))
    }

    private var allSelected: Bool {
        !importableIDs.isEmpty && importableIDs.isSubset(of: selected)
    }

    private func toggle(_ id: UUID) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    private func toggleAll() {
        if allSelected { selected.subtract(importableIDs) }
        else { selected.formUnion(importableIDs) }
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { candidates.first(where: { $0.id == id })?.label ?? "" },
            set: { value in
                guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
                candidates[index].label = value
            })
    }

    // MARK: - 4. Done

    private var doneScreen: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text(result?.summary ?? "Done").font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24).frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if screen == .formats {
                Button("Cancel") { dismiss() }
            } else if screen == .done {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Back") { backToFormats() }
            }
            if screen == .preview {
                Spacer()
                Button("Import \(selected.count) selected") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.bar)
    }

    private func noteLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Green "template saved" confirmation with a reveal-in-Finder shortcut.
    private func savedTemplateLabel(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Template saved to \(url.lastPathComponent)")
                .fixedSize(horizontal: false, vertical: true)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
        }
        .font(.callout)
    }

    // MARK: - Actions

    private func backToFormats() {
        screen = .formats; title = "Add hosts to your vault"; note = nil
        savedTemplateURL = nil
        candidates = []; selected = []; filter = ""
    }

    private func startSSH() {
        let hosts = HostImporter.parseSSHConfig()
        if hosts.isEmpty { note = "No hosts found in ~/.ssh/config."; return }
        showPreview(hosts, title: "Import from ~/.ssh/config")
    }

    private func startiTerm2() {
        let (hosts, error) = HostImporter.parseiTerm2()
        if let error { note = error; return }
        showPreview(hosts, title: "Review \(hosts.count) iTerm2 profile\(hosts.count == 1 ? "" : "s")")
    }

    private func chooseTabby() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Tabby exports YAML files, but macOS does not always classify .yaml
        // and .yml as plain text. Include both extensions explicitly while
        // keeping plain text available for files without a standard suffix.
        panel.allowedContentTypes = [
            .plainText,
            UTType(filenameExtension: "yaml"),
            UTType(filenameExtension: "yml")
        ].compactMap { $0 }
        panel.prompt = "Import"
        panel.message = "Choose your Tabby version 8 YAML configuration."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                note = "Couldn't read that Tabby YAML file."
                return
            }
            let (profiles, error) = HostImporter.parseTabby(content)
            if let error { note = error; return }
            showPreview(profiles, title: "Review \(profiles.count) Tabby profile\(profiles.count == 1 ? "" : "s")")
        }
    }

    private func startPuTTY() {
        pickFile(allowDirectory: false) { content in
            let (hosts, error) = HostImporter.parsePuTTY(content)
            if let error { note = error; return }
            showPreview(hosts, title: "Review \(hosts.count) PuTTY session\(hosts.count == 1 ? "" : "s")")
        }
    }

    private func startMobaXterm() {
        pickFile(allowDirectory: false) { content in
            let (hosts, error) = HostImporter.parseMobaXterm(content)
            if let error { note = error; return }
            showPreview(hosts, title: "Review \(hosts.count) MobaXterm session\(hosts.count == 1 ? "" : "s")")
        }
    }

    private func startSecureCRT() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // pick the Sessions folder or a single .ini
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose your SecureCRT 'Sessions' folder (or a single .ini)."
        // Async `begin` (not `runModal`): a synchronous modal opened from a
        // SwiftUI event handler inside a `.sheet` hangs the app.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let (hosts, error) = HostImporter.parseSecureCRT(at: url)
            if let error { note = error; return }
            showPreview(hosts, title: "Review \(hosts.count) SecureCRT session\(hosts.count == 1 ? "" : "s")")
        }
    }

    /// Open a file panel and hand its text contents to `handler`. No-op on
    /// cancel; sets `note` if the file can't be read. Uses async `begin` (see
    /// `startSecureCRT`) so it never hangs the sheet.
    private func pickFile(allowDirectory: Bool, then handler: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowDirectory
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                note = "Couldn't read that file."
                return
            }
            handler(content)
        }
    }

    private func chooseCSV() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.prompt = "Open"
        savedTemplateURL = nil   // a new action supersedes the "saved" confirmation
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                note = "Couldn't read that file."; return
            }
            let (hosts, error) = HostImporter.parseCSV(content)
            if let error { note = error; return }
            showPreview(hosts, title: "Review \(hosts.count) host\(hosts.count == 1 ? "" : "s")")
        }
    }

    private func showPreview(_ hosts: [ParsedHost], title: String) {
        candidates = hosts
        selected = Set(hosts.filter(\.defaultSelected).map(\.id))
        filter = ""; note = nil
        self.title = title
        screen = .preview
    }

    private func commit() {
        let chosen = candidates.filter { selected.contains($0.id) }
        result = HostImporter.commit(chosen, into: targetGroupID)
        title = "Import complete"
        screen = .done
    }

    private func saveTemplate() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "sarvterminal-hosts-template.csv"
        // Async `begin` (not `runModal`): a synchronous modal opened from a
        // SwiftUI event handler inside a `.sheet` hangs the app.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try HostImporter.csvTemplate.write(to: url, atomically: true, encoding: .utf8)
                note = nil
                savedTemplateURL = url   // shows the green in-app confirmation
            } catch {
                savedTemplateURL = nil
                note = "Couldn't save the template: \(error.localizedDescription)"
            }
        }
    }
}

/// Moves the complete Hosts vault between Sarv builds or machines. The archive
/// is encrypted with a user-chosen password, so saved SSH passwords can travel
/// with the Hosts without being written to a plain-text export.
struct HostTransferView: View {
    enum Operation: String, CaseIterable, Identifiable {
        case export, `import`
        var id: Self { self }
        var label: String { self == .export ? "Export" : "Import" }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var operation: Operation
    @State private var transferPassword = ""
    @State private var confirmPassword = ""
    @State private var archiveURL: URL?
    @State private var replaceExisting = false
    @State private var message: String?
    @State private var result: HostTransferResult?
    @State private var finished = false

    init(operation: Operation = .export) {
        _operation = State(initialValue: operation)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right.square")
                    .font(.system(size: 34)).foregroundStyle(.tint)
                Text("Transfer Hosts")
                    .font(.title2.weight(.bold))
                Text("Move Hosts, Groups, and saved passwords between Sarv builds.")
                    .font(.callout).foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22).padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Picker("Operation", selection: $operation) {
                    ForEach(Operation.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if operation == .export {
                    exportForm
                } else {
                    importForm
                }

                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let result {
                    Label(result.summary, systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if finished {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 560, height: 480)
        .background(.background)
        .onChange(of: operation) { _ in
            message = nil
            result = nil
            finished = false
        }
    }

    private var exportForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This creates an encrypted `.sarvhosts` archive.")
                .font(.callout)
            Text("\(HostTransfer.currentHostCount) Hosts · \(HostTransfer.currentGroupCount) Groups")
                .font(.caption).foregroundStyle(.secondaryText)
            SecureField("Transfer password", text: $transferPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm transfer password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)
            if !confirmPassword.isEmpty && transferPassword != confirmPassword {
                Text("Passwords do not match.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button("Choose location and export…") { chooseExportLocation() }
                .controlSize(.large)
                .disabled(transferPassword.isEmpty || transferPassword != confirmPassword)
        }
    }

    private var importForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(archiveURL?.lastPathComponent ?? "Choose `.sarvhosts` file…") {
                chooseImportFile()
            }
            .controlSize(.large)
            SecureField("Transfer password", text: $transferPassword)
                .textFieldStyle(.roundedBorder)
            Picker("When Hosts already exist", selection: $replaceExisting) {
                Text("Merge with current Hosts").tag(false)
                Text("Replace current Hosts").tag(true)
            }
            .pickerStyle(.radioGroup)
            if replaceExisting {
                Text("Replace removes the current Hosts and Groups before importing.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Merge keeps current Hosts and skips duplicate endpoints.")
                    .font(.caption).foregroundStyle(.secondaryText)
            }
            Button("Import archive") { importArchive() }
                .controlSize(.large)
                .disabled(archiveURL == nil || transferPassword.isEmpty)
        }
    }

    private func chooseExportLocation() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sarvhosts") ?? .data]
        panel.nameFieldStringValue = "sarv-hosts.sarvhosts"
        panel.prompt = "Export"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try HostTransfer.export(to: url, password: transferPassword)
                message = nil
                result = HostTransferResult(imported: HostTransfer.currentHostCount, exported: true)
                finished = true
            } catch {
                result = nil
                message = error.localizedDescription
            }
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sarvhosts") ?? .data]
        panel.prompt = "Open"
        panel.begin { response in
            guard response == .OK else { return }
            archiveURL = panel.url
            message = nil
            result = nil
            finished = false
        }
    }

    private func importArchive() {
        guard let archiveURL else { return }
        do {
            result = try HostTransfer.importArchive(
                from: archiveURL, password: transferPassword, replace: replaceExisting)
            message = nil
            finished = true
        } catch {
            result = nil
            message = error.localizedDescription
        }
    }
}
