# iOS WebRTCManager.swift P2P 修改文档

> **文件路径**：`ios/srs_yql_p/srs/Managers/WebRTCManager.swift`  
> **修改日期**：2026-03-25  
> **修改目的**：实现 P2P 直连模式，修复信令时序 Bug

---

## 背景说明

将 SRS 中继模式改为 WebRTC P2P 直连模式后，信令流程变为：

```
PC 发送 WEBRTC_REQUEST → iOS 创建 Offer → PC 收到 Offer 创建 Answer → iOS 收到 Answer
```

在此过程中存在一个**时序问题**：PC 的 ICE 候选者可能在 Answer 之前到达 iOS，此时 iOS 的 `remoteDescription` 为 nil，直接调用 `add(iceCandidate)` 会失败。此外，iOS 视频轨道就绪后需要通过心跳通知 PC 端触发连接。

---

## 修改清单（共 6 处）

### 修改 1：新增 `pendingRemoteIceCandidates` 属性

**位置**：属性声明区，在 `p2pViewerSenders` 下方

**原因**：需要一个字典来按 PC 设备ID 缓存提前到达的 ICE 候选者，等 `remoteDescription` 设置成功后再统一添加

**找到这段代码**：

```swift
private(set) var p2pViewerSessions: [String: RTCPeerConnection] = [:]  // pcDeviceId → PeerConnection
private var p2pViewerSenders: [String: RTCRtpSender] = [:]         // pcDeviceId → VideoSender（用于码率控制）
var maxP2PViewers: Int = 4
```

**改为**：

```swift
private(set) var p2pViewerSessions: [String: RTCPeerConnection] = [:]  // pcDeviceId → PeerConnection
private var p2pViewerSenders: [String: RTCRtpSender] = [:]         // pcDeviceId → VideoSender（用于码率控制）
private var pendingRemoteIceCandidates: [String: [RTCIceCandidate]] = [:]  // ★ 缓存 PC 的 ICE 候选者（等待 remoteDescription 设置后再添加）
var maxP2PViewers: Int = 4
```

---

### 修改 2：`startPublish()` 末尾标记 `publishStatus=1`

**位置**：`startPublish()` 函数末尾，`isReadyForViewers = true` 之后

**原因**：P2P 模式下不再经过 SRS 推流，之前 `publishStatus` 是在 SRS 连接成功后才设为 1。现在视频轨道就绪即代表 iOS 准备好了，需要立即标记为 1，这样心跳每秒发送 `publishStatus=1` 给服务器，PC 端收到后才会触发 `playP2P()` 发送 `WEBRTC_REQUEST`。**不加这行，PC 端永远不会发起连接请求。**

**找到这段代码**：

```swift
isReadyForViewers = true
registerWebRTCSignalingObserver()
print("✅ [P2P] 视频轨道就绪，等待 PC 观看请求... (最多\(maxP2PViewers)人)")
```

**改为**：

```swift
isReadyForViewers = true
registerWebRTCSignalingObserver()

// ★ 关键：标记 publishStatus=1，心跳会每秒推送给已订阅的 PC
// PC 收到 publishStatus=1 后会自动触发 playP2P() → 发送 WEBRTC_REQUEST
// 这样无论 iOS/PC 哪个先登录，都能自动配对连接
WebSocketManager.isPublishingFlag = 1
print("🟢 [P2P] publishStatus=1 ← 视频轨道就绪，心跳将通知 PC")
print("✅ [P2P] 视频轨道就绪，等待 PC 观看请求... (最多\(maxP2PViewers)人)")
```

---

### 修改 3：`removeViewerSession()` 清理缓存 ICE

**位置**：`removeViewerSession(_ pcDeviceId:)` 函数内

**原因**：移除某个 PC 观看者的会话时，必须同时清理为该 PC 缓存的 ICE 候选者，防止内存泄漏和数据残留

**找到这段代码**：

```swift
p2pViewerSessions.removeValue(forKey: pcDeviceId)
p2pViewerSenders.removeValue(forKey: pcDeviceId)
print("🔌 [P2P] 已关闭 PC \(pcDeviceId) 的会话，剩余观看者: \(p2pViewerSessions.count)")
```

**改为**：

```swift
p2pViewerSessions.removeValue(forKey: pcDeviceId)
p2pViewerSenders.removeValue(forKey: pcDeviceId)
pendingRemoteIceCandidates.removeValue(forKey: pcDeviceId)  // ★ 清理缓存 ICE
print("🔌 [P2P] 已关闭 PC \(pcDeviceId) 的会话，剩余观看者: \(p2pViewerSessions.count)")
```

