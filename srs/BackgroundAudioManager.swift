//
//  BackgroundAudioManager.swift
//  srs
//
//  后台保活：通过播放静音音频防止App被系统挂起
//  推流期间保持后台运行，确保WebRTC推流和WebSocket不断连
//

import Foundation
import AVFoundation
import UIKit

class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()
    
    private var audioPlayer: AVAudioPlayer?
    private var isPlaying = false
    
    private init() {
        setupAudioSession()
        setupNotifications()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Setup
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            
            // 设置为播放模式，允许后台播放，混合其他音频
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            
            print("🔊 [保活] 音频会话已配置")
        } catch {
            print("❌ [保活] 配置音频会话失败: \(error)")
        }
    }
    
    private func setupNotifications() {
        // 监听音频中断（如来电）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        // 监听App进入后台
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        // 监听App进入前台
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    // MARK: - Control
    
    /// 开始后台保活（推流时调用）
    func startBackgroundKeepAlive() {
        guard !isPlaying else {
            print("🔊 [保活] 已在播放中")
            return
        }
        
        // 创建静音音频数据
        guard let silentAudioData = createSilentAudio() else {
            print("❌ [保活] 创建静音音频失败")
            return
        }
        
        do {
            audioPlayer = try AVAudioPlayer(data: silentAudioData)
            audioPlayer?.numberOfLoops = -1  // 无限循环
            audioPlayer?.volume = 0.01       // 极低音量（不能为0，否则系统会优化掉）
            audioPlayer?.play()
            
            isPlaying = true
            print("🔊 [保活] ✅ 后台保活已启动")
        } catch {
            print("❌ [保活] 播放失败: \(error)")
        }
    }
    
    /// 停止后台保活（退出登录/停止推流时调用）
    func stopBackgroundKeepAlive() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        print("🔊 [保活] 🔴 后台保活已停止")
    }
    
    /// 是否正在保活
    var isKeepingAlive: Bool {
        return isPlaying
    }
    
    // MARK: - Create Silent Audio
    
    private func createSilentAudio() -> Data? {
        // 创建1秒的静音WAV音频
        let sampleRate: Int = 44100
        let channels: Int = 1
        let bitsPerSample: Int = 16
        let duration: Double = 1.0
        
        let numSamples = Int(Double(sampleRate) * duration)
        let dataSize = numSamples * channels * (bitsPerSample / 8)
        let fileSize = 36 + dataSize
        
        var data = Data()
        
        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        
        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * channels * bitsPerSample / 8).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(channels * bitsPerSample / 8).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
        
        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        
        // 静音数据（全0）
        data.append(contentsOf: [UInt8](repeating: 0, count: dataSize))
        
        return data
    }
    
    // MARK: - Notifications
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            print("🔊 [保活] ⚠️ 音频中断开始（可能来电）")
            
        case .ended:
            print("🔊 [保活] ✅ 音频中断结束，恢复播放")
            if isPlaying {
                audioPlayer?.play()
            }
            
        @unknown default:
            break
        }
    }
    
    @objc private func appDidEnterBackground() {
        // App进入后台时确保音频在播放
        if isPlaying && !(audioPlayer?.isPlaying ?? false) {
            audioPlayer?.play()
            print("🔊 [保活] 后台恢复播放")
        }
    }
    
    @objc private func appWillEnterForeground() {
        print("🔊 [保活] App进入前台")
    }
}
