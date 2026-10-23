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

    // MARK: - Forward secrecy (X25519)

    private func secret(_ a: Curve25519.KeyAgreement.PrivateKey,
                        _ b: Curve25519.KeyAgreement.PublicKey) -> Data {
        let s = try! a.sharedSecretFromKeyAgreement(with: b)
        return s.withUnsafeBytes { Data($0) }
    }

    func testX25519AgreementIsSymmetric() {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertEqual(secret(a, b.publicKey), secret(b, a.publicKey))
        XCTAssertNotEqual(secret(a, b.publicKey), secret(a, Curve25519.KeyAgreement.PrivateKey().publicKey))
    }

    func testSessionKeysDependOnEphemeralSecret() {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let shared = secret(a, b.publicKey)

        let plain = deriveSessionKeys(psk: psk, nonce: nonce)
        let upgraded = deriveSessionKeys(psk: psk, nonce: nonce, extra: shared)
        XCTAssertNotEqual(plain.c2s.withUnsafeBytes { Data($0) },
                          upgraded.c2s.withUnsafeBytes { Data($0) },
                          "the PSK alone must not yield the session key any more")

        // A different session (fresh ephemeral pair) gives different keys even
        // with the same PSK and nonce.
        let c = Curve25519.KeyAgreement.PrivateKey()
        let other = deriveSessionKeys(psk: psk, nonce: nonce, extra: secret(a, c.publicKey))
        XCTAssertNotEqual(upgraded.c2s.withUnsafeBytes { Data($0) },
                          other.c2s.withUnsafeBytes { Data($0) })
    }

    func testRekeyedStreamsStayAlignedInBothDirections() throws {
        // Mirrors the wire roles: the client sends with c2s and reads with s2c,
        // the server the other way round (this is the bug that made the first
        // re-keyed packet fail to decrypt once).
        let clientPair = Curve25519.KeyAgreement.PrivateKey()
        let serverPair = Curve25519.KeyAgreement.PrivateKey()
        let shared = secret(clientPair, serverPair.publicKey)

        let keys = deriveSessionKeys(psk: psk, nonce: nonce, extra: shared)
        let clientOut = SessionCipher(key: keys.c2s)
        let clientIn = SessionCipher(key: keys.s2c)
        let serverIn = SessionCipher(key: keys.c2s)
        let serverOut = SessionCipher(key: keys.s2c)

        for i in 0..<20 {
            let c2s = packet(type: .input, flags: 0, ptsMicros: Int64(i), payload: Data([UInt8(i)]))
            let sealedC2S = clientOut.seal(c2s)
            let openedC2S = try serverIn.open(header: Data(sealedC2S.prefix(HEADER_SIZE)),
                                              body: Data(sealedC2S.dropFirst(HEADER_SIZE)))
            XCTAssertEqual(openedC2S, Data([UInt8(i)]))

            let s2c = packet(type: .frame, flags: 0, ptsMicros: Int64(i), payload: Data([UInt8(i), 1]))
            let sealedS2C = serverOut.seal(s2c)
            let openedS2C = try clientIn.open(header: Data(sealedS2C.prefix(HEADER_SIZE)),
                                              body: Data(sealedS2C.dropFirst(HEADER_SIZE)))
            XCTAssertEqual(openedS2C, Data([UInt8(i), 1]))
        }
    }
}