---

### 修改 4：`closeAllViewerSessions()` 清理所有缓存 ICE

**位置**：`closeAllViewerSessions()` 函数内

**原因**：关闭所有观看者会话时（如 iOS 停止推流），必须同时清空全部缓存的 ICE 候选者

**找到这段代码**：

```swift
p2pViewerSessions.removeAll()
p2pViewerSenders.removeAll()
pc = nil
```

**改为**：

```swift
p2pViewerSessions.removeAll()
p2pViewerSenders.removeAll()
pendingRemoteIceCandidates.removeAll()  // ★ 清理所有缓存 ICE
pc = nil
```

---

### 修改 5：收到 PC Answer 后刷入缓存的 ICE 候选者

**位置**：`handleWebRTCSignaling` 函数中 `case "WEBRTC_SDP":` → `sdpType == "answer"` 分支，`setRemoteDescription` 成功回调内

**原因**：这是整个 ICE 缓存机制的关键出口。当 iOS 成功设置了 PC 的 Answer（即 `remoteDescription` 生效）后，之前缓存的所有 ICE 候选者此时可以安全添加到 PeerConnection 中。**不加这段，所有提前到达的 ICE 候选者会永远留在缓存中，导致 P2P 连接无法建立。**

**找到这段代码（在 `setRemoteDescription` 的成功回调里）**：

```swift
    } else {
        print("✅ [P2P] PC \(fromDevice) Answer 设置成功，连接建立中...")
        DispatchQueue.main.async {
            // 只要有一个 PC 连接成功，就标记为正在推流
            self.isPublishing = true
            WebSocketManager.isPublishingFlag = 1
```

**改为**：

```swift
    } else {
        print("✅ [P2P] PC \(fromDevice) Answer 设置成功，连接建立中...")
        
        // ★ 刷入缓存的 ICE 候选者（之前因 remoteDescription 为空而缓存的）
        if let pending = self.pendingRemoteIceCandidates[fromDevice], !pending.isEmpty {
            print("📦 [P2P] 刷入 PC \(fromDevice) 缓存的 \(pending.count) 个 ICE 候选者")
            for ice in pending {
                viewerPC.add(ice) { err in
                    if let err = err {
                        print("❌ [P2P] 刷入缓存 ICE 失败: \(err)")
                    }
                }
            }
            self.pendingRemoteIceCandidates.removeValue(forKey: fromDevice)
        }
        
        DispatchQueue.main.async {
            // 只要有一个 PC 连接成功，就标记为正在推流
            self.isPublishing = true
            WebSocketManager.isPublishingFlag = 1
```

---

### 修改 6：`WEBRTC_ICE` 处理改为先缓存后添加

**位置**：`handleWebRTCSignaling` 函数中 `case "WEBRTC_ICE":` 分支

**原因**：P2P 信令流程中，PC 创建 Answer 后立刻开始收集 ICE 候选者并发送给 iOS。但 Answer SDP 通过 WebSocket 中转有网络延迟，PC 的 ICE 候选者可能比 Answer 更早到达 iOS。此时 iOS 的 `remoteDescription` 还是 nil，直接调用 `viewerPC.add(iceCandidate)` 会报错或静默丢弃。**必须先缓存，等 Answer 到了（修改 5）再统一添加。**

**找到这段代码**：

```swift
case "WEBRTC_ICE":
    // ★ 收到指定 PC 的 ICE 候选者 → 路由到对应 PeerConnection
    guard let viewerPC = p2pViewerSessions[fromDevice] else {
        print("⚠️ [P2P] 未找到 PC \(fromDevice) 的会话，忽略 ICE")
        return
    }
    let candidate = message["candidate"] as? String ?? ""
    let sdpMid = message["sdpMid"] as? String ?? "0"
    let sdpMLineIndex = message["sdpMLineIndex"] as? Int32 ?? 0
    let ice = RTCIceCandidate(sdp: candidate,
                               sdpMLineIndex: sdpMLineIndex,
                               sdpMid: sdpMid)
    viewerPC.add(ice) { error in
        if let error = error {
            print("❌ [P2P] 添加 PC \(fromDevice) ICE 失败: \(error)")
        } else {
            print("🧊 [P2P] 添加 PC \(fromDevice) ICE 成功")
        }
    }
```

**改为**：

