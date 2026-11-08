import XCTest
@testable import OpenTapCore

/// Minimal HID report-descriptor walker: total bits per (report type, report ID).
private struct DescriptorSummary {
    var inputBits: [UInt8: Int] = [:]
    var outputBits: [UInt8: Int] = [:]
    var usagePagesByID: [UInt8: Set<UInt16>] = [:]
    var collectionsBalanced = true
    var logicalRanges: [UInt8: [(Int, Int)]] = [:]

    init(_ d: [UInt8]) {
        var i = 0, size = 0, count = 0, id: UInt8 = 0, page: UInt16 = 0, depth = 0
        var lmin = 0, lmax = 0
        while i < d.count {
            let prefix = d[i]
            let len = [0, 1, 2, 4][Int(prefix & 0x03)]
            let tag = prefix & 0xFC
            var u = 0
            for k in 0..<len { u |= Int(d[i + 1 + k]) << (8 * k) }
            let signed: Int = len == 1 ? Int(Int8(bitPattern: UInt8(u))) : (len == 2 ? Int(Int16(bitPattern: UInt16(u))) : u)
            switch tag {
            case 0x04: page = UInt16(u)
            case 0x14: lmin = signed
            case 0x24: lmax = len == 1 && lmin >= 0 ? u : signed
            case 0x74: size = u
            case 0x94: count = u
            case 0x84: id = UInt8(u)
            case 0x80:
                inputBits[id, default: 0] += size * count
                usagePagesByID[id, default: []].insert(page)
                if u & 0x01 == 0 { logicalRanges[id, default: []].append((lmin, lmax)) }
            case 0x90: outputBits[id, default: 0] += size * count
            case 0xA0: depth += 1
            case 0xC0: depth -= 1; if depth < 0 { collectionsBalanced = false }
            default: break
            }
            i += 1 + len
        }
        if depth != 0 { collectionsBalanced = false }
    }
}

/// Records reports instead of touching the radio.
private final class RecordingTransport: HIDTransport {
    let state = StateChannel<HIDConnectionState>(.connected(hostName: "Test"))
    var sent: [HIDReport] = []
    func start() async throws {}
    func stop() {}
    func send(_ report: HIDReport) async throws { sent.append(report) }
}

final class BluetoothTests: XCTestCase {
    // MARK: Descriptor

    func testDescriptorReportSizesMatchSharedLayouts() {
        let s = DescriptorSummary(HIDDescriptor.reportDescriptor)
        XCTAssertTrue(s.collectionsBalanced)
        XCTAssertEqual(s.inputBits[HIDReportID.keyboard], KeyboardReport().payload.count * 8)
        XCTAssertEqual(s.inputBits[HIDReportID.mouse], MouseReport().payload.count * 8)
        XCTAssertEqual(s.inputBits[HIDReportID.consumer], ConsumerReport.released.payload.count * 8)
        XCTAssertEqual(s.outputBits[HIDReportID.keyboard], 8)
        XCTAssertEqual(Set(s.inputBits.keys), [1, 2, 3])
        XCTAssertEqual(s.usagePagesByID[HIDReportID.consumer], [0x0C])
    }

    func testDescriptorRangesCoverUsages() {
        let s = DescriptorSummary(HIDDescriptor.reportDescriptor)
        // Mouse axes are signed 8-bit.
        XCTAssertTrue(s.logicalRanges[HIDReportID.mouse]!.contains { $0 == (-127, 127) })
        // Consumer range covers AC Home.
        let c = s.logicalRanges[HIDReportID.consumer]!.first!
        XCTAssertLessThanOrEqual(c.0, 0)
        XCTAssertGreaterThanOrEqual(c.1, Int(ConsumerUsage.acHome))
        XCTAssertLessThan(HIDDescriptor.reportDescriptor.count, 512)  // fits one SDP text element comfortably
    }

    func testDescriptorBeginsWithEachReportID() {
        let d = HIDDescriptor.reportDescriptor
        for id in [HIDReportID.keyboard, HIDReportID.mouse, HIDReportID.consumer] {
            XCTAssertTrue(zip(d, d.dropFirst()).contains { $0 == (0x85, id) }, "missing Report ID \(id)")
        }
    }

