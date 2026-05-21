//
//  VideoFilterPipeline.swift
//  金凤凰
//
//  从 WebRTCManager.swift 拆分 — 视频滤镜管道 (单个 Metal CIColorKernel)
//

import Foundation
import CoreImage
import Metal
import CoreVideo

// MARK: - ⭐ 视频滤镜管道 (单个 Metal CIColorKernel — GPU 统一处理)
//
// v3 重构 (解决发热 + 黑色变灰):
//   v2 用 3 个独立 CIFilter 串联 (CIColorControls + CIColorMatrix + CISharpenLuminance),
//   每帧 3 次 GPU dispatch + ISP 上下文切换, 是发热大头.
//   v3 把所有色彩运算合到 1 个 CIColorKernel, 单 pass 完成:
//
//     1. blackPoint  — 黑场压死 (减后归一化, 真正黑色归 0, 不会变灰)
//     2. brightness  — 中调亮度曲线 (保端点不会让黑变灰, 只弯中调)
//     3. saturation  — Rec.601 luma 加权混合
//     4. contrast    — 绕中点 0.5 拉
//     5. redGlow     — 选择性红色发光 (仅 R 高且 G/B 低的纯红区域非线性推向 1.0)
//     6. highlightLift — 高光提亮 (>0.7 区域非线性推向 1.0, 白色更白)
//
//   锐化已移除 — 卷积 9 采样开销最贵, ISP 自带 edge enhancement 已够用.
//   旧字段 sharpness 保留为 @Published 仅为兼容服务端推送, kernel 不读取.
//
//   v3.1: brightness 重新启用, 但用保端点曲线 (rgb + b·rgb·(1-rgb)) 替代 v2 的加法偏移,
//         拖滑块会有效果但不会把黑色拉灰.
//
// 兼容:
//   - UserDefaults key 不变, UI 滑块继续可绑定
//   - 服务端 filterSharpness 推下来不会报错, 只是不生效
//   - 服务端 filterBrightness 直接生效 (新算法)
//   - 服务端 filterRedBoost 推下来转作 redGlow 强度
final class VideoFilterPipeline: ObservableObject {

    // ===== 实际生效参数（kernel 读取）=====

    /// 黑场压死: 输入像素先减去 blackPoint 再归一化, 把暗部彻底推到 0
    /// 默认 0.10 是为了对抗 limited-range YUV 编码的"黑色 = 0.063 灰" 现象
    @Published var blackPoint: Float = VideoFilterPipeline.loadDefault(.blackPoint, fallback: 0.10) {
        didSet { saveDefault(.blackPoint, blackPoint); if oldValue != blackPoint { logChange("blackPoint", blackPoint) } }
    }
    /// 中调亮度: 保端点曲线 rgb + b·rgb·(1-rgb), -1..+1
    @Published var brightness: Float = VideoFilterPipeline.loadDefault(.brightness, fallback: 0.05) {
        didSet { saveDefault(.brightness, brightness); if oldValue != brightness { logChange("brightness", brightness) } }
    }
    /// 曝光: rgb × 2^EV, -3..+3 stops, 乘法增益
    @Published var exposure: Float = VideoFilterPipeline.loadDefault(.exposure, fallback: 0.0) {
        didSet { saveDefault(.exposure, exposure); if oldValue != exposure { logChange("exposure", exposure) } }
    }
    /// 伽马: pow 曲线 rgb' = rgb^(1/gamma), 0.5..2.0, 保端点
    @Published var gamma: Float = VideoFilterPipeline.loadDefault(.gamma, fallback: 1.0) {
        didSet { saveDefault(.gamma, gamma); if oldValue != gamma { logChange("gamma", gamma) } }
    }
    /// 对比度: 绕 0.5 中点拉. 1.0 = 不变, 1.20 = 显著但不死
    @Published var contrast: Float = VideoFilterPipeline.loadDefault(.contrast, fallback: 1.20) {
        didSet { saveDefault(.contrast, contrast); if oldValue != contrast { logChange("contrast", contrast) } }
    }
    /// 饱和度: Rec.601 luma 混合. 1.0 = 不变, 1.30 = 红绿色更鲜艳
    @Published var saturation: Float = VideoFilterPipeline.loadDefault(.saturation, fallback: 1.30) {
        didSet { saveDefault(.saturation, saturation); if oldValue != saturation { logChange("saturation", saturation) } }
    }
    /// ⭐ 红色发光强度: 仅作用于"R 高且 G/B 低"的纯红像素 (♥♦), 0 = 不动, 0.30 = 强发光
    @Published var redGlow: Float = VideoFilterPipeline.loadDefault(.redGlow, fallback: 0.25) {
        didSet { saveDefault(.redGlow, redGlow); if oldValue != redGlow { logChange("redGlow", redGlow) } }
    }
    /// 高光提亮: > 0.7 的像素非线性推向 1.0, 让白色卡面更白净, 不影响中暗调
    @Published var highlightLift: Float = VideoFilterPipeline.loadDefault(.highlightLift, fallback: 0.15) {
        didSet { saveDefault(.highlightLift, highlightLift); if oldValue != highlightLift { logChange("highlightLift", highlightLift) } }
    }

