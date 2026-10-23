import XCTest
@testable import BoltKVMCore

/// Translation tables are user-visible UI: a missing key shows up as a raw
/// `server.panel.nokey` in the panel, and a key that exists only in one language
/// silently falls back. Both are cheap to catch here and impossible to see from
/// the server side of the app.
final class LocalizationTests: XCTestCase {
    /// Sources/ is three levels up from this file (Tests/BoltKVMCoreTests/…).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BoltKVMCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func table(_ language: String) throws -> [String: String] {
        let url = repoRoot.appendingPathComponent("Packaging/Resources/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<eq])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let value = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\";"))
            if out[key] != nil { XCTFail("duplicate key \(key) in \(language)") }
            out[key] = value
        }
        return out
    }

    func testBothLanguagesDefineTheSameKeys() throws {
        let zh = try table("zh-Hans")
        let en = try table("en")
        XCTAssertGreaterThan(zh.count, 50, "table looks truncated")
        XCTAssertEqual(Set(zh.keys).subtracting(en.keys), [], "missing in en")
        XCTAssertEqual(Set(en.keys).subtracting(zh.keys), [], "missing in zh-Hans")
    }

    func testNoEmptyTranslations() throws {
        for language in ["zh-Hans", "en"] {
            for (key, value) in try table(language) where value.trimmingCharacters(in: .whitespaces).isEmpty {
                XCTFail("\(language): \(key) is empty")
            }
        }
    }

    func testEveryKeyUsedInSourcesExists() throws {
        let zh = try table("zh-Hans")
        let sources = repoRoot.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var checked = 0

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            // L.t("key") / L.f("key", …) — the argument is always a literal in
            // this codebase (menu items pass a variable built from literals).
            let regex = try NSRegularExpression(pattern: #"L\.[tf]\("([^"]+)""#)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                let key = String(text[r])
                checked += 1
                XCTAssertNotNil(zh[key], "\(url.lastPathComponent) uses \(key), which is not in the table")
            }
        }
        XCTAssertGreaterThan(checked, 50, "regex found too few usages; did L.t change shape?")
    }

    func testMenuKeysAreTranslated() throws {
        // Built from a variable, so the scan above cannot see them.
        let zh = try table("zh-Hans")
        for key in ["menu.remote", "menu.remote.missionControl", "menu.remote.showDesktop"] {
            XCTAssertNotNil(zh[key], "\(key) missing")
            XCTAssertNotEqual(zh[key], key, "\(key) not translated")
        }
    }
}
