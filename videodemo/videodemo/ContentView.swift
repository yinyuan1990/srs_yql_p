//
//  ContentView.swift
//  videodemo
//
//  Created by h3r4 on 2025/12/27.
//

import SwiftUI
import AVFoundation
import Photos
import Combine

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.videoPreviewLayer.session = session
        if let connection = view.videoPreviewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        if let connection = uiView.videoPreviewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}

final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var isRecording = false
    @Published var statusMessage = "准备就绪"
    @Published var cameraPosition: AVCaptureDevice.Position = .front
    @Published var activeFPS: Double = 0
    @Published var formatSize: CGSize = .zero
    @Published var permissionDenied = false

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "videodemo.camera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "videodemo.camera.video")
    private let writerQueue = DispatchQueue(label: "videodemo.camera.writer")
    private let sizeQueue = DispatchQueue(label: "videodemo.camera.size")
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var isWriting = false
    private var videoAssetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var firstSampleTime: CMTime?
    private var currentFormatSize: CGSize = .zero
    private let ciContext = CIContext()
    private var currentFrameDuration: CMTime = .invalid

    func requestPermissionsAndStart() {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.permissionDenied = !granted
                if granted {
                    self.startSession()
                } else {
                    self.statusMessage = "相机权限被拒绝"
                }
            }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    func startSession() {
        sessionQueue.async {
            if !self.isConfigured {
                self.configureSession(position: self.cameraPosition)
                self.isConfigured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func toggleRecording() {
        writerQueue.async {
            if self.isWriting {
                self.stopWriting()
            } else {
                self.startWriting()
            }
        }
    }

    func switchCamera() {
        sessionQueue.async {
            let newPosition: AVCaptureDevice.Position = (self.cameraPosition == .front) ? .back : .front
            self.configureSession(position: newPosition)
            DispatchQueue.main.async {
                self.cameraPosition = newPosition
            }
        }
    }

    private func configureSession(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        if let input = videoDeviceInput {
            session.removeInput(input)
        }
        if session.outputs.contains(videoOutput) {
            session.removeOutput(videoOutput)
        }

        guard let device = Self.pickDevice(position: position) else {
            DispatchQueue.main.async { self.statusMessage = "未找到摄像头" }
            session.commitConfiguration()
            return
        }

        let targetFPS = Self.targetFPS(for: position)
        let selection = Self.selectFormat(device: device, targetFPS: targetFPS)
        if let selection {
            do {
                try device.lockForConfiguration()
                device.activeFormat = selection.format
                let fps = selection.actualFPS
                let duration = CMTimeMake(value: 1, timescale: Int32(fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.activeFPS = fps
                    self.formatSize = selection.size
                    if selection.actualFPS < targetFPS {
                        self.statusMessage = "未找到 \(Int(targetFPS))fps"
                    } else {
                        self.statusMessage = "已配置 \(Int(fps))fps"
                    }
                }
                self.sizeQueue.sync {
                    self.currentFormatSize = selection.size
                }
                self.currentFrameDuration = duration
            } catch {
                DispatchQueue.main.async { self.statusMessage = "配置失败：\(error.localizedDescription)" }
            }
        } else {
            DispatchQueue.main.async { self.statusMessage = "未找到合适的 4:3 格式" }
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                videoDeviceInput = input
            }
        } catch {
            DispatchQueue.main.async { self.statusMessage = "输入添加失败：\(error.localizedDescription)" }
        }

        if session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
            session.addOutput(videoOutput)
            if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
            }
        }

        session.commitConfiguration()
    }

    private static func pickDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }

    private static func targetFPS(for position: AVCaptureDevice.Position) -> Double {
        // 注意：大多数 iPhone 前置摄像头最高 60fps，只有 iPhone 16 Pro 等支持 120fps
        // 后置摄像头慢动作通常支持 240fps
        position == .front ? 120.0 : 240.0
    }

    private struct FormatChoice {
        let format: AVCaptureDevice.Format
        let size: CGSize
        let maxFPS: Double
        let actualFPS: Double
        let area: Int
        let isFourByThree: Bool
    }

    private static func selectFormat(device: AVCaptureDevice, targetFPS: Double) -> (format: AVCaptureDevice.Format, size: CGSize, actualFPS: Double, isFourByThree: Bool)? {
        var candidates: [FormatChoice] = []
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)
            if w == 0 || h == 0 { continue }
            let maxFPS = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            let size = CGSize(width: w, height: h)
            let isFourByThree = (w * 3 == h * 4)
            candidates.append(
                FormatChoice(
                    format: format,
                    size: size,
                    maxFPS: maxFPS,
                    actualFPS: min(targetFPS, maxFPS),
                    area: w * h,
                    isFourByThree: isFourByThree
                )
            )
        }

        let fourByThree = candidates.filter { $0.isFourByThree }
        let preferred = fourByThree.filter { $0.maxFPS >= targetFPS }
        let sortedPreferred = preferred.sorted { ($0.maxFPS, $0.area) > ($1.maxFPS, $1.area) }
        if let best = sortedPreferred.first {
            return (best.format, best.size, best.actualFPS, best.isFourByThree)
        }

        let anyAtTarget = candidates.filter { $0.maxFPS >= targetFPS }
        let sortedAnyAtTarget = anyAtTarget.sorted { ($0.maxFPS, $0.area) > ($1.maxFPS, $1.area) }
        if let best = sortedAnyAtTarget.first {
            return (best.format, best.size, best.actualFPS, best.isFourByThree)
        }

        let sortedFourByThree = fourByThree.sorted { ($0.maxFPS, $0.area) > ($1.maxFPS, $1.area) }
        if let best = sortedFourByThree.first {
            return (best.format, best.size, best.actualFPS, best.isFourByThree)
        }

        let sortedAny = candidates.sorted { ($0.maxFPS, $0.area) > ($1.maxFPS, $1.area) }
        if let best = sortedAny.first {
            return (best.format, best.size, best.actualFPS, best.isFourByThree)
        }

        return nil
    }

    private static func makeTempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }

    private func startWriting() {
        recordingURL = Self.makeTempURL()
        firstSampleTime = nil
        isWriting = true
        DispatchQueue.main.async {
            self.isRecording = true
            self.statusMessage = "录制中..."
        }
    }

    private func setupWriter(outputSize: CGSize, timestamp: CMTime) -> Bool {
        guard let url = recordingURL else { return false }

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let width = Int(outputSize.width)
            let height = Int(outputSize.height)
            let compression: [String: Any] = [
                AVVideoAverageBitRateKey: max(width * height * 6, 2_000_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )

            if writer.canAdd(input) {
                writer.add(input)
            }

            videoAssetWriter = writer
            videoWriterInput = input
            pixelBufferAdaptor = adaptor

            writer.startWriting()
            writer.startSession(atSourceTime: timestamp)
            firstSampleTime = timestamp
            return true
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "录制初始化失败：\(error.localizedDescription)"
            }
            return false
        }
    }

    private func stopWriting() {
        guard isWriting else { return }
        isWriting = false
        let urlToSave = recordingURL

        // 如果 writer 还没创建（没有收到任何帧），直接取消
        guard let writer = videoAssetWriter, writer.status == .writing else {
            videoAssetWriter?.cancelWriting()
            cleanupWriter(deleteFile: true)
            DispatchQueue.main.async {
                self.isRecording = false
                self.statusMessage = "录制已取消（无有效帧）"
            }
            return
        }

        videoWriterInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isRecording = false
                self.statusMessage = "正在保存到相册..."
            }
            self.cleanupWriter(deleteFile: false)
            if let url = urlToSave, writer.status == .completed {
                self.saveToPhotoLibrary(url: url)
            } else {
                DispatchQueue.main.async {
                    self.statusMessage = "录制失败：\(writer.error?.localizedDescription ?? "未知错误")"
                }
                if let url = urlToSave {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func cleanupWriter(deleteFile: Bool = true) {
        if deleteFile, let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        videoAssetWriter = nil
        videoWriterInput = nil
        pixelBufferAdaptor = nil
        firstSampleTime = nil
    }

    private func saveToPhotoLibrary(url: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { [weak self] success, saveError in
            DispatchQueue.main.async {
                if success {
                    self?.statusMessage = "已保存到相册"
                } else if let saveError {
                    self?.statusMessage = "保存失败：\(saveError.localizedDescription)"
                } else {
                    self?.statusMessage = "保存失败"
                }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func targetCropSize(for inputSize: CGSize) -> CGSize {
        let targetAspect: CGFloat = 4.0 / 3.0
        let inputAspect = inputSize.width / max(inputSize.height, 1)

        if inputAspect >= targetAspect {
            let height = inputSize.height
            let width = height * targetAspect
            return CGSize(width: width, height: height)
        } else {
            let width = inputSize.width
            let height = width / targetAspect
            return CGSize(width: width, height: height)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isWriting else { return }

        var copyBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleBufferOut: &copyBuffer)
        guard status == noErr, let buffer = copyBuffer else { return }

        writerQueue.async { [weak self] in
            guard let self, self.isWriting else {
                return
            }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
            let inputSize = CGSize(
                width: CVPixelBufferGetWidth(imageBuffer),
                height: CVPixelBufferGetHeight(imageBuffer)
            )
            let outputSize = self.targetCropSize(for: inputSize)
            if self.firstSampleTime == nil {
                guard self.setupWriter(outputSize: outputSize, timestamp: timestamp) else {
                    return
                }
            }

            guard let writer = self.videoAssetWriter,
                  let input = self.videoWriterInput,
                  let adaptor = self.pixelBufferAdaptor,
                  writer.status == .writing,
                  input.isReadyForMoreMediaData,
                  let pool = adaptor.pixelBufferPool
            else {
                return
            }

            var outputBuffer: CVPixelBuffer?
            let createStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
            guard createStatus == kCVReturnSuccess, let outBuffer = outputBuffer else { return }

            let cropWidth = outputSize.width
            let cropHeight = outputSize.height
            let x = max((inputSize.width - cropWidth) / 2.0, 0)
            let y = max((inputSize.height - cropHeight) / 2.0, 0)
            let cropRect = CGRect(x: x, y: y, width: cropWidth, height: cropHeight)

            let image = CIImage(cvPixelBuffer: imageBuffer)
            let cropped = image.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -x, y: -y))
            self.ciContext.render(cropped, to: outBuffer)

            adaptor.append(outBuffer, withPresentationTime: timestamp)
        }
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()

    var body: some View {
        ZStack {
            // 全屏预览
            if camera.permissionDenied {
                Color.black
                    .ignoresSafeArea()
                Text("请在设置中允许相机权限")
                    .foregroundStyle(.white)
            } else {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
            }

            VStack {
                VStack(spacing: 4) {
                    Text(camera.statusMessage)
                        .font(.footnote)
//                    Text("摄像头: \(camera.cameraPosition == .front ? "前置" : "后置") | FPS: \(Int(camera.activeFPS)) | 分辨率: \(Int(camera.formatSize.width))x\(Int(camera.formatSize.height))")
//                        .font(.caption)
                    
                    Text("摄像头: \(camera.cameraPosition == .front ? "前置" : "后置")")
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.top, 60)

                Spacer()

                HStack(spacing: 40) {
                    Button(action: camera.switchCamera) {
                        Image(systemName: "camera.rotate")
                            .font(.title)
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .disabled(camera.isRecording)

                    Button(action: camera.toggleRecording) {
                        ZStack {
                            Circle()
                                .stroke(.white, lineWidth: 4)
                                .frame(width: 80, height: 80)
                            if camera.isRecording {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.red)
                                    .frame(width: 32, height: 32)
                            } else {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 64, height: 64)
                            }
                        }
                    }

                    Color.clear
                        .frame(width: 60, height: 60)
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear { camera.requestPermissionsAndStart() }
        .onDisappear { camera.stopSession() }
    }
}

#Preview {
    ContentView()
}
