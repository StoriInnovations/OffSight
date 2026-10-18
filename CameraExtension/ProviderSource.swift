import CoreMediaIO
import Foundation
import OffSightCore
import os

/// Publishes OffSight Camera. Its single format is the live camera's native size as reported by
/// OffSight.app; a new size is stored and the device re-registered once no app is streaming, so no
/// meeting app ever sees the resolution change mid-call.
final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "provider")
    private let lock = NSLock()
    private var _deviceSource: DeviceSource!
    private var pendingFormat: Dimensions?
    private let formatQueue = DispatchQueue(label: "com.storiinnovations.offsight.extension.format")

    private var deviceSource: DeviceSource {
        lock.lock(); defer { lock.unlock() }
        return _deviceSource
    }

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        publishDevice(format: FormatStore.load())
    }

    private func publishDevice(format: Dimensions) {
        let device = DeviceSource(localizedName: OffSightConstants.deviceName, format: format)
        device.onFormatRequest = { [weak self] requested in
            self?.formatQueue.async { self?.handleFormatRequest(requested) }
        }
        device.onIdle = { [weak self] in
            self?.formatQueue.async { self?.applyPendingFormatIfIdle() }
        }
        do {
            try provider.addDevice(device.device)
        } catch {
            log.fault("Failed to add device: \(error.localizedDescription, privacy: .public)")
        }
        lock.lock()
        _deviceSource = device
        lock.unlock()
    }

    private func handleFormatRequest(_ requested: Dimensions) {
        guard OffSightConstants.isAcceptableFormat(requested) else {
            log.error("Ignoring unacceptable format request \(requested.description, privacy: .public)")
            return
        }
        guard requested != deviceSource.format else {
            pendingFormat = nil
            return
        }
        if pendingFormat != requested {
            log.notice("Camera format \(requested.description, privacy: .public) requested; applying when idle")
            FormatStore.save(requested)
            pendingFormat = requested
            deviceSource.setPendingFormat(requested)
        }
        applyPendingFormatIfIdle()
    }

    private func applyPendingFormatIfIdle() {
        guard let format = pendingFormat else { return }
        let current = deviceSource
        guard current.isIdle else { return }
        pendingFormat = nil
        current.shutdown()
        do {
            try provider.removeDevice(current.device)
        } catch {
            log.error("Failed to remove device for re-registration: \(error.localizedDescription, privacy: .public)")
        }
        log.notice("Re-registering OffSight Camera at \(format.description, privacy: .public)")
        publishDevice(format: format)
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

/// Remembers the advertised format across extension restarts (in the extension's own container).
enum FormatStore {
    private static let key = "OffSightCameraFormat"

    static func load() -> Dimensions {
        if let value = UserDefaults.standard.string(forKey: key) {
            let parts = value.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 {
                let format = Dimensions(width: parts[0], height: parts[1])
                if OffSightConstants.isAcceptableFormat(format) { return format }
            }
        }
        return OffSightConstants.defaultFormat
    }

    static func save(_ format: Dimensions) {
        UserDefaults.standard.set("\(format.width)x\(format.height)", forKey: key)
    }
}
