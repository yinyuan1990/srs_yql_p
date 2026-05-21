//
//  FrameThrottler.swift
//  金凤凰
//
//  从 WebRTCManager.swift 拆分 — 帧节流器（整除跳帧算法）
//

import Foundation
import WebRTC
import CoreImage

// MARK: - 帧节流器（整除跳帧算法：确保帧时间戳等差分布）
final class FrameThrottler: NSObject, RTCVideoCapturerDelegate {
    weak var inner: RTCVideoCapturerDelegate?
    weak var previewDelegate: RTCVideoCapturerDelegate?
    var videoFilter: VideoFilterPipeline?

    /// 编码前降噪开关（P1画质优化：消除噪点，让编码器把码率用于真实细节）
    var noiseReductionEnabled: Bool = true
    var noiseReductionLevel: Float = 0.02
    var noiseReductionSharpness: Float = 0.5

    /// 编码前降噪 CIContext（复用，避免每帧创建）
    private lazy var denoiseContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private func applyFilter(_ frame: RTCVideoFrame) -> RTCVideoFrame {
        guard let filter = videoFilter, !filter.isPassThrough else { return frame }
        guard let cvBuffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return frame }
        guard let processed = filter.processFrame(cvBuffer) else { return frame }

        // P1: 编码前降噪 — 消除传感器噪点，让编码器不浪费码率编码噪点
        var finalBuffer = processed
        if noiseReductionEnabled {
            if let denoised = applyNoiseReduction(to: processed) {
                finalBuffer = denoised
            }
        }

        // P1: 锐化 — 如果 sharpness > 0 则应用 CISharpenLuminance
        if let sharpness = videoFilter?.sharpness, sharpness > 0.01 {
            if let sharpened = applySharpen(to: finalBuffer, amount: sharpness) {
                finalBuffer = sharpened
            }
        }