```swift
case "WEBRTC_ICE":
    // ★ 收到指定 PC 的 ICE 候选者 → 路由到对应 PeerConnection
    guard let viewerPC = p2pViewerSessions[fromDevice] else {
        print("⚠️ [P2P] 未找到 PC \(fromDevice) 的会话，忽略 ICE")
        return
    }
    let candidate = message["candidate"] as? String ?? ""
    let sdpMid = message["sdpMid"] as? String ?? "0"
    let sdpMLineIndex = message["sdpMLineIndex"] as? Int32 ?? 0
    let ice = RTCIceCandidate(sdp: candidate,
                               sdpMLineIndex: sdpMLineIndex,
                               sdpMid: sdpMid)
    
    // ★ 如果 remoteDescription 还没设置（PC 的 Answer 还没到），先缓存
    if viewerPC.remoteDescription == nil {
        if pendingRemoteIceCandidates[fromDevice] == nil {
            pendingRemoteIceCandidates[fromDevice] = []
        }
        pendingRemoteIceCandidates[fromDevice]?.append(ice)
        print("📦 [P2P] 缓存 PC \(fromDevice) ICE（等待 remoteDescription），已缓存 \(pendingRemoteIceCandidates[fromDevice]?.count ?? 0) 个")
    } else {
        viewerPC.add(ice) { error in
            if let error = error {
                print("❌ [P2P] 添加 PC \(fromDevice) ICE 失败: \(error)")
            } else {
                print("🧊 [P2P] 添加 PC \(fromDevice) ICE 成功")
            }
        }
    }
```

---

## 修改总结

| # | 位置 | 操作 | 原因 |
|---|------|------|------|
| 1 | 属性声明区 | 新增 `pendingRemoteIceCandidates` 字典 | ICE 缓存容器 |
| 2 | `startPublish()` 末尾 | 加 `WebSocketManager.isPublishingFlag = 1` | 通知 PC 端可以发起连接 |
| 3 | `removeViewerSession()` | 加 `pendingRemoteIceCandidates.removeValue` | 清理单个 PC 的缓存 |
| 4 | `closeAllViewerSessions()` | 加 `pendingRemoteIceCandidates.removeAll()` | 清理全部缓存 |
| 5 | Answer 设置成功回调 | 刷入缓存的 ICE 候选者 | Answer 到了才能安全添加 ICE |
| 6 | `WEBRTC_ICE` 处理分支 | 加 `remoteDescription == nil` 缓存判断 | ICE 可能比 Answer 先到 |

## 核心原理

```
时间线：
iOS 创建 Offer → 发给 PC
PC 创建 Answer → 发给 iOS（走 WebSocket，有延迟）
PC 同时收集 ICE → 发给 iOS（也走 WebSocket，可能比 Answer 更快到达）

问题：iOS 收到 ICE 时，Answer 还没到，remoteDescription 是 nil → add(ICE) 失败
解决：先缓存 ICE → 等 Answer 到了设好 remoteDescription → 统一刷入缓存的 ICE
```

---
---

# iOS P2P 调试日志增强（第二批修改）

> **修改日期**：2026-03-25  
> **修改目的**：PC 端发送 `WEBRTC_REQUEST` 后 iOS 没有任何响应，增加详细调试日志以定位问题

---

## 背景说明

PC 端日志显示 `WEBRTC_REQUEST` 已成功发送，但 iOS 端没有任何反应（没有创建 Offer、没有返回 Reject）。可能的原因：

1. iOS 的 `WebSocketManager.shared.deviceId` 与 PC 发送的 `toDevice` 不匹配，导致 iOS 没有订阅到正确的信令频道
2. SwiftStomp 传递的消息可能是 `Data` 类型而非 `String`，导致 JSON 解析失败、信令被静默丢弃
3. `handleWebRTCSignaling` 收到消息但 `type` 字段解析失败
4. `createViewerSession` 内部某个检查不通过但没有日志

---

## 文件一：WebSocketManager.swift 修改（共 2 处）

> **文件路径**：`ios/srs_yql_p/srs/Managers/WebSocketManager.swift`

### 修改 7：`subscribeToDeviceConfig()` 增加 deviceId 日志

**位置**：`subscribeToDeviceConfig()` 函数内，订阅 WebRTC 信令频道的 print 语句

**原因**：确认 iOS 实际订阅的频道 `deviceId` 是什么，如果跟 PC 端发送的 `toDevice` 不一致，消息自然收不到

**找到这段代码**：

