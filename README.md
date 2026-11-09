# POS Link (sunmi_usb)

Links a Sunmi **cashier** device (e.g. Flex 3) to a Sunmi **payment terminal** (e.g. P3) with a
USB cable. The cashier sends the amount; the terminal shows "ready to pay", takes the card and
sends the result back. One APK; you pick the role on first launch.

```
 Flex 3 — Cashier (USB host)                  P3 — Terminal (USB accessory)
 Flutter UI: amount, progress, result         Flutter UI: ready to pay, progress, result
 Cashier controller ─┐                    ┌── Terminal controller ── Payment adapter
 LinkSession (frames, ACK, retry, heartbeat)  LinkSession                 (simulator now)
 Kotlin AoaHostTransport ◄── USB cable ──► Kotlin AoaAccessoryTransport
```

USB uses **Android Open Accessory (AOA)**, a standard Android feature. It needs no developer
options and no USB debugging on either device. A Wi-Fi/LAN (TCP) link with the same protocol is
built in as a fallback and for testing on ordinary phones.

## Status

| Area | State |
|---|---|
| USB link: AOA host (cashier) and accessory (terminal) in Kotlin | done; **not yet tried on real Sunmi hardware** |
| Wi-Fi/LAN fallback link | done |
| Protocol: framing, CRC, ACK/retry, duplicate filter, heartbeat, handshake | done, unit-tested |
| Sale, cancel, busy, status query, result re-delivery after a cable pull | done, unit-tested |
| Transaction journal on both devices (duplicate-charge protection, recovery) | done |
| Cashier and terminal screens, history, settings, link log | done |
| Real card payment on the P3 | **not done**: `MockPaymentAdapter` simulates it (screen says so) |
| Pairing / message signing (HMAC), foreground service, refund/void/print | not done (see Next steps) |

## Run it

```bash
flutter test                 # protocol + full sale flow over an in-memory link
flutter build apk --debug    # build/app/outputs/flutter-apk/app-debug.apk
```

1. Install the APK on both devices and open it. Pick **Cashier** on the Flex and **Payment
   terminal** on the P3.
2. Connect a **data** cable: the Flex's USB-A (or USB-C OTG) port to the P3's USB-C port.
3. On the P3, accept "Open POS Link when this accessory is connected" (tick *always*).
4. First time only, on the Flex: **Settings › USB devices › Use as terminal** on the P3's entry,
   then allow USB access. The Flex remembers it. To skip this step, put the P3's normal VID:PID
   in `android/app/src/main/res/xml/device_filter.xml`.
5. Enter an amount on the Flex and tap **Charge**. On the P3, use the *Simulate card* buttons.

**Without USB:** Settings › Connection › Wi-Fi / LAN on both devices. Enter the terminal's IP
(shown on the terminal's Settings screen) on the cashier. Default port is 8765.

## Phase 0: check a production P3 first

Payment-series Sunmi devices (P2, P3…) are locked down, and Sunmi doesn't document whether AOA is
allowed on them. Check before relying on it. **Nothing is installed on the P3 and it stays in
production mode.** The Mac plays the Flex's role:

```bash
# one-time setup (Homebrew Python blocks a global pip install, so use a venv)
brew install libusb
python3 -m venv tools/.venv && tools/.venv/bin/pip install pyusb

tools/.venv/bin/python tools/aoa_probe.py --list                     # plug in the P3, note its VID:PID
tools/.venv/bin/python tools/aoa_probe.py --vid 0x.... --pid 0x....  # PASS / FAIL
```

Use a USB-C **data** cable straight into the Mac, not through a hub. On an Apple-silicon MacBook,
click **Allow** if macOS asks "Allow accessory to connect?". The P3 shows up as a new accessory
after it switches modes.

- **PASS:** the P3 comes back as `18D1:2D00`/`2D01`, and the P3 shows an accessory popup. USB will work.
- **FAIL:** the P3 firmware blocks accessory mode. Use the Wi-Fi/LAN link, or ask Sunmi for their
  supported ECR connection.

**Result on 2026-11-05: PASS.** The P3 (SUNMI OS 3.0.39, Android 11, user build) is `0E8D:201C`
and reports AOA protocol 2. It switched to accessory mode with developer options and USB debugging
both off, after a restart. That firmware keeps ADB on the USB port even with debugging off, so it
comes back as `2D01` (accessory + ADB), not `2D00`.

On a P3 that has the app installed, `--sale 12500` also makes the Mac act as the cashier and
send a 12.500 LYD sale. That lets you test the terminal without a Flex.

## Sunmi production notes

- A production P-series device only installs apps from the **SUNMI App Store** / partner
  channel. Debug mode needs an auth code from Sunmi and **cannot be undone**, so only use it on one
  development unit.
- Change `applicationId` / `namespace` from `com.example.sunmi_usb` to your own before publishing.
- If a bank or acquirer owns the terminals, they decide what may be installed.

## Code map

| Path | What |
|---|---|
| `android/app/src/main/kotlin/.../usb/AoaHostTransport.kt` | Cashier: AOA handshake, bulk I/O, permissions, reconnect |
| `android/app/src/main/kotlin/.../usb/AoaAccessoryTransport.kt` | Terminal: open accessory, stream I/O |
| `android/app/src/main/kotlin/.../usb/UsbLinkPlugin.kt` | Method/Event channels to Flutter |
| `lib/core/protocol/` | Frame codec, message types, payloads |
| `lib/core/link/` | `Transport` (USB, TCP, in-memory) and `LinkSession` (reliability) |
| `lib/features/cashier/`, `lib/features/terminal/` | State machines and screens |
| `lib/payment/` | `PaymentAdapter` interface + simulator |
| `lib/data/` | Settings, transaction journal |
| `docs/PROTOCOL.md` | Wire protocol spec |
| `tools/aoa_probe.py` | Phase 0 hardware check / PC cashier |

## Next steps

1. Run Phase 0 on a production P3, then the app on a Flex 3 + P3 pair.
2. Connect a real `PaymentAdapter` on the P3: the bank/acquirer payment app (Intent/AIDL) or
   Sunmi PayLib.
3. Pairing + HMAC-SHA256 on every frame, so a rogue USB device can't inject a fake "approved".
4. Foreground service so the link survives the app going to the background.
5. Refund / void / receipt printing (P3 built-in printer).
