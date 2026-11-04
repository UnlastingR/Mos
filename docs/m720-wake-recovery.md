# Personal M720 BLE & wake recovery

This fork includes two targeted M720 Triathlon (`0x046D:0xB015`) fixes:

1. **Composite BLE mouse attachment & HID++ candidate detection**: M720 over Bluetooth Low Energy places its onboard-shortcut Keyboard collection first in the HID report descriptor (`PrimaryUsagePage = 0x0001, PrimaryUsage = 0x0006`) while exposing Mouse (`0x0001/0x0002`) and BLE HID++ (`0xFF43/0x0202`) on the same composite interface. Mos now inspects `DeviceUsagePairs` (while continuing to exclude Logitech BLE keyboards `0xB300...0xB3FF` and pure keyboard interfaces so #948 sleep behavior remains intact).
2. **Bounded idle/wake divert probe-then-repair (Receiver & BLE Direct)**: replaces the unconditional two-pass restoration in LJAYi's PR #1012 with a bounded probe-then-repair path and retains the offline-slot activity inference from #1013.

A reproduced failure on the stock 4.3.0 beta (20260820.1) showed both tilt controls returning GetControlReporting flags 0x00 while Mos still displayed local ownership. A manual Re-Divert changed the left tilt readback to 0x01 and restored both desktop-switch bindings. This confirms lost temporary diversion; the exact reason the device cleared it remains unknown.

## Behavior

- Track unsolicited HID++ activity separately for each receiver slot, using monotonic time. Host query replies cannot trigger recovery.
- After at least 60 seconds without such activity, query the expected bound controls once. Skip during discovery, ordinary reporting queries, and recording.
- Use separate software IDs so late probe replies cannot advance normal UI/discovery queries.
- Repair only CIDs whose replies explicitly show tmpDivert missing and which are still expected. Healthy or unanswered controls receive no writes.
- Finish within two seconds, with no retries or repeating timers. Preserve the existing contention breaker. Cancel pending recovery on disconnect, rediscovery, manual diversion changes, binding changes, or recording.

## Validation

The regression cases in `MosTests/LogiReceiverConnectionStateTests.swift` cover healthy state, captured missing tilt flags, timeouts, unrelated/duplicate/stale replies, removed bindings, cancellation, repeated activity, and independent slots. The personal Actions workflow runs the full Debug test plan and builds a universal app.

This is a personal test build. Real M720 idle/resume validation is still required after installing the artifact; a successful build does not prove the hardware failure is permanently resolved.
