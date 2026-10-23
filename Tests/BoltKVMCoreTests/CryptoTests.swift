import XCTest
import CryptoKit
@testable import BoltKVMCore

/// The transport is authenticated encryption with a per-direction key; these
/// tests pin the properties the protocol actually relies on (both ends stay in
/// step, tampering anywhere is rejected) rather than implementation details.
final class CryptoTests: XCTestCase {
    private let psk = Data((0..<32).map { UInt8($0) })
    private let nonce = Data(repeating: 0x5A, count: 32)

    func testDerivedKeysAreDeterministicAndDistinct() {
        let a = deriveSessionKeys(psk: psk, nonce: nonce)
        let b = deriveSessionKeys(psk: psk, nonce: nonce)
        let aBytes = a.c2s.withUnsafeBytes { Data($0) }
        let bBytes = b.c2s.withUnsafeBytes { Data($0) }
        let s2cBytes = a.s2c.withUnsafeBytes { Data($0) }

        XCTAssertEqual(aBytes, bBytes, "same inputs must derive the same key")
        XCTAssertNotEqual(aBytes, s2cBytes, "directions must not share a key")
        XCTAssertEqual(aBytes.count, 32)
    }

    func testDerivedKeysDependOnNonceAndKey() {
        let base = deriveSessionKeys(psk: psk, nonce: nonce)
        let otherNonce = deriveSessionKeys(psk: psk, nonce: Data(repeating: 0x01, count: 32))
        let otherKey = deriveSessionKeys(psk: Data(repeating: 0x11, count: 32), nonce: nonce)

        let a = base.c2s.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(a, otherNonce.c2s.withUnsafeBytes { Data($0) })
        XCTAssertNotEqual(a, otherKey.c2s.withUnsafeBytes { Data($0) })
    }

    func testSealOpenRoundTrip() throws {
        let keys = deriveSessionKeys(psk: psk, nonce: nonce)
        let sender = SessionCipher(key: keys.c2s)
        let receiver = SessionCipher(key: keys.c2s)

        for i in 0..<50 {
            let body = Data((0..<(i * 7 % 300)).map { UInt8($0 % 251) })
            let frame = packet(type: .frame, flags: 0, ptsMicros: Int64(i), payload: body)
            let sealed = sender.seal(frame)

            // The header stays readable (framing needs length/type), but the
            // encrypted flag must be set and the length must cover tag+ciphertext.
            let header = Data(sealed.prefix(HEADER_SIZE))
            XCTAssertNotEqual(header[6] & FLAG_ENCRYPTED, 0)
            XCTAssertEqual(Int(header.readUInt32BE(8)), body.count + 16)
            XCTAssertEqual(sealed.count, HEADER_SIZE + body.count + 16)

            let opened = try receiver.open(header: header, body: Data(sealed.dropFirst(HEADER_SIZE)))
            XCTAssertEqual(opened, body, "frame \(i) did not survive the round trip")
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let keys = deriveSessionKeys(psk: psk, nonce: nonce)
        let sender = SessionCipher(key: keys.c2s)
        let receiver = SessionCipher(key: keys.c2s)

        let sealed = sender.seal(packet(type: .frame, flags: 0, ptsMicros: 0, payload: Data(repeating: 7, count: 64)))
        var body = Data(sealed.dropFirst(HEADER_SIZE))
        body[0] ^= 0x01
        XCTAssertThrowsError(try receiver.open(header: Data(sealed.prefix(HEADER_SIZE)), body: body))
    }

    func testTamperedHeaderIsRejected() throws {
        let keys = deriveSessionKeys(psk: psk, nonce: nonce)
        let sender = SessionCipher(key: keys.c2s)
        let receiver = SessionCipher(key: keys.c2s)

        let sealed = sender.seal(packet(type: .frame, flags: 0, ptsMicros: 0, payload: Data(repeating: 7, count: 16)))
        var header = Data(sealed.prefix(HEADER_SIZE))
        header[5] = PacketType.input.rawValue          // header is AAD: changing type must fail
        let body = Data(sealed.dropFirst(HEADER_SIZE))
        XCTAssertThrowsError(try receiver.open(header: header, body: body))
    }

    func testWrongKeyIsRejected() throws {
        let keys = deriveSessionKeys(psk: psk, nonce: nonce)
        let stranger = deriveSessionKeys(psk: Data(repeating: 0x99, count: 32), nonce: nonce)
        let sealed = SessionCipher(key: keys.c2s)
            .seal(packet(type: .frame, flags: 0, ptsMicros: 0, payload: Data([1, 2, 3])))

        let receiver = SessionCipher(key: stranger.c2s)
        XCTAssertThrowsError(try receiver.open(header: Data(sealed.prefix(HEADER_SIZE)),
                                               body: Data(sealed.dropFirst(HEADER_SIZE))))
    }

    func testShortBodyIsRejected() {
        let cipher = SessionCipher(key: deriveSessionKeys(psk: psk, nonce: nonce).c2s)
        XCTAssertThrowsError(try cipher.open(header: Data(repeating: 0, count: HEADER_SIZE),
                                             body: Data([0, 1, 2])))
    }

    func testAuthMacRoundTrip() {
        let mac = authMAC(key: psk, nonce: nonce)
        XCTAssertEqual(mac.count, 32)
        XCTAssertTrue(authMACMatches(mac, authMAC(key: psk, nonce: nonce)))
        XCTAssertFalse(authMACMatches(mac, authMAC(key: psk, nonce: Data(repeating: 1, count: 32))))
        XCTAssertFalse(authMACMatches(mac, Data()), "different lengths must not compare equal")
        var flipped = mac
        flipped[0] ^= 0x01
        XCTAssertFalse(authMACMatches(mac, flipped))
    }
}