    func testClassOfDeviceIsPeripheralCombo() {
        let cod = HIDDescriptor.classOfDevice
        XCTAssertEqual((cod >> 8) & 0x1F, 0x05)  // major: peripheral
        XCTAssertEqual(cod & 0xFC, 0xC0)         // minor: combo keyboard/pointing
    }

    // MARK: SDP

    func testSDPRecordCoreAttributes() {
        let r = HIDDescriptor.serviceRecord
        XCTAssertEqual(r[.serviceClassIDList], .sequence([.uuid16(0x1124)]))
        XCTAssertEqual(r[.protocolDescriptorList], .sequence([.sequence([.uuid16(0x0100), .uint16(0x11)]), .sequence([.uuid16(0x0011)])]))
        XCTAssertEqual(r[.additionalProtocolDescriptorLists],
                       .sequence([.sequence([.sequence([.uuid16(0x0100), .uint16(0x13)]), .sequence([.uuid16(0x0011)])])]))
        XCTAssertEqual(r[.bootDevice], .bool(false))
        XCTAssertEqual(r[.reconnectInitiate], .bool(true))
        XCTAssertEqual(r[.normallyConnectable], .bool(true))
        XCTAssertEqual(r[.virtualCable], .bool(true))
        XCTAssertEqual(r[.serviceName], .string("OpenTap"))
        XCTAssertEqual(r[.descriptorList], .sequence([.sequence([.uint8(0x22), .bytes(HIDDescriptor.reportDescriptor)])]))
    }

