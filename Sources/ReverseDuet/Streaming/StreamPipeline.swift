import CGVirtualDisplayBridge
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct StreamGeometry {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let codec: VideoCodec
    let isVirtual: Bool
}

/// Capture → encode for one connected browser.
///
/// Mirror mode captures the main display. Extend mode first creates a virtual
/// display sized to the browser's screen and captures that instead, which is
/// what turns the remote device into a real second monitor.
final class StreamPipeline: NSObject, SCStreamOutput, SCStreamDelegate {
    var onReady: ((StreamGeometry) -> Void)?
    var onFrame: ((EncodedFrame) -> Void)?
    var onError: ((String) -> Void)?

    private let params: StreamParameters
    private let codec: VideoCodec
    private let client: ClientScreen
    private let clientName: String
    private let showsCursor: Bool
    private let serial: UInt32
    private let queue = DispatchQueue(label: "reverse-duet.pipeline", qos: .userInteractive)

    private var virtualDisplay: RDVirtualDisplay?
    private var stream: SCStream?
    private var h264: H264Encoder?
    private var jpeg: JPEGEncoder?
    private var lastPixelBuffer: CVPixelBuffer?
    private var forceKeyframe = true
    private var stopped = false

    init(params: StreamParameters, codec: VideoCodec, client: ClientScreen, clientName: String, showsCursor: Bool, serial: UInt32) {
        self.params = params
        self.codec = codec
        self.client = client
        self.clientName = clientName
        self.showsCursor = showsCursor
        self.serial = serial
    }

    // MARK: Lifecycle

    func start() {
        if params.mode == .extend {
            guard RDVirtualDisplay.isSupported else {
                fail("Extend mode isn't available on this Mac. Switch the device to Mirror.")
                return
            }
            let size = extendedSize()
            // CoreGraphics expects virtual displays to be created on the main thread.
            DispatchQueue.main.async { [self] in
                let display = RDVirtualDisplay(name: "Reverse Duet (\(clientName))", width: size.width, height: size.height,
                                               ppi: 110, hiDPI: size.hiDPI, refreshRate: Double(params.fps), serial: serial)
                queue.async { [self] in
                    guard !stopped else { return }
                    guard let display else {
                        fail("macOS refused to create the virtual display. Try Mirror mode.")
                        return
                    }
                    virtualDisplay = display
                    findDisplay(display.displayID, width: size.width, height: size.height, attempt: 0)
                }
            }
        } else {
            queue.async { [self] in
                let displayID = CGMainDisplayID()
                let size = mirroredSize(of: displayID)
                findDisplay(displayID, width: size.width, height: size.height, attempt: 0)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            onFrame = nil
            onReady = nil
            onError = nil
            h264?.invalidate()
            h264 = nil
            lastPixelBuffer = nil
            let display = virtualDisplay
            virtualDisplay = nil
            guard let stream else {
                Self.release(display)
                return
            }
            self.stream = nil
            stream.stopCapture { _ in Self.release(display) }
        }
    }

    /// The browser lost (or never had) decoder state; send a key frame now even
    /// if the screen isn't changing.
    func requestKeyframe() {
        queue.async { [self] in
            forceKeyframe = true
            if let buffer = lastPixelBuffer { encode(buffer) }
        }
    }

    private static func release(_ display: RDVirtualDisplay?) {
        guard let display else { return }
        DispatchQueue.main.async { withExtendedLifetime(display) {} }
    }

    // MARK: Geometry

    private static func even(_ value: Double) -> Int {
        max(2, Int(value) & ~1)
    }

    /// Virtual display size for Extend mode. Retina renders at 2x points so
    /// text stays crisp on high-density tablets.
    private func extendedSize() -> (width: Int, height: Int, hiDPI: Bool) {
        let width = Double(max(client.width, 320))
        let height = Double(max(client.height, 240))
        if params.retina, client.scale >= 1.5, width * 2 <= 4096, height * 2 <= 4096 {
            return (Self.even(width * 2), Self.even(height * 2), true)
        }
        let fit = min(1, 4096 / max(width, height))
        return (Self.even(width * fit), Self.even(height * fit), false)
    }

    /// Mirror size: the Mac's screen scaled to fit the browser's pixels.
    private func mirroredSize(of displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        let bounds = CGDisplayBounds(displayID)
        let mode = CGDisplayCopyDisplayMode(displayID)
        let nativeWidth = Double(mode?.pixelWidth ?? Int(bounds.width))
        let nativeHeight = Double(mode?.pixelHeight ?? Int(bounds.height))
        var scale = min(1, Double(max(client.pixelWidth, 320)) / nativeWidth, Double(max(client.pixelHeight, 240)) / nativeHeight)
        if !params.retina, bounds.width > 0 {
            scale = min(scale, Double(bounds.width) / nativeWidth)
        }
        scale = min(scale, 4096 / max(nativeWidth, nativeHeight))
        return (Self.even(nativeWidth * scale), Self.even(nativeHeight * scale))
    }

    // MARK: Capture

    private func findDisplay(_ displayID: CGDirectDisplayID, width: Int, height: Int, attempt: Int) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                if let display = content?.displays.first(where: { $0.displayID == displayID }) {
                    self.startCapture(display, width: width, height: height)
                } else if let error {
                    self.fail(Self.describe(error))
                } else if attempt < 20 {
                    // A freshly created virtual display takes a moment to show up.
                    self.queue.asyncAfter(deadline: .now() + 0.15) {
                        self.findDisplay(displayID, width: width, height: height, attempt: attempt + 1)
                    }
                } else {
                    self.fail("Couldn't find the display to capture.")
                }
            }
        }
    }

    private func startCapture(_ display: SCDisplay, width: Int, height: Int) {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(params.fps))
        configuration.pixelFormat = codec == .h264 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        configuration.showsCursor = showsCursor
        configuration.queueDepth = 6

        do {
            if codec == .h264 {
                let bitrate = Int(Double(width * height * params.fps) * params.quality.bitsPerPixel)
                let encoder = try H264Encoder(width: width, height: height, fps: params.fps,
                                              bitrate: min(max(bitrate, 2_000_000), 80_000_000))
                encoder.onEncoded = { [weak self] frame in self?.onFrame?(frame) }
                h264 = encoder
            } else {
                jpeg = JPEGEncoder(quality: params.quality.jpegQuality)
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            self.stream = stream
            stream.startCapture { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped else { return }
                    if let error {
                        self.fail(Self.describe(error))
                    } else {
                        self.onReady?(StreamGeometry(displayID: display.displayID, width: width, height: height,
                                                     codec: self.codec, isVirtual: self.virtualDisplay != nil))
                    }
                }
            }
        } catch {
            fail(Self.describe(error))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lastPixelBuffer = pixelBuffer
        encode(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            guard !stopped else { return }
            fail(Self.describe(error))
        }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer) {
        guard !stopped else { return }
        let timestamp = Date().timeIntervalSince1970 * 1000
        if let h264 {
            let force = forceKeyframe
            forceKeyframe = false
            h264.encode(pixelBuffer, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()),
                        forceKeyframe: force, timestamp: timestamp)
        } else if let jpeg, let frame = jpeg.encode(pixelBuffer, timestamp: timestamp) {
            onFrame?(frame)
        }
    }

    private func fail(_ message: String) {
        let handler = onError
        handler?(message)
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return "Screen Recording permission is needed. Grant it in System Settings › Privacy & Security."
        }
        return error.localizedDescription
    }
}
