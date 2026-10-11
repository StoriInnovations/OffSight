import AVFoundation
import Foundation
import OffSightCore
import os

/// Detects any other app using a physical camera directly, bypassing OffSight (UR-35, §8).
/// OffSight Camera never opens a physical camera and OffSight.app's own use is excluded by
/// `isInUseByAnotherApplication`, so any use reported here is a bypass.
final class BypassMonitor: NSObject {
    var onChange: (() -> Void)?

    private(set) var camerasInUse: [String] = []
    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "bypass")
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var devicesObservation: NSKeyValueObservation?
    private var inUseObservations: [String: NSKeyValueObservation] = [:]
    private var inUse: [String: (name: String, inUse: Bool)] = [:]

    private static let virtualTransport = Int32(bitPattern: 0x7669_7274) // 'virt'

    private static var deviceTypes: [AVCaptureDevice.DeviceType] {
        if #available(macOS 14.0, *) {
            return [.builtInWideAngleCamera, .external, .continuityCamera]
        } else {
            return [.builtInWideAngleCamera, .externalUnknown]
        }
    }

    static func isPhysical(_ device: AVCaptureDevice) -> Bool {
        device.transportType != virtualTransport
            && device.uniqueID != OffSightConstants.deviceUUID.uuidString
            && device.localizedName != OffSightConstants.deviceName
    }

    static func physicalCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
            .devices.filter(isPhysical)
    }

    func start() {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: Self.deviceTypes, mediaType: .video, position: .unspecified)
        discovery = session
        devicesObservation = session.observe(\.devices, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }
    }

    private func refreshDevices() {
        guard let discovery else { return }
        let devices = discovery.devices.filter(Self.isPhysical)
        let ids = Set(devices.map(\.uniqueID))
        for id in inUseObservations.keys where !ids.contains(id) {
            inUseObservations[id] = nil
            inUse[id] = nil
        }
        for device in devices where inUseObservations[device.uniqueID] == nil {
            let id = device.uniqueID
            let name = device.localizedName
            inUseObservations[id] = device.observe(\.isInUseByAnotherApplication, options: [.initial, .new]) { [weak self] device, _ in
                let busy = device.isInUseByAnotherApplication
                DispatchQueue.main.async { self?.update(id: id, name: name, inUse: busy) }
            }
        }
        recompute()
    }

    private func update(id: String, name: String, inUse busy: Bool) {
        inUse[id] = (name, busy)
        if busy {
            log.notice("Bypass: \(name, privacy: .public) is in use by another app")
        }
        recompute()
    }

    private func recompute() {
        let names = inUse.values.filter { $0.inUse }.map { $0.name }.sorted()
        guard names != camerasInUse else { return }
        camerasInUse = names
        onChange?()
    }

    var bypassDetected: Bool { !camerasInUse.isEmpty }
}
