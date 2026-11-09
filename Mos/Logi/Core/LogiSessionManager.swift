//
//  LogiSessionManager.swift
//  Mos
//  Logitech HID 设备管理器 - 通过 IOKit 枚举和监控 Logitech 设备
//  Created by Mos on 2026/3/16.
//  Copyright © 2026 Caldis. All rights reserved.
//

import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

/// Cycle direction for DPI / SmartShift toggle helpers.
public enum Direction { case up, down }

/// HID `DeviceUsagePairs` 单项 (`kIOHIDDeviceUsagePageKey` + `kIOHIDDeviceUsageKey`).
struct LogiHIDUsagePair: Equatable, Hashable {
    let usagePage: Int
    let usage: Int

    static func fromIOHIDProperty(_ rawProperty: Any?) -> [LogiHIDUsagePair] {
        guard let entries = rawProperty as? [[String: Any]] else { return [] }
        let pageKey = kIOHIDDeviceUsagePageKey as String
        let usageKey = kIOHIDDeviceUsageKey as String
        return entries.compactMap { entry in
            guard let page = (entry[pageKey] as? NSNumber)?.intValue,
                  let usage = (entry[usageKey] as? NSNumber)?.intValue else {
                return nil
            }
            return LogiHIDUsagePair(usagePage: page, usage: usage)
        }
    }
}

/// Internal manager that orchestrates Logi HID device sessions. The only
/// supported public surface is `LogiCenter` (Step 5's lint script enforces
/// this against the rest of the app). Tests in `MosTests/Logi*Tests.swift`
/// reference internal Logi symbols by design.
internal class LogiSessionManager {
    internal static let shared = LogiSessionManager()
    init() { NSLog("Module initialized: LogiSessionManager") }

    // MARK: - Constants
    static let logitechVendorId: Int = 0x046D
    static let buttonEventNotification = NSNotification.Name("LogiButtonEvent")
    private static let screenIsLockedNotification = Notification.Name("com.apple.screenIsLocked")
    private static let screenIsUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    private static let unlockRecoveryDelay: TimeInterval = 0.35
    private static let maxUnlockSettlePolls = 4
    private static let permissionRetryDelays: [TimeInterval] = [0.5, 1.5, 3.0]
    private static let lazyActivityRecoveryCooldown: TimeInterval = 3.0
    private static let maxLazyActivityRecoveryAttempts = 2

    enum UnlockRecoveryAction: Equatable {
        case none
        case restartManager
        case probeActiveSessions
    }

    // MARK: - State
    private var hidManager: IOHIDManager?
    private var sessions: [IOHIDDevice: LogiDeviceSession] = [:]
    private(set) var isActive = false
    private let deliveryModes = LogiButtonDeliveryModeStore()
    private var systemObserversInstalled = false
    private var screenLockObserved = false
    private var unlockRecoveryWorkItem: DispatchWorkItem?
    private var unlockSettlePollCount = 0
    private var permissionRetryWorkItem: DispatchWorkItem?
    private var permissionRetryCount = 0
    private var lazyActivityRecoveryCount = 0
    private var lastLazyActivityRecoveryTime: TimeInterval = 0
    private var isRestartingForRecovery = false

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        installSystemObserversIfNeeded()
        screenLockObserved = Self.queryScreenLocked()
        LogiDebugPanel.log("[LogitechHID] Starting")

        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else {
            LogiDebugPanel.log("[LogitechHID] Failed to create IOHIDManager")
            return
        }

        // 只匹配 Logitech 设备
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: LogiSessionManager.logitechVendorId
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

        // 注册回调 (使用 C 函数指针 + context)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemovedCallback, context)

