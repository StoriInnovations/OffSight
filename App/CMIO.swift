import CoreMediaIO
import Foundation

/// Thin wrappers over the CoreMediaIO C API used to talk to OffSight Camera.
enum CMIO {
    static func address(_ selector: UInt32) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func objectIDs(of object: CMIOObjectID, selector: UInt32) -> [CMIOObjectID] {
        var address = CMIO.address(selector)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, dataSize, &dataUsed, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(dataUsed) / MemoryLayout<CMIOObjectID>.size))
    }

    static func devices() -> [CMIOObjectID] {
        objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: UInt32(kCMIOHardwarePropertyDevices))
    }

    static func streams(of device: CMIOObjectID) -> [CMIOStreamID] {
        objectIDs(of: device, selector: UInt32(kCMIODevicePropertyStreams))
    }

    static func string(of object: CMIOObjectID, selector: UInt32) -> String? {
        var address = CMIO.address(selector)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<CFString>.size) else { return nil }
        var value: Unmanaged<CFString>?
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectGetPropertyData(object, &address, 0, nil, dataSize, &dataUsed, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func name(of object: CMIOObjectID) -> String? {
        string(of: object, selector: UInt32(kCMIOObjectPropertyName))
    }

    static func deviceUID(of device: CMIOObjectID) -> String? {
        string(of: device, selector: UInt32(kCMIODevicePropertyDeviceUID))
    }

    static func uint32(of object: CMIOObjectID, selector: UInt32) -> UInt32? {
        var address = CMIO.address(selector)
        var value: UInt32 = 0
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &dataUsed, &value)
        return status == noErr ? value : nil
    }

    /// The CoreMediaIO device whose UID matches an AVCaptureDevice's uniqueID.
    static func device(withUID uid: String) -> CMIOObjectID? {
        devices().first { deviceUID(of: $0) == uid }
    }

    static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool? {
        uint32(of: device, selector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere)).map { $0 != 0 }
    }
}
