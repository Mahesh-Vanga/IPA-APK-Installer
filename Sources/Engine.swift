import Foundation

struct InstallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Platform: String, Sendable, Codable {
    case apple = "iOS / iPadOS"
    case android = "Android"
    var fileExtension: String { self == .apple ? "ipa" : "apk" }
}

struct Device: Identifiable, Sendable, Codable {
    let platform: Platform
    let deviceID: String
    var id: String { platform.rawValue + ":" + deviceID }
    let name: String
    let model: String
    let version: String
    let udid: String?
    let connection: String
    let developerMode: String
    let paired: String
    let state: String
    var available: Bool {
        if platform == .android { return state == "device" }
        return !["unpaired", "notpaired", "disconnected", "unavailable"].contains(paired.lowercased()) &&
            !["unavailable", "disconnected", "offline"].contains(state.lowercased())
    }
    var statusText: String {
        if platform == .android {
            switch state {
            case "device": return "Authorized"
            case "unauthorized": return "Unlock Android and approve USB debugging"
            case "offline": return "Offline — reconnect the device"
            default: return "ADB state: \(state)"
            }
        }
        return "Pairing: \(paired) · Developer Mode: \(developerMode)"
    }
}

struct CommandResult: Sendable {
    let status: Int32
    let output: Data
    let errors: Data
    var text: String {
        [String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
    func checked(_ action: String) throws -> CommandResult {
        guard status == 0 else {
            throw InstallError(message: "\(action) failed (exit \(status)).\n\(text)")
        }
        return self
    }
}

struct PackageInfo: Sendable, Codable {
    let name: String
    let bundleID: String
    let version: String
    let minimumOS: String
    let team: String
    let expiration: Date
    let app: URL
}

// No shell interpolation or credential storage. Each task owns a private scratch directory.
enum Engine {
    static let fm = FileManager.default
    static func scratch() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("IPAInstaller-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func run(_ executable: String, _ args: [String], in work: URL) throws -> CommandResult {
        let id = UUID().uuidString
        let stdout = work.appendingPathComponent(id + ".stdout")
        let stderr = work.appendingPathComponent(id + ".stderr")
        guard fm.createFile(atPath: stdout.path, contents: nil), fm.createFile(atPath: stderr.path, contents: nil) else {
            throw InstallError(message: "Unable to create private diagnostic files.")
        }
        defer { try? fm.removeItem(at: stdout); try? fm.removeItem(at: stderr) }
        let out = try FileHandle(forWritingTo: stdout)
        defer { try? out.close() }
        let err = try FileHandle(forWritingTo: stderr)
        defer { try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: try Data(contentsOf: stdout, options: .mappedIfSafe), errors: try Data(contentsOf: stderr, options: .mappedIfSafe))
    }
    static func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }; return s
    }
    static func appleDevices() throws -> [Device] {
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        _ = try run("/usr/bin/xcrun", ["--find", "devicectl"], in: dir).checked("Finding devicectl. Install full Xcode and select its developer directory")
        let json = dir.appendingPathComponent("devices.json")
        _ = try run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", json.path], in: dir).checked("Discovering devices")
        let root = dictionary(try JSONSerialization.jsonObject(with: Data(contentsOf: json)))
        let result = dictionary(root["result"])
        guard let records = result["devices"] as? [[String: Any]] else {
            throw InstallError(message: "Unexpected device list format. Update Xcode or this installer.")
        }
        return records.compactMap { row in
            let properties = dictionary(row["properties"])
            let hardware = dictionary(row["hardwareProperties"])
            let software = dictionary(row["deviceProperties"])
            let connection = dictionary(row["connectionProperties"])
            func field(_ keys: [String], _ groups: [[String: Any]]) -> String? {
                for group in groups { for key in keys { if let value = string(group[key]) { return value } } }; return nil
            }
            let platform = field(["platform", "operatingSystem", "os"], [properties, hardware, row]) ?? ""
            let model = field(["marketingName", "modelName", "productType", "deviceType"], [properties, hardware, row]) ?? "Apple device"
            let label = (platform + " " + model).lowercased()
            guard label.contains("ios") || label.contains("ipados") || label.contains("iphone") || label.contains("ipad") else { return nil }
            guard let id = field(["identifier", "udid", "deviceIdentifier"], [row, properties, hardware]) else { return nil }
            return Device(platform: .apple, deviceID: id,
                          name: field(["name", "deviceName"], [properties, software, row]) ?? model,
                          model: model,
                          version: field(["osVersionNumber", "osVersion", "operatingSystemVersion"], [properties, software, row]) ?? "Unknown OS",
                          udid: field(["udid"], [properties, hardware, row]),
                          connection: field(["transportType", "connectionType", "tunnelState"], [properties, connection, row]) ?? "Unknown",
                          developerMode: field(["developerModeStatus"], [properties, software]) ?? "Unknown",
                          paired: field(["pairingState"], [properties, connection]) ?? "Unknown",
                          state: field(["state", "connectionState"], [connection, row]) ?? "Unknown")
        }
    }
    static func older(_ actual: String, than required: String) -> Bool {
        func components(_ text: String) -> [Int] {
            text.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let a = components(actual), b = components(required)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y }
        }
        return false
    }
    static func package(_ ipa: URL, target: Device?, in dir: URL) throws -> PackageInfo {
        guard ipa.pathExtension.lowercased() == "ipa" else { throw InstallError(message: "Select an .ipa file.") }
        // Copy to private staging so extraction and installation use the same file.
        let source = dir.appendingPathComponent("Input.ipa")
        try fm.copyItem(at: ipa, to: source)
        let listing = try run("/usr/bin/unzip", ["-Z1", source.path], in: dir).checked("Reading IPA archive")
        let entries = String(decoding: listing.output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        guard !entries.isEmpty, entries.allSatisfy({ entry in
            !entry.hasPrefix("/") && !entry.contains("\\") && !entry.split(separator: "/").contains("..")
        }) else { throw InstallError(message: "Archive contains unsafe file paths.") }
        let details = try run("/usr/bin/unzip", ["-Z", "-l", source.path], in: dir).checked("Checking IPA archive")
        guard !String(decoding: details.output, as: UTF8.self).split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("l") }) else {
            throw InstallError(message: "IPA contains symbolic links; this version accepts ordinary self-built iOS packages only.")
        }
        let output = dir.appendingPathComponent("Extracted", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        _ = try run("/usr/bin/ditto", ["-x", "-k", source.path, output.path], in: dir).checked("Extracting IPA")
        let payload = output.appendingPathComponent("Payload", isDirectory: true)
        let apps = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter { $0.pathExtension.lowercased() == "app" }
        guard apps.count == 1, let app = apps.first,
              try app.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw InstallError(message: "Expected exactly one top-level iOS application in Payload.")
        }
        let info = dictionary(try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), options: [], format: nil))
        guard let bundleID = string(info["CFBundleIdentifier"]), info["CFBundlePackageType"] as? String == "APPL",
              (info["CFBundleSupportedPlatforms"] as? [String])?.contains("iPhoneOS") == true else {
            throw InstallError(message: "Not an iPhone/iPad device app. Simulator and macOS builds cannot be installed on an iPhone.")
        }
        _ = try run("/usr/bin/codesign", ["-d", "--verbose=2", app.path], in: dir).checked("Checking code signature presence")
        let profileURL = app.appendingPathComponent("embedded.mobileprovision")
        guard fm.fileExists(atPath: profileURL.path) else {
            throw InstallError(message: "No embedded provisioning profile. Export a development or ad hoc IPA from your Xcode project.")
        }
        let decoded = try run("/usr/bin/security", ["cms", "-D", "-i", profileURL.path], in: dir).checked("Decoding provisioning profile")
        let profile = dictionary(try PropertyListSerialization.propertyList(from: decoded.output, options: [], format: nil))
        guard let expires = profile["ExpirationDate"] as? Date, expires > Date() else {
            throw InstallError(message: "The provisioning profile has expired or has no valid expiration date. Re-export your signed build.")
        }
        guard let provisioned = profile["ProvisionedDevices"] as? [String], !provisioned.isEmpty else {
            throw InstallError(message: "This installer accepts development/ad hoc IPAs provisioned for specific devices, not App Store or enterprise packages.")
        }
        if let udid = target?.udid, !provisioned.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) {
            throw InstallError(message: "The selected device is not included in this IPA's provisioning profile. Re-export for the device.")
        }
        let entitlements = dictionary(profile["Entitlements"])
        if let appID = string(entitlements["application-identifier"]), let dot = appID.firstIndex(of: ".") {
            let pattern = String(appID[appID.index(after: dot)...])
            let matches = pattern.hasSuffix("*") ? bundleID.hasPrefix(String(pattern.dropLast())) : bundleID == pattern
            guard matches else { throw InstallError(message: "Provisioning profile does not match the bundle identifier.") }
        }
        let minimum = string(info["MinimumOSVersion"]) ?? "Unknown"
        if let version = target?.version, version.first?.isNumber == true, minimum != "Unknown", older(version, than: minimum) {
            throw InstallError(message: "This IPA requires iOS/iPadOS \(minimum) or later.")
        }
        return PackageInfo(name: string(info["CFBundleDisplayName"]) ?? string(info["CFBundleName"]) ?? app.deletingPathExtension().lastPathComponent,
                           bundleID: bundleID, version: string(info["CFBundleShortVersionString"]) ?? "Unknown", minimumOS: minimum,
                           team: (profile["TeamIdentifier"] as? [String])?.first ?? "Unknown", expiration: expires, app: app)
    }
    static func inspectApple(_ ipa: URL, target: Device?) throws -> PackageInfo {
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        return try package(ipa, target: target, in: dir)
    }
    static func installApple(_ ipa: URL, target: Device) throws -> String {
        guard target.platform == .apple, target.available else { throw InstallError(message: "Select a paired Apple device.") }
        guard let target = try appleDevices().first(where: { $0.id == target.id && $0.available }) else { throw InstallError(message: "Apple device is no longer available. Refresh and reconnect.") }
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        let item = try package(ipa, target: target, in: dir)
        let result = try run("/usr/bin/xcrun", ["devicectl", "device", "install", "app", "--device", target.deviceID, item.app.path], in: dir).checked("Installing \(item.name)")
        return "Installed \(item.name) (\(item.bundleID)) on \(target.name).\n\(result.text)"
    }
}


