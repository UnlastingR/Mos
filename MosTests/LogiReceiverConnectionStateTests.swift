import IOKit
import XCTest
@testable import Mos_Debug

final class LogiReceiverConnectionStateTests: XCTestCase {

    func testBLEIsAlwaysSendableForReceiverTargetChecks() {
        XCTAssertTrue(LogiDeviceSession.receiverTargetIsConnectedForTests(
            connectionMode: .bleDirect,
            deviceIndex: 0xFF,
            pairedDevices: []
        ))
    }

    func testKnownDisconnectedReceiverTargetIsNotSendable() {
        XCTAssertFalse(LogiDeviceSession.receiverTargetIsConnectedForTests(
            connectionMode: .receiver,
            deviceIndex: 0x03,
            pairedDevices: [
                .init(slot: 0x03, isConnected: false)
            ]
        ))
    }

    func testUnknownReceiverTargetDefaultsToSendable() {
        XCTAssertTrue(LogiDeviceSession.receiverTargetIsConnectedForTests(
            connectionMode: .receiver,
            deviceIndex: 0x03,
            pairedDevices: []
        ))
    }

    // MARK: - chooseReceiverTargetSlot (Phase 0 prefer-mouse 巡检游标)

    private func device(
        slot: UInt8,
        connected: Bool,
        type: UInt8
    ) -> LogiDeviceSession.ReceiverPairedDevice {
        var d = LogiDeviceSession.ReceiverPairedDevice(slot: slot)
        d.isConnected = connected
        d.deviceType = type
        return d
    }

    func testChooseTargetPrefersMouseOverLowerNumberedKeyboard() {
        // 键盘在更低号 slot, 鼠标在更高号 slot -> 选鼠标 (修复旧的锁最低号 bug)
        XCTAssertEqual(LogiDeviceSession.chooseReceiverTargetSlot(devices: [
            device(slot: 1, connected: true, type: 0x01),  // Keyboard
            device(slot: 3, connected: true, type: 0x02)   // Mouse
        ]), 3)
    }

    func testChooseTargetFallsBackToFirstConnectedWhenNoMouse() {
        XCTAssertEqual(LogiDeviceSession.chooseReceiverTargetSlot(devices: [
            device(slot: 2, connected: true, type: 0x01),  // Keyboard
            device(slot: 4, connected: true, type: 0x01)   // Keyboard
        ]), 2)
    }

    func testChooseTargetFallsBackToFirstConnectedWhenTypesUnknown() {
        // device-info 未到齐 (deviceType 全 0) 时回退首个在线 slot, 不退化
        XCTAssertEqual(LogiDeviceSession.chooseReceiverTargetSlot(devices: [
            device(slot: 2, connected: true, type: 0x00),
            device(slot: 4, connected: true, type: 0x00)
        ]), 2)
    }

    func testChooseTargetSkipsDisconnectedMouse() {
        // 鼠标已断开, 只有键盘在线 -> 回退在线键盘, 不选断开的鼠标
        XCTAssertEqual(LogiDeviceSession.chooseReceiverTargetSlot(devices: [
            device(slot: 1, connected: false, type: 0x02),  // Mouse (disconnected)
            device(slot: 3, connected: true, type: 0x01)    // Keyboard
        ]), 3)
    }

    func testChooseTargetPicksFirstConnectedMouse() {
        XCTAssertEqual(LogiDeviceSession.chooseReceiverTargetSlot(devices: [
            device(slot: 2, connected: true, type: 0x02),  // Mouse
            device(slot: 5, connected: true, type: 0x02)   // Mouse
        ]), 2)
    }

    func testChooseTargetReturnsNilWhenNothingConnected() {
        XCTAssertNil(LogiDeviceSession.chooseReceiverTargetSlot(devices: [
            device(slot: 1, connected: false, type: 0x02),
            device(slot: 2, connected: false, type: 0x01)
        ]))
        XCTAssertNil(LogiDeviceSession.chooseReceiverTargetSlot(devices: []))
    }

    // MARK: - receiverDivertSlots (Phase 2 接管集合)

    private func device(
        slot: UInt8,
        connected: Bool,
        type: UInt8,
        pid: UInt16
    ) -> LogiDeviceSession.ReceiverPairedDevice {
        var d = LogiDeviceSession.ReceiverPairedDevice(slot: slot)
        d.isConnected = connected
        d.deviceType = type
        d.wirelessPID = pid
        return d
    }