    func testSDPDictionaryFormat() throws {
        let d = HIDDescriptor.serviceRecordDictionary
        XCTAssertEqual(d.count, HIDDescriptor.Attribute.allCases.count)
        XCTAssertEqual(HIDDescriptor.Attribute.serviceClassIDList.key, "0001 - ServiceClassIDList")
        XCTAssertEqual(HIDDescriptor.Attribute.descriptorList.key, "0206 - HIDDescriptorList")
        let classes = try XCTUnwrap(d["0001 - ServiceClassIDList"] as? [Any])
        XCTAssertEqual(classes.first as? Data, Data([0x11, 0x24]))
        let boot = try XCTUnwrap(d["020E - HIDBootDevice"] as? [String: Any])
        XCTAssertEqual(boot[SDPElement.typeKey] as? Int, 5)
        XCTAssertEqual((boot[SDPElement.valueKey] as? NSNumber)?.boolValue, false)
        let descList = try XCTUnwrap(d["0206 - HIDDescriptorList"] as? [[Any]])
        let desc = try XCTUnwrap(descList.first?.last as? [String: Any])
        XCTAssertEqual(desc[SDPElement.typeKey] as? Int, 4)
        XCTAssertEqual(desc[SDPElement.valueKey] as? Data, Data(HIDDescriptor.reportDescriptor))
        XCTAssertEqual(desc[SDPElement.sizeKey] as? Int, HIDDescriptor.reportDescriptor.count)
        // Must be a valid property list (IOBluetooth takes plist-typed dictionaries).
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0))
    }

    // MARK: Report encoding

    func testInterruptPackets() {
        XCTAssertEqual(HIDReport.keyboard(KeyboardReport(modifiers: [.shift], keys: [0x04])).interruptPacket,
                       [0xA1, 0x01, 0x02, 0x00, 0x04, 0, 0, 0, 0, 0])
        XCTAssertEqual(HIDReport.mouse(MouseReport(buttons: .left, dx: -1, dy: 127, wheel: -127)).interruptPacket,
                       [0xA1, 0x02, 0x01, 0xFF, 0x7F, 0x81])
        XCTAssertEqual(HIDReport.consumer(ConsumerReport(usage: ConsumerUsage.acHome)).interruptPacket, [0xA1, 0x03, 0x23, 0x02])
    }

    // MARK: Move chunking

    func testMoveStepsSumAndBounds() {
        for (dx, dy) in [(0, 0), (1, 0), (127, -127), (128, 0), (-1000, 300), (5, -999), (254, 254), (-128, 1)] {
            let steps = HIDReportSequence.moveSteps(dx: dx, dy: dy)
            XCTAssertEqual(steps.reduce(0) { $0 + Int($1.dx) }, dx)
            XCTAssertEqual(steps.reduce(0) { $0 + Int($1.dy) }, dy)
            XCTAssertTrue(steps.allSatisfy { abs(Int($0.dx)) <= 127 && abs(Int($0.dy)) <= 127 })
            let minimum = max((abs(dx) + 126) / 127, (abs(dy) + 126) / 127)
            XCTAssertEqual(steps.count, minimum, "(\(dx),\(dy))")
        }
        XCTAssertEqual(HIDReportSequence.moveSteps(dx: 254, dy: 0), [HIDMouseStep(dx: 127, dy: 0), HIDMouseStep(dx: 127, dy: 0)])
    }

    func testMoveStepsWithSmallMaxStep() {
        let steps = HIDReportSequence.moveSteps(dx: 50, dy: -20, maxStep: 10)
        XCTAssertEqual(steps.count, 5)
        XCTAssertTrue(steps.allSatisfy { $0 == HIDMouseStep(dx: 10, dy: -4) })
    }

    func testUniformSteps() {
        let s = HIDReportSequence.uniformSteps(dx: 25, dy: -7, step: 10)
        XCTAssertEqual(s, [HIDMouseStep(dx: 10, dy: -7), HIDMouseStep(dx: 10, dy: 0), HIDMouseStep(dx: 5, dy: 0)])
        XCTAssertEqual(HIDReportSequence.uniformSteps(dx: 0, dy: 0, step: 5), [])
        XCTAssertEqual(HIDReportSequence.uniformSteps(dx: -300, dy: 0, step: 500).map(\.dx), [-127, -127, -46])
    }

    // MARK: Key sequences

    func testKeyTapAndCombo() throws {
        XCTAssertEqual(HIDReportSequence.keyTap(KeyUsage.returnKey),
                       [.keyboard(KeyboardReport(keys: [0x28])), .keyboard(.released)])
        let spotlight = HIDReportSequence.combo(try KeyCombo.parse("cmd+space"))
        XCTAssertEqual(spotlight, [
            .keyboard(KeyboardReport(modifiers: .command)),
            .keyboard(KeyboardReport(modifiers: .command, keys: [KeyUsage.space])),
            .keyboard(KeyboardReport(modifiers: .command)),
            .keyboard(.released),
        ])
        XCTAssertEqual(HIDReportSequence.combo(try KeyCombo.parse("home")),
                       [.consumer(ConsumerReport(usage: 0x0223)), .consumer(.released)])
    }

    func testTypeASCIIMapping() throws {
        let taps = try HIDReportSequence.type("aZ!\n")
        XCTAssertEqual(taps.count, 4)
        XCTAssertEqual(taps[0].first, .keyboard(KeyboardReport(keys: [0x04])))
        XCTAssertTrue(taps[1].contains(.keyboard(KeyboardReport(modifiers: .shift, keys: [0x1D]))))
        XCTAssertTrue(taps[2].contains(.keyboard(KeyboardReport(modifiers: .shift, keys: [0x1E]))))
        XCTAssertEqual(taps[3].first, .keyboard(KeyboardReport(keys: [KeyUsage.returnKey])))
        XCTAssertTrue(taps.allSatisfy { $0.last == .keyboard(.released) })
        XCTAssertThrowsError(try HIDReportSequence.type("café")) { e in
            XCTAssertEqual((e as? OpenTapError)?.code, .invalidArgument)
        }
    }

    func testHelpersSendExpectedReports() async throws {
        let t = RecordingTransport()
        try await t.typeASCII("Hi", holdMs: 0, gapMs: 0)
        try await t.click(holdMs: 0)
        try await t.mouseMove(dx: 200, dy: 0)
        try await t.consumer(ConsumerUsage.volumeUp, holdMs: 0)
        XCTAssertEqual(t.sent.count, 4 + 2 + 2 + 2 + 2)
        XCTAssertEqual(t.sent[8], .mouse(MouseReport(dx: 100)))
        XCTAssertEqual(t.sent.last, .consumer(.released))
        // A bad character sends nothing.
        t.sent.removeAll()
        do { try await t.typeASCII("ok😀"); XCTFail("should throw") } catch {}
        XCTAssertTrue(t.sent.isEmpty)
    }

    // MARK: HIDP control channel

    func testSetAndGetProtocol() {
        var r = HIDPControlResponder()
        XCTAssertEqual(r.handleControl([0x60]).reply, [0xA0, 0x01])          // report protocol by default
        let set = r.handleControl([0x70])                                    // SET_PROTOCOL boot
        XCTAssertEqual(set.reply, [0x00])
        XCTAssertEqual(set.event, .protocolChanged(boot: true))
        XCTAssertEqual(r.handleControl([0x60]).reply, [0xA0, 0x00])
        XCTAssertEqual(r.handleControl([0x71]).event, .protocolChanged(boot: false))
    }

    func testGetReport() {
        var r = HIDPControlResponder()
        XCTAssertEqual(r.handleControl([0x41, 0x02]).reply, [0xA1, 0x02, 0, 0, 0, 0])
        XCTAssertEqual(r.handleControl([0x41, 0x03]).reply, [0xA1, 0x03, 0, 0])
        XCTAssertEqual(r.handleControl([0x41, 0x01]).reply?.count, 10)
        XCTAssertEqual(r.handleControl([0x41, 0x09]).reply, [0x02])          // unknown ID
        XCTAssertEqual(r.handleControl([0x43, 0x01]).reply, [0x02])          // no feature reports
        XCTAssertEqual(r.handleControl([0x41]).reply, [0x04])                // missing ID
        XCTAssertEqual(r.handleControl([0x49, 0x01, 0x03, 0x00]).reply, [0xA1, 0x01, 0x00, 0x00]) // buffer size 3
    }

    func testSetReportLEDsAndIdle() {
        var r = HIDPControlResponder()
        let o = r.handleControl([0x52, 0x01, 0x02])
        XCTAssertEqual(o.reply, [0x00]); XCTAssertEqual(o.event, .leds(0x02)); XCTAssertEqual(r.leds, 0x02)
        XCTAssertEqual(r.handleControl([0x42, 0x01]).reply, [0xA2, 0x01, 0x02])
        XCTAssertEqual(r.handleControl([0x90, 0x05]).reply, [0x00])
        XCTAssertEqual(r.handleControl([0x80]).reply, [0xA0, 0x05])
        XCTAssertEqual(r.handleInterrupt([0xA2, 0x01, 0x01]), .leds(0x01))
        XCTAssertEqual(r.handleControl([0x52, 0x07, 0x00]).reply, [0x02])
    }

    func testHIDControlAndUnknown() {
        var r = HIDPControlResponder()
        XCTAssertEqual(r.handleControl([0x15]), .init(reply: nil, event: .virtualCableUnplug))
        XCTAssertEqual(r.handleControl([0x13]).event, .suspend)
        XCTAssertEqual(r.handleControl([0x14]).event, .exitSuspend)
        XCTAssertEqual(r.handleControl([0x20]).reply, [0x03])                // reserved type -> unsupported
        XCTAssertNil(r.handleControl([0x00]).reply)                          // handshake from host
        XCTAssertNil(r.handleControl([]).reply)
    }

    // MARK: Transport without radio

    func testSendWhenNotStartedThrowsActionableError() async {
        let t = BluetoothHIDTransport(log: Log())
        do {
            try await t.send(.keyboard(.released)); XCTFail("should throw")
        } catch let e as OpenTapError {
            XCTAssertEqual(e.code, .hidNotConnected)
            XCTAssertFalse(e.why.isEmpty); XCTAssertTrue(e.fix.contains("Settings > Bluetooth"))
        } catch { XCTFail("\(error)") }
    }

    func testPacerSpacesSlots() async {
        let p = ReportPacer(interval: 0.01)
        let start = ContinuousClock.now
        for _ in 0..<4 { await p.waitTurn() }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(28))
    }
}
