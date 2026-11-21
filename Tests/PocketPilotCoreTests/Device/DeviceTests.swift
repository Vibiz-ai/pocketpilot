import Foundation
import XCTest
@testable import PocketPilotCore

// MARK: - Fakes (no hardware, no private framework)

final class FakeLoader: DynamicLibraryLoader {
    var opens: Bool
    var missing: Set<String>
    var lastError: String?
    var requested: [String] = []
    init(opens: Bool = true, missing: Set<String> = []) { self.opens = opens; self.missing = missing }

    func open(_ path: String) -> LibraryHandle? {
        guard opens else { lastError = "image not found"; return nil }
        return LibraryHandle(UnsafeMutableRawPointer(bitPattern: 0x1000)!)
    }

    func symbol(_ name: String, in library: LibraryHandle) -> UnsafeMutableRawPointer? {
        requested.append(name)
        // Never called: loading only resolves pointers.
        return missing.contains(name) ? nil : UnsafeMutableRawPointer(bitPattern: 0x2000)
    }
}

final class FakePhone {
    var udid = "00008110-000A1B2C3D4E5F60"
    var interface = 1
    var paired = false
    var locked = false
    var values: [String: Any] = [
        "DeviceName": "Test iPhone", "DeviceClass": "iPhone", "ProductType": "iPhone16,2", "ProductVersion": "18.1",
    ]
    var accessibility: [String: Any] = [:]
    /// Results AMDevicePair returns in order; the last one repeats. 0 = user tapped Trust.
    var pairScript: [Int32] = [0]
}

final class FakeMobileDeviceAPI: MobileDeviceAPI {
    var capabilities = MobileDeviceCapabilities()
    var phones: [MDDevice: FakePhone] = [:]
    var handler: ((MDDeviceEvent) -> Void)?
    var subscribeError: Error?
    var retainCount: [MDDevice: Int] = [:]
    var setCalls: [(domain: String?, key: String, value: Any)] = []
    var pairCalls = 0
    var connected: Set<MDDevice> = []
    var sessions: Set<MDDevice> = []

    func subscribe(_ handler: @escaping (MDDeviceEvent) -> Void) throws {
        if let subscribeError { throw subscribeError }
        self.handler = handler
    }
    func unsubscribe() { handler = nil }
    func retain(_ d: MDDevice) { retainCount[d, default: 0] += 1 }
    func release(_ d: MDDevice) { retainCount[d, default: 0] -= 1 }
    func identifier(_ d: MDDevice) -> String? { phones[d]?.udid }
    func interfaceType(_ d: MDDevice) -> Int? { phones[d]?.interface }
    func connect(_ d: MDDevice) -> Int32 {
        guard phones[d] != nil else { return Int32(bitPattern: 0xE800_0001) }
        connected.insert(d); return 0
    }
    func disconnect(_ d: MDDevice) -> Int32 { connected.remove(d); return 0 }
    func isPaired(_ d: MDDevice) -> Bool { phones[d]?.paired ?? false }
    func validatePairing(_ d: MDDevice) -> Int32 {
        guard let p = phones[d], p.paired else { return AMDResult.invalidHostIDCode }
        return 0
    }
    func pair(_ d: MDDevice) -> Int32 {
        guard let p = phones[d] else { return -1 }
        pairCalls += 1
        let rc = p.pairScript.count > 1 ? p.pairScript.removeFirst() : p.pairScript[0]
        if rc == 0 { p.paired = true }
        return rc
    }
    func startSession(_ d: MDDevice) -> Int32 {
        guard let p = phones[d], p.paired else { return AMDResult.invalidHostIDCode }
        if p.locked { return AMDResult.passwordProtectedCode }
        sessions.insert(d); return 0
    }
    func stopSession(_ d: MDDevice) -> Int32 { sessions.remove(d); return 0 }
    func copyValue(_ d: MDDevice, domain: String?, key: String) -> Any? {
        guard let p = phones[d], connected.contains(d) else { return nil }
        if domain == LockdownKeys.accessibilityDomain { return sessions.contains(d) ? p.accessibility[key] : nil }
        // Unpaired lockdown hides the name, like a real device may.
        if key == LockdownKeys.deviceName && !sessions.contains(d) { return nil }
        return p.values[key]
    }
    func setValue(_ d: MDDevice, domain: String?, key: String, value: Any) -> Int32 {
        guard let p = phones[d], sessions.contains(d) else { return AMDResult.invalidHostIDCode }
        setCalls.append((domain, key, value))
        if domain == LockdownKeys.accessibilityDomain { p.accessibility[key] = value }
        return 0
    }