        // Schedule 到 main RunLoop (HID++ 事件低频, 避免线程同步)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        isActive = true
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            isActive = false
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            hidManager = nil
            LogiDebugPanel.log("[LogitechHID] Failed to open IOHIDManager: \(String(format: "0x%08x", result))")
            return
        }

        LogiDebugPanel.log("[LogitechHID] Started")
    }

    func stop() {
        guard isActive else { return }
        LogiDebugPanel.log("[LogitechHID] Stopping")

        if !isRestartingForRecovery {
            unlockRecoveryWorkItem?.cancel()
            unlockRecoveryWorkItem = nil
            unlockSettlePollCount = 0
            permissionRetryWorkItem?.cancel()
            permissionRetryWorkItem = nil
            permissionRetryCount = 0
            lazyActivityRecoveryCount = 0
            lastLazyActivityRecoveryTime = 0
            deliveryModes.resetAll()
        }

        // 清理所有设备会话
        for (_, session) in sessions {
            session.teardown()
        }
        sessions.removeAll()

        if let manager = hidManager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        hidManager = nil
        isActive = false
        // sessions 被清空后重算一次, 把 lastKnownBusy 归位并让 UI 同步关闭 spinner.
        recomputeAndNotifyActivityState()
        LogiDebugPanel.log("[LogitechHID] Stopped")
    }

    // MARK: - Screen Lock & Permission-Denied Session Recovery

    static func queryScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    var isScreenLocked: Bool {
        return screenLockObserved || Self.queryScreenLocked()
    }

    static func unlockRecoveryAction(
        isActive: Bool,
        hasCandidateSessions: Bool,
        anySessionNeedsReopen: Bool,
        anyCandidateIncomplete: Bool
    ) -> UnlockRecoveryAction {
        guard isActive, hasCandidateSessions else { return .none }
        if anySessionNeedsReopen || anyCandidateIncomplete {
            return .restartManager
        }
        return .probeActiveSessions
    }

    static func nextPermissionRetryDelay(completedAttempts: Int) -> TimeInterval? {
        guard completedAttempts >= 0, completedAttempts < permissionRetryDelays.count else {
            return nil
        }
        return permissionRetryDelays[completedAttempts]
    }

    static func canAttemptLazyActivityRecovery(
        isScreenLocked: Bool,
        completedAttempts: Int,
        now: TimeInterval,
        lastAttemptTime: TimeInterval
    ) -> Bool {
        guard !isScreenLocked,
              completedAttempts < maxLazyActivityRecoveryAttempts,
              lastAttemptTime == 0 || (now - lastAttemptTime) >= lazyActivityRecoveryCooldown else {
            return false
        }
        return true
    }

    private func installSystemObserversIfNeeded() {
        guard !systemObserversInstalled else { return }
        systemObserversInstalled = true
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: Self.screenIsLockedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenLocked()
        }
        dnc.addObserver(
            forName: Self.screenIsUnlockedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenUnlocked()
        }
    }

    private func handleScreenLocked() {
        screenLockObserved = true
        unlockRecoveryWorkItem?.cancel()
        unlockRecoveryWorkItem = nil
        unlockSettlePollCount = 0
        permissionRetryWorkItem?.cancel()
        permissionRetryWorkItem = nil
        LogiDebugPanel.log("[LogitechHID] Screen locked")
    }

    private func handleScreenUnlocked() {
        screenLockObserved = false
        unlockSettlePollCount = 0
        permissionRetryCount = 0
        lazyActivityRecoveryCount = 0
        lastLazyActivityRecoveryTime = 0
        permissionRetryWorkItem?.cancel()
        permissionRetryWorkItem = nil
        guard isActive else { return }
        LogiDebugPanel.log("[LogitechHID] Screen unlocked; scheduling session verification")
        scheduleUnlockRecovery(delay: Self.unlockRecoveryDelay)
    }

    private func scheduleUnlockRecovery(delay: TimeInterval) {
        unlockRecoveryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.unlockRecoveryWorkItem = nil
            self.performUnlockRecovery()
        }
        unlockRecoveryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func performUnlockRecovery() {
        guard isActive, !screenLockObserved else { return }
        if Self.queryScreenLocked(), unlockSettlePollCount < Self.maxUnlockSettlePolls {
            unlockSettlePollCount += 1
            scheduleUnlockRecovery(delay: Self.unlockRecoveryDelay)
            return
        }
        unlockSettlePollCount = 0

        let candidates = sessions.values.filter { $0.isHIDPPCandidate }
        let anyNeedsReopen = candidates.contains { $0.needsSessionReopen }
        let anyIncomplete = candidates.contains { $0.needsPostSleepHandshakeRecovery }
        let action = Self.unlockRecoveryAction(
            isActive: isActive,
            hasCandidateSessions: !candidates.isEmpty,
            anySessionNeedsReopen: anyNeedsReopen,
            anyCandidateIncomplete: anyIncomplete
        )
        switch action {
        case .none:
            break
        case .restartManager:
            restartManagerForRecovery(reason: "screen unlocked with blocked or incomplete HID++ session")
        case .probeActiveSessions:
            for session in candidates {
                session.triggerImmediateWakeProbe(reason: "screen unlocked")
            }
        }
    }

    func noteSessionPermissionDenied(_ session: LogiDeviceSession, ioreturn: IOReturn) {
        guard isActive else { return }
        if isScreenLocked {
            LogiDebugPanel.log(
                "[LogitechHID] \(session.deviceInfo.name) setReport denied (\(String(format: "0x%08x", ioreturn))) while screen locked; waiting for unlock"
            )
            return
        }
        guard permissionRetryWorkItem == nil,
              let delay = Self.nextPermissionRetryDelay(completedAttempts: permissionRetryCount) else {
            return
        }
        permissionRetryCount += 1
        let attempt = permissionRetryCount
        LogiDebugPanel.log(
            "[LogitechHID] \(session.deviceInfo.name) setReport denied (\(String(format: "0x%08x", ioreturn))); scheduling session reopen #\(attempt) in \(String(format: "%.1fs", delay))"
        )
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.permissionRetryWorkItem = nil
            guard self.isActive, !self.isScreenLocked else { return }
            guard self.sessions.values.contains(where: { $0.needsSessionReopen }) else { return }
            self.restartManagerForRecovery(reason: "HID setReport permission retry #\(attempt)")
        }
        permissionRetryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func noteSessionActivityWhileBlocked(_ session: LogiDeviceSession, at now: TimeInterval) {
        guard isActive,
              unlockRecoveryWorkItem == nil,
              permissionRetryWorkItem == nil,
              Self.canAttemptLazyActivityRecovery(
                  isScreenLocked: isScreenLocked,
                  completedAttempts: lazyActivityRecoveryCount,
                  now: now,
                  lastAttemptTime: lastLazyActivityRecoveryTime
              ) else {
            return
        }
        lazyActivityRecoveryCount += 1
        lastLazyActivityRecoveryTime = now
        let attempt = lazyActivityRecoveryCount
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isActive, !self.isScreenLocked else { return }
            guard self.sessions.values.contains(where: { $0.needsSessionReopen }) else { return }
            self.restartManagerForRecovery(reason: "post-denial input activity #\(attempt)")
        }
    }

    func noteSessionSendSucceeded() {
        guard !sessions.values.contains(where: { $0.needsSessionReopen }) else { return }
        permissionRetryCount = 0
        lazyActivityRecoveryCount = 0
        lastLazyActivityRecoveryTime = 0
    }

    private func restartManagerForRecovery(reason: String) {
        guard isActive else { return }
        let preserveRecording = isRecording
        LogiDebugPanel.log("[LogitechHID] Restarting IOHIDManager (\(reason))")
        isRestartingForRecovery = true
        defer { isRestartingForRecovery = false }
        stop()
        start()
        if preserveRecording {
            temporarilyDivertAll()
        }
    }

    // MARK: - Device Callbacks (C function pointers)

    private static let deviceMatchedCallback: IOHIDDeviceCallback = { context, result, sender, device in
        guard let context = context else { return }
        let manager = Unmanaged<LogiSessionManager>.fromOpaque(context).takeUnretainedValue()
        manager.deviceConnected(device)
    }

    private static let deviceRemovedCallback: IOHIDDeviceCallback = { context, result, sender, device in
        guard let context = context else { return }
        let manager = Unmanaged<LogiSessionManager>.fromOpaque(context).takeUnretainedValue()
        manager.deviceDisconnected(device)
    }

    // MARK: - Device Management

    private func deviceConnected(_ device: IOHIDDevice) {
        // 读取设备信息
        let vendorId = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productId = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let isBLE = Self.isBluetoothTransport(transport)
        let deviceUsagePairs = LogiHIDUsagePair.fromIOHIDProperty(
            IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString)
        )

        LogiDebugPanel.log("[LogitechHID] Device connected: \(productName) (VID: \(String(format: "0x%04X", vendorId)), PID: \(String(format: "0x%04X", productId)))")

        // 避免重复会话
        guard sessions[device] == nil else { return }

        // 键盘接口跳过: Mos 对键盘没有 HID++ 用途, 一旦创建会话会在接口上注册
        // input-report 回调, 使键盘无法进入休眠, 导致背光常亮 (issue #948)。
        // 不创建 LogiDeviceSession 即可完全不触碰该 HID 接口。
        guard Self.shouldAttachSession(
            usagePage: usagePage,
            usage: usage,
            isBLE: isBLE,
            productId: productId,
            deviceUsagePairs: deviceUsagePairs
        ) else {
            LogiDebugPanel.log("[LogitechHID] Skipping keyboard interface (keeps device awake): \(productName)")
            return
        }

        // 创建会话
        let session = LogiDeviceSession(hidDevice: device)
        sessions[device] = session
        session.setup()
        NotificationCenter.default.post(name: Self.sessionChangedNotification, object: nil)
    }

    static func isBluetoothTransport(_ transport: String) -> Bool {
        return transport.lowercased().contains("bluetooth")
    }

    /// Logitech 蓝牙键盘 PID 段 (`0xB300...0xB3FF`, 如 K380/MX Keys/MX Mechanical)。
    /// 部分复合蓝牙键盘描述符中可能附带模拟鼠标键的 Mouse collection,
    /// 显式排除该段可确保 #948 的键盘休眠保护不被误放行。
    static func isLogitechBLEKeyboardProductId(_ productId: Int) -> Bool {
        return (0xB300...0xB3FF).contains(productId)
    }

    /// 决定 Mos 是否应为某条 Logitech HID 接口创建会话。
    ///
    /// 纯键盘接口 (Generic Desktop `0x0001` / Keyboard `0x0006`) 永远不是 HID++ 候选,
    /// 若创建会话并注册 input-report 回调会让键盘端点保持活跃、背光常亮 (issue #948)。
    /// 但部分 BLE 鼠标 (如 M720 Triathlon `0xB015`、MX Master 2S `0xB019`、MX Anywhere 2S `0xB01A`)
    /// 将板载快捷键的 Keyboard collection 排在 HID 描述符首位 (`PrimaryUsage = 1/6`),
    /// 同时在同一条复合 BLE 接口上暴露 Mouse (`1/2`) 与 BLE HID++ (`0xFF43/0x0202`),
    /// 这类复合 BLE 鼠标必须挂载会话。
    static func shouldAttachSession(
        usagePage: Int,
        usage: Int,
        isBLE: Bool = false,
        productId: Int = 0,
        deviceUsagePairs: [LogiHIDUsagePair] = []
    ) -> Bool {
        // Generic Desktop (0x0001) Keyboard (0x0006)
        if usagePage == 0x0001 && usage == 0x0006 {
            guard isBLE, !isLogitechBLEKeyboardProductId(productId) else {
                return false
            }
            return deviceUsagePairs.contains(LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0002))
        }
        return true
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        guard let session = sessions.removeValue(forKey: device) else { return }
        LogiDebugPanel.log("[LogitechHID] Device disconnected: \(session.deviceInfo.name)")
        deliveryModes.removeModes(forDeviceNamed: session.deviceInfo.name, productId: session.deviceInfo.productId)
        session.teardown()
        NotificationCenter.default.post(name: Self.sessionChangedNotification, object: nil)
        // 断开的 session 可能曾处于 busy 状态, 重新聚合一次防止 spinner 卡住.
        recomputeAndNotifyActivityState()
    }

    // MARK: - Query

    /// 获取当前已连接的 Logitech 设备列表
    var connectedDevices: [InputDevice] {
        return sessions.values.map { $0.deviceInfo }
    }

    /// Debug: 暴露活跃的设备会话
    var activeSessions: [LogiDeviceSession] {
        return Array(sessions.values)
    }

    static let sessionChangedNotification = NSNotification.Name("LogiSessionChanged")

    /// 某个 session 的 discovery 握手流程开始或结束时触发; UI 据此切换 spinner.
    static let discoveryStateDidChangeNotification = NSNotification.Name("LogiDiscoveryStateDidChange")

    /// 某个 session 完成 reporting 查询后触发, UI 可据此刷新冲突指示.
    static let reportingQueryDidCompleteNotification = NSNotification.Name("LogiReportingQueryDidComplete")

    /// 任一 HID++ session 的活动状态 (discovery / reporting query) 发生变化时触发;
    /// 聚合后只在 "全局是否忙碌" 翻转的瞬间 post, UI 订阅后用来驱动 activity spinner.
    static let activityStateDidChangeNotification = NSNotification.Name("LogiActivityStateDidChange")

    /// 冲突状态变化通知; Step 4/5 会在 reporting query 完成等位置 post 此通知.
    /// Step 2 仅声明命名,不在任何位置 post.
    static let conflictChangedNotification = NSNotification.Name("LogiConflictChanged")

    // MARK: - Activity State Aggregation

    /// 最近一次已广播的聚合忙碌状态. 仅用于去抖 (transition-only post).
    private var lastKnownBusy: Bool = false

    /// 当前是否有任一 Logi session 正在执行 HID++ 交互 (discovery 或 reporting query).
    /// UI 在 main thread 同步读此值, 零阻塞.
    var isBusy: Bool { lastKnownBusy }

    /// 由 session 在活动状态变化的关键位置调用 (setDiscoveryInFlight / startReportingQuery /
    /// advanceReportingQuery 完成分支 / session 增删). Manager 聚合所有 session, 仅在全局
    /// 忙碌状态翻转时广播 `activityStateDidChangeNotification`.
    /// 调用链完全在 main thread (IOHIDManager 调度到 main RunLoop), 无需额外同步.
    func recomputeAndNotifyActivityState() {
        let newBusy = sessions.values.contains(where: { $0.isActivityInProgress })
        guard newBusy != lastKnownBusy else { return }
        lastKnownBusy = newBusy
        NotificationCenter.default.post(name: Self.activityStateDidChangeNotification, object: nil)
    }

    /// UI hover popover 的数据源: 所有当前活跃 session 的状态快照.
    /// popover 在可见时以低频 (~250ms) 拉取此快照而非订阅细粒度通知, 避免
    /// reporting query 每次 advance 都产生 post 导致通知风暴.
    var currentActivitySummary: [SessionActivityStatus] {
        return sessions.values.compactMap { $0.activityStatus }
    }

    // MARK: - Reporting Refresh Throttle

    /// 最小刷新间隔:避免 UI 事件频繁触发导致 HID++ 协议压力.
    /// 用户的预期场景 (打开面板 / 切分页 / App 激活) 在 10s 内几乎不会产生新的冲突变化,
    /// 取 10s 是响应性 vs HID link 稳定性的折中.
    private static let reportingRefreshMinInterval: TimeInterval = 10

    private var lastReportingRefresh: Date?

    /// Coalesced 入口:刷新所有 HID++ session 的 reporting 状态 (重跑 GetControlReporting).
    /// 调用方决定时机 (例如 UI 想看冲突图标), manager 只负责执行 + 节流.
    ///
    /// 节流: `reportingRefreshMinInterval` (~3s) 内重复调用直接返回, 防 UI 抖动.
    /// 没 Logi 候选会话时自然 no-op (sessions filter 后为空集合).
    /// 同步返回, 不阻塞 UI — 实际 HID++ 请求在各自 session 的 input-report 回调里
    /// 异步处理, 完成后通过 `reportingQueryDidCompleteNotification` 刷新 indicator.
    func refreshReportingStates() {
        if let last = lastReportingRefresh,
           Date().timeIntervalSince(last) < Self.reportingRefreshMinInterval {
            #if DEBUG
            LogiTrace.log("[Manager] refreshReportingStates throttled")
            #endif
            return
        }
        lastReportingRefresh = Date()
        #if DEBUG
        LogiTrace.log("[Manager] refreshReportingStates sessions=\(sessions.count)")
        #endif
        for session in sessions.values where session.isHIDPPCandidate {
            session.refreshReportingState()
        }
    }

    /// 查询某 Logi MosCode 当前是否被第三方 (如 Logitech Options+) 接管.
    /// 未连接设备 / 未完成 reporting 查询 / 非 Logi code -> unknown.
    func conflictStatus(forMosCode mosCode: UInt16) -> ConflictStatus {
        return buttonCaptureDiagnosis(forMosCode: mosCode).ownership
    }

    func buttonCaptureDiagnosis(forMosCode mosCode: UInt16) -> LogiButtonCaptureDiagnosis {
        guard let cid = LogiCIDDirectory.toCID(mosCode) else {
            return .unknown(nativeMouseButton: nil)
        }
        let nativeMouseButton = LogiCIDDirectory.nativeMouseButton(forCID: cid)
        var diagnoses: [LogiButtonCaptureDiagnosis] = []

        for session in sessions.values.sorted(by: Self.prefersDiagnosisSession) where session.isHIDPPCandidate {
            if let control = session.control(forCID: cid) {
                let mosOwns = session.debugDivertedCIDs.contains(cid)
                let ownership = LogiConflictDetector.status(
                    reportingFlags: control.reportingFlags,
                    targetCID: control.targetCID,
                    cid: cid,
                    reportingQueried: control.reportingQueried,
                    mosOwnsDivert: mosOwns
                )
                let key = session.ownershipKey(forCID: cid)
                let delivery = deliveryModes.mode(for: key)
                let usesNativeEvents = !LogiButtonDeliveryPolicy.default.shouldUseHIDPPDelivery(
                    transport: key.transport,
                    cid: cid,
                    phase: .normal
                )
                let diagnosis = LogiButtonCaptureDiagnosis(
                    ownership: ownership,
                    delivery: delivery,
                    ownershipKey: key,
                    nativeMouseButton: nativeMouseButton,
                    usesNativeEvents: usesNativeEvents
                )
                diagnoses.append(diagnosis)
            }
        }
        return diagnoses.first ?? .unknown(nativeMouseButton: nativeMouseButton)
    }

    private static func prefersDiagnosisSession(_ lhs: LogiDeviceSession, _ rhs: LogiDeviceSession) -> Bool {
        return diagnosisSessionRank(lhs) < diagnosisSessionRank(rhs)
    }

    private static func diagnosisSessionRank(_ session: LogiDeviceSession) -> Int {
        return diagnosisSessionRank(
            transport: LogiTransportIdentity(session.connectionMode),
            receiverTargetConnected: session.debugCurrentReceiverTargetIsConnected
        )
    }

    private static func diagnosisSessionRank(
        transport: LogiTransportIdentity,
        receiverTargetConnected: Bool
    ) -> Int {
        switch transport {
        case .receiver:
            return receiverTargetConnected ? 0 : 3
        case .bleDirect:
            return 1
        case .unsupported:
            return 4
        }
    }

    #if DEBUG
    internal static func diagnosisSessionRankForTests(
        transport: LogiTransportIdentity,
        receiverTargetConnected: Bool
    ) -> Int {
        return diagnosisSessionRank(
            transport: transport,
            receiverTargetConnected: receiverTargetConnected
        )
    }
    #endif

    func deliveryMode(forMosCode mosCode: UInt16) -> LogiButtonDeliveryMode? {
        return deliveryModes.deliveryMode(forMosCode: mosCode, matching: activeOwnershipKeys)
    }

    func notifyConflictChanged() {
        NotificationCenter.default.post(name: Self.conflictChangedNotification, object: nil)
    }

    private var activeOwnershipKeys: [LogiOwnershipKey] {
        return sessions.values.flatMap { $0.ownershipKeysForKnownControls() }
    }

    func deliveryMode(for key: LogiOwnershipKey) -> LogiButtonDeliveryMode {
        return deliveryModes.mode(for: key)
    }

    @discardableResult
    func recordExternalClear(for key: LogiOwnershipKey, at now: Date = Date()) -> LogiButtonDeliveryMode {
        let previousMode = deliveryModes.mode(for: key)
        let mode = deliveryModes.recordExternalClear(for: key, at: now)
        #if DEBUG
        LogiTrace.log("[Manager] recordExternalClear key=\(key.name) cid=\(String(format: "0x%04X", key.cid)) transport=\(key.transport) previous=\(previousMode.debugLabel) current=\(mode.debugLabel)")
        #endif
        if mode != previousMode {
            LogiDebugPanel.log(
                device: key.name,
                type: .buttonEvent,
                message: "[DeliveryMode] changed cid=\(String(format: "0x%04X", key.cid)) mosCode=\(LogiCIDDirectory.toMosCode(key.cid)) transport=\(key.transport) previous=\(previousMode.debugLabel) current=\(mode.debugLabel)"
            )
            if mode == .contended {
                showDeliveryContentionToast(for: key)
            }
        }
        if mode != .hidpp {
            notifyConflictChanged()
        }
        return mode
    }

    private func showDeliveryContentionToast(for key: LogiOwnershipKey) {
        let messageKey: String
        if key.transport == .bleDirect,
           LogiCIDDirectory.nativeMouseButton(forCID: key.cid) != nil {
            messageKey = "logi_ble_contention_standard_mouse_alias_toast"
        } else {
            messageKey = "logi_hidpp_contention_toast"
        }
        let controlName = LogiCIDDirectory.name(forCID: key.cid)
        let message = String(format: NSLocalizedString(messageKey, comment: ""), controlName)
        LogiCenter.shared.externalBridge.showLogiToast(message, severity: .warning)
    }

    // MARK: - Divert Control

    /// 录制模式标志: 录制期间跳过动作执行, 只转发事件给 KeyRecorder
    private(set) var isRecording = false

    /// 录制模式: 临时 divert 所有按键
    func temporarilyDivertAll() {
        isRecording = true
        #if DEBUG
        LogiTrace.log("[Manager] beginRecording sessions=\(sessions.count) candidates=\(sessions.values.filter { $0.isHIDPPCandidate }.count)")
        #endif
        for (_, session) in sessions where session.isHIDPPCandidate {
            session.temporarilyDivertAll()
        }
    }

    /// 录制结束: 恢复到只 divert 有绑定的按键
    func restoreDivertToBindings() {
        isRecording = false
        #if DEBUG
        LogiTrace.log("[Manager] endRecording sessions=\(sessions.count) candidates=\(sessions.values.filter { $0.isHIDPPCandidate }.count)")
        #endif
        for (_, session) in sessions where session.isHIDPPCandidate {
            session.restoreDivertToBindings()
        }
    }

    // MARK: - Logi Action Execution

    /// 获取最佳活跃 session (优先已完成 init 的, 其次 BLE)
    private var primarySession: LogiDeviceSession? {
        // 优先: 已完成 init 的 session
        if let ready = sessions.values.first(where: { $0.isHIDPPCandidate && $0.debugReprogInitComplete }) {
            return ready
        }
        // 其次: BLE 候选
        if let ble = sessions.values.first(where: { $0.isHIDPPCandidate && $0.debugIsBLE }) {
            return ble
        }
        // 最后: 任意候选
        return sessions.values.first(where: { $0.isHIDPPCandidate })
    }

    /// SmartShift 切换: 读取当前模式, 取反
    func executeSmartShiftToggle() {
        guard let session = primarySession else { return }
        session.executeSmartShiftToggle()
    }

    /// DPI 循环
    func executeDPICycle(direction: Direction) {
        guard let session = primarySession else { return }
        session.executeDPICycle(direction: direction)
    }
}