    func testDivertSlotsIncludesOnlyConnectedBoundMice() {
        let devices = [
            device(slot: 1, connected: true, type: 0x01, pid: 0xB350),  // Keyboard -> excluded
            device(slot: 2, connected: true, type: 0x02, pid: 0x4082),  // Mouse, bound
            device(slot: 3, connected: false, type: 0x02, pid: 0x4082), // Mouse, disconnected -> excluded
            device(slot: 4, connected: true, type: 0x02, pid: 0x999),   // Mouse, no binding -> excluded
            device(slot: 5, connected: true, type: 0x02, pid: 0x4082)   // Mouse, bound
        ]
        let bound: Set<UInt16> = [0x4082]
        XCTAssertEqual(
            LogiDeviceSession.receiverDivertSlots(devices: devices) { bound.contains($0) },
            [2, 5]
        )
    }

    func testDivertSlotsEmptyWhenNoBindings() {
        let devices = [
            device(slot: 2, connected: true, type: 0x02, pid: 0x4082),
            device(slot: 3, connected: true, type: 0x02, pid: 0x4083)
        ]
        XCTAssertEqual(
            LogiDeviceSession.receiverDivertSlots(devices: devices) { _ in false },
            []
        )
    }

    func testDivertSlotsSortedAscending() {
        let devices = [
            device(slot: 5, connected: true, type: 0x02, pid: 0x4082),
            device(slot: 2, connected: true, type: 0x02, pid: 0x4082)
        ]
        XCTAssertEqual(
            LogiDeviceSession.receiverDivertSlots(devices: devices) { _ in true },
            [2, 5]
        )
    }

    func testDivertSlotsIncludesUnknownTypeSlots() {
        // 关键回归: 接收器不返回 deviceType (寄存器 0xB5 InvalidSubID) 时类型恒为 0(未知).
        // 未知类型的鼠标必须纳入接管, 否则永不 divert (真实 USB Receiver 上的现象).
        let devices = [
            device(slot: 1, connected: true, type: 0x00, pid: 0x0000),  // 未知(实为键盘, 但类型拿不到)
            device(slot: 4, connected: true, type: 0x00, pid: 0x0000)   // 未知(实为鼠标)
        ]
        XCTAssertEqual(
            LogiDeviceSession.receiverDivertSlots(devices: devices) { _ in true },
            [1, 4]
        )
    }

    func testDivertSlotsExcludesKnownKeyboardIncludesUnknownMouse() {
        // 类型部分已知: 键盘(0x01)排除, 未知/鼠标纳入.
        let devices = [
            device(slot: 1, connected: true, type: 0x01, pid: 0x0000),  // Keyboard -> excluded
            device(slot: 4, connected: true, type: 0x00, pid: 0x0000),  // Unknown -> included
            device(slot: 5, connected: true, type: 0x02, pid: 0x0000)   // Mouse -> included
        ]
        XCTAssertEqual(
            LogiDeviceSession.receiverDivertSlots(devices: devices) { _ in true },
            [4, 5]
        )
    }

    // MARK: - receiverReportRoute (Phase 2 报文分发)

    func testReportRouteProcessesCurrentSlot() {
        XCTAssertEqual(
            LogiDeviceSession.receiverReportRoute(incomingSlot: 2, currentSlot: 2, managedSlots: [2, 5]),
            .processCurrent
        )
    }

    func testReportRouteScopesToOtherManagedSlot() {
        XCTAssertEqual(
            LogiDeviceSession.receiverReportRoute(incomingSlot: 5, currentSlot: 2, managedSlots: [2, 5]),
            .processScoped(5)
        )
    }

    func testReportRouteDropsUnmanagedSlot() {
        XCTAssertEqual(
            LogiDeviceSession.receiverReportRoute(incomingSlot: 4, currentSlot: 2, managedSlots: [2, 5]),
            .drop
        )
    }

    func testReportRouteSingleDeviceDropsNonCurrent() {
        // 单设备: managedSlots = {current}, 其它 slot 一律 drop (与旧 stale 过滤等价)
        XCTAssertEqual(
            LogiDeviceSession.receiverReportRoute(incomingSlot: 3, currentSlot: 1, managedSlots: [1]),
            .drop
        )
    }

