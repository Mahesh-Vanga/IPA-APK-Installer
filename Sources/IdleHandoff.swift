import Foundation

struct IdleHandoff {
    static let argument = "--resume-menu-bar"
    let id: UUID
    private var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("IPAInstaller-Idle-" + id.uuidString, isDirectory: true)
    }

    static var isContinuation: Bool { CommandLine.arguments.dropFirst().first == argument }

    static var fromArguments: IdleHandoff? {
        guard isContinuation, CommandLine.arguments.count == 3,
              let id = UUID(uuidString: CommandLine.arguments[2]) else { return nil }
        return IdleHandoff(id: id)
    }

    static func create(with snapshot: Data) throws -> IdleHandoff {
        let handoff = IdleHandoff(id: UUID())
        try FileManager.default.createDirectory(at: handoff.directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            try snapshot.write(to: handoff.directory.appendingPathComponent("state"), options: [.atomic])
            return handoff
        } catch {
            handoff.remove()
            throw error
        }
    }

    func readSnapshot() throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("state"))
    }

    func signal(_ name: String) throws {
        try Data().write(to: directory.appendingPathComponent(name), options: [.atomic])
    }

    func waitFor(_ name: String) async throws {
        let location = directory.appendingPathComponent(name)
        for _ in 0..<200 {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: location.path) { return }
            guard FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileNoSuchFile) }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CocoaError(.fileReadUnknown)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