```swift
// ★ P2P: 订阅 WebRTC 信令频道
let webrtcDest = "/topic/device/\(deviceId)/webrtc"
swiftStomp?.subscribe(to: webrtcDest)
print("✅ [P2P] 已订阅 WebRTC 信令频道: \(webrtcDest)")
```

**改为**：

```swift
// ★ P2P: 订阅 WebRTC 信令频道
let webrtcDest = "/topic/device/\(deviceId)/webrtc"
swiftStomp?.subscribe(to: webrtcDest)
print("✅ [P2P] 已订阅 WebRTC 信令频道: \(webrtcDest) (deviceId=\(deviceId))")
```

---

### 修改 8：`onMessageReceived` 增强 WebRTC 信令消息解析和调试

**位置**：`onMessageReceived` 函数内，`// ★ P2P: 处理 WebRTC 信令消息` 部分

**原因**：
1. SwiftStomp 可能以 `Data` 类型传递 JSON 消息，之前只处理了 `String` 和 `[String: Any]`，`Data` 类型会被静默丢弃
2. 需要增加详细的调试日志，确认消息是否到达、解析是否成功

**找到这段代码**：

```swift
// ★ P2P: 处理 WebRTC 信令消息
if destination.contains("/topic/device/") && destination.contains("/webrtc") {
    var signalingDict: [String: Any]?
    if let text = message as? String, let data = text.data(using: .utf8) {
        signalingDict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    } else if let dict = message as? [String: Any] {
        signalingDict = dict
    }
    if let dict = signalingDict {
        let sigType = dict["type"] as? String ?? ""
        let fromDevice = dict["fromDevice"] as? String ?? ""
        print("📥 [P2P] 收到信令: type=\(sigType), from=\(fromDevice)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .webrtcSignalingReceived,
                object: nil,
                userInfo: dict
            )
        }
    }
}
```

**改为**：

```swift
// ★ P2P: 处理 WebRTC 信令消息
if destination.contains("/topic/device/") && destination.contains("/webrtc") {
    print("🔔 [P2P-DEBUG] 收到 webrtc 频道消息, destination=\(destination), messageType=\(type(of: message))")
    var signalingDict: [String: Any]?
    if let text = message as? String, let data = text.data(using: .utf8) {
        signalingDict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        if signalingDict == nil {
            print("⚠️ [P2P-DEBUG] String→JSON 解析失败, text=\(text.prefix(200))")
        }
    } else if let dict = message as? [String: Any] {
        signalingDict = dict
    } else if let data = message as? Data, let text = String(data: data, encoding: .utf8) {
        // ★ 兼容 SwiftStomp 以 Data 类型传递 JSON 的情况
        signalingDict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        if signalingDict == nil {
            print("⚠️ [P2P-DEBUG] Data→JSON 解析失败, text=\(text.prefix(200))")
        }
    } else {
        print("❌ [P2P-DEBUG] message 类型未知: \(String(describing: message))")
    }
    if let dict = signalingDict {
        let sigType = dict["type"] as? String ?? ""
        let fromDevice = dict["fromDevice"] as? String ?? ""
        print("📥 [P2P] 收到信令: type=\(sigType), from=\(fromDevice)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .webrtcSignalingReceived,
                object: nil,
                userInfo: dict
            )
        }
    } else {
        print("❌ [P2P-DEBUG] signalingDict 解析为 nil，信令消息被丢弃!")
    }
}
```

---

## 文件二：WebRTCManager.swift 修改（共 2 处）

> **文件路径**：`ios/srs_yql_p/srs/Managers/WebRTCManager.swift`

### 修改 9：`handleWebRTCSignaling` 增加调试日志

**位置**：`handleWebRTCSignaling(_ message:)` 函数开头 + `WEBRTC_REQUEST` case 分支

**原因**：确认消息是否到达这个函数、`type` 是否正确解析、`isReadyForViewers` 和观看者数量等状态

**找到这段代码**：

```swift
func handleWebRTCSignaling(_ message: [String: Any]) {
    guard let type = message["type"] as? String else { return }
    let fromDevice = message["fromDevice"] as? String ?? ""
    
    switch type {
    // ★★★ 新增：PC 请求观看（核心入口）
    case "WEBRTC_REQUEST":
        print("📥 [P2P] 收到 PC \(fromDevice) 的观看请求")
        guard isReadyForViewers else {
```

**改为**：

