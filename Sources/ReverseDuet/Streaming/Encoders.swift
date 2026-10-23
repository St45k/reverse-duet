import CoreImage
import CoreMedia
import Foundation
import ImageIO
import VideoToolbox

/// One encoded video frame plus the wire framing the browser expects:
/// `[u8 codec][u8 flags][f64le capture time ms][payload]`.
struct EncodedFrame {
    let codec: VideoCodec
    let isKeyframe: Bool
    /// Capture time in ms since 1970, echoed back by the browser for latency stats.
    let timestamp: Double
    let payload: Data

    static let headerSize = 10

    var packet: Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(codec.wireType)
        data.append(isKeyframe ? 1 : 0)
        var bits = timestamp.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}

enum EncoderError: LocalizedError {
    case sessionCreation(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreation(let status): return "Couldn't start the H.264 encoder (\(status))."
        }
    }
}

/// Hardware H.264 encoder producing Annex B access units (what WebCodecs'
/// VideoDecoder accepts when no `description` is configured).
final class H264Encoder {
    var onEncoded: ((EncodedFrame) -> Void)?

    private var session: VTCompressionSession?
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else { throw EncoderError.sessionCreation(status) }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        let bytesPerSecondCap = Double(bitrate) * 1.5 / 8
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: bytesPerSecondCap), NSNumber(value: 1.0)] as CFArray)
        // Screens are often static, so key frames are mostly requested on demand.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 5 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool, timestamp: Double) {
        guard let session else { return }
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            if let frame = Self.annexB(from: sampleBuffer, timestamp: timestamp) {
                self.onEncoded?(frame)
            }
        }
    }

    /// Converts VideoToolbox's AVCC output (length-prefixed NAL units) into
    /// Annex B, prefixing SPS/PPS on key frames.
    private static func annexB(from sampleBuffer: CMSampleBuffer, timestamp: Double) -> EncodedFrame? {
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            isKeyframe = !notSync
        }

        var output = Data()
        var nalLengthSize: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLengthSize)
            if isKeyframe {
                for index in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                        let pointer {
                        output.append(contentsOf: startCode)
                        output.append(pointer, count: size)
                    }
                }
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }

        let prefix = Int(nalLengthSize)
        var offset = 0
        while offset + prefix <= length {
            var nalLength = 0
            for i in 0..<prefix { nalLength = (nalLength << 8) | Int(bytes[offset + i]) }
            offset += prefix
            guard nalLength > 0, offset + nalLength <= length else { break }
            output.append(contentsOf: startCode)
            output.append(contentsOf: bytes[offset..<(offset + nalLength)])
            offset += nalLength
        }
        return EncodedFrame(codec: .h264, isKeyframe: isKeyframe, timestamp: timestamp, payload: output)
    }
}

/// Fallback for browsers without WebCodecs: every frame is a standalone JPEG.
final class JPEGEncoder {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let quality: Double

    init(quality: Double) {
        self.quality = quality
    }

    func encode(_ pixelBuffer: CVPixelBuffer, timestamp: Double) -> EncodedFrame? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else { return nil }
        return EncodedFrame(codec: .jpeg, isKeyframe: true, timestamp: timestamp, payload: data)
    }
}
