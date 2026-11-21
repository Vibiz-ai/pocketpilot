import Foundation

/// Owner: bluetooth. The HID report descriptor (keyboard ID 1, mouse ID 2, consumer ID 3 — the payload layouts in
/// Shared/HID.swift), the Bluetooth class of device, and the SDP service record PocketPilot publishes.
public enum HIDDescriptor {
    public static let deviceName = "PocketPilot"
    public static let controlPSM: UInt16 = 0x11
    public static let interruptPSM: UInt16 = 0x13

    /// Report descriptor. Describes exactly:
    /// - ID 1 keyboard input, 8 bytes: modifier bits (E0...E7), reserved byte, 6 key usages; plus a 1-byte LED output.
    /// - ID 2 mouse input, 4 bytes: 3 buttons + 5 pad bits, X, Y, wheel as signed 8-bit relative values.
    /// - ID 3 consumer input, 2 bytes: one 16-bit consumer usage (little-endian), 0 = nothing pressed.
    public static let reportDescriptor: [UInt8] = keyboard + mouse + consumer

    static let keyboard: [UInt8] = [
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x06,       // Usage (Keyboard)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x01,       //   Report ID (1)
        0x05, 0x07,       //   Usage Page (Keyboard/Keypad)
        0x19, 0xE0,       //   Usage Minimum (Left Control)
        0x29, 0xE7,       //   Usage Maximum (Right GUI)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x01,       //   Logical Maximum (1)
        0x75, 0x01,       //   Report Size (1)
        0x95, 0x08,       //   Report Count (8)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)        ; modifiers
        0x95, 0x01,       //   Report Count (1)
        0x75, 0x08,       //   Report Size (8)
        0x81, 0x01,       //   Input (Constant)                        ; reserved
        0x95, 0x05,       //   Report Count (5)
        0x75, 0x01,       //   Report Size (1)
        0x05, 0x08,       //   Usage Page (LEDs)
        0x19, 0x01,       //   Usage Minimum (Num Lock)
        0x29, 0x05,       //   Usage Maximum (Kana)
        0x91, 0x02,       //   Output (Data, Variable, Absolute)       ; LEDs
        0x95, 0x01,       //   Report Count (1)
        0x75, 0x03,       //   Report Size (3)
        0x91, 0x01,       //   Output (Constant)                       ; LED padding
        0x95, 0x06,       //   Report Count (6)
        0x75, 0x08,       //   Report Size (8)
        0x15, 0x00,       //   Logical Minimum (0)
        0x26, 0xFF, 0x00, //   Logical Maximum (255)
        0x05, 0x07,       //   Usage Page (Keyboard/Keypad)
        0x19, 0x00,       //   Usage Minimum (0)
        0x2A, 0xFF, 0x00, //   Usage Maximum (255)
        0x81, 0x00,       //   Input (Data, Array, Absolute)           ; 6 keys
        0xC0,             // End Collection
    ]

    static let mouse: [UInt8] = [
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x02,       // Usage (Mouse)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x02,       //   Report ID (2)
        0x09, 0x01,       //   Usage (Pointer)
        0xA1, 0x00,       //   Collection (Physical)
        0x05, 0x09,       //     Usage Page (Button)
        0x19, 0x01,       //     Usage Minimum (1)
        0x29, 0x03,       //     Usage Maximum (3)
        0x15, 0x00,       //     Logical Minimum (0)
        0x25, 0x01,       //     Logical Maximum (1)
        0x95, 0x03,       //     Report Count (3)
        0x75, 0x01,       //     Report Size (1)
        0x81, 0x02,       //     Input (Data, Variable, Absolute)     ; buttons
        0x95, 0x01,       //     Report Count (1)
        0x75, 0x05,       //     Report Size (5)
        0x81, 0x01,       //     Input (Constant)                     ; padding
        0x05, 0x01,       //     Usage Page (Generic Desktop)
        0x09, 0x30,       //     Usage (X)
        0x09, 0x31,       //     Usage (Y)
        0x09, 0x38,       //     Usage (Wheel)
        0x15, 0x81,       //     Logical Minimum (-127)
        0x25, 0x7F,       //     Logical Maximum (127)
        0x75, 0x08,       //     Report Size (8)
        0x95, 0x03,       //     Report Count (3)
        0x81, 0x06,       //     Input (Data, Variable, Relative)     ; X, Y, wheel
        0xC0,             //   End Collection
        0xC0,             // End Collection
    ]