struct Discovery: Sendable {
    let devices: [Device]
    let appleStatus: String
    let androidStatus: String
    let adbPath: String?
}

struct APKInfo: Sendable, Codable {
    let name: String
    let size: Int64
    let entries: Int
}

enum Inspection: Sendable, Codable {
    case apple(PackageInfo)
    case android(APKInfo)
}

extension Engine {
    static func adbPath(custom: String?) -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [String] = []
        // Explicitly selected tool wins; an invalid explicit path is not silently replaced.
        if let custom = custom, !custom.isEmpty {
            return URL(fileURLWithPath: custom).lastPathComponent == "adb" && fm.isExecutableFile(atPath: custom) ? custom : nil
        }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = env[key], !sdk.isEmpty { candidates.append(URL(fileURLWithPath: sdk).appendingPathComponent("platform-tools/adb").path) }
        }
        candidates += [home.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path,
                       home.appendingPathComponent("Android/Sdk/platform-tools/adb").path,
                       home.appendingPathComponent("platform-tools/adb").path,
                       home.appendingPathComponent("Downloads/platform-tools/adb").path,
                       "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        for dir in (env["PATH"] ?? "").split(separator: ":") where dir.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("adb").path)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static func parseADBDevices(_ output: String) -> [Device] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*"), !line.hasPrefix("adb:") else { return nil }
            let state = fields[1]
            guard ["device", "unauthorized", "offline", "recovery", "sideload", "bootloader", "no", "authorizing", "connecting", "rescue"].contains(state) else { return nil }
            let serial = fields[0]
            let model = fields.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? "Android device"
            let transport = serial.hasPrefix("emulator-") ? "Emulator" : (fields.contains { $0.hasPrefix("usb:") } ? "USB" : (serial.contains(":") || serial.contains("._adb-tls-") ? "Wireless" : "ADB"))
            return Device(platform: .android, deviceID: serial, name: model == "Android device" ? serial : model,
                          model: model, version: "Android", udid: nil, connection: transport,
                          developerMode: "USB or wireless debugging", paired: state, state: state)
        }
    }

    static func androidDevices(adb: String) throws -> [Device] {
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        let result = try run(adb, ["devices", "-l"], in: dir).checked("Discovering Android devices")
        return parseADBDevices(String(decoding: result.output, as: UTF8.self))
    }

    static func discover(customADB: String?) -> Discovery {
        var list: [Device] = []
        var appleStatus: String
        var androidStatus: String
        do {
            let apple = try appleDevices()
            list += apple
            appleStatus = apple.isEmpty ? "No Apple devices found. Connect, unlock and trust this Mac." : "\(apple.count) Apple device(s) found."
        } catch { appleStatus = "Apple discovery unavailable: \(error.localizedDescription)" }
        let adb = adbPath(custom: customADB)
        if let adb = adb {
            do {
                let android = try androidDevices(adb: adb)
                list += android
                androidStatus = android.isEmpty ? "No Android devices found. Enable USB debugging and connect." : "\(android.count) Android device(s) found."
            } catch { androidStatus = "Android discovery unavailable: \(error.localizedDescription)" }
        } else { androidStatus = "ADB not found. Install Google Platform-Tools or locate your existing adb." }
        return Discovery(devices: list, appleStatus: appleStatus, androidStatus: androidStatus, adbPath: adb)
    }

    // APKs are not extracted. A private copy is used for inspection and installation.
    static func stageAPK(_ url: URL, in dir: URL) throws -> (URL, APKInfo) {
        guard url.pathExtension.lowercased() == "apk", url.isFileURL,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw InstallError(message: "Select a regular .apk file.")
        }
        let staged = dir.appendingPathComponent("Input.apk")
        try fm.copyItem(at: url, to: staged)
        let result = try run("/usr/bin/unzip", ["-Z1", staged.path], in: dir).checked("Reading APK archive")
        let entries = String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard entries.filter({ $0 == "AndroidManifest.xml" }).count == 1 else {
            throw InstallError(message: "Not a standalone Android APK: AndroidManifest.xml is missing or duplicated.")
        }
        let size = Int64(try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return (staged, APKInfo(name: url.lastPathComponent, size: size, entries: entries.count))
    }

    static func inspectAPK(_ url: URL) throws -> APKInfo {
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        return try stageAPK(url, in: dir).1
    }

    static func installAPK(_ url: URL, target: Device, adb: String, allowTest: Bool) throws -> String {
        guard target.platform == .android, target.available else { throw InstallError(message: "Choose an authorized Android device.") }
        guard let _ = try androidDevices(adb: adb).first(where: { $0.id == target.id && $0.available }) else {
            throw InstallError(message: "Android device is no longer authorized or connected. Unlock it and refresh.")
        }
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        let (staged, info) = try stageAPK(url, in: dir)
        var args = ["-s", target.deviceID, "install", "-r"]
        if allowTest { args.append("-t") }
        args.append(staged.path)
        let result = try run(adb, args, in: dir).checked("Installing APK")
        guard result.text.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Success" }) else {
            throw InstallError(message: "ADB did not confirm installation.\n\(result.text)")
        }
        return "Installed \(info.name) on \(target.name).\n\(result.text)"
    }
}