    // MARK: - hidppDeviceTypeName (feature 0x0005 getDeviceType 枚举映射)

    func testHidppDeviceTypeNameMapping() {
        func name(_ t: UInt8) -> String? {
            var d = LogiDeviceSession.ReceiverPairedDevice(slot: 1)
            d.hidppDeviceType = t
            return d.hidppDeviceTypeName
        }
        XCTAssertEqual(name(0x00), "Keyboard (0x00)")
        XCTAssertEqual(name(0x03), "Mouse (0x03)")
        XCTAssertEqual(name(0x05), "Trackball (0x05)")
        XCTAssertEqual(name(0x06), "Presenter (0x06)")
        XCTAssertEqual(name(0x99), "Unknown (0x99)")
    }

    func testHidppDeviceTypeNameNilWhenUnknown() {
        let d = LogiDeviceSession.ReceiverPairedDevice(slot: 1)
        XCTAssertNil(d.hidppDeviceTypeName)  // 未查询 -> nil
    }

    // MARK: - controlsLookLikeMouse (类型不可知接收器上据控件识别鼠标)

    func testControlsLookLikeMouseWithLeftAndRight() {
        // 鼠标: 有 Left(0x50) + Right(0x51) + 其它
        XCTAssertTrue(LogiDeviceSession.controlsLookLikeMouse(
            cids: [0x0050, 0x0051, 0x0052, 0x0053, 0x00C3]))
    }

    func testControlsLookLikeKeyboardWithoutLeftRight() {
        // 键盘: media/backlight 类 CID, 无标准 Left/Right
        XCTAssertFalse(LogiDeviceSession.controlsLookLikeMouse(
            cids: [0x00D1, 0x00D2, 0x00E2, 0x00E5, 0x0103]))
    }

    func testControlsLookLikeMouseNeedsBothButtons() {
        XCTAssertFalse(LogiDeviceSession.controlsLookLikeMouse(cids: [0x0050]))
        XCTAssertFalse(LogiDeviceSession.controlsLookLikeMouse(cids: [0x0051]))
        XCTAssertFalse(LogiDeviceSession.controlsLookLikeMouse(cids: []))
    }

    func testReportRouteDropsOutOfRangeSlot() {
        XCTAssertEqual(
            LogiDeviceSession.receiverReportRoute(incomingSlot: 0, currentSlot: 1, managedSlots: [1]),
            .drop
        )
        XCTAssertEqual(
            LogiDeviceSession.receiverReportRoute(incomingSlot: 7, currentSlot: 1, managedSlots: [1]),
            .drop
        )
    }

    // MARK: - Bounded probe-then-repair after idle activity

    private let wakeBindings: Set<UInt16> = [0x005B, 0x005D, 0x00D0]

    private func startedWakeProbe() -> LogiReceiverWakeRecovery {
        var recovery = LogiReceiverWakeRecovery()
        XCTAssertTrue(recovery.noteActivity(at: 100, expectedCIDs: wakeBindings).isEmpty)
        XCTAssertEqual(recovery.noteActivity(at: 160, expectedCIDs: wakeBindings), wakeBindings)
        return recovery
    }

    func testHealthyWakeDoesNotWriteAnyDivert() {
        var recovery = startedWakeProbe()
        for cid in wakeBindings {
            XCTAssertTrue(recovery.receive(cid: cid, flags: 0x01, softwareID: recovery.softwareID))
        }
        XCTAssertTrue(recovery.finish(currentExpectedCIDs: wakeBindings).isEmpty)
    }

    func testCapturedM720LostTiltStateRepairsOnlyThoseControlsOnce() {
        var recovery = startedWakeProbe()
        XCTAssertTrue(recovery.receive(cid: 0x005B, flags: 0x00, softwareID: recovery.softwareID))
        XCTAssertTrue(recovery.receive(cid: 0x005D, flags: 0x00, softwareID: recovery.softwareID))
        XCTAssertTrue(recovery.receive(cid: 0x00D0, flags: 0x01, softwareID: recovery.softwareID))
        XCTAssertEqual(recovery.finish(currentExpectedCIDs: wakeBindings), [0x005B, 0x005D])
        XCTAssertTrue(recovery.finish(currentExpectedCIDs: wakeBindings).isEmpty)
        XCTAssertFalse(recovery.receive(cid: 0x005B, flags: 0, softwareID: recovery.softwareID))
    }

