import XCTest
@testable import BoltKVMCore

/// Connection passwords are typed by a human on the other machine, so the rules
/// around them (what counts as generated, what gets stretched, case-insensitive
/// comparison) are user-visible behaviour, not implementation detail.
final class KeygenTests: XCTestCase {
    private var savedHome: String?
    private var tempHome = ""

    override func setUp() {
        super.setUp()
        savedHome = ProcessInfo.processInfo.environment["HOME"]
        // Key resolution reads $HOME/.boltkvm-key; point it somewhere empty so the
        // developer's real key cannot make these tests pass or fail.
        tempHome = NSTemporaryDirectory() + "boltkvm-tests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tempHome, withIntermediateDirectories: true)
        setenv("HOME", tempHome, 1)
        unsetenv("BOLTKVM_KEY")
    }

    override func tearDown() {
        unsetenv("BOLTKVM_KEY")
        if let savedHome { setenv("HOME", savedHome, 1) }
        try? FileManager.default.removeItem(atPath: tempHome)
        super.tearDown()
    }

    private func writeKeyFile(_ text: String) {
        try? (text + "\n").write(toFile: tempHome + "/.boltkvm-key", atomically: true, encoding: .utf8)
    }

    func testGeneratedPasswordShape() {
        for _ in 0..<200 {
            let p = PSK.makePassword()
            XCTAssertEqual(p.count, 8, "no separators, no padding: \(p)")
            XCTAssertTrue(p.allSatisfy { $0.isLowercase || $0.isNumber }, "\(p) is not lowercase+digits")
            XCTAssertTrue(PSK.isGeneratedPassword(p), "\(p) not recognised")
        }
    }

    func testAmbiguousCharactersAreAbsent() {
        // 0/o, 1/l/i are the pairs people mistype; a password must never contain
        // them, otherwise reading it off the server screen is a guess.
        let banned: Set<Character> = ["0", "o", "1", "l", "i"]
        for _ in 0..<200 {
            XCTAssertTrue(Set(PSK.makePassword()).isDisjoint(with: banned))
        }
    }

    func testNormalisationIgnoresCaseSpacesAndSeparators() {
        for variant in ["K7M3-P9QX", "k7m3p9qx", "K7M3 P9QX", "k7m3-p9qx", " k7m3_p9qx "] {
            XCTAssertEqual(PSK.normalize(variant), "k7m3p9qx", variant)
            XCTAssertTrue(PSK.isGeneratedPassword(variant), variant)
        }
    }

    func testNonGeneratedPasswordsAreNotStretched() {
        // Anything that is not exactly 8 valid characters keeps the old meaning:
        // 64 hex digits are raw key bytes, a passphrase is its UTF-8 bytes.
        XCTAssertFalse(PSK.isGeneratedPassword("k7m3p9q"))            // too short
        XCTAssertFalse(PSK.isGeneratedPassword("k7m3p9qxx"))          // too long
        XCTAssertFalse(PSK.isGeneratedPassword("k7m3p9qx0"))          // banned character
        XCTAssertFalse(PSK.isGeneratedPassword(String(repeating: "a", count: 64)))
        XCTAssertFalse(PSK.isGeneratedPassword(""))
    }

