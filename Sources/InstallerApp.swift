import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

@MainActor final class InstallerModel: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published var showDropPrompt = false
    @Published var selectedID = ""
    @Published private(set) var package: URL?
    @Published private(set) var metadata: Inspection?
    var workDidFinish: (() -> Void)?
    @Published private(set) var busy = false {
        didSet { if oldValue && !busy { workDidFinish?() } }
    }
    @Published private(set) var status = "Connect a device or drop a build to begin."
    @Published var log = "Ready.\n"
    @Published private(set) var failed = false
    @Published private(set) var appleStatus = "Not checked"
    @Published private(set) var androidStatus = "Not checked"
    @Published private(set) var adb: String?
    @Published private(set) var customADB: String? = UserDefaults.standard.string(forKey: "customADBPath")
    @Published var allowTest = false

    var menuBarPreferenceChanged: ((Bool) -> Void)?
    @Published var showMenuBar = UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showMenuBar, forKey: "showMenuBar")
            if oldValue != showMenuBar { menuBarPreferenceChanged?(showMenuBar) }
        }
    }
    struct IdleSnapshot: Codable {
        let devices: [Device]
        let selectedID: String
        let package: URL?
        let metadata: Inspection?
        let status: String
        let log: String
        let failed: Bool
        let appleStatus: String
        let androidStatus: String
        let adb: String?
        let allowTest: Bool
    }

    func idleSnapshot() -> IdleSnapshot {
        IdleSnapshot(devices: devices, selectedID: selectedID, package: package, metadata: metadata,
                     status: status, log: log, failed: failed, appleStatus: appleStatus,
                     androidStatus: androidStatus, adb: adb, allowTest: allowTest)
    }

    func restore(_ snapshot: IdleSnapshot) {
        devices = snapshot.devices
        selectedID = snapshot.selectedID
        package = snapshot.package
        metadata = snapshot.metadata
        status = snapshot.status
        log = snapshot.log
        failed = snapshot.failed
        appleStatus = snapshot.appleStatus
        androidStatus = snapshot.androidStatus
        adb = snapshot.adb
        allowTest = snapshot.allowTest
    }

    private var refreshOnDrop: Bool { UserDefaults.standard.object(forKey: "refreshOnDrop") as? Bool ?? true }
    private var selectOnlyDevice: Bool { UserDefaults.standard.object(forKey: "selectOnlyDevice") as? Bool ?? true }

    func selectDropped(_ urls: [URL]) -> Bool {
        guard !busy else { return false }
        guard urls.count == 1, let url = urls.first else {
            report(InstallError(message: "Drop one IPA or APK at a time."))
            return false
        }
        guard select(url) else { return false }
        if refreshOnDrop { refresh() }
        return true
    }

    var platform: Platform? {
        switch package?.pathExtension.lowercased() {
        case "ipa": return .apple
        case "apk": return .android
        default: return nil
        }
    }
    var compatible: [Device] { devices.filter { platform == nil || $0.platform == platform } }
    var target: Device? { compatible.first { $0.id == selectedID && $0.available } }
    var canInstall: Bool {
        guard let platform = platform, let device = target else { return false }
        return !busy && device.platform == platform && (platform == .apple || adb != nil)
    }

    func append(_ text: String) { log = boundedDiagnosticTail(log + "\n[\(Date().formatted(date: .omitted, time: .standard))] \(boundedDiagnosticTail(text))\n") }
    func report(_ error: Error) {
        failed = true
        status = error.localizedDescription.components(separatedBy: "\n").first ?? "Operation failed"
        append(error.localizedDescription)
    }
    func selectCompatibleTarget() {
        if target != nil { return }
        let ready = compatible.filter(\.available)
        selectedID = selectOnlyDevice && ready.count == 1 ? ready[0].id : ""
    }
    func targetChanged() { metadata = nil }
    func refresh() {
        guard !busy else { return }
        busy = true; failed = false; status = "Discovering Apple and Android devices…"
        let custom = customADB
        Task {
            defer { busy = false }
            let discovery = await Task.detached(priority: .userInitiated) { Engine.discover(customADB: custom) }.value
            devices = discovery.devices; adb = discovery.adbPath
            appleStatus = discovery.appleStatus; androidStatus = discovery.androidStatus
            metadata = nil; selectCompatibleTarget()
            status = devices.isEmpty ? "No devices found. See connection details below." : "Found \(devices.count) device(s). Choose a compatible target."
            append(appleStatus); append(androidStatus)
            if let adb = adb { append("ADB: \(adb)") }
        }
    }
    func pick() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        // Dynamic UTIs can be generic ZIP/data on some Macs; validate the exact extension below.
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data, UTType(filenameExtension: "apk") ?? .data]
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "Choose your signed IPA or APK build."
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }
    @discardableResult func select(_ url: URL) -> Bool {
        guard !busy else { return false }
        guard url.isFileURL, ["ipa", "apk"].contains(url.pathExtension.lowercased()),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            report(InstallError(message: "Drop a single regular .ipa or .apk file.")); return false
        }
        showDropPrompt = false
        package = url; metadata = nil; allowTest = false; failed = false
        selectCompatibleTarget()
        status = "\(url.pathExtension.uppercased()) selected. Choose a device and install."
        append("Selected \(url.lastPathComponent)")
        return true
    }
    func clearPackage() {
        guard !busy else { return }
        package = nil; metadata = nil; allowTest = false; failed = false
        selectCompatibleTarget(); status = "Drop another IPA or APK."
    }
    func locateADB() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.message = "Select the adb executable from Google's Android SDK platform-tools folder."
        if panel.runModal() == .OK, let url = panel.url {
            guard Engine.adbPath(custom: url.path) != nil else { report(InstallError(message: "Select an executable named adb from trusted Google Platform-Tools.")); return }
            customADB = url.path; UserDefaults.standard.set(url.path, forKey: "customADBPath"); refresh()
        }
    }
    func resetADB() {
        guard !busy else { return }
        UserDefaults.standard.removeObject(forKey: "customADBPath"); customADB = nil; refresh()
    }
    func inspect() {
        guard !busy, let url = package, let platform = platform else { return }
        let device = target; busy = true; failed = false; status = "Inspecting \(url.pathExtension.uppercased())…"
        Task {
            defer { busy = false }
            do {
                metadata = try await Task.detached(priority: .userInitiated) { () throws -> Inspection in
                    switch platform {
                    case .apple: return .apple(try Engine.inspectApple(url, target: device))
                    case .android: return .android(try Engine.inspectAPK(url))
                    }
                }.value
                status = platform == .apple ? "IPA preflight passed. Final validation occurs on the device." : "APK archive preflight passed. Android checks signature and compatibility at installation."
                append(status)
            } catch { metadata = nil; report(error) }
        }
    }
    func install() {
        guard canInstall, let url = package, let device = target else { return }
        let adb = adb; let test = allowTest
        busy = true; failed = false; status = "Validating and installing on \(device.name)…"
        append("Starting \(url.lastPathComponent) → \(device.name) (\(device.deviceID))")
        Task {
            defer { busy = false }
            do {
                let output = try await Task.detached(priority: .userInitiated) { () throws -> String in
                    if device.platform == .apple { return try Engine.installApple(url, target: device) }
                    guard let adb = adb else { throw InstallError(message: "ADB is not available. Locate Platform-Tools first.") }
                    return try Engine.installAPK(url, target: device, adb: adb, allowTest: test)
                }.value
                status = "Installation completed on \(device.name)."; append(output)
            } catch { report(error) }
        }
    }
}