```swift
func handleWebRTCSignaling(_ message: [String: Any]) {
    guard let type = message["type"] as? String else {
        print("❌ [P2P-DEBUG] handleWebRTCSignaling: type 字段为空或不是 String, message keys=\(message.keys)")
        return
    }
    let fromDevice = message["fromDevice"] as? String ?? ""
    print("🔔 [P2P-DEBUG] handleWebRTCSignaling: type=\(type), from=\(fromDevice)")
    
    switch type {
    // ★★★ 新增：PC 请求观看（核心入口）
    case "WEBRTC_REQUEST":
        print("📥 [P2P] 收到 PC \(fromDevice) 的观看请求")
        print("🔔 [P2P-DEBUG] isReadyForViewers=\(isReadyForViewers), localVideoTrack=\(localVideoTrack != nil ? "有" : "nil"), 当前观看者=\(p2pViewerSessions.count)/\(maxP2PViewers)")
        guard isReadyForViewers else {
```

---

### 修改 10：`createViewerSession` 增加全流程调试日志

**位置**：`createViewerSession(for pcDeviceId:)` 函数全部

**原因**：追踪 PeerConnection 创建、Offer 生成、SDP 发送的每一步，确认哪一步失败

**找到这段代码**：

```swift
func createViewerSession(for pcDeviceId: String) {
    // 1. 检查是否已有该 PC 的会话
    if p2pViewerSessions[pcDeviceId] != nil {
```

**改为**：

```swift
func createViewerSession(for pcDeviceId: String) {
    print("🔔 [P2P-DEBUG] createViewerSession 开始, pcDeviceId=\(pcDeviceId)")
    
    // 1. 检查是否已有该 PC 的会话
    if p2pViewerSessions[pcDeviceId] != nil {
```

---

**继续在 `createViewerSession` 内部找到这段代码（视频轨道检查后）**：

```swift
// 3. 检查视频轨道是否就绪
guard let videoTrack = localVideoTrack else {
    print("❌ [P2P] 视频轨道未就绪，无法创建会话")
    return
}
```

**改为**：

```swift
// 3. 检查视频轨道是否就绪
guard let videoTrack = localVideoTrack else {
    print("❌ [P2P] 视频轨道未就绪，无法创建会话 (localVideoTrack=nil)")
    return
}
print("🔔 [P2P-DEBUG] 视频轨道就绪, 开始创建 PeerConnection...")
```

---

**继续在 `createViewerSession` 内部找到创建 Offer 的部分**：

```swift
// 9. 创建 Offer 并发送给这个 PC
let sdpCons = RTCMediaConstraints(
    mandatoryConstraints: ["OfferToReceiveAudio":"false", "OfferToReceiveVideo":"false"],
    optionalConstraints: nil
)

newPC.offer(for: sdpCons) { [weak self] sdp, err in
    guard let self else { return }
    guard let sdp else {
        print("❌ [P2P] 创建 Offer 失败 for \(pcDeviceId): \(err?.localizedDescription ?? "unknown error")")
        return
    }
    
    newPC.setLocalDescription(sdp) { setErr in
        if let setErr = setErr {
            print("⚠️ [P2P] setLocalDescription 失败: \(setErr)")
        }
    }
    
    print("📤 [P2P] 发送 Offer 给 PC \(pcDeviceId)")
    WebSocketManager.shared.sendWebRTCSignalingSDP(
        sdpType: "offer",
        sdp: sdp.sdp,
        toDevice: pcDeviceId
    )
}
```

**改为**：

```swift
// 9. 创建 Offer 并发送给这个 PC
let sdpCons = RTCMediaConstraints(
    mandatoryConstraints: ["OfferToReceiveAudio":"false", "OfferToReceiveVideo":"false"],
    optionalConstraints: nil
)

print("🔔 [P2P-DEBUG] 开始创建 Offer for \(pcDeviceId)...")
newPC.offer(for: sdpCons) { [weak self] sdp, err in
    guard let self else {
        print("❌ [P2P-DEBUG] self 已释放，无法发送 Offer for \(pcDeviceId)")
        return
    }
    guard let sdp else {
        print("❌ [P2P] 创建 Offer 失败 for \(pcDeviceId): \(err?.localizedDescription ?? "unknown error")")
        return
    }
    
    print("🔔 [P2P-DEBUG] Offer 创建成功, SDP 长度=\(sdp.sdp.count) 字节")
    
    newPC.setLocalDescription(sdp) { setErr in
        if let setErr = setErr {
            print("⚠️ [P2P-DEBUG] setLocalDescription 失败: \(setErr)")
        } else {
            print("✅ [P2P-DEBUG] setLocalDescription 成功")
        }
    }
    
    print("📤 [P2P] 发送 Offer 给 PC \(pcDeviceId)")
    WebSocketManager.shared.sendWebRTCSignalingSDP(
        sdpType: "offer",
        sdp: sdp.sdp,
        toDevice: pcDeviceId
    )
    print("🔔 [P2P-DEBUG] sendWebRTCSignalingSDP 调用完成")
}
```