    // Test drivers (simulate the run-loop thread).
    @discardableResult
    func plug(_ phone: FakePhone, bits: UInt = 0xA0) -> MDDevice {
        let d = MDDevice(bits: bits)
        phones[d] = phone
        handler?(.attached(d))
        return d
    }
    func unplug(_ d: MDDevice) { handler?(.detached(d)) }
}

// MARK: - Tests

final class DeviceTests: XCTestCase {
    private func makeLink(_ api: FakeMobileDeviceAPI, timeout: TimeInterval = 2, poll: TimeInterval = 0.01) -> MobileDeviceLink {
        MobileDeviceLink(log: Log(), apiProvider: { .success(api) }, pairTimeout: timeout, pollInterval: poll)
    }

    private func waitFor(_ link: MobileDeviceLink, timeout: TimeInterval = 2,
                         _ predicate: @escaping (DeviceLinkState) -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let exp = expectation(description: "state")
        exp.assertForOverFulfill = false
        let sub = link.state.subscribe { if predicate($0) { exp.fulfill() } }
        wait(for: [exp], timeout: timeout)
        sub.cancel()
    }

    // Loader soft-fail

    func testMissingFrameworkGivesManualSteps() {
        let result = MobileDeviceFramework.load(loader: FakeLoader(opens: false))
        guard case .failure(let e) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(e.code, .frameworkUnavailable)
        XCTAssertTrue(e.why.contains("image not found"))
        XCTAssertTrue(e.fix.contains("Settings > Accessibility > Touch > AssistiveTouch"))
        XCTAssertTrue(e.fix.contains("Trust"))
    }

    func testMissingRequiredSymbolIsNamed() {
        let result = MobileDeviceFramework.load(loader: FakeLoader(missing: ["AMDeviceCopyValue", "AMDeviceConnect"]))
        guard case .failure(let e) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(e.code, .frameworkUnavailable)
        XCTAssertTrue(e.why.contains("AMDeviceCopyValue"))
        XCTAssertTrue(e.why.contains("AMDeviceConnect"))
        XCTAssertTrue(e.fix.contains("AssistiveTouch"))
    }

    func testMissingOptionalSymbolsOnlyDisableFeatures() throws {
        let loader = FakeLoader(missing: ["AMDevicePair", "AMDeviceSetValue", "AMDeviceGetInterfaceType"])
        let api = try MobileDeviceFramework.load(loader: loader).get()
        XCTAssertEqual(api.capabilities, MobileDeviceCapabilities(canPair: false, canSetValues: false, canFilterInterface: false))
        let full = try MobileDeviceFramework.load(loader: FakeLoader()).get()
        XCTAssertEqual(full.capabilities, MobileDeviceCapabilities())
        for s in MobileDeviceFramework.requiredSymbols { XCTAssertTrue(loader.requested.contains(s), s) }
    }

