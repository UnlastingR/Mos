import XCTest
@testable import Mos_Debug

/// Spec §4.4 / Round 4 M2 — emit `.up` via bridge before clearing per-session
/// state on each of: teardown, setTargetSlot, rediscoverFeatures, LogiCenter.stop.
/// Cannot construct LogiDeviceSession easily in unit tests; this case is
/// covered by Tier 3a real-device test (LogiBridgeDeviceTests, Task 4.4).
final class LogiTeardownTests: XCTestCase {
    func test_pathsCovered_byTier3a() {
        // Smoke marker for the test plan; full coverage is in Tier 3a.
        XCTAssertTrue(true)
    }

    // MARK: - Keyboard interface skip (issue #948)

    /// A Logitech keyboard interface must NOT get a session attached. Attaching
    /// one registers an input-report callback that keeps the keyboard's HID
    /// endpoint active, so it never sleeps and its backlight stays on (#948).
    /// `shouldAttachSession` gates session creation in `deviceConnected`.
    func test_shouldAttachSession_skipsKeyboardInterface() {
        // Generic Desktop (0x0001) Keyboard (0x0006) — e.g. MX Mechanical.
        XCTAssertFalse(
            LogiSessionManager.shouldAttachSession(usagePage: 0x0001, usage: 0x0006),
            "Keyboard interfaces must be skipped so the device can sleep / dim its backlight"
        )
    }

    func test_shouldAttachSession_attachesMouseAndHIDPPInterfaces() {
        // Generic Desktop Mouse (0x0002) — BLE HID++ candidate.
        XCTAssertTrue(LogiSessionManager.shouldAttachSession(usagePage: 0x0001, usage: 0x0002))
        // Vendor-specific HID++ interfaces (USB receiver / Bolt / Unifying).
        XCTAssertTrue(LogiSessionManager.shouldAttachSession(usagePage: 0xFF00, usage: 0x0000))
        XCTAssertTrue(LogiSessionManager.shouldAttachSession(usagePage: 0xFF43, usage: 0x0000))
        XCTAssertTrue(LogiSessionManager.shouldAttachSession(usagePage: 0xFFC0, usage: 0x0000))
        // Consumer Control interface some Logi devices also expose.
        XCTAssertTrue(LogiSessionManager.shouldAttachSession(usagePage: 0x000C, usage: 0x0001))
    }

    /// Regression guard: the skip must be keyboard-specific, not a blanket drop
    /// of the whole Generic Desktop usage page (which would also drop BLE mice).
    func test_shouldAttachSession_doesNotBlanketDropGenericDesktop() {
        // Generic Desktop Pointer (0x0001) must still attach.
        XCTAssertTrue(LogiSessionManager.shouldAttachSession(usagePage: 0x0001, usage: 0x0001),
                      "Pointer (Generic Desktop) must still attach")
    }

    // MARK: - Composite BLE mouse vs BLE keyboard (M720 0xB015 vs #948)

