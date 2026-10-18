import AVFoundation
import Foundation
import OffSightCore

/// A minimal "meeting app": captures from a camera and records when frames arrive and their size.
final class CameraClient: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "offsight-test.client")
    private let lock = NSLock()
    private var times: [TimeInterval] = []
    private var sizes = Set<String>()

    static var offSightCamera: AVCaptureDevice? {
        AVCaptureDevice(uniqueID: OffSightConstants.deviceUUID.uuidString)
    }

    static var physicalCamera: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
    }

    init?(device: AVCaptureDevice?) {
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        self.device = device
        super.init()
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else { return nil }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
    }

    /// Starts capturing; returns when the session is running.
    func start() {
        lock.lock(); times.removeAll(); sizes.removeAll(); lock.unlock()
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return times.count
    }

    var frameSizes: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return sizes
    }

    /// Frames per second over the last `window` seconds.
    func fps(window: TimeInterval) -> Double {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        return Double(times.filter { now - $0 <= window }.count) / window
    }

    /// The longest gap between frames since `since` (systemUptime seconds).
    func maxGap(since: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let recent = times.filter { $0 >= since }
        guard recent.count > 1 else { return .infinity }
        return zip(recent.dropFirst(), recent).map { $0 - $1 }.max() ?? 0
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = ProcessInfo.processInfo.systemUptime
        var size = "?"
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            size = "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
        }
        lock.lock()
        times.append(time)
        if times.count > 2000 { times.removeFirst(times.count - 2000) }
        sizes.insert(size)
        lock.unlock()
    }
}
