import CoreMediaIO
import Foundation
import OffSightCore

/// Reads OffSight Camera's own state straight from CoreMediaIO: the client snapshot the camera
/// extension publishes, including how many live, placeholder and fallback frames it has sent.
/// This is the ground truth for "what did meeting apps receive", independent of the app.
enum Probe {
    struct Counters: Equatable {
        var live: UInt64
        var appPlaceholder: UInt64
        var fallback: UInt64
        var placeholders: UInt64 { appPlaceholder + fallback }
    }

    /// `after - before`, or 0 if the counters went back (the camera extension restarted).
    static func delta(_ after: UInt64, _ before: UInt64) -> UInt64 {
        after >= before ? after - before : 0
    }

    static func snapshot() -> ClientSnapshot? {
        guard let stream = sourceStream(),
              let json = string(of: stream, selector: fourCharCode(OffSightConstants.snapshotPropertyFourCC)) else { return nil }
        return ClientSnapshot.decode(json: json)
    }

    static func counters() -> Counters? {
        guard let source = snapshot()?.source else { return nil }
        return Counters(live: source.sentLive, appPlaceholder: source.sentAppPlaceholder, fallback: source.sentFallback)
    }

    /// Clients currently streaming from OffSight Camera.
    static func streamingClients() -> [ClientRecord] {
        snapshot()?.clients.filter(\.streaming) ?? []
    }

    // MARK: CoreMediaIO

    private static func sourceStream() -> CMIOStreamID? {
        guard let device = devices().first(where: { string(of: $0, selector: UInt32(kCMIODevicePropertyDeviceUID))
                                                == OffSightConstants.deviceUUID.uuidString }) else { return nil }
        return objectIDs(of: device, selector: UInt32(kCMIODevicePropertyStreams)).first {
            string(of: $0, selector: UInt32(kCMIOObjectPropertyName)) == OffSightConstants.sourceStreamName
        }
    }

    private static func address(_ selector: UInt32) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func devices() -> [CMIOObjectID] {
        objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: UInt32(kCMIOHardwarePropertyDevices))
    }

    private static func objectIDs(of object: CMIOObjectID, selector: UInt32) -> [CMIOObjectID] {
        var address = address(selector)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, dataSize, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func string(of object: CMIOObjectID, selector: UInt32) -> String? {
        var address = address(selector)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<CFString>.size) else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(object, &address, 0, nil, dataSize, &used, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