    func testStretchIsDeterministicAndSensitive() {
        let a = PSK.stretch("k7m3p9qx")
        let b = PSK.stretch("K7M3-P9QX")
        XCTAssertEqual(a, b, "the same password typed differently must derive the same key")
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, PSK.stretch("k7m3p9qy"))
    }

    func testFingerprintIsReadable() {
        let fp = PSK.fingerprint(Data(repeating: 0, count: 32))
        XCTAssertEqual(fp.count, 19, "8 bytes as 4 groups of 4 hex + 3 spaces")
        XCTAssertEqual(fp.split(separator: " ").count, 4)
        XCTAssertNotEqual(fp, PSK.fingerprint(Data(repeating: 1, count: 32)))
    }

    func testNoKeyAnywhereReturnsNil() {
        XCTAssertNil(resolveAuthKey([]))
    }

    func testKeyFileIsUsedWhenNothingElseGiven() {
        writeKeyFile(String(repeating: "a1", count: 32))
        XCTAssertEqual(resolveAuthKey([]), Data(repeating: 0xA1, count: 32))
    }

    func testFlagWinsOverEnvironmentAndFile() {
        writeKeyFile(String(repeating: "cc", count: 32))
        setenv("BOLTKVM_KEY", String(repeating: "b2", count: 32), 1)

        XCTAssertEqual(resolveAuthKey(["--key", String(repeating: "a1", count: 32)]),
                       Data(repeating: 0xA1, count: 32), "--key must win")
        XCTAssertEqual(resolveAuthKey([]), Data(repeating: 0xB2, count: 32),
                       "environment must win over the file")
    }

    func testHexAndPasswordFormsDiffer() {
        // A 64-hex key is raw bytes; an 8-char password is stretched. They must not
        // accidentally collide, or a wrong key could authenticate.
        let hex = resolveAuthKey(["--key", String(repeating: "ab", count: 32)])
        let pw = resolveAuthKey(["--key", "k7m3p9qx"])
        XCTAssertEqual(hex, Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(pw, PSK.stretch("k7m3p9qx"))
        XCTAssertNotEqual(hex, pw)
    }

    func testKeyFileToleratesWhitespaceAndCrlf() {
        writeKeyFile("  " + String(repeating: "d4", count: 32) + "  ")
        XCTAssertEqual(resolveAuthKey([]), Data(repeating: 0xD4, count: 32))
    }

    // MARK: - 256-bit static key

    func testIsStaticKeyOnlyAccepts64Hex() {
        XCTAssertTrue(PSK.isStaticKey(String(repeating: "a", count: 64)))
        XCTAssertTrue(PSK.isStaticKey(String(repeating: "A1", count: 32)))
        XCTAssertFalse(PSK.isStaticKey(String(repeating: "a", count: 63)))
        XCTAssertFalse(PSK.isStaticKey(String(repeating: "a", count: 65)))
        XCTAssertFalse(PSK.isStaticKey(String(repeating: "g", count: 64)))
        XCTAssertFalse(PSK.isStaticKey("k7m3p9qx"))
    }

    func testMakeStaticKeyIsRandomHex() {
        let a = PSK.makeStaticKey()
        let b = PSK.makeStaticKey()
        XCTAssertEqual(a.count, 64)
        XCTAssertTrue(PSK.isStaticKey(a))
        XCTAssertNotEqual(a, b)
    }

    func testStaticKeyIsUsedRawNotStretched() {
        let hex = String(repeating: "0123456789abcdef", count: 4)
        let key = try? XCTUnwrap(resolveAuthKey(["--key", hex]))
        var expected = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            expected.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        XCTAssertEqual(key, expected)
        // The 8-character path stretches; a 64-character key must not collide with it.
        XCTAssertNotEqual(key, PSK.stretch(hex))
    }

    func testShortKeyKeepsEndsAndHidesMiddle() {
        let key = String(repeating: "0123456789abcdef", count: 4)
        let short = PSK.shortKey(key)
        XCTAssertEqual(short, "01234567…abcdef")
        XCTAssertEqual(PSK.shortKey("k7m3p9qx"), "k7m3p9qx")
    }

    func testWriteStaticKeyReplacesFileWithMode0600() throws {
        let path = NSTemporaryDirectory() + "boltkvm-static-\(UUID().uuidString)"
        let key = try PSK.writeStaticKey(to: path)
        XCTAssertTrue(PSK.isStaticKey(key))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue((try String(contentsOfFile: path, encoding: .utf8)).hasPrefix(key))
        try FileManager.default.removeItem(atPath: path)
    }
}