---

## 第二批修改总结

| # | 文件 | 位置 | 操作 | 原因 |
|---|------|------|------|------|
| 7 | WebSocketManager.swift | `subscribeToDeviceConfig()` | print 加 `deviceId` | 确认订阅的频道 ID 是否正确 |
| 8 | WebSocketManager.swift | `onMessageReceived` webrtc 分支 | 增加 Data 类型兼容 + 详细日志 | 防止消息被静默丢弃 |
| 9 | WebRTCManager.swift | `handleWebRTCSignaling` 开头 + REQUEST 分支 | 增加调试日志 | 确认信令是否到达、状态是否就绪 |
| 10 | WebRTCManager.swift | `createViewerSession` 全流程 | 增加每一步调试日志 | 追踪 Offer 创建和发送的全链路 |

## 调试日志预期输出

如果一切正常，iOS 控制台应该看到以下日志序列：

```
✅ [P2P] 已订阅 WebRTC 信令频道: /topic/device/XXXX/webrtc (deviceId=XXXX)
🔔 [P2P-DEBUG] 收到 webrtc 频道消息, destination=..., messageType=String
📥 [P2P] 收到信令: type=WEBRTC_REQUEST, from=V-142457898
🔔 [P2P-DEBUG] handleWebRTCSignaling: type=WEBRTC_REQUEST, from=V-142457898
📥 [P2P] 收到 PC V-142457898 的观看请求
🔔 [P2P-DEBUG] isReadyForViewers=true, localVideoTrack=有, 当前观看者=0/4
🔔 [P2P-DEBUG] createViewerSession 开始, pcDeviceId=V-142457898
🔔 [P2P-DEBUG] 视频轨道就绪, 开始创建 PeerConnection...
✅ [P2P] 为 PC V-142457898 创建会话成功，当前观看者: 1/4
🔔 [P2P-DEBUG] 开始创建 Offer for V-142457898...
🔔 [P2P-DEBUG] Offer 创建成功, SDP 长度=XXXX 字节
📤 [P2P] 发送 Offer 给 PC V-142457898
```

**如果没有看到上面的日志**，根据断点位置排查：
- 没有 `🔔 [P2P-DEBUG] 收到 webrtc 频道消息` → iOS 根本没收到消息，检查 `deviceId` 是否匹配
- 有 `收到 webrtc 频道消息` 但没有 `📥 [P2P] 收到信令` → 消息解析失败，查看 `⚠️` 或 `❌` 日志
- 有 `handleWebRTCSignaling` 但没有 `createViewerSession` → `isReadyForViewers=false`，视频轨道未就绪
- 有 `createViewerSession 开始` 但没有 `Offer 创建成功` → PeerConnection 创建或 Offer 生成失败

---

## 修改 11：修复 `packetsLost` 整数溢出导致崩溃（Fatal error: Not enough bits to represent the passed value）

### 崩溃原因

WebRTC `remote-inbound-rtp` 统计的 `packetsLost` 是 `int64`（有符号），可以返回**负值**。但代码用 `NSNumber.uint64Value` 读取，导致负数被解释为巨大的 `UInt64`（例如 `-1` → `18446744073709551615`）。后续做 `Int(packetsLost - self.lastPacketsLost)` 时，差值超过 `Int.max`，Swift 直接 fatal error。

`nackCount`、`pliCount` 也有同样的风险。

### 位置 A：`WebRTCManager.swift` 搜索 `// ✅ 远端入站统计：包含丢包、RTT、抖动`

把从 stats 读取 `packetsLost` 的 3 行改为安全转换（防止负值包裹成巨大 UInt64）：

**原代码：**
```swift
                            if let v = s.values["packetsLost"] {
                                if let num = v as? NSNumber { packetsLost = num.uint64Value }
                                else if let d = v as? Double { packetsLost = UInt64(d) }
                                else if let i = v as? Int { packetsLost = UInt64(i) }
                            }
```

**改为：**
```swift
                            if let v = s.values["packetsLost"] {
                                if let num = v as? NSNumber { packetsLost = UInt64(clamping: max(0, num.int64Value)) }
                                else if let d = v as? Double { packetsLost = d >= 0 ? UInt64(d) : 0 }
                                else if let i = v as? Int { packetsLost = i >= 0 ? UInt64(i) : 0 }
                            }
```