        let newBuffer = RTCCVPixelBuffer(pixelBuffer: finalBuffer)
        return RTCVideoFrame(
            buffer: newBuffer,
            rotation: frame.rotation,
            timeStampNs: frame.timeStampNs
        )
    }

    /// CINoiseReduction 降噪
    private func applyNoiseReduction(to pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let filter = CIFilter(name: "CINoiseReduction") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(noiseReductionLevel, forKey: "inputNoiseLevel")
        filter.setValue(noiseReductionSharpness, forKey: "inputSharpness")
        guard let output = filter.outputImage else { return nil }
        denoiseContext.render(output, to: pixelBuffer)
        return pixelBuffer
    }

    /// CISharpenLuminance 锐化
    private func applySharpen(to pixelBuffer: CVPixelBuffer, amount: Float) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let filter = CIFilter(name: "CISharpenLuminance") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(amount * 2.0, forKey: kCIInputSharpnessKey)
        guard let output = filter.outputImage else { return nil }
        denoiseContext.render(output, to: pixelBuffer)
        return pixelBuffer
    }

    private var maxAllowedFps: Int = 60

    var captureFps: Int = 60 {
        didSet { updateAccumulatorParams() }
    }

    var targetSendFps: Int = 30 {
        didSet {
            if targetSendFps > maxAllowedFps { targetSendFps = maxAllowedFps }
            if targetSendFps < 1 { targetSendFps = 1 }
            updateAccumulatorParams()
            print("🎯 [FrameThrottler] 推送目标FPS变更: \(oldValue) → \(targetSendFps)")
        }
    }

    /// P2: 240fps 模式时提升上限
    func setMaxAllowedFps(_ fps: Int) {
        maxAllowedFps = fps
        print("🎯 [FrameThrottler] FPS上限变更: \(maxAllowedFps)")
    }

    private var sendAccumulator: Int = 0
    private var previewAccumulator: Int = 0

    private let rtpClockRate: Int64 = 90_000
    private var rtp90kTimestamp: Int64 = 0
    private var rtp90kStep: Int64 = 1500
    private var isFirstFrame: Bool = true

    private let previewFps: Int = 15
    private var previewSentCounter: Int = 0

    private var detectedCaptureFps: Int = 60
    private var captureFpsDetectCounter: Int = 0
    private var captureFpsDetectStartTime: Double = 0

    var fpsReportHandler: ((Int, Int) -> Void)?
    private var lastReportTsSec: Double = 0
    private var captureCounter: Int = 0
    private var sentCounter: Int = 0
    private var lastFrameWidth: Int32 = 0
    private var lastFrameHeight: Int32 = 0
    private var lastOriginalRotation: RTCVideoRotation = ._0

    var isFrontCamera: Bool = false
    var currentProfileName: String = "unknown"
    var expectedCaptureWidth: Int = 0
    var expectedCaptureHeight: Int = 0
    var expectedOutputWidth: Int = 0
    var expectedOutputHeight: Int = 0
    var currentScaleDown: Double = 1.0
    var hasReceivedFrame: Bool = false

    private var diagCapCount: Int = 0
    private var diagPushCount: Int = 0
    private var diagTimer: Timer?
    private let diagQueue = DispatchQueue(label: "fps.diag", qos: .utility)

    override init() {
        super.init()
        updateAccumulatorParams()
        startDiagTimer()
    }

    deinit { stopDiagTimer() }

    private func startDiagTimer() {
        stopDiagTimer()
        diagTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.diagQueue.async {
                let cap = self.diagCapCount
                let push = self.diagPushCount
                let target = self.targetSendFps
                self.diagCapCount = 0
                self.diagPushCount = 0
                _ = (cap, push, target)
            }
        }
    }

    private func stopDiagTimer() { diagTimer?.invalidate(); diagTimer = nil }

    // MARK: - 累加器算法

    private func updateAccumulatorParams() {
        let captureRate = max(1, captureFps)
        let targetRate = max(1, min(targetSendFps, maxAllowedFps))
        rtp90kStep = rtpClockRate / Int64(targetRate)
        let intervalMs = Double(rtp90kStep) * 1000.0 / Double(rtpClockRate)
        print("📊 [FrameThrottler] 90k RTP时钟参数更新:")
        print("   采集=\(captureRate)fps")
        print("   推送=\(targetRate)fps")
        print("   90k步进=\(rtp90kStep) ticks/帧 (间隔\(String(format: "%.3f", intervalMs))ms)")
        print("   预览=\(previewFps)fps")
        if rtpClockRate % Int64(targetRate) != 0 {
            print("⚠️ [FrameThrottler] 警告: \(targetRate)fps 不能整除90000，可能有微小误差")
        }
        sendAccumulator = 0
        previewAccumulator = 0
    }

    private func shouldSendPushFrame() -> Bool {
        sendAccumulator += targetSendFps
        if sendAccumulator >= captureFps {
            sendAccumulator -= captureFps
            return true
        }
        return false
    }

    private func shouldSendPreviewFrame() -> Bool {
        previewAccumulator += previewFps
        if previewAccumulator >= captureFps {
            previewAccumulator -= captureFps
            return true
        }
        return false
    }

    // MARK: - RTCVideoCapturerDelegate

    func capturer(_ capturer: RTCVideoCapturer, didCapture videoFrame: RTCVideoFrame) {
        let nowSec = CFAbsoluteTimeGetCurrent()
        captureCounter += 1
        diagCapCount += 1
        lastFrameWidth = videoFrame.width
        lastFrameHeight = videoFrame.height
        lastOriginalRotation = videoFrame.rotation

        if isFirstFrame {
            isFirstFrame = false
            hasReceivedFrame = true
            let step = rtp90kStep
            DispatchQueue.global(qos: .utility).async {
                print("🎬 [FrameThrottler] 首帧，90k RTP时钟从0开始，步进=\(step)")
            }
        }

        captureFpsDetectCounter += 1
        if captureFpsDetectStartTime == 0 {
            captureFpsDetectStartTime = nowSec
        } else if nowSec - captureFpsDetectStartTime >= 1.0 {
            let newDetectedFps = captureFpsDetectCounter
            if abs(newDetectedFps - captureFps) > 5 {
                let detected = newDetectedFps
                let expected = captureFps
                DispatchQueue.global(qos: .utility).async {
                    print("⚠️ [FrameThrottler] 检测FPS(\(detected))与设置FPS(\(expected))差距较大")
                }
            }
            detectedCaptureFps = max(1, newDetectedFps)
            captureFpsDetectCounter = 0
            captureFpsDetectStartTime = nowSec
        }

        if shouldSendPreviewFrame() {
            sendPreviewFrame(capturer, videoFrame: videoFrame)
        }
        if shouldSendPushFrame() {
            sendFrameWithArithmeticTimestamp(capturer, videoFrame: videoFrame)
        }

        if lastReportTsSec == 0 { lastReportTsSec = nowSec }
        if (nowSec - lastReportTsSec) >= 1.0 {
            let cap = captureCounter
            let snd = sentCounter
            DispatchQueue.main.async { [weak self] in
                self?.fpsReportHandler?(cap, snd)
            }
            captureCounter = 0
            sentCounter = 0
            previewSentCounter = 0
            lastReportTsSec = nowSec
        }
    }

    // MARK: - 发送方法

    private func sendPreviewFrame(_ capturer: RTCVideoCapturer, videoFrame: RTCVideoFrame) {
        previewSentCounter += 1
        let fixedFrame = RTCVideoFrame(
            buffer: videoFrame.buffer,
            rotation: ._0,
            timeStampNs: videoFrame.timeStampNs
        )
        previewDelegate?.capturer(capturer, didCapture: fixedFrame)
    }

    private func sendFrameWithArithmeticTimestamp(_ capturer: RTCVideoCapturer, videoFrame: RTCVideoFrame) {
        sentCounter += 1
        diagPushCount += 1
        let timestampNs = rtp90kTimestamp * 1_000_000_000 / rtpClockRate
        rtp90kTimestamp += rtp90kStep
        // 240fps 模式跳过滤镜（滤镜处理>4ms，会拖慢帧率）
        let outputFrame: RTCVideoFrame
        if targetSendFps >= 240 {
            outputFrame = videoFrame
        } else {
            outputFrame = applyFilter(videoFrame)
        }
        let fixedFrame = RTCVideoFrame(
            buffer: outputFrame.buffer,
            rotation: ._0,
            timeStampNs: timestampNs
        )
        inner?.capturer(capturer, didCapture: fixedFrame)
    }

    private func sendFrame(_ capturer: RTCVideoCapturer, videoFrame: RTCVideoFrame) {
        sentCounter += 1
        let filtered = applyFilter(videoFrame)
        let fixedFrame = RTCVideoFrame(
            buffer: filtered.buffer,
            rotation: ._0,
            timeStampNs: videoFrame.timeStampNs
        )
        inner?.capturer(capturer, didCapture: fixedFrame)
    }

    func reset() {
        sendAccumulator = 0
        previewAccumulator = 0
        rtp90kTimestamp = 0
        isFirstFrame = true
        lastReportTsSec = 0
        captureCounter = 0
        sentCounter = 0
        previewSentCounter = 0
        captureFpsDetectCounter = 0
        captureFpsDetectStartTime = 0
    }

    func stop() { reset() }
}
