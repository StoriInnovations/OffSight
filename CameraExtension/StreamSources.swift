import CoreMediaIO
import Foundation
import OffSightCore

private let frameDuration = CMTime(value: 1, timescale: OffSightConstants.frameRate)

/// The stream meeting apps read from.
final class SourceStreamSource: NSObject, CMIOExtensionStreamSource {
    static let snapshotProperty = CMIOExtensionProperty(rawValue: OffSightConstants.snapshotPropertyName)

    private(set) var stream: CMIOExtensionStream!
    private unowned let device: DeviceSource
    private let streamFormats: [CMIOExtensionStreamFormat]

    init(localizedName: String, streamID: UUID, streamFormats: [CMIOExtensionStreamFormat], device: DeviceSource) {
        self.device = device
        self.streamFormats = streamFormats
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { streamFormats }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, Self.snapshotProperty]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = device.currentFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = frameDuration
        }
        if properties.contains(Self.snapshotProperty) {
            streamProperties.setPropertyState(CMIOExtensionPropertyState(value: device.snapshotJSON() as NSString),
                                              forProperty: Self.snapshotProperty)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            device.setActiveFormatIndex(index)
        }
        // The snapshot property is read-only: writes from any client are ignored (threat T3).
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // Every meeting app may start the stream; what it receives is decided by the frame gate.
        device.sourceClientStarting(client)
        return true
    }

    func startStream() throws {
        device.startSourceStreaming()
    }

    func stopStream() throws {
        device.stopSourceStreaming()
    }
}

/// The stream OffSight.app writes frames into. Only the authenticated app may start it.
final class SinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let device: DeviceSource
    private let streamFormats: [CMIOExtensionStreamFormat]

    init(localizedName: String, streamID: UUID, streamFormats: [CMIOExtensionStreamFormat], device: DeviceSource) {
        self.device = device
        self.streamFormats = streamFormats
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { streamFormats }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = device.currentFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = frameDuration
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 2
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        device.authorizeSinkClient(client)
    }

    func startStream() throws {
        device.startSink()
    }

    func stopStream() throws {
        device.stopSink()
    }
}