### 位置 B：`WebRTCManager.swift` 搜索 `// 🔥 计算每秒丢包数和重传统计`

把 3 行 `Int()` 转换改为 `Int(clamping:)` 防御溢出：

**原代码（Mac Cursor 已修改过的版本）：**
```swift
                        if self.lastTs > 0 {
                            packetsLostPerSec = packetsLost >= self.lastPacketsLost ? Int(packetsLost - self.lastPacketsLost) : 0
                            nackPerSec = nackCount >= self.lastNackCount ? Int(nackCount - self.lastNackCount) : 0
                            pliPerSec = pliCount >= self.lastPliCount ? Int(pliCount - self.lastPliCount) : 0
                        }
```

**或原代码（原始 `&-` 版本）：**
```swift
                        if self.lastTs > 0 {
                            packetsLostPerSec = Int(packetsLost &- self.lastPacketsLost)
                            nackPerSec = Int(nackCount &- self.lastNackCount)
                            pliPerSec = Int(pliCount &- self.lastPliCount)
                        }
```

**统一改为：**
```swift
                        if self.lastTs > 0 {
                            packetsLostPerSec = packetsLost >= self.lastPacketsLost ? Int(clamping: packetsLost - self.lastPacketsLost) : 0
                            nackPerSec = nackCount >= self.lastNackCount ? Int(clamping: nackCount - self.lastNackCount) : 0
                            pliPerSec = pliCount >= self.lastPliCount ? Int(clamping: pliCount - self.lastPliCount) : 0
                        }
```

### 位置 C：`WebRTCManager.swift` 搜索 `let sentThisSec =`

**原代码：**
```swift
                                let sentThisSec = Int(packetsSent &- self.lastPacketsSent)
```

**改为：**
```swift
                                let sentThisSec = packetsSent >= self.lastPacketsSent ? Int(clamping: packetsSent - self.lastPacketsSent) : 0
```

### 位置 D（可选）：`nackCount` 和 `pliCount` 从 stats 读取也加保护

搜索 `// 🔥 提取 NACK 统计（重传机制）`：

**原代码：**
```swift
                            if let v = s.values["nackCount"] {
                                if let num = v as? NSNumber { nackCount = num.uint64Value }
                                else if let d = v as? Double { nackCount = UInt64(d) }
                                else if let i = v as? Int { nackCount = UInt64(i) }
                            }
```

**改为：**
```swift
                            if let v = s.values["nackCount"] {
                                if let num = v as? NSNumber { nackCount = UInt64(clamping: max(0, num.int64Value)) }
                                else if let d = v as? Double { nackCount = d >= 0 ? UInt64(d) : 0 }
                                else if let i = v as? Int { nackCount = i >= 0 ? UInt64(i) : 0 }
                            }
```

搜索 `// 🔥 提取 PLI 统计（关键帧请求）`：

**原代码：**
```swift
                            if let v = s.values["pliCount"] {
                                if let num = v as? NSNumber { pliCount = num.uint64Value }
                                else if let d = v as? Double { pliCount = UInt64(d) }
                                else if let i = v as? Int { pliCount = UInt64(i) }
                            }
```

**改为：**
```swift
                            if let v = s.values["pliCount"] {
                                if let num = v as? NSNumber { pliCount = UInt64(clamping: max(0, num.int64Value)) }
                                else if let d = v as? Double { pliCount = d >= 0 ? UInt64(d) : 0 }
                                else if let i = v as? Int { pliCount = i >= 0 ? UInt64(i) : 0 }
                            }
```

### 为什么会崩溃的具体场景

```
统计回调时：
  packetsLost (WebRTC stats) = -1  (int64，网络抖动导致)
  ↓ num.uint64Value
  packetsLost (UInt64) = 18446744073709551615  （二进制补码）
  ↓
  self.lastPacketsLost = 0
  packetsLost >= self.lastPacketsLost → true（18446... >= 0）
  packetsLost - self.lastPacketsLost → 18446744073709551615
  ↓ Int(18446744073709551615)
  💥 Fatal error: Not enough bits to represent the passed value
```

---
---

# 修改 12：支持「强制走 TURN 中继」开关（forceRelay）

> **修改日期**：2026-03-26  
> **修改目的**：后台总代理可开启「强制走 TURN 中继」测试开关，用于验证海外 TURN 线路是否正常。开启后 iOS 创建 PeerConnection 时只生成 relay 类型的 ICE 候选者，所有流量必须经过 TURN 服务器中转。

