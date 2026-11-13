import Foundation
import Testing
import WinstonCore

/// A real bundle in a temporary folder, whose Info.plist holds `info`, as the app's does once
/// `Secrets.xcconfig` is expanded into it.
private struct TestBundle {
    let folder: URL
    let bundle: Bundle

    init(info: [String: String]) throws {
        folder = try makeTemporaryFolder()
        let url = folder.appending(path: "Secrets.bundle", directoryHint: .isDirectory)
        #if os(macOS)
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        #else
        let contents = url
        #endif
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = "com.example.winston-tests.secrets"
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        bundle = try #require(Bundle(url: url))
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Reading the Telegram API credentials from the app's Info.plist.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppSecretsTests {
    @Test func theIDAndHashAreReadFromTheBundle() throws {
        let secrets = try TestBundle(info: ["TelegramAPIID": "12345", "TelegramAPIHash": "0123456789abcdef"])
        defer { secrets.remove() }

        #expect(AppSecrets.load(from: secrets.bundle) == AppSecrets(apiID: 12345, apiHash: "0123456789abcdef"))
    }

    @Test func withoutTheKeysThereAreNoCredentials() throws {
        let secrets = try TestBundle(info: [:])
        defer { secrets.remove() }

        #expect(AppSecrets.load(from: secrets.bundle) == nil)
    }

    @Test func anIDOfZeroIsNoCredentials() throws {
        let secrets = try TestBundle(info: ["TelegramAPIID": "0", "TelegramAPIHash": "0123456789abcdef"])
        defer { secrets.remove() }

        #expect(AppSecrets.load(from: secrets.bundle) == nil)
    }

    @Test func anIDThatIsNotANumberIsNoCredentials() throws {
        // The placeholder as App/Config/Info.plist writes it, not expanded.
        let secrets = try TestBundle(info: ["TelegramAPIID": "$(TG_API_ID)", "TelegramAPIHash": "0123456789abcdef"])
        defer { secrets.remove() }

        #expect(AppSecrets.load(from: secrets.bundle) == nil)
    }

    @Test func anEmptyHashIsNoCredentials() throws {
        let secrets = try TestBundle(info: ["TelegramAPIID": "12345", "TelegramAPIHash": ""])
        defer { secrets.remove() }

        #expect(AppSecrets.load(from: secrets.bundle) == nil)
    }
}