    // ===== 兼容旧服务端推送字段 (kernel 不读取, 留着不报错) =====
    @Published var sharpness: Float = VideoFilterPipeline.loadDefault(.sharpness, fallback: 0.0) {
        didSet { saveDefault(.sharpness, sharpness) }
    }

    // ⭐ 主开关. UI / 后端可关掉整个滤镜让画面恢复原生 (省电省热, 排查问题用)
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "videoFilter.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "videoFilter.enabled"); print("📷 [Filter] enabled=\(enabled)") }
    }

    private enum Key: String {
        case brightness    = "videoFilter.brightness"
        case contrast      = "videoFilter.contrast"
        case saturation    = "videoFilter.saturation"
        case sharpness     = "videoFilter.sharpness"
        case blackPoint    = "videoFilter.blackPoint"
        case redGlow       = "videoFilter.redGlow"
        case highlightLift = "videoFilter.highlightLift"
        case gamma         = "videoFilter.gamma"
        case exposure      = "videoFilter.exposure"
    }

    private static func loadDefault(_ key: Key, fallback: Float) -> Float {
        if UserDefaults.standard.object(forKey: key.rawValue) != nil {
            return UserDefaults.standard.float(forKey: key.rawValue)
        }
        return fallback
    }
    private func saveDefault(_ key: Key, _ value: Float) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
    private func logChange(_ name: String, _ v: Float) {
        print("📷 [Filter] \(name) = \(String(format: "%.3f", v))")
    }

    // ⭐ 一次性批量更新（避免多次 didSet 触发）
    func applyAll(brightness: Float?, contrast: Float?, saturation: Float?,
                  sharpness: Float?, redBoost: Float? = nil,
                  blackPoint: Float? = nil, redGlow: Float? = nil, highlightLift: Float? = nil,
                  gamma: Float? = nil, exposure: Float? = nil,
                  enabled: Bool? = nil, source: String = "remote") {
        if let v = brightness { self.brightness = v }
        if let v = contrast   { self.contrast   = v }
        if let v = saturation { self.saturation = v }
        if let v = sharpness  { self.sharpness  = v }
        if let v = redBoost   { self.redGlow    = v }
        if let v = redGlow    { self.redGlow    = v }
        if let v = blackPoint { self.blackPoint = v }
        if let v = highlightLift { self.highlightLift = v }
        if let v = gamma      { self.gamma      = v }
        if let v = exposure   { self.exposure   = v }
        if let v = enabled    { self.enabled    = v }
        print("📷 [Filter] 批量应用 (\(source)): exp=\(self.exposure) bp=\(self.blackPoint) bright=\(self.brightness) gamma=\(self.gamma) contrast=\(self.contrast) sat=\(self.saturation) redGlow=\(self.redGlow) hi=\(self.highlightLift) enabled=\(self.enabled)")
    }

    // ===== Metal CIColorKernel: 一次 dispatch 完成所有色彩运算 =====
    private static let kernelSource: String = """
    kernel vec4 cardEnhance(__sample s,
                            float exposure,
                            float blackPoint,
                            float brightness,
                            float gamma,
                            float contrast,
                            float saturation,
                            float redGlow,
                            float highlightLift) {
        vec3 rgb = s.rgb;

        // 0. 曝光: rgb × 2^EV
        rgb = rgb * exp2(exposure);

        // 1. 黑场压死
        float bpDenom = max(1.0 - blackPoint, 0.001);
        rgb = max(rgb - vec3(blackPoint), vec3(0.0)) / vec3(bpDenom);

        // 2. 中调亮度 (保端点)
        rgb = rgb + brightness * rgb * (1.0 - rgb);

        // 3. 伽马
        float invGamma = 1.0 / max(gamma, 0.01);
        rgb = pow(max(rgb, vec3(0.0)), vec3(invGamma));

        // 4. 饱和度
        float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
        rgb = mix(vec3(luma), rgb, saturation);

        // 5. 对比度
        rgb = (rgb - 0.5) * contrast + 0.5;

        // 6. 红色发光 (仅纯红像素 ♥♦)
        float gbMax = max(rgb.g, rgb.b);
        float redMask = smoothstep(0.15, 0.45, rgb.r) * max(0.0, 1.0 - gbMax);
        rgb.r = rgb.r + redGlow * redMask * (1.0 - rgb.r);

        // 7. 高光提亮
        vec3 highlightMask = smoothstep(vec3(0.7), vec3(1.0), rgb);
        rgb = rgb + highlightLift * highlightMask * (1.0 - rgb);

        rgb = clamp(rgb, 0.0, 1.0);
        return vec4(rgb, s.a);
    }
    """

    private let ciContext: CIContext
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private let cardEnhanceKernel: CIColorKernel?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709) as Any,
            .cacheIntermediates: false,
            .useSoftwareRenderer: false,
        ]
        if let device = device {
            ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            ciContext = CIContext(options: options)
        }
        cardEnhanceKernel = CIColorKernel(source: VideoFilterPipeline.kernelSource)
        if cardEnhanceKernel == nil {
            print("❌ [Filter] CIColorKernel 编译失败, 滤镜将走直通")
        } else {
            print("✅ [Filter] Metal kernel 已加载 (单 pass GPU 处理)")
        }
    }

    /// 直通条件:
    ///   1. enabled = false (主开关关闭)
    ///   2. 所有参数都是中性值
    ///   3. kernel 编译失败 (兜底)
    var isPassThrough: Bool {
        if !enabled { return true }
        if cardEnhanceKernel == nil { return true }
        return exposure == 0 && blackPoint == 0 && brightness == 0 && gamma == 1.0
            && contrast == 1.0 && saturation == 1.0 && redGlow == 0 && highlightLift == 0
    }

    /// 处理一帧, 返回新的 CVPixelBuffer (BGRA 格式) 或 nil (失败/直通时调用方使用原帧)
    func processFrame(_ inputPB: CVPixelBuffer) -> CVPixelBuffer? {
        if isPassThrough { return nil }
        guard let kernel = cardEnhanceKernel else { return nil }

        let width = CVPixelBufferGetWidth(inputPB)
        let height = CVPixelBufferGetHeight(inputPB)
        guard width > 0 && height > 0 else { return nil }

        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                    poolAttrs as CFDictionary,
                                    attrs as CFDictionary, &pool)
            pixelBufferPool = pool
            poolWidth = width
            poolHeight = height
        }
        guard let pool = pixelBufferPool else { return nil }

        let ciImage = CIImage(cvPixelBuffer: inputPB)

        let outImage = kernel.apply(
            extent: ciImage.extent,
            arguments: [ciImage, exposure, blackPoint, brightness, gamma, contrast, saturation, redGlow, highlightLift]
        )
        guard let result = outImage else { return nil }

        var outputPB: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPB)
        guard let out = outputPB else { return nil }
        ciContext.render(result, to: out)
        return out
    }
}
