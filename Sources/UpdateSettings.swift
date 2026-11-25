import SwiftUI

@MainActor struct UpdateSettings: View {
    @AppStorage("updateRepository") private var savedRepository = ""
    @StateObject private var checker = UpdateChecker()
    private var bundledRepository: String {
        Bundle.main.object(forInfoDictionaryKey: "UpdateRepository") as? String ?? ""
    }
    private var repository: String { bundledRepository.isEmpty ? savedRepository : bundledRepository }

    var body: some View {
        Section("Updates") {
            if bundledRepository.isEmpty {
                TextField("GitHub release source", text: $savedRepository, prompt: Text("owner/repository"))
                    .disabled(checker.checking)
                    .onChange(of: savedRepository) { _, _ in checker.reset() }
            }
            HStack {
                Button("Check for Updates") { checker.check(repository: repository) }
                    .disabled(checker.checking || !UpdateChecker.validRepository(repository))
                if checker.checking {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { checker.cancel() }
                }
                if let release = checker.release { Link("Open Release", destination: release) }
            }
            if !checker.message.isEmpty { Text(checker.message).font(.callout) }
            Text("Checks only when you ask. Your IPA and APK files are never uploaded.")
                .font(.callout).foregroundStyle(.secondary)
        }.onDisappear { if checker.checking { checker.cancel() } }
    }
}

@MainActor final class UpdateChecker: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var message = ""
    @Published private(set) var release: URL?
    private var task: Task<Void, Never>?
    private var session: URLSession?

    nonisolated static func validRepository(_ value: String) -> Bool {
        value.range(of: #"\A[A-Za-z0-9-]+/[A-Za-z0-9_.-]+\z"#, options: .regularExpression) != nil &&
            !value.hasSuffix("/.") && !value.hasSuffix("/..")
    }

    func reset() { release = nil; message = "" }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        checking = false
        release = nil
        message = "Update check canceled. You can keep working offline."
    }

    func check(repository: String) {
        guard !checking, Self.validRepository(repository),
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return }
        reset()
        checking = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        self.session = session
        task = Task { [weak self] in
            defer { session.invalidateAndCancel() }
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let self else { return }
                self.finish()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    self.message = "No release could be checked. Verify the public repository and try again."
                    return
                }
                let info = try JSONDecoder().decode(ReleaseInfo.self, from: data)
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                guard let comparison = Self.compare(info.tag_name, current) else {
                    self.message = "The latest release tag is not a supported version number."
                    return
                }
                if comparison == .orderedDescending {
                    self.release = URL(string: "https://github.com/\(repository)/releases/tag/\(info.tag_name)")
                    self.message = "Version \(info.tag_name) is available. Open the release to download it."
                } else {
                    self.message = "You have the latest version."
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.finish()
                self.message = "Couldn’t check for updates. You can keep working offline."
            }
        }
    }

    nonisolated static func compare(_ candidate: String, _ current: String) -> ComparisonResult? {
        func parse(_ value: String) -> [Int]? {
            let version = value.hasPrefix("v") ? String(value.dropFirst()) : value
            guard version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil else { return nil }
            let numbers = version.split(separator: ".").compactMap { Int($0) }
            return numbers.count == 3 ? numbers : nil
        }
        guard let lhs = parse(candidate), let rhs = parse(current) else { return nil }
        for (a, b) in zip(lhs, rhs) where a != b { return a > b ? .orderedDescending : .orderedAscending }
        return .orderedSame
    }

    private func finish() {
        checking = false
        task = nil
        session = nil
    }

    private struct ReleaseInfo: Decodable { let tag_name: String }
}