    func testTimeoutDoesNotTreatUnansweredControlsAsLost() {
        var recovery = startedWakeProbe()
        XCTAssertTrue(recovery.receive(cid: 0x005B, flags: 0, softwareID: recovery.softwareID))
        XCTAssertEqual(recovery.finish(currentExpectedCIDs: wakeBindings), [0x005B])
        var noResponse = startedWakeProbe()
        XCTAssertTrue(noResponse.finish(currentExpectedCIDs: wakeBindings).isEmpty)
    }

    func testNormalUIQueryCannotAuthorizeWakeRepair() {
        var recovery = startedWakeProbe()
        XCTAssertFalse(recovery.receive(cid: 0x005B, flags: 0, softwareID: 1))
        XCTAssertFalse(recovery.receive(cid: 0x0053, flags: 0, softwareID: recovery.softwareID))
        XCTAssertTrue(recovery.finish(currentExpectedCIDs: wakeBindings).isEmpty)
    }

    func testDuplicateOrPriorWakeReplyCannotAuthorizeAnotherRepair() {
        var recovery = startedWakeProbe()
        let oldID = recovery.softwareID
        XCTAssertTrue(recovery.receive(cid: 0x005B, flags: 1, softwareID: oldID))
        XCTAssertFalse(recovery.receive(cid: 0x005B, flags: 0, softwareID: oldID))
        XCTAssertTrue(recovery.finish(currentExpectedCIDs: wakeBindings).isEmpty)
        XCTAssertEqual(recovery.noteActivity(at: 220, expectedCIDs: wakeBindings), wakeBindings)
        XCTAssertNotEqual(recovery.softwareID, oldID)
        XCTAssertFalse(recovery.receive(cid: 0x005B, flags: 0, softwareID: oldID))
        XCTAssertTrue(recovery.finish(currentExpectedCIDs: wakeBindings).isEmpty)
    }

    func testDisabledBindingOrContendedControlIsNotRepaired() {
        var recovery = startedWakeProbe()
        for cid in wakeBindings {
            XCTAssertTrue(recovery.receive(cid: cid, flags: 0, softwareID: recovery.softwareID))
        }
        XCTAssertEqual(recovery.finish(currentExpectedCIDs: [0x00D0]), [0x00D0])
    }

    func testDisconnectOrManualRediscoveryCancelsPendingRepair() {
        var recovery = startedWakeProbe()
        let token = recovery.softwareID
        XCTAssertTrue(recovery.receive(cid: 0x005B, flags: 0, softwareID: token))
        recovery.cancel()
        XCTAssertFalse(recovery.receive(cid: 0x005D, flags: 0, softwareID: token))
        XCTAssertTrue(recovery.finish(currentExpectedCIDs: wakeBindings).isEmpty)
    }

    func testWakeDoesNotContinuouslyProbeDuringNormalActivity() {
        var recovery = startedWakeProbe()
        XCTAssertTrue(recovery.noteActivity(at: 161, expectedCIDs: wakeBindings).isEmpty)
        _ = recovery.finish(currentExpectedCIDs: wakeBindings)
        XCTAssertTrue(recovery.noteActivity(at: 170, expectedCIDs: wakeBindings).isEmpty)
        XCTAssertTrue(recovery.noteActivity(at: 229, expectedCIDs: wakeBindings).isEmpty)
        XCTAssertEqual(recovery.noteActivity(at: 289, expectedCIDs: wakeBindings), wakeBindings)
    }

    func testSlotsKeepIndependentWakeReadbackState() {
        var first = startedWakeProbe()
        var second = startedWakeProbe()
        XCTAssertTrue(first.receive(cid: 0x005B, flags: 0, softwareID: first.softwareID))
        for cid in wakeBindings {
            XCTAssertTrue(second.receive(cid: cid, flags: 1, softwareID: second.softwareID))
        }
        XCTAssertTrue(second.finish(currentExpectedCIDs: wakeBindings).isEmpty)
        XCTAssertEqual(first.finish(currentExpectedCIDs: wakeBindings), [0x005B])
    }

    func testOfflineOrUnboundSlotOnlyRecordsActivityWithoutProbing() {
        var recovery = LogiReceiverWakeRecovery()
        XCTAssertTrue(recovery.noteActivity(at: 100, expectedCIDs: []).isEmpty)
        XCTAssertTrue(recovery.noteActivity(at: 160, expectedCIDs: []).isEmpty)
        XCTAssertTrue(recovery.noteActivity(at: 161, expectedCIDs: wakeBindings).isEmpty)
        XCTAssertEqual(recovery.noteActivity(at: 221, expectedCIDs: wakeBindings), wakeBindings)
    }

    func testWakeProbeTargetSupportsBLEDirectAndManagedReceiverSlots() {
        XCTAssertTrue(LogiDeviceSession.canUseWakeProbeTarget(
            connectionMode: .bleDirect,
            slot: 0xFF,
            managedSlots: [],
            receiverSweepActive: false,
            hasPendingBLEUndivertGuardQueries: false
        ))
        XCTAssertFalse(LogiDeviceSession.canUseWakeProbeTarget(
            connectionMode: .bleDirect,
            slot: 0xFF,
            managedSlots: [],
            receiverSweepActive: false,
            hasPendingBLEUndivertGuardQueries: true
        ))
        XCTAssertFalse(LogiDeviceSession.canUseWakeProbeTarget(
            connectionMode: .bleDirect,
            slot: 0x01,
            managedSlots: [],
            receiverSweepActive: false,
            hasPendingBLEUndivertGuardQueries: false
        ))
        XCTAssertTrue(LogiDeviceSession.canUseWakeProbeTarget(
            connectionMode: .receiver,
            slot: 0x01,
            managedSlots: [0x01],
            receiverSweepActive: false,
            hasPendingBLEUndivertGuardQueries: false
        ))
        XCTAssertFalse(LogiDeviceSession.canUseWakeProbeTarget(
            connectionMode: .receiver,
            slot: 0x01,
            managedSlots: [0x01],
            receiverSweepActive: true,
            hasPendingBLEUndivertGuardQueries: false
        ))
        XCTAssertFalse(LogiDeviceSession.canUseWakeProbeTarget(
            connectionMode: .unsupported,
            slot: 0xFF,
            managedSlots: [],
            receiverSweepActive: false,
            hasPendingBLEUndivertGuardQueries: false
        ))
    }

    // MARK: - receiverSlotConnectionAction (Phase 4 热插拔)

    func testSlotConnectionDisconnectedManagedReleases() {
        // 已接管的 slot 断开 -> 释放其接管状态
        XCTAssertEqual(
            LogiDeviceSession.receiverSlotConnectionAction(
                slot: 4, connected: false, isDivertCandidate: false, alreadyManaged: true),
            .release(4)
        )
    }

    func testSlotConnectionDisconnectedUnmanagedIgnored() {
        XCTAssertEqual(
            LogiDeviceSession.receiverSlotConnectionAction(
                slot: 4, connected: false, isDivertCandidate: false, alreadyManaged: false),
            .ignore
        )
    }

    func testSlotConnectionReconnectUnmanagedCandidateTakesOver() {
        // 关键: 鼠标关机/切 slot 再回来 -> 未接管 + 候选 -> 重新 discovery+divert
        XCTAssertEqual(
            LogiDeviceSession.receiverSlotConnectionAction(
                slot: 4, connected: true, isDivertCandidate: true, alreadyManaged: false),
            .takeover(4)
        )
    }

    func testSlotConnectionConnectedAlreadyManagedIgnored() {
        // 防振荡: 已接管且在线的 slot 再收到 connected 通知 -> 忽略, 不重复 discovery
        XCTAssertEqual(
            LogiDeviceSession.receiverSlotConnectionAction(
                slot: 4, connected: true, isDivertCandidate: true, alreadyManaged: true),
            .ignore
        )
    }

    func testSlotConnectionConnectedNonCandidateIgnored() {
        // 键盘等非候选设备连接 -> 不接管
        XCTAssertEqual(
            LogiDeviceSession.receiverSlotConnectionAction(
                slot: 1, connected: true, isDivertCandidate: false, alreadyManaged: false),
            .ignore
        )
    }

    func testSlotConnectionOutOfRangeIgnored() {
        XCTAssertEqual(
            LogiDeviceSession.receiverSlotConnectionAction(
                slot: 0, connected: true, isDivertCandidate: true, alreadyManaged: false),
            .ignore
        )
        XCTAssertEqual(
            LogiDeviceSession.receiverSlotConnectionAction(
                slot: 7, connected: false, isDivertCandidate: false, alreadyManaged: true),
            .ignore
        )
    }

    func testPeripheralActivityTakesOverPreviouslyOfflineSlotOnce() {
        XCTAssertEqual(
            LogiDeviceSession.receiverPeripheralActivityAction(
                slot: 1, wasConnected: false, isDivertCandidate: true, alreadyManaged: false),
            .takeover(1)
        )
        XCTAssertEqual(
            LogiDeviceSession.receiverPeripheralActivityAction(
                slot: 1, wasConnected: true, isDivertCandidate: true, alreadyManaged: false),
            .ignore
        )
    }

    // MARK: - BLE Long-Sleep & Screen-Lock Recovery (M720 0xB015)

    func testSeededWakeRecoveryProbesOnFirstWakeEventAfterIdle() {
        var recovery = LogiReceiverWakeRecovery()
        recovery.seedActivity(at: 100)
        // Re-seeding later must not overwrite an existing baseline timestamp.
        recovery.seedActivity(at: 140)
        XCTAssertEqual(recovery.noteActivity(at: 160, expectedCIDs: wakeBindings), wakeBindings)
    }

    func testContinuousNonHIDPPActivityPreventsFalseIdleProbeUntilQuietPeriod() {
        var recovery = LogiReceiverWakeRecovery()
        recovery.seedActivity(at: 100)
        recovery.touchActivity(at: 145)
        recovery.touchActivity(at: 190)
        // Pressing a HID++ button immediately after 90s of cursor movement must not probe.
        XCTAssertTrue(recovery.noteActivity(at: 190.5, expectedCIDs: wakeBindings).isEmpty)
        // After 60s of genuine idle, the very first report probes once.
        XCTAssertEqual(recovery.noteActivity(at: 250.5, expectedCIDs: wakeBindings), wakeBindings)
    }

    func testForcedUnlockProbeStartsReadbackImmediatelyWithoutWaitingIdleThreshold() {
        var recovery = LogiReceiverWakeRecovery()
        recovery.seedActivity(at: 100)
        XCTAssertEqual(recovery.beginForcedProbe(at: 110, expectedCIDs: wakeBindings), wakeBindings)
        // Duplicate forced probe while batch is pending must be ignored.
        XCTAssertTrue(recovery.beginForcedProbe(at: 111, expectedCIDs: wakeBindings).isEmpty)
        XCTAssertTrue(recovery.receive(cid: 0x005B, flags: 0x00, softwareID: recovery.softwareID))
        XCTAssertTrue(recovery.receive(cid: 0x005D, flags: 0x00, softwareID: recovery.softwareID))
        XCTAssertTrue(recovery.receive(cid: 0x00D0, flags: 0x01, softwareID: recovery.softwareID))
        XCTAssertEqual(recovery.finish(currentExpectedCIDs: wakeBindings), [0x005B, 0x005D])
    }

    func testPermissionDeniedIOReturnAndCompositeKeyboardClientDetection() {
        // 0xe00002e2 (kIOReturnNotPermitted) is emitted by XNU IOHIDLibUserClient::setReport
        // when M720 BLE (PrimaryUsage=1/6) connects while macOS Lock Screen is active.
        XCTAssertTrue(LogiDeviceSession.isPermissionDeniedIOReturn(kIOReturnNotPermitted))
        XCTAssertTrue(LogiDeviceSession.isPermissionDeniedIOReturn(kIOReturnNotPrivileged))
        XCTAssertFalse(LogiDeviceSession.isPermissionDeniedIOReturn(kIOReturnSuccess))
        XCTAssertFalse(LogiDeviceSession.isPermissionDeniedIOReturn(kIOReturnTimeout))

        XCTAssertTrue(LogiDeviceSession.requiresUnlockedKeyboardClient(usagePage: 0x0001, usage: 0x0006))
        XCTAssertFalse(LogiDeviceSession.requiresUnlockedKeyboardClient(usagePage: 0x0001, usage: 0x0002))
        XCTAssertFalse(LogiDeviceSession.requiresUnlockedKeyboardClient(usagePage: 0xFF00, usage: 0x0001))
    }

