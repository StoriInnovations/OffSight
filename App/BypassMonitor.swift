import AVFoundation
import CoreMediaIO
import Foundation
import OffSightCore
import os

/// Detects any other app using a physical camera directly, bypassing OffSight (UR-35, §8).
/// OffSight Camera never opens a physical camera and OffSight.app's own use is excluded, so any
/// use reported here is a bypass.
///
/// Two signals are combined (spike S4): AVFoundation's `isInUseByAnotherApplication` and
/// CoreMediaIO's "device is running somewhere". The second also counts OffSight's own capture,
/// so it is only trusted while OffSight is not capturing.
final class BypassMonitor: NSObject {
    struct CameraSignal {
        let name: String
        let uniqueID: String
        let avInUseByAnotherApp: Bool
        let cmioRunningSomewhere: Bool?
        let counted: Bool
    }

    var onChange: (() -> Void)?
    /// Returns true while OffSight's own capture session is running.
    var ownCaptureRunning: () -> Bool = { false }

    private(set) var camerasInUse: [String] = []
    private(set) var lastSignals: [CameraSignal] = []
    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "bypass")
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var devicesObservation: NSKeyValueObservation?
    private var inUseObservations: [String: NSKeyValueObservation] = [:]
    private var pollTimer: Timer?

    private static let virtualTransport = Int32(bitPattern: 0x7669_7274) // 'virt'

    static var deviceTypes: [AVCaptureDevice.DeviceType] {
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

    static func allCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified).devices
    }

    static func physicalCameras() -> [AVCaptureDevice] {
        allCameras().filter(isPhysical)
    }

    func start() {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: Self.deviceTypes, mediaType: .video, position: .unspecified)
        discovery = session
        devicesObservation = session.observe(\.devices, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }
        // KVO alone may not fire for every change; poll as a fallback (spike S4).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func refreshDevices() {
        guard let discovery else { return }
        let devices = discovery.devices.filter(Self.isPhysical)
        let ids = Set(devices.map(\.uniqueID))
        for id in inUseObservations.keys where !ids.contains(id) {
            inUseObservations[id] = nil
        }
        for device in devices where inUseObservations[device.uniqueID] == nil {
            inUseObservations[device.uniqueID] = device.observe(\.isInUseByAnotherApplication, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.poll() }
            }
        }
        poll()
    }

    private func poll() {
        guard let discovery else { return }
        let ownRunning = ownCaptureRunning()
        var signals: [CameraSignal] = []
        for device in discovery.devices where Self.isPhysical(device) {
            let avInUse = device.isInUseByAnotherApplication
            let running = CMIO.device(withUID: device.uniqueID).flatMap(CMIO.isRunningSomewhere)
            let counted = avInUse || (!ownRunning && running == true)
            signals.append(CameraSignal(name: device.localizedName, uniqueID: device.uniqueID,
                                        avInUseByAnotherApp: avInUse, cmioRunningSomewhere: running, counted: counted))
        }
        lastSignals = signals
        let names = signals.filter(\.counted).map(\.name).sorted()
        guard names != camerasInUse else { return }
        if !names.isEmpty {
            log.notice("Bypass detected: \(names.joined(separator: ", "), privacy: .public)")
        }
        camerasInUse = names
        onChange?()
    }

    var bypassDetected: Bool { !camerasInUse.isEmpty }
}
