import AppKit
import SwiftUI

struct Headset: Decodable, Identifiable {
    let id: String
    let name: String
    let udid: String
    let developerMode: Bool
}

struct Setup: Decodable {
    let sdk: String
    let teams: [String]
    let devices: [Headset]
    let deviceError: String?
}

struct CommandFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func xcodeDeveloperDirectory() -> URL? {
    let applications = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
    let selected = Process()
    let output = Pipe()
    selected.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    selected.arguments = ["-p"]
    selected.standardOutput = output
    selected.standardError = FileHandle.nullDevice
    guard (try? selected.run()) != nil else { return nil }
    let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let candidates = [URL(fileURLWithPath: path)] + applications.map {
        $0.appending(path: "Xcode.app/Contents/Developer")
    }
    return candidates.first {
        FileManager.default.isExecutableFile(atPath: $0.appending(path: "usr/bin/xcodebuild").path)
    }
}

func run(_ arguments: [String], developerDirectory: URL, log: URL? = nil,
         update: @Sendable (String) -> Void = { _ in }) throws -> Data {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["python3"] + arguments
    process.environment = [
        "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        "DEVELOPER_DIR": developerDirectory.path,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "PYTHONUNBUFFERED": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
    ]
    process.standardOutput = pipe
    process.standardError = pipe
    let logHandle: FileHandle?
    if let log {
        try Data().write(to: log, options: .atomic)
        logHandle = try FileHandle(forWritingTo: log)
    } else {
        logHandle = nil
    }
    defer { try? logHandle?.close() }
    try process.run()
    var output = Data()
    var pending = Data()
    var lastStage: String?
    var errorMessage: String?
    while true {
        let bytes = pipe.fileHandleForReading.availableData
        if bytes.isEmpty { break }
        if let logHandle {
            try? logHandle.write(contentsOf: bytes)
            pending.append(bytes)
            while let end = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                if line.hasPrefix("VXPRO_STAGE ") {
                    let stage = String(line.dropFirst("VXPRO_STAGE ".count))
                    lastStage = stage
                    update(stage)
                }
                if line.hasPrefix("VXPRO_ERROR ") {
                    errorMessage = String(line.dropFirst("VXPRO_ERROR ".count))
                }
                if line.hasPrefix("  copying ") {
                    update("Copying game data · " + line.dropFirst("  copying ".count).prefix(while: { $0 != ":" }))
                }
            }
        } else {
            output.append(bytes)
        }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        if log != nil {
            if let errorMessage { throw CommandFailure(errorMessage) }
            let message = lastStage.map { "Stopped at “\($0)”." } ?? "Setup could not start."
            throw CommandFailure("\(message) Open the installation log for the reason. After fixing it, select Install to Vision Pro again to retry.")
        }
        throw CommandFailure(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return output
}

@MainActor
final class Installer: ObservableObject {
    @Published var game: URL?
    @Published var team = ""
    @Published var device = ""
    @Published var bundleID = ""
    @Published var installedHosts: [String] = []
    @Published var checkingInstallations = false
    @Published var installationLookupError: String?
    @Published var setup: Setup?
    @Published var error: String?
    @Published var stage = ""
    @Published var checking = false
    @Published var installing = false
    @Published var installed = false
    @Published var log: URL?
    private var developerDirectory: URL?
    private var installationLookup: Task<Void, Never>?

    private var resources: URL {
        Bundle.main.resourceURL!.appending(path: "Payload")
    }

    var selectedHeadset: Headset? { setup?.devices.first { $0.id == device } }
    var ready: Bool {
        !checking && !checkingInstallations && installationLookupError == nil && !installing &&
            game != nil && !team.isEmpty && (installedHosts.count <= 1 || !bundleID.isEmpty) &&
            selectedHeadset?.developerMode == true && !(setup?.sdk.isEmpty ?? true)
    }

    func refresh() {
        guard !checking, !checkingInstallations, !installing else { return }
        checking = true
        error = nil
        if game.map(Self.isGame) != true { game = Self.findGame() }
        let script = resources.appending(path: "installer/setup.py").path
        Task {
            defer { checking = false }
            do {
                let (directory, result) = try await Task.detached {
                    guard let directory = xcodeDeveloperDirectory() else {
                        throw CommandFailure("Install Xcode and open it once to complete setup.")
                    }
                    let data = try run([script, "discover"], developerDirectory: directory)
                    return (directory, try JSONDecoder().decode(Setup.self, from: data))
                }.value
                developerDirectory = directory
                setup = result
                if !result.teams.contains(team) { team = result.teams.first ?? "" }
                let preferred = result.devices.first(where: \.developerMode)?.id ?? result.devices.first?.id ?? ""
                let selected = result.devices.contains(where: { $0.id == device }) ? device : preferred
                selectHeadset(selected)
            } catch {
                setup = nil
                self.error = error.localizedDescription
            }
        }
    }

    func selectHeadset(_ selected: String) {
        installationLookup?.cancel()
        if device != selected {
            device = selected
            bundleID = ""
            installedHosts = []
        }
        installationLookupError = nil
        guard let developerDirectory, !selected.isEmpty else {
            checkingInstallations = false
            return
        }
        checkingInstallations = true
        let script = resources.appending(path: "installer/setup.py").path
        installationLookup = Task {
            do {
                let hosts = try await Task.detached {
                    let data = try run([script, "installed-hosts", "--device", selected],
                                       developerDirectory: developerDirectory)
                    return try JSONDecoder().decode([String].self, from: data)
                }.value
                guard device == selected, !Task.isCancelled else { return }
                installedHosts = hosts
                if bundleID.isEmpty, hosts.count == 1 { bundleID = hosts[0] }
                checkingInstallations = false
            } catch {
                guard device == selected, !Task.isCancelled else { return }
                installationLookupError = "Could not check existing installations. Unlock Vision Pro, then refresh."
                checkingInstallations = false
            }
        }
    }

    func chooseGame() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.message = "Choose your Cyberpunk 2077 app from the Mac App Store."
        panel.prompt = "Choose Game"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        if Self.isGame(chosen) {
            game = chosen
            installed = false
            error = nil
        } else {
            error = "This folder does not contain the Mac App Store game and its data."
        }
    }

    private static func isGame(_ url: URL) -> Bool {
        ["Contents/MacOS/Cyberpunk2077", "Contents/_MASReceipt/receipt", "Contents/Data/archive"].allSatisfy {
            FileManager.default.fileExists(atPath: url.appending(path: $0).path)
        }
    }

    private static func findGame() -> URL? {
        let files = FileManager.default
        let system = files.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        let external = files.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let directories = system + external.flatMap { [$0.appending(path: "Applications"), $0] }
        return directories.lazy.flatMap { directory in
            ["Cyberpunk2077.app", "Cyberpunk 2077.app", "Cyberpunk 2077 Ultimate Edition.app"].map {
                directory.appending(path: $0)
            }
        }.first(where: isGame)
    }

    func install() {
        guard ready, let game, let headset = selectedHeadset, let developerDirectory else { return }
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VXpro")
        let buildID = Bundle.main.object(forInfoDictionaryKey: "VXproPayloadVersion") as? String ?? "local"
        let work = support.appending(path: "Installer/\(buildID)")
        let log = support.appending(path: "Installer/Install-\(UUID().uuidString).log")
        let payload = resources
        var args = [work.appending(path: "installer/setup.py").path, "install", "--game", game.path,
                    "--team", team, "--device", headset.id, "--udid", headset.udid,
                    "--state-dir", work.deletingLastPathComponent().path]
        let existing = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { args += ["--bundle-id", existing] }
        let command = args
        error = nil
        installing = true
        installed = false
        stage = "Starting setup"
        self.log = nil
        Task {
            defer {
                installing = false
                if files.fileExists(atPath: log.path) { self.log = log }
            }
            do {
                try await Task.detached {
                    try files.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !files.fileExists(atPath: work.path) {
                        let staging = work.deletingLastPathComponent().appending(path: UUID().uuidString)
                        defer { try? files.removeItem(at: staging) }
                        try files.copyItem(at: payload, to: staging)
                        do {
                            try files.moveItem(at: staging, to: work)
                        } catch {
                            if !files.fileExists(atPath: work.path) { throw error }
                        }
                    }
                    _ = try run(command, developerDirectory: developerDirectory, log: log) { message in
                        Task { @MainActor in self.stage = message }
                    }
                }.value
                installed = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct InstallerView: View {
    @StateObject private var model = Installer()
    @State private var advanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: "visionpro.fill")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.teal)
                    .frame(width: 56, height: 56)
                    .background(.teal.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("VXpro").font(.system(size: 27, weight: .semibold))
                    Text("Cyberpunk 2077 on Apple Vision Pro").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
                    .labelStyle(.iconOnly)
                    .help("Check Xcode, signing and Vision Pro again")
                    .disabled(model.checking || model.checkingInstallations || model.installing)
            }

            VStack(spacing: 0) {
                row("Game", icon: "gamecontroller", ready: model.game != nil) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cyberpunk 2077")
                        Text(model.game == nil ? "A purchased Mac App Store copy" : "Mac App Store")
                            .font(.caption).foregroundStyle(.secondary)
                            .help(model.game?.path ?? "")
                    }
                    Spacer()
                    Button(model.game == nil ? "Choose…" : "Change…", action: model.chooseGame)
                }
                Divider()
                row("Xcode", icon: "hammer", ready: !(model.setup?.sdk.isEmpty ?? true)) {
                    if let sdk = model.setup?.sdk, !sdk.isEmpty {
                        Text("visionOS \(sdk) SDK")
                    } else {
                        Text(model.checking ? "Checking…" : "Install the visionOS SDK in Xcode")
                    }
                    Spacer()
                    Button("Open Xcode") {
                        if let developer = xcodeDeveloperDirectory() {
                            NSWorkspace.shared.open(developer.deletingLastPathComponent().deletingLastPathComponent())
                        } else if let url = URL(string: "https://developer.apple.com/xcode/") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Divider()
                row("Signing", icon: "signature", ready: !model.team.isEmpty) {
                    if let teams = model.setup?.teams, !teams.isEmpty {
                        Picker("Developer team", selection: $model.team) {
                            ForEach(teams, id: \.self) { Text(teams.count == 1 ? "Apple Development" : $0).tag($0).help($0) }
                        }.labelsHidden().frame(maxWidth: 215)
                    } else {
                        Text("Add an Apple Development certificate in Xcode").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Divider()
                row("Vision Pro", icon: "visionpro", ready: model.selectedHeadset?.developerMode == true) {
                    if let devices = model.setup?.devices, !devices.isEmpty {
                        Picker("Vision Pro", selection: Binding(get: { model.device }, set: model.selectHeadset)) {
                            ForEach(devices) { Text(devices.count == 1 ? "Apple Vision Pro" : $0.name).tag($0.id).help($0.name) }
                        }.labelsHidden().frame(maxWidth: 260)
                        if model.selectedHeadset?.developerMode == false {
                            Text("Enable Developer Mode").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Pair your headset in Xcode").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .disabled(model.installing)

            DisclosureGroup(model.bundleID.isEmpty ? "Existing installation" : "Updating an existing installation",
                            isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 7) {
                    if !model.installedHosts.isEmpty {
                        Menu("Use detected installation") {
                            ForEach(model.installedHosts, id: \.self) { bundleID in
                                Button(bundleID) { model.bundleID = bundleID }
                            }
                        }
                    }
                    TextField("Existing bundle ID", text: $model.bundleID,
                              prompt: Text("Leave blank for a new installation"))
                        .textFieldStyle(.roundedBorder)
                    Text("Use the original signing team when updating.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 5)
            }
            .font(.subheadline)
            .disabled(model.installing)

            if let error = model.error ?? model.installationLookupError ?? model.setup?.deviceError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if model.installed {
                Label("Installed. Open VX Mac Host on your Vision Pro.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.teal)
            } else if model.installing {
                ProgressView(model.stage).progressViewStyle(.linear)
            } else if model.checkingInstallations {
                ProgressView("Checking existing installations").progressViewStyle(.linear)
            } else if model.installedHosts.count > 1 && model.bundleID.isEmpty {
                Text("Choose which installation to update under Existing installation.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("1280 × 720 native · Motion Blur off. Keep Vision Pro awake during the first transfer.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                if let log = model.log {
                    Button("Installation Log") { NSWorkspace.shared.open(log) }
                } else {
                    Link("Setup Guide", destination: URL(string: "https://github.com/Ag3497120/VXpro/blob/main/docs/VISION_PRO_CYBERPUNK_MAC.md")!)
                }
                Spacer()
                Button("Install to Vision Pro", action: model.install)
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.teal)
                    .disabled(!model.ready)
            }
        }
        .padding(24)
        .frame(width: 610)
        .task { model.refresh() }
    }

    private func row<Content: View>(_ title: String, icon: String, ready: Bool,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon)
                .frame(width: 105, alignment: .leading)
                .font(.callout.weight(.medium))
            content()
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ready ? Color.teal : Color.secondary)
                .accessibilityLabel(ready ? "Ready" : "Setup needed")
        }.frame(minHeight: 45).padding(.horizontal, 13)
    }
}

@main
struct VXproApp: App {
    var body: some Scene {
        Window("VXpro Installer", id: "installer") {
            InstallerView()
        }.windowResizability(.contentSize)
    }
}