    func testUnlockRecoveryActionAndBoundedRetries() {
        XCTAssertEqual(
            LogiSessionManager.unlockRecoveryAction(
                isActive: false,
                hasCandidateSessions: true,
                anySessionNeedsReopen: true,
                anyCandidateIncomplete: false
            ),
            .none
        )
        XCTAssertEqual(
            LogiSessionManager.unlockRecoveryAction(
                isActive: true,
                hasCandidateSessions: false,
                anySessionNeedsReopen: false,
                anyCandidateIncomplete: false
            ),
            .none
        )
        XCTAssertEqual(
            LogiSessionManager.unlockRecoveryAction(
                isActive: true,
                hasCandidateSessions: true,
                anySessionNeedsReopen: true,
                anyCandidateIncomplete: false
            ),
            .restartManager
        )
        XCTAssertEqual(
            LogiSessionManager.unlockRecoveryAction(
                isActive: true,
                hasCandidateSessions: true,
                anySessionNeedsReopen: false,
                anyCandidateIncomplete: true
            ),
            .restartManager
        )
        XCTAssertEqual(
            LogiSessionManager.unlockRecoveryAction(
                isActive: true,
                hasCandidateSessions: true,
                anySessionNeedsReopen: false,
                anyCandidateIncomplete: false
            ),
            .probeActiveSessions
        )

        XCTAssertEqual(LogiSessionManager.nextPermissionRetryDelay(completedAttempts: 0), 0.5)
        XCTAssertEqual(LogiSessionManager.nextPermissionRetryDelay(completedAttempts: 1), 1.5)
        XCTAssertEqual(LogiSessionManager.nextPermissionRetryDelay(completedAttempts: 2), 3.0)
        XCTAssertNil(LogiSessionManager.nextPermissionRetryDelay(completedAttempts: 3))

        XCTAssertFalse(LogiSessionManager.canAttemptLazyActivityRecovery(
            isScreenLocked: true, completedAttempts: 0, now: 100, lastAttemptTime: 0
        ))
        XCTAssertTrue(LogiSessionManager.canAttemptLazyActivityRecovery(
            isScreenLocked: false, completedAttempts: 0, now: 100, lastAttemptTime: 0
        ))
        XCTAssertFalse(LogiSessionManager.canAttemptLazyActivityRecovery(
            isScreenLocked: false, completedAttempts: 1, now: 101.5, lastAttemptTime: 100
        ))
        XCTAssertTrue(LogiSessionManager.canAttemptLazyActivityRecovery(
            isScreenLocked: false, completedAttempts: 1, now: 103.5, lastAttemptTime: 100
        ))
        XCTAssertFalse(LogiSessionManager.canAttemptLazyActivityRecovery(
            isScreenLocked: false, completedAttempts: 2, now: 110, lastAttemptTime: 103.5
        ))
    }

    func testIncompleteCandidateSessionDistinguishesPacketTimeoutFromUnsupportedFeature() {
        XCTAssertTrue(LogiDeviceSession.shouldRecoverIncompleteCandidateSession(
            connectionMode: .bleDirect,
            handshakeComplete: false,
            reprogInitComplete: false,
            reprogFeatureUnsupported: false
        ))
        XCTAssertTrue(LogiDeviceSession.shouldRecoverIncompleteCandidateSession(
            connectionMode: .bleDirect,
            handshakeComplete: true,
            reprogInitComplete: false,
            reprogFeatureUnsupported: false
        ))
        XCTAssertFalse(LogiDeviceSession.shouldRecoverIncompleteCandidateSession(
            connectionMode: .bleDirect,
            handshakeComplete: true,
            reprogInitComplete: false,
            reprogFeatureUnsupported: true
        ))
        XCTAssertFalse(LogiDeviceSession.shouldRecoverIncompleteCandidateSession(
            connectionMode: .bleDirect,
            handshakeComplete: true,
            reprogInitComplete: true,
            reprogFeatureUnsupported: false
        ))
    }

    func testDeliveryModeStoreResetAllClearsContendedState() {
        let store = LogiButtonDeliveryModeStore(clearWindow: 30, clearThreshold: 2)
        let key = LogiOwnershipKey(
            vendorId: 0x046D,
            productId: 0xB015,
            name: "M720 Triathlon",
            transport: .bleDirect,
            cid: 0x005B
        )
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(store.recordExternalClear(for: key, at: t0), .hidpp)
        XCTAssertEqual(store.recordExternalClear(for: key, at: t0.addingTimeInterval(1)), .contended)
        store.resetAll()
        XCTAssertEqual(store.mode(for: key), .hidpp)
    }
}