@main @MainActor struct MobileInstallerApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = InstallerDelegate()
        app.delegate = delegate
        app.setActivationPolicy(delegate.startsInMenuBar || IdleHandoff.isContinuation ? .accessory : .regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor struct InstallerView: View {
    @ObservedObject var model: InstallerModel
    @AppStorage("showMenuBarDiagnostics") private var showMenuBarDiagnostics = false
    @State private var hovering = false
    @State private var showWindowDiagnostics = false
    var inPopover = false
    private var invitingDrop: Bool { inPopover && (model.showDropPrompt || hovering) }

    private var dropHighlighted: Bool { hovering || invitingDrop || (!inPopover && model.package == nil) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                dropArea
                devicePanel
                if let info = model.metadata { details(info) }
                if model.platform == .android {
                    Toggle("Allow test-only APKs (developer builds)", isOn: $model.allowTest).disabled(model.busy).font(.callout)
                }
                HStack(spacing: 12) {
                    Button("Inspect \(model.platform?.fileExtension.uppercased() ?? "Package")") { model.inspect() }
                        .disabled(model.package == nil || model.busy)
                    Spacer()
                    Button { model.install() } label: { Label("Install on Device", systemImage: "arrow.down.to.line") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canInstall)
                }
                HStack(alignment: .top, spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.failed ? "exclamationmark.triangle.fill" : "info.circle").foregroundStyle(model.failed ? Color.orange : Color.secondary) }
                    Text(model.status).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                if inPopover {
                    if showMenuBarDiagnostics { diagnostics }
                } else {
                    DisclosureGroup("Diagnostics", isExpanded: $showWindowDiagnostics) {
                        diagnosticsLog.padding(.top, 8)
                    }
                }
                Text("Local installation · No re-signing · No app removal · No security bypasses").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(12)
        }
        .task { if !invitingDrop && model.appleStatus == "Not checked" && !model.busy { model.refresh() } }
        .onChange(of: model.selectedID) { _, _ in model.targetChanged() }

    }

    private var dropTitle: String {
        if invitingDrop { return "Drop me here" }
        if let name = model.package?.lastPathComponent { return name }
        return inPopover ? "Drag & drop your IPA or APK here" : "Drop me here"
    }

    private var dropArea: some View {
        VStack(spacing: 8) {
            Button { model.pick() } label: {
                VStack(spacing: 8) {
                    Image(systemName: invitingDrop || model.package == nil ? "square.and.arrow.down" : "shippingbox").font(.system(size: 30)).foregroundStyle(.tint)
                    Text(dropTitle).font(.headline).lineLimit(2)
                    Text(invitingDrop || model.package == nil ? "iPhone / iPad (.ipa)  ·  Android (.apk)" : "\(model.platform?.rawValue ?? "") · Click to choose another file").font(.callout).foregroundStyle(.secondary)
                    if model.package == nil && !invitingDrop { Text("or click to browse").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy)
            if model.package != nil { Button("Remove file selection") { model.clearPackage() }.buttonStyle(.link).disabled(model.busy) }
        }.padding(.bottom, model.package == nil ? 0 : 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(dropHighlighted ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropHighlighted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [6,4])).allowsHitTesting(false))
        .onDrop(of: [UTType.fileURL], isTargeted: $hovering, perform: acceptDrop)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
            guard !model.busy else { return false }
            guard providers.count == 1, let provider = providers.first else {
                model.report(InstallError(message: "Drop one IPA or APK at a time.")); return false
            }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let url: URL?
                if let direct = item as? URL { url = direct }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let string = item as? String { url = URL(string: string) }
                else { url = nil }
                Task { @MainActor in
                    guard !model.busy else { return }
                    if let url = url { _ = model.selectDropped([url]) }
                    else { model.report(InstallError(message: error?.localizedDescription ?? "Could not read dropped file. Try Browse.")) }
                }
            }
            return true
    }

    private var devicePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Target", selection: $model.selectedID) {
                        Text("Choose a device").tag("")
                        ForEach(model.compatible) { d in
                            Text("\(d.name) · \(d.platform.rawValue)\(d.available ? "" : " · Not ready")").tag(d.id)
                        }
                    }.disabled(model.busy || model.compatible.isEmpty)
                    Spacer()
                    Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.busy)
                }
                if let d = model.compatible.first(where: { $0.id == model.selectedID }) {
                    Text("\(d.model) · \(d.version) · \(d.connection)").font(.subheadline)
                    Text(d.statusText).font(.caption).foregroundStyle(d.available ? Color.secondary : Color.orange)
                    Text(d.deviceID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text(model.platform == nil ? "Drop a package to filter compatible devices." : "Connect or authorize a compatible \(model.platform?.rawValue ?? "") device.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                statusLine("Apple", model.appleStatus, icon: "iphone")
                statusLine("Android", model.androidStatus, icon: "cable.connector")
                ViewThatFits(in: .horizontal) {
                    HStack { adbControls }
                    VStack(alignment: .leading) { adbControls }
                }.font(.caption)
                if let adb = model.adb { Text(adb).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(adb) }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Connected devices", systemImage: "iphone.gen3") }
    }
    @ViewBuilder private var adbControls: some View {
        Button("Locate ADB…") { model.locateADB() }.disabled(model.busy)
        if model.customADB != nil {
            Button("Auto-detect ADB") { model.resetADB() }.disabled(model.busy)
        }
        Link("Get Platform-Tools", destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!)
    }
    private func statusLine(_ name: String, _ status: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(.secondary)
            Text(name).font(.caption.weight(.semibold)).frame(width: 52, alignment: .leading)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(status)
            Spacer(minLength: 0)
        }
    }
    @ViewBuilder private func details(_ info: Inspection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            switch info {
            case .apple(let item):
                Text("\(item.name) · \(item.version)").font(.headline)
                Text(item.bundleID).font(.caption.monospaced())
                Text("Minimum OS: \(item.minimumOS) · Team: \(item.team) · Profile expires: \(item.expiration.formatted(date: .abbreviated, time: .omitted))").font(.caption)
            case .android(let item):
                Text(item.name).font(.headline)
                Text("\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(item.entries) archive entries · Android manifest present").font(.caption)
                Text("Preliminary archive check only; Android verifies signing and compatibility.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            logContents(showTitle: true)
        }
    }

    private var diagnosticsLog: some View { logContents(showTitle: false) }

    private func logContents(showTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if showTitle { Text("Diagnostics").font(.headline) }
                Spacer()
                Button("Copy Log") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.log, forType: .string) }
                Button("Clear") { model.log = "Ready.\n" }
            }
            ScrollView { Text(model.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                .frame(height: 76).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
