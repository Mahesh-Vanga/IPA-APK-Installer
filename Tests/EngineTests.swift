import Foundation

@main struct EngineTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw InstallError(message: "FAIL: \(message)") }
    }
    static func expectError(_ action: () throws -> Void, _ label: String) throws {
        var rejected = false
        do { try action() } catch { rejected = true }
        try require(rejected, label)
    }
    static func main() throws {
        let output = """
        List of devices attached
        A123 device usb:1-1 product:demo model:Pixel_Test device:demo transport_id:1
        B456 unauthorized usb:1-2 transport_id:2
        C789 offline transport_id:3
        emulator-5554 device product:sdk model:Emulator transport_id:4
        192.168.1.5:5555 device model:Tablet transport_id:5
        """
        let devices = Engine.parseADBDevices(output)
        try require(devices.count == 5, "Parse all ADB devices")
        try require(devices[0].available && devices[0].connection == "USB", "USB device readiness")
        try require(!devices[1].available && !devices[2].available, "Reject unauthorized/offline devices")
        try require(devices[3].connection == "Emulator" && devices[4].connection == "Wireless", "Transport labels")
        try require(devices[0].name == "Pixel Test", "Friendly model name")
        try require(Set(devices.map(\.id)).count == 5, "Unique target identifiers")
        try require(Engine.older("17.2", than: "18.0"), "IPA OS compatibility")
        try require(!Engine.older("18.0.1", than: "18.0"), "IPA version ordering")
        let dir = try Engine.scratch(); defer { try? Engine.fm.removeItem(at: dir) }
        let apk = dir.appendingPathComponent("test package.apk")
        let manifest = dir.appendingPathComponent("AndroidManifest.xml")
        try Data("synthetic test fixture; not an installable APK".utf8).write(to: manifest)
        _ = try Engine.run("/usr/bin/zip", ["-j", apk.path, manifest.path], in: dir).checked("Creating test fixture")
        let info = try Engine.inspectAPK(apk)
        try require(info.name == "test package.apk" && info.entries == 1 && info.size > 0, "APK archive inspection")
        let invalid = dir.appendingPathComponent("invalid.apk")
        try Data("not a zip".utf8).write(to: invalid)
        try expectError({ _ = try Engine.inspectAPK(invalid) }, "Reject malformed archive")
        let noManifest = dir.appendingPathComponent("missing.apk")
        _ = try Engine.run("/usr/bin/zip", ["-j", noManifest.path, invalid.path], in: dir).checked("Create missing-manifest fixture")
        try expectError({ _ = try Engine.inspectAPK(noManifest) }, "Reject missing manifest")
        let adb = dir.appendingPathComponent("adb")
        func mock(_ mode: String, expectedTest: Bool = false) throws {
            let testCheck = expectedTest ? "[ \"$5\" = -t ] && [ -f \"$6\" ]" : "[ \"$5\" != -t ] && [ -f \"$5\" ]"
            let script = """
            #!/bin/sh
            if [ "$1" = devices ] && [ "$2" = -l ]; then
              printf 'List of devices attached\\nA123 device usb:1-1 model:Pixel_Test\\nB456 unauthorized\\n'
              exit 0
            fi
            [ "$1" = -s ] && [ "$2" = A123 ] && [ "$3" = install ] && [ "$4" = -r ] && \(testCheck) || exit 99
            \(mode)
            """
            try Data(script.utf8).write(to: adb)
            try Engine.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        }
        try mock("printf 'Performing Streamed Install\\nSuccess\\n'")
        try require(Engine.adbPath(custom: adb.path) == adb.path, "Explicit ADB selection")
        try require(Engine.adbPath(custom: invalid.path) == nil, "Reject invalid ADB selection")
        let success = try Engine.installAPK(apk, target: devices[0], adb: adb.path, allowTest: false)
        try require(success.contains("Installed test package.apk"), "Mock install command targets selected serial and supports spaces")
        try expectError({ _ = try Engine.installAPK(apk, target: devices[1], adb: adb.path, allowTest: false) }, "Block unauthorized target")
        try expectError({ _ = try Engine.installAPK(apk, target: devices[4], adb: adb.path, allowTest: false) }, "Block disconnected target")
        try expectError({ _ = try Engine.installApple(apk, target: devices[0]) }, "Block cross-platform installation")
        try mock("printf 'Success\\n'", expectedTest: true)
        _ = try Engine.installAPK(apk, target: devices[0], adb: adb.path, allowTest: true)
        try mock("printf 'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]\\n' >&2; exit 1")
        try expectError({ _ = try Engine.installAPK(apk, target: devices[0], adb: adb.path, allowTest: false) }, "Propagate failure exit code")
        try mock("printf 'Failure [INSTALL_FAILED_INVALID_APK]\\n'; exit 0")
        try expectError({ _ = try Engine.installAPK(apk, target: devices[0], adb: adb.path, allowTest: false) }, "Do not treat exit zero without Success as success")
        print("PASS: Foundation engine tests (mock ADB and synthetic archive fixtures; no device installation performed).")
    }
}