    static let consumer: [UInt8] = [
        0x05, 0x0C,       // Usage Page (Consumer)
        0x09, 0x01,       // Usage (Consumer Control)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x03,       //   Report ID (3)
        0x15, 0x00,       //   Logical Minimum (0)
        0x26, 0xFF, 0x03, //   Logical Maximum (1023)
        0x19, 0x00,       //   Usage Minimum (0)
        0x2A, 0xFF, 0x03, //   Usage Maximum (1023)  ; covers AC Home 0x0223, volume, mute, play/pause
        0x75, 0x10,       //   Report Size (16)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x00,       //   Input (Data, Array, Absolute)
        0xC0,             // End Collection
    ]

    /// Class of device: major class Peripheral (0x05), minor Combo keyboard/pointing (0xC0),
    /// service bit Limited Discoverable (0x2000). iOS lists peripherals with this class in Settings > Bluetooth.
    public static let classOfDevice: UInt32 = 0x0025C0

    // MARK: SDP

    /// HID SDP attribute IDs (Bluetooth HID profile).
    public enum Attribute: UInt16, CaseIterable {
        case serviceClassIDList = 0x0001
        case protocolDescriptorList = 0x0004
        case browseGroupList = 0x0005
        case languageBaseAttributeIDList = 0x0006
        case profileDescriptorList = 0x0009
        case additionalProtocolDescriptorLists = 0x000D
        case serviceName = 0x0100
        case serviceDescription = 0x0101
        case providerName = 0x0102
        case parserVersion = 0x0201
        case deviceSubclass = 0x0202
        case countryCode = 0x0203
        case virtualCable = 0x0204
        case reconnectInitiate = 0x0205
        case descriptorList = 0x0206
        case langIDBaseList = 0x0207
        case batteryPower = 0x0209
        case remoteWake = 0x020A
        case profileVersion = 0x020B
        case supervisionTimeout = 0x020C
        case normallyConnectable = 0x020D
        case bootDevice = 0x020E

        var label: String {
            switch self {
            case .serviceClassIDList: return "ServiceClassIDList"
            case .protocolDescriptorList: return "ProtocolDescriptorList"
            case .browseGroupList: return "BrowseGroupList"
            case .languageBaseAttributeIDList: return "LanguageBaseAttributeIDList"
            case .profileDescriptorList: return "BluetoothProfileDescriptorList"
            case .additionalProtocolDescriptorLists: return "AdditionalProtocolDescriptorLists"
            case .serviceName: return "ServiceName"
            case .serviceDescription: return "ServiceDescription"
            case .providerName: return "ProviderName"
            case .parserVersion: return "HIDParserVersion"
            case .deviceSubclass: return "HIDDeviceSubclass"
            case .countryCode: return "HIDCountryCode"
            case .virtualCable: return "HIDVirtualCable"
            case .reconnectInitiate: return "HIDReconnectInitiate"
            case .descriptorList: return "HIDDescriptorList"
            case .langIDBaseList: return "HIDLANGIDBaseList"
            case .batteryPower: return "HIDBatteryPower"
            case .remoteWake: return "HIDRemoteWake"
            case .profileVersion: return "HIDProfileVersion"
            case .supervisionTimeout: return "HIDSupervisionTimeout"
            case .normallyConnectable: return "HIDNormallyConnectable"
            case .bootDevice: return "HIDBootDevice"
            }
        }

        /// Dictionary key in the format IOBluetooth parses: leading hex attribute ID, then a label.
        public var key: String { String(format: "%04X - ", rawValue) + label }
    }

    static let uuidL2CAP: UInt16 = 0x0100
    static let uuidHIDP: UInt16 = 0x0011
    static let uuidHIDService: UInt16 = 0x1124
    static let uuidPublicBrowseRoot: UInt16 = 0x1002