---

## 背景说明

后端登录接口新增了 `forceRelay` 字段（布尔值，默认 `false`）。当总代理在后台打开此开关后：
- 所有新登录的 iOS 设备会收到 `forceRelay: true`
- iOS 创建 PeerConnection 时设置 `iceTransportPolicy = .relay`（而非默认的 `.all`）
- WebRTC 只生成经过 TURN 服务器的 relay 候选者，不生成 host/srflx 候选者
- PC 端无需改动（PC 的 `.all` 策略包含 relay 候选者，iOS 只提供 relay 候选者时双方自然走 TURN）

**注意**：此开关仅用于测试，验证完成后应在后台关闭，恢复直连以获得最低延迟。

---

## 文件：WebRTCManager.swift（共 2 处）

> **文件路径**：`ios/srs_yql_p/srs/Managers/WebRTCManager.swift`

### 修改 12-A：新增 `forceRelay` 属性

**位置**：P2P 模式属性区，在 `maxP2PViewers` 下方

**找到这段代码**：

```swift
    var maxP2PViewers: Int = 4                   // 最大同时观看人数（后端可配置）
    var isReadyForViewers: Bool = false           // 视频轨道已就绪，可以接受观看请求
```

**改为**：

```swift
    var maxP2PViewers: Int = 4                   // 最大同时观看人数（后端可配置）
    var forceRelay: Bool = false                  // ★ 强制走 TURN 中继（后台开关，测试用）
    var isReadyForViewers: Bool = false           // 视频轨道已就绪，可以接受观看请求
```

---

### 修改 12-B：`createViewerSession` 根据 `forceRelay` 设置 ICE 传输策略

**位置**：`createViewerSession(for pcDeviceId:)` 函数内，设置 `cfg.iceTransportPolicy` 的那一行

**找到这段代码**：

```swift
        cfg.continualGatheringPolicy = .gatherContinually
        cfg.iceBackupCandidatePairPingInterval = 2000
        cfg.iceCandidatePoolSize = 2
        cfg.iceTransportPolicy = .all
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
```

**改为**：

```swift
        cfg.continualGatheringPolicy = .gatherContinually
        cfg.iceBackupCandidatePairPingInterval = 2000
        cfg.iceCandidatePoolSize = 2
        // ★ 强制中继模式：只生成 relay 候选者（所有流量经 TURN 服务器中转）
        cfg.iceTransportPolicy = forceRelay ? .relay : .all
        if forceRelay {
            print("⚠️ [P2P] 强制中继模式已开启，iceTransportPolicy=relay")
        }
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
```

---

## iOS 登录处理：读取 `forceRelay` 字段

在 iOS 的登录成功回调中（解析后端返回 JSON 的地方），需要读取 `forceRelay` 字段并设置到 WebRTCManager。

**在设置 `maxP2PViewers` 和 `iceServerConfig` 的同一位置附近，新增**：

```swift
// ★ 读取强制中继开关（后台测试用）
if let forceRelay = loginResponse["forceRelay"] as? Bool {
    WebRTCManager.shared.forceRelay = forceRelay
    print("🔄 [Login] forceRelay = \(forceRelay)")
}
```

> 说明：`loginResponse` 是登录接口返回的 JSON 字典，具体变量名根据你实际代码中的命名来替换。

---

## 修改总结

| # | 位置 | 操作 | 原因 |
|---|------|------|------|
| 12-A | WebRTCManager 属性区 | 新增 `forceRelay: Bool = false` | 存储后台下发的强制中继开关 |
| 12-B | `createViewerSession` | `iceTransportPolicy = forceRelay ? .relay : .all` | 开启时只走 TURN 中继 |
| 12-C | 登录回调 | 读取 `forceRelay` 写入 WebRTCManager | 后台配置同步到客户端 |

## 工作原理

```
后台关闭（默认）：
  iceTransportPolicy = .all
  → iOS 生成 host + srflx + relay 候选者
  → PC 和 iOS 直连（局域网走 host，公网走 srflx/relay）
  → 延迟最低

后台开启（测试）：
  iceTransportPolicy = .relay
  → iOS 只生成 relay 候选者（必须经过 TURN 服务器）
  → PC 的 host/srflx 候选者找不到 iOS 的 host/srflx 匹配
  → 双方通过 relay 候选者建立连接 → 流量走 TURN 服务器
  → 可验证 TURN 服务器是否正常工作
```