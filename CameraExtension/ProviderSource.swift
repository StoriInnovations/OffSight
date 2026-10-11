import CoreMediaIO
import Foundation
import OffSightCore
import os

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!
    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "provider")

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: OffSightConstants.deviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            log.fault("Failed to add device: \(error.localizedDescription, privacy: .public)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        log.info("Client connected pid=\(client.pid) signingID=\(client.signingID ?? "nil", privacy: .public)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        log.info("Client disconnected pid=\(client.pid)")
        deviceSource.clientDisconnected(client)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = OffSightConstants.manufacturer
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

extension CMIOExtensionClient {
    /// The client's signing ID, or nil when CoreMediaIO does not provide one.
    /// Spike S2 found that macOS reports the literal string "unknown" for every client.
    var knownSigningID: String? {
        guard let id = signingID, !id.isEmpty, id != "unknown" else { return nil }
        return id
    }
}