    func testLinkReportsUnavailableWhenFrameworkMissing() async throws {
        let link = MobileDeviceLink(log: Log(), apiProvider: { MobileDeviceFramework.load(loader: FakeLoader(opens: false)) })
        await link.start()
        guard case .unavailable(let e) = link.state.value else { return XCTFail("got \(link.state.value)") }
        XCTAssertEqual(e.code, .frameworkUnavailable)
        do { _ = try await link.assistiveTouchEnabled(); XCTFail("should throw") } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .frameworkUnavailable)
            XCTAssertTrue(e.fix.contains("AssistiveTouch"))
        }
        do { try await link.pair(); XCTFail("should throw") } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .frameworkUnavailable)
        }
    }

    func testSubscribeFailureIsUnavailable() async {
        let api = FakeMobileDeviceAPI()
        api.subscribeError = PocketPilotError(.frameworkUnavailable, what: "x", why: "y", fix: "z")
        let link = makeLink(api)
        await link.start()
        guard case .unavailable = link.state.value else { return XCTFail("got \(link.state.value)") }
    }

    // Value parsing

    func testBoolParsing() {
        XCTAssertEqual(DeviceValueParser.bool(kCFBooleanTrue), true)
        XCTAssertEqual(DeviceValueParser.bool(kCFBooleanFalse), false)
        XCTAssertEqual(DeviceValueParser.bool(NSNumber(value: 1)), true)
        XCTAssertEqual(DeviceValueParser.bool(0), false)
        XCTAssertEqual(DeviceValueParser.bool("YES"), true)
        XCTAssertEqual(DeviceValueParser.bool(" false "), false)
        XCTAssertNil(DeviceValueParser.bool("maybe"))
        XCTAssertNil(DeviceValueParser.bool(nil))
        XCTAssertNil(DeviceValueParser.bool(Data()))
    }

    func testDeviceInfoParsingWithFallbacks() {
        let full = DeviceValueParser.deviceInfo(udid: "U1", values: [
            "DeviceName": " Lau's iPhone ", "DeviceClass": "iPhone", "ProductType": "iPhone16,2",
            "ProductVersion": "18.1", "UniqueDeviceID": "IGNORED",
        ])
        XCTAssertEqual(full, DeviceInfo(udid: "U1", name: "Lau's iPhone", model: "iPhone", productType: "iPhone16,2", iosVersion: "18.1"))
        let sparse = DeviceValueParser.deviceInfo(udid: nil, values: ["UniqueDeviceID": "U2", "DeviceName": ""])
        XCTAssertEqual(sparse, DeviceInfo(udid: "U2", name: "iPhone", model: "iPhone", productType: "unknown", iosVersion: "unknown"))
    }

    func testResultCodeMapping() {
        XCTAssertEqual(AMDResult(0), .ok)
        XCTAssertEqual(AMDResult(Int32(bitPattern: 0xE800_001A)), .locked)
        XCTAssertEqual(AMDResult(Int32(bitPattern: 0xE800_0095)), .denied)
        XCTAssertEqual(AMDResult(Int32(bitPattern: 0xE800_0096)), .pending)
        XCTAssertEqual(AMDResult(Int32(bitPattern: 0xE800_0007)), .notPaired)
        XCTAssertEqual(AMDResult(-5), .other(-5))
        XCTAssertNil(AMDResult.error(0, what: "w"))
        let locked = AMDResult.error(AMDResult.passwordProtectedCode, what: "w", deviceName: "Phone")!
        XCTAssertEqual(locked.code, .deviceLocked)
        XCTAssertTrue(locked.fix.lowercased().contains("unlock your iphone"))
        let other = AMDResult.error(Int32(bitPattern: 0xE800_00FF), what: "w")!
        XCTAssertEqual(other.code, .io)
        XCTAssertTrue(other.why.contains("0xE80000FF"))
    }

    // Link behaviour over a fake API

    func testAttachDetachPairedDevice() async throws {
        let api = FakeMobileDeviceAPI()
        let link = makeLink(api)
        await link.start()
        XCTAssertEqual(link.state.value, .noDevice)
        let phone = FakePhone(); phone.paired = true
        let dev = api.plug(phone)
        waitFor(link) { $0.device != nil }
        XCTAssertEqual(link.state.value, .attached(
            DeviceInfo(udid: phone.udid, name: "Test iPhone", model: "iPhone", productType: "iPhone16,2", iosVersion: "18.1"),
            trust: .paired))
        XCTAssertEqual(link.attachedDevices.count, 1)
        XCTAssertTrue(api.connected.isEmpty, "connection must be closed after reading")
        let paired = try await link.isPaired()
        XCTAssertTrue(paired)
        api.unplug(dev)
        waitFor(link) { $0 == .noDevice }
        XCTAssertEqual(api.retainCount[dev], 0)
        XCTAssertTrue(link.attachedDevices.isEmpty)
        link.stop()
        XCTAssertEqual(link.state.value, .idle)
    }

    func testUnpairedDeviceShowsNotPairedWithFallbackName() async throws {
        let api = FakeMobileDeviceAPI()
        let link = makeLink(api)
        await link.start()
        api.plug(FakePhone())
        waitFor(link) { $0.device != nil }
        guard case .attached(let info, let trust) = link.state.value else { return XCTFail() }
        XCTAssertEqual(trust, .notPaired)
        XCTAssertEqual(info.name, "iPhone")
        let paired = try await link.isPaired()
        XCTAssertFalse(paired)
    }

    func testWiFiDeviceIgnored() async {
        let api = FakeMobileDeviceAPI()
        let link = makeLink(api)
        await link.start()
        let phone = FakePhone(); phone.interface = 2
        let dev = api.plug(phone)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(link.state.value, .noDevice)
        XCTAssertEqual(api.retainCount[dev], 0)
    }

    func testPairWaitsForTrustThenSucceeds() async throws {
        let api = FakeMobileDeviceAPI()
        let link = makeLink(api)
        await link.start()
        let phone = FakePhone()
        phone.pairScript = [AMDResult.dialogPendingCode, AMDResult.dialogPendingCode, 0]
        api.plug(phone)
        waitFor(link) { $0.device != nil }
        var seen: [TrustState] = []
        let sub = link.state.subscribe { if case .attached(_, let t) = $0 { seen.append(t) } }
        try await link.pair()
        sub.cancel()
        XCTAssertEqual(api.pairCalls, 3)
        XCTAssertTrue(seen.contains(.awaitingUserTrust))
        guard case .attached(let info, .paired) = link.state.value else { return XCTFail("got \(link.state.value)") }
        XCTAssertEqual(info.name, "Test iPhone", "name readable once trusted")
    }

    func testPairWhileLockedTimesOutWithUnlockMessage() async {
        let api = FakeMobileDeviceAPI()
        let link = makeLink(api, timeout: 0.1)
        await link.start()
        let phone = FakePhone(); phone.pairScript = [AMDResult.passwordProtectedCode]
        api.plug(phone)
        waitFor(link) { $0.device != nil }
        do { try await link.pair(); XCTFail("should throw") } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .deviceLocked)
            XCTAssertTrue(e.fix.lowercased().contains("unlock your iphone"))
        } catch { XCTFail("\(error)") }
        guard case .attached(_, .locked) = link.state.value else { return XCTFail("got \(link.state.value)") }
    }

    func testPairPendingTimesOut() async {
        let api = FakeMobileDeviceAPI()
        let link = makeLink(api, timeout: 0.1)
        await link.start()
        let phone = FakePhone(); phone.pairScript = [AMDResult.dialogPendingCode]
        api.plug(phone)
        waitFor(link) { $0.device != nil }
        do { try await link.pair(); XCTFail("should throw") } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .timeout)
            XCTAssertTrue(e.fix.contains("Trust"))
        } catch { XCTFail("\(error)") }
    }

    func testPairDenied() async {
        let api = FakeMobileDeviceAPI()
        let link = makeLink(api)
        await link.start()
        let phone = FakePhone(); phone.pairScript = [AMDResult.userDeniedCode]
        api.plug(phone)
        waitFor(link) { $0.device != nil }
        do { try await link.pair(); XCTFail("should throw") } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .notPaired)
            XCTAssertTrue(e.fix.contains("Reset Location & Privacy"))
        } catch { XCTFail("\(error)") }
        guard case .attached(_, .denied) = link.state.value else { return XCTFail("got \(link.state.value)") }
    }

    func testPairWithoutDeviceOrWithoutSymbol() async {
        let api = FakeMobileDeviceAPI()
        let link = makeLink(api)
        do { try await link.pair(); XCTFail() } catch let e as PocketPilotError { XCTAssertEqual(e.code, .noDevice) } catch {}
        await link.start()
        do { try await link.pair(); XCTFail() } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .noDevice); XCTAssertTrue(e.fix.contains("USB"))
        } catch {}
        api.capabilities.canPair = false
        api.plug(FakePhone())
        waitFor(link) { $0.device != nil }
        do { try await link.pair(); XCTFail() } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .frameworkUnavailable); XCTAssertTrue(e.fix.contains("Trust"))
        } catch {}
    }

    func testAssistiveTouchReadAndWrite() async throws {
        let api = FakeMobileDeviceAPI()
        let link = makeLink(api)
        await link.start()
        let phone = FakePhone(); phone.paired = true
        api.plug(phone)
        waitFor(link) { $0.device != nil }
        let initial = try await link.assistiveTouchEnabled()
        XCTAssertFalse(initial, "absent key reads as off")
        try await link.setAssistiveTouch(true)
        XCTAssertEqual(api.setCalls.count, 1)
        XCTAssertEqual(api.setCalls[0].domain, "com.apple.Accessibility")
        XCTAssertEqual(api.setCalls[0].key, "AssistiveTouchEnabledByiTunes")
        XCTAssertEqual(DeviceValueParser.bool(api.setCalls[0].value), true)
        let now = try await link.assistiveTouchEnabled()
        XCTAssertTrue(now)
        XCTAssertTrue(api.sessions.isEmpty && api.connected.isEmpty, "sessions closed")
    }

    func testAssistiveTouchSoftFails() async throws {
        let api = FakeMobileDeviceAPI()
        let link = makeLink(api)
        await link.start()
        let phone = FakePhone()
        api.plug(phone)
        waitFor(link) { $0.device != nil }
        // Not paired.
        do { _ = try await link.assistiveTouchEnabled(); XCTFail() } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .notPaired)
            XCTAssertTrue(e.fix.contains("Settings > Accessibility > Touch > AssistiveTouch"))
        }
        // Paired but locked.
        phone.paired = true; phone.locked = true
        do { try await link.setAssistiveTouch(true); XCTFail() } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .deviceLocked)
            XCTAssertTrue(e.fix.contains("AssistiveTouch"))
        }
        // No SetValue symbol.
        phone.locked = false
        api.capabilities.canSetValues = false
        do { try await link.setAssistiveTouch(true); XCTFail() } catch let e as PocketPilotError {
            XCTAssertEqual(e.code, .frameworkUnavailable)
            XCTAssertEqual(e.fix, ManualSteps.assistiveTouch)
        }
        XCTAssertTrue(api.setCalls.isEmpty)
    }
}
