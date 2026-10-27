import XCTest
@testable import BoltKVMCore

/// Wire format: the two machines must agree byte for byte, so these tests pin the
/// layout rather than "round-trips with itself" only.
final class ProtocolTests: XCTestCase {
    func testHeaderLayout() {
        let p = packet(type: .frame, flags: 0x02, ptsMicros: 0x0102030405060708, payload: Data([0xAA]))
        XCTAssertEqual(p.count, HEADER_SIZE + 1)
        XCTAssertEqual(p.readUInt32BE(0), BKVM_MAGIC)
        XCTAssertEqual(p[4], BKVM_VERSION)
        XCTAssertEqual(p[5], PacketType.frame.rawValue)
        XCTAssertEqual(p[6], 0x02)
        XCTAssertEqual(p[7], 0)                                   // reserved
        XCTAssertEqual(p.readUInt32BE(8), 1)                      // payload length
        XCTAssertEqual(p.readInt64BE(12), 0x0102030405060708)
    }

    func testHeaderDecode() {
        let p = packet(type: .heartbeat, flags: 0, ptsMicros: 42, payload: Data())
        guard let h = PacketHeader.decode(p) else { return XCTFail("decode failed") }
        XCTAssertEqual(h.type, .heartbeat)
        XCTAssertEqual(h.payloadLength, 0)
        XCTAssertEqual(h.ptsMicros, 42)
    }

    func testHeaderRejectsShortAndAlienPackets() {
        XCTAssertNil(PacketHeader.decode(Data()))
        XCTAssertNil(PacketHeader.decode(Data(repeating: 0, count: HEADER_SIZE - 1)))

        var wrongMagic = packet(type: .frame, flags: 0, ptsMicros: 0, payload: Data())
        wrongMagic[0] = 0xFF
        XCTAssertNil(PacketHeader.decode(wrongMagic), "a foreign stream must not be parsed as ours")

        var wrongVersion = packet(type: .frame, flags: 0, ptsMicros: 0, payload: Data())
        wrongVersion[4] = BKVM_VERSION &+ 1
        XCTAssertNil(PacketHeader.decode(wrongVersion))
    }

    func testStreamFormatRoundTrip() {
        let sets = [Data([0x40, 0x01, 0x0c]), Data([0x42, 0x01, 0x01]), Data([0x44, 0x01])]
        let f = StreamFormat(width: 6016, height: 3384, codec: .hevc, parameterSets: sets)
        guard let back = StreamFormat.decode(f.encode()) else { return XCTFail("decode failed") }
        XCTAssertEqual(back.width, 6016)
        XCTAssertEqual(back.height, 3384)
        XCTAssertEqual(back.codec, .hevc)
        XCTAssertEqual(back.parameterSets, sets)
    }

    func testStreamFormatRejectsTruncation() {
        let f = StreamFormat(width: 1920, height: 1080, codec: .prores422,
                             parameterSets: [Data([0x01, 0x02, 0x03])])
        let encoded = f.encode()
        // Every prefix shorter than the whole payload must be refused, not
        // half-parsed: a partial format would silently disable decoding.
        for cut in 0..<encoded.count {
            XCTAssertNil(StreamFormat.decode(encoded.prefix(cut)), "accepted prefix of \(cut) bytes")
        }
        XCTAssertNotNil(StreamFormat.decode(encoded))
    }

    func testSessionConfigRoundTrip() {
        let c = SessionConfig(width: 3008, height: 1692, quality: 1)
        guard let back = SessionConfig.decode(c.encode()) else { return XCTFail("decode failed") }
        XCTAssertEqual(back.width, 3008)
        XCTAssertEqual(back.height, 1692)
        XCTAssertEqual(back.quality, 1)
        XCTAssertEqual(c.encode().count, SessionConfig.payloadSize)
    }

    func testColorModeRidesInTheReservedByte() {
        let wide = SessionConfig(width: 3008, height: 1692, quality: 1, color: .wide)
        let data = wide.encode()
        XCTAssertEqual(data[5], 1, "colour mode must use the byte that used to be reserved")
        XCTAssertEqual(SessionConfig.decode(data)?.color, .wide)

        // A config from a build that predates the field has 0 there.
        var legacy = data
        legacy[5] = 0
        XCTAssertEqual(SessionConfig.decode(legacy)?.color, .standard)
        // Unknown values must not make the server reject the session.
        var future = data
        future[5] = 0xFF
        XCTAssertEqual(SessionConfig.decode(future)?.color, .standard)
    }

    func testStreamFormatCarriesColorWithoutBreakingParameterSets() {
        let f = StreamFormat(width: 6016, height: 3384, codec: .prores422,
                             parameterSets: [], color: .wide)
        guard let back = StreamFormat.decode(f.encode()) else { return XCTFail("decode failed") }
        XCTAssertEqual(back.color, .wide)
        XCTAssertEqual(back.parameterSets, [], "the colour tag is metadata, not a parameter set")
        XCTAssertEqual(back.width, 6016)

        // Standard keeps the packet exactly as older builds expect (no tag).
        let standard = StreamFormat(width: 6016, height: 3384, codec: .prores422, parameterSets: [])
        let raw = standard.encode()
        XCTAssertEqual(raw[12], 0, "no parameter sets, no tag")
        XCTAssertEqual(StreamFormat.decode(raw)?.color, .standard)
    }

    func testClipboardPacketValuesAreAppendOnly() {
        // Old peers must keep seeing the same numbers for existing packets.
        XCTAssertEqual(PacketType.clipboard.rawValue, 13)
        XCTAssertEqual(PacketType.fileTransfer.rawValue, 14)
        XCTAssertEqual(PacketType.audio.rawValue, 9)
        XCTAssertEqual(PacketType.authExchange.rawValue, 12)
    }

    func testPauseMediaActionKeepsExistingCommandValues() {
        // New command at the end; old servers ignore it, old clients never send it.
        XCTAssertEqual(RemoteAction.pauseMedia.rawValue, 7)
        XCTAssertEqual(RemoteAction.hideDesktop.rawValue, 6)
        XCTAssertEqual(RemoteAction.missionControl.rawValue, 1)
    }

    func testSessionConfigRejectsImpossibleSizes() {
        // A malicious or buggy client must not be able to make the server build a
        // virtual display of 0×0 or 60000×60000.
        for (w, h) in [(0, 1080), (1920, 0), (100, 200), (9000, 4000)] {
            let c = SessionConfig(width: w, height: h, quality: 0)
            XCTAssertNil(SessionConfig.decode(c.encode()), "\(w)x\(h) should be refused")
        }
    }
}