    func test_logiHIDUsagePair_parsesIOHIDDeviceUsagePairsProperty() {
        let rawProperty: [[String: Any]] = [
            ["DeviceUsagePage": 1, "DeviceUsage": 6],
            ["DeviceUsagePage": NSNumber(value: 1), "DeviceUsage": NSNumber(value: 2)],
            ["DeviceUsagePage": 1, "DeviceUsage": 1],
            ["DeviceUsagePage": 65347, "DeviceUsage": 514],
            ["DeviceUsagePage": 11] // Incomplete entry should be ignored
        ]
        XCTAssertEqual(LogiHIDUsagePair.fromIOHIDProperty(rawProperty), [
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0006),
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0002),
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0001),
            LogiHIDUsagePair(usagePage: 0xFF43, usage: 0x0202)
        ])
        XCTAssertTrue(LogiHIDUsagePair.fromIOHIDProperty(nil).isEmpty)
        XCTAssertTrue(LogiHIDUsagePair.fromIOHIDProperty("invalid").isEmpty)
    }

    func test_shouldAttachSession_attachesCompositeBLEMouseWithPrimaryKeyboardUsage() {
        // Exact IORegistry descriptor captured from Logitech M720 Triathlon over BLE (0x046D:0xB015):
        // PrimaryUsage = Keyboard (1/6), with Mouse (1/2), Pointer (1/1), and BLE HID++ (0xFF43/0x0202).
        let m720Pairs: [LogiHIDUsagePair] = [
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0006),
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0002),
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0001),
            LogiHIDUsagePair(usagePage: 0xFF43, usage: 0x0202)
        ]
        XCTAssertTrue(
            LogiSessionManager.shouldAttachSession(
                usagePage: 0x0001,
                usage: 0x0006,
                isBLE: true,
                productId: 0xB015,
                deviceUsagePairs: m720Pairs
            ),
            "Composite BLE mouse (M720 0xB015) must attach despite PrimaryUsage=Keyboard"
        )
    }

    func test_shouldAttachSession_skipsBLEAndUSBKeyboardsEvenWithCompositePairs() {
        let keyboardOnlyPairs: [LogiHIDUsagePair] = [
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0006),
            LogiHIDUsagePair(usagePage: 0x000C, usage: 0x0001),
            LogiHIDUsagePair(usagePage: 0xFF43, usage: 0x0202)
        ]
        XCTAssertFalse(
            LogiSessionManager.shouldAttachSession(
                usagePage: 0x0001,
                usage: 0x0006,
                isBLE: true,
                productId: 0xB366, // MX Mechanical (#948)
                deviceUsagePairs: keyboardOnlyPairs
            )
        )

        let compositeKeyboardPairs: [LogiHIDUsagePair] = [
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0006),
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0002),
            LogiHIDUsagePair(usagePage: 0xFF43, usage: 0x0202)
        ]
        XCTAssertFalse(
            LogiSessionManager.shouldAttachSession(
                usagePage: 0x0001,
                usage: 0x0006,
                isBLE: true,
                productId: 0xB366, // Logitech BLE keyboard PID range 0xB300...0xB3FF
                deviceUsagePairs: compositeKeyboardPairs
            ),
            "Logitech BLE keyboards (0xB3xx) must still be skipped even if they expose a mouse-keys collection"
        )
        XCTAssertFalse(
            LogiSessionManager.shouldAttachSession(
                usagePage: 0x0001,
                usage: 0x0006,
                isBLE: false,
                productId: 0xC336,
                deviceUsagePairs: compositeKeyboardPairs
            ),
            "Non-BLE keyboard interfaces must still be skipped"
        )
    }

    func test_isHIDPPCandidate_handlesStandardAndCompositeBLEMice() {
        let m720Pairs: [LogiHIDUsagePair] = [
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0006),
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0002),
            LogiHIDUsagePair(usagePage: 0x0001, usage: 0x0001),
            LogiHIDUsagePair(usagePage: 0xFF43, usage: 0x0202)
        ]
        // Standard BLE mouse (e.g. M750 0xB02C)
        XCTAssertTrue(LogiDeviceSession.isHIDPPCandidate(
            isBLE: true, usagePage: 0x0001, usage: 0x0002, productId: 0xB02C
        ))
        // Composite BLE mouse with PrimaryUsage=Keyboard (M720 0xB015)
        XCTAssertTrue(LogiDeviceSession.isHIDPPCandidate(
            isBLE: true, usagePage: 0x0001, usage: 0x0006, productId: 0xB015, deviceUsagePairs: m720Pairs
        ))
        // BLE keyboard (MX Mechanical 0xB366) must never become HID++ candidate
        XCTAssertFalse(LogiDeviceSession.isHIDPPCandidate(
            isBLE: true, usagePage: 0x0001, usage: 0x0006, productId: 0xB366, deviceUsagePairs: m720Pairs
        ))
        // USB/Receiver vendor HID++ interfaces vs USB standard mouse interface
        XCTAssertTrue(LogiDeviceSession.isHIDPPCandidate(isBLE: false, usagePage: 0xFF00, usage: 0x0001))
        XCTAssertTrue(LogiDeviceSession.isHIDPPCandidate(isBLE: false, usagePage: 0xFF43, usage: 0x0202))
        XCTAssertFalse(LogiDeviceSession.isHIDPPCandidate(isBLE: false, usagePage: 0x0001, usage: 0x0002))
    }
}