    /// The HID service record as typed SDP elements, keyed by attribute.
    public static var serviceRecord: [Attribute: SDPElement] {
        [
            .serviceClassIDList: .sequence([.uuid16(uuidHIDService)]),
            .protocolDescriptorList: .sequence([
                .sequence([.uuid16(uuidL2CAP), .uint16(controlPSM)]),
                .sequence([.uuid16(uuidHIDP)]),
            ]),
            .browseGroupList: .sequence([.uuid16(uuidPublicBrowseRoot)]),
            .languageBaseAttributeIDList: .sequence([.uint16(0x656E), .uint16(0x006A), .uint16(0x0100)]),
            .profileDescriptorList: .sequence([.sequence([.uuid16(uuidHIDService), .uint16(0x0101)])]),
            .additionalProtocolDescriptorLists: .sequence([
                .sequence([
                    .sequence([.uuid16(uuidL2CAP), .uint16(interruptPSM)]),
                    .sequence([.uuid16(uuidHIDP)]),
                ]),
            ]),
            .serviceName: .string(deviceName),
            .serviceDescription: .string("Keyboard and mouse for AI agents"),
            .providerName: .string(deviceName),
            .parserVersion: .uint16(0x0111),
            .deviceSubclass: .uint8(0xC0),              // combo keyboard + pointing device
            .countryCode: .uint8(0x21),                 // US
            .virtualCable: .bool(true),
            .reconnectInitiate: .bool(true),
            .descriptorList: .sequence([.sequence([.uint8(0x22), .bytes(reportDescriptor)])]), // 0x22 = report descriptor
            .langIDBaseList: .sequence([.sequence([.uint16(0x0409), .uint16(0x0100)])]),
            .batteryPower: .bool(true),
            .remoteWake: .bool(true),
            .profileVersion: .uint16(0x0101),
            .supervisionTimeout: .uint16(0x0C80),
            .normallyConnectable: .bool(true),
            .bootDevice: .bool(false),
        ]
    }

    /// The record as the dictionary `IOBluetoothSDPServiceRecord.publishedServiceRecord(with:)` takes.
    public static var serviceRecordDictionary: [String: Any] {
        var d: [String: Any] = [:]
        for (attr, element) in serviceRecord { d[attr.key] = element.foundationValue }
        return d
    }
}

/// A typed SDP data element, convertible to IOBluetooth's dictionary representation.
public indirect enum SDPElement: Equatable {
    case uint8(UInt8)
    case uint16(UInt16)
    case uint32(UInt32)
    case bool(Bool)
    case uuid16(UInt16)
    case string(String)
    /// A text-string element holding raw bytes (used for the HID report descriptor).
    case bytes([UInt8])
    case sequence([SDPElement])

    /// IOBluetooth data element type codes (kBluetoothSDPDataElementType*).
    public enum TypeCode: Int {
        case unsignedInt = 1, uuid = 3, string = 4, bool = 5, sequence = 6
    }

    public static let typeKey = "DataElementType"
    public static let sizeKey = "DataElementSize"
    public static let valueKey = "DataElementValue"

    /// NSArray for sequences, NSData (big-endian) for UUIDs, NSString for strings, and an explicit
    /// {DataElementType, DataElementSize, DataElementValue} dictionary for numbers, booleans and raw bytes.
    public var foundationValue: Any {
        func typed(_ t: TypeCode, _ size: Int, _ value: Any) -> [String: Any] {
            [Self.typeKey: t.rawValue, Self.sizeKey: size, Self.valueKey: value]
        }
        switch self {
        case .uint8(let v): return typed(.unsignedInt, 1, NSNumber(value: v))
        case .uint16(let v): return typed(.unsignedInt, 2, NSNumber(value: v))
        case .uint32(let v): return typed(.unsignedInt, 4, NSNumber(value: v))
        case .bool(let v): return typed(.bool, 1, NSNumber(value: v))
        case .uuid16(let v): return Data([UInt8(v >> 8), UInt8(v & 0xFF)])
        case .string(let s): return s
        case .bytes(let b): return typed(.string, b.count, Data(b))
        case .sequence(let items): return items.map { $0.foundationValue }
        }
    }
}
