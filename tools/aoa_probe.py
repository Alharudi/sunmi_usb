#!/usr/bin/env python3
"""
Phase 0 check: can a Sunmi terminal (e.g. a production P3) be switched into
Android Open Accessory (AOA) mode, the USB mode POS Link uses?

The PC (Mac/Linux) plays the cashier's role as USB host, exactly like the Flex 3 does.
Nothing has to be installed on the terminal, and it needs no debug mode, developer
options or USB debugging: the switch is handled by Android itself.

Setup (macOS, once):
    brew install libusb
    python3 -m venv tools/.venv && tools/.venv/bin/pip install pyusb
    Quit Android File Transfer / OpenMTP if they are running (they grab Android devices).

Usage (PY = tools/.venv/bin/python):
    $PY tools/aoa_probe.py --list
        List USB devices. Plug the P3 in and note its VID:PID.

    $PY tools/aoa_probe.py --vid 0x1234 --pid 0x5678
        Ask that device to switch to accessory mode and report PASS / FAIL.

    $PY tools/aoa_probe.py --vid 0x1234 --pid 0x5678 --sale 12500
        Same, then act as the cashier: handshake with POS Link (terminal role) on the
        device and send a 12.500 LYD sale, printing every message. Needs the app installed.

PASS means the device came back as Google accessory 18D1:2D00 or 2D01. Without POS Link
installed, Android on the terminal also shows a "no app works with this accessory" popup.
"""

import argparse
import json
import struct
import sys
import time
import uuid

try:
    import usb.backend.libusb1
    import usb.core
    import usb.util
except ImportError:
    sys.exit("pyusb is missing. Run: python3 -m venv tools/.venv && tools/.venv/bin/pip install pyusb\n"
             "then use tools/.venv/bin/python tools/aoa_probe.py ...   (macOS also needs: brew install libusb)")

# Must match android/app/src/main/kotlin/.../usb/LinkTransport.kt (object Aoa) and accessory_filter.xml.
MANUFACTURER = "SunmiUsb"
MODEL = "PosLink"
DESCRIPTION = "Sunmi POS payment link (aoa_probe)"
VERSION = "1.0"
URI = "https://example.com/poslink"
SERIAL = "0001"

GOOGLE_VID = 0x18D1
ACCESSORY_PIDS = {0x2D00, 0x2D01, 0x2D02, 0x2D03, 0x2D04, 0x2D05}

MSG_NAMES = {
    0x01: "HELLO", 0x03: "PING", 0x04: "PONG", 0x05: "ACK", 0x06: "NAK",
    0x10: "STATUS", 0x20: "SALE_REQUEST", 0x21: "READY_TO_PAY", 0x22: "PROGRESS",
    0x23: "SALE_RESULT", 0x24: "CANCEL", 0x25: "TXN_STATUS_QUERY", 0x26: "TXN_STATUS", 0x7F: "ERROR",
}
LINK_LEVEL = {0x01, 0x03, 0x04, 0x05, 0x06}


def backend():
    b = usb.backend.libusb1.get_backend()
    if b is None:
        for path in ("/opt/homebrew/lib/libusb-1.0.dylib", "/usr/local/lib/libusb-1.0.dylib"):
            b = usb.backend.libusb1.get_backend(find_library=lambda _name, p=path: p)
            if b is not None:
                break
    if b is None:
        sys.exit("libusb not found. On macOS run: brew install libusb")
    return b


BACKEND = backend()


def describe(dev):
    def s(index):
        if not index:
            return ""
        try:
            return usb.util.get_string(dev, index) or ""
        except Exception:
            return "?"
    return f"{s(dev.iManufacturer)} {s(dev.iProduct)}".strip()


def is_accessory(dev):
    return dev.idVendor == GOOGLE_VID and dev.idProduct in ACCESSORY_PIDS


def list_devices():
    devices = list(usb.core.find(find_all=True, backend=BACKEND))
    if not devices:
        print("No USB devices found.")
    for d in devices:
        tag = "   <-- already in ACCESSORY mode" if is_accessory(d) else ""
        print(f"{d.idVendor:04X}:{d.idProduct:04X}  bus {d.bus} addr {d.address}  {describe(d)}{tag}")


def find_accessory():
    return usb.core.find(backend=BACKEND, custom_match=is_accessory)


def switch_to_accessory(vid, pid):
    already = find_accessory()
    if already is not None:
        print("A device is already in accessory mode; using it.")
        return already

    dev = usb.core.find(idVendor=vid, idProduct=pid, backend=BACKEND)
    if dev is None:
        sys.exit(f"Device {vid:04X}:{pid:04X} not found. Run with --list.")
    print(f"Found {vid:04X}:{pid:04X} {describe(dev)}")

    try:
        data = dev.ctrl_transfer(0xC0, 51, 0, 0, 2, timeout=1000)
    except usb.core.USBError as e:
        print(f"FAIL: the device rejected AOA GET_PROTOCOL ({e}).")
        print("      Its firmware does not offer accessory mode on this port.")
        sys.exit(1)
    version = data[0] | (data[1] << 8)
    print(f"AOA protocol version reported: {version}")
    if version < 1:
        print("FAIL: device answered but does not support accessory mode.")
        sys.exit(1)

    for index, value in enumerate([MANUFACTURER, MODEL, DESCRIPTION, VERSION, URI, SERIAL]):
        dev.ctrl_transfer(0x40, 52, 0, index, value.encode() + b"\0", timeout=1000)
    dev.ctrl_transfer(0x40, 53, 0, 0, None, timeout=1000)
    usb.util.dispose_resources(dev)
    print("Accessory START sent, waiting for the device to come back…")

    print("(On an Apple-silicon MacBook, click Allow if macOS asks 'Allow accessory to connect?'.)")

    deadline = time.time() + 30
    left = False
    while time.time() < deadline:
        time.sleep(0.5)
        acc = find_accessory()
        if acc is not None:
            print(f"PASS: device re-enumerated as {acc.idVendor:04X}:{acc.idProduct:04X} (accessory mode).")
            print("      Accessory mode works on this device without debug mode.")
            return acc
        if usb.core.find(idVendor=vid, idProduct=pid, backend=BACKEND) is None:
            left = True

    if left:
        print("NOT SURE: the device disconnected to switch modes, but the Mac never saw it come back as")
        print("          an accessory within 30 s. If macOS showed 'Allow accessory to connect?', click")
        print("          Allow and run the same command again (it picks up a device already in accessory")
        print("          mode). Otherwise unplug, replug and retry once. Two misses in a row = FAIL.")
    else:
        print("FAIL: the device took the accessory strings but never switched modes (no disconnect).")
        print("      Its firmware blocks accessory mode.")
    sys.exit(1)


# ---- minimal POS Link protocol (see docs/PROTOCOL.md) ----

def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def encode(msg_type, seq, payload=None):
    body = json.dumps(payload, separators=(",", ":")).encode() if payload else b""
    head = bytes([1, msg_type]) + struct.pack(">HH", seq, len(body)) + body
    frame = b"\x02" + head + struct.pack(">H", crc16(head))
    if len(frame) % 64 == 0:
        frame += b"\x00"
    return frame


def decode(buffer):
    frames = []
    while True:
        start = buffer.find(b"\x02")
        if start < 0:
            buffer.clear()
            break
        del buffer[:start]
        if len(buffer) < 7:
            break
        length = struct.unpack(">H", buffer[5:7])[0]
        total = 7 + length + 2
        if length > 8192:
            del buffer[:1]
            continue
        if len(buffer) < total:
            break
        if crc16(buffer[1:7 + length]) != struct.unpack(">H", buffer[7 + length:total])[0]:
            del buffer[:1]
            continue
        _, msg_type, seq = buffer[1], buffer[2], struct.unpack(">H", buffer[3:5])[0]
        body = bytes(buffer[7:7 + length])
        frames.append((msg_type, seq, json.loads(body) if body else {}))
        del buffer[:total]
    return frames


def talk(acc, amount):
    try:
        acc.set_configuration()
    except usb.core.USBError:
        pass
    intf = acc.get_active_configuration()[(0, 0)]
    usb.util.claim_interface(acc, intf)
    ep_out = usb.util.find_descriptor(intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
    ep_in = usb.util.find_descriptor(intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)

    session = str(uuid.uuid4())
    hello = {"role": "cashier", "manufacturer": "PC", "model": "aoa_probe", "appVersion": "probe",
             "protocol": 1, "sessionId": session, "needReply": True}
    seq = 0
    online = False
    sale_sent = False
    txn_id = str(uuid.uuid4())
    buffer = bytearray()
    last_hello = 0.0
    prev_hello = None
    hello_repeats = 0
    deadline = time.time() + 120
    finished = False
    print("Talking to POS Link on the terminal (Ctrl+C to stop)…")

    while time.time() < deadline:
        if not online and time.time() - last_hello > 2:
            ep_out.write(encode(0x01, 0, hello))
            last_hello = time.time()
        if online and not sale_sent:
            seq += 1
            sale = {"txnId": txn_id, "amount": amount, "currency": "LYD",
                    "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
            print(f"→ SALE_REQUEST #{seq} {sale}")
            ep_out.write(encode(0x20, seq, sale))
            sale_sent = True
        try:
            buffer.extend(bytes(ep_in.read(16384, timeout=300)))
        except usb.core.USBError as e:
            timeout_type = getattr(usb.core, "USBTimeoutError", ())
            if isinstance(e, timeout_type) or e.errno in (60, 110) or "timed out" in str(e).lower():
                continue
            print(f"USB error: {e}")
            break
        for msg_type, frame_seq, payload in decode(buffer):
            name = MSG_NAMES.get(msg_type, hex(msg_type))
            if msg_type == 0x03:
                ep_out.write(encode(0x04, frame_seq))
                continue
            if msg_type in (0x04, 0x05):
                continue
            if msg_type == 0x01 and payload == prev_hello:
                hello_repeats += 1  # e.g. HELLOs the terminal queued while nobody was reading
            else:
                if hello_repeats:
                    print(f"  (+{hello_repeats} identical HELLO)")
                    hello_repeats = 0
                print(f"← {name} #{frame_seq} {payload}")
                if msg_type == 0x01:
                    prev_hello = payload
            if msg_type == 0x01:
                if payload.get("needReply"):
                    ep_out.write(encode(0x01, 0, {**hello, "needReply": False}))
                online = True
            elif msg_type not in LINK_LEVEL:
                ep_out.write(encode(0x05, frame_seq))
                if msg_type == 0x23 and payload.get("txnId") == txn_id and not finished:
                    print(f"Sale finished: {payload.get('outcome')}")
                    finished = True
                    # Stay 2 s to ACK what the terminal sends next (STATUS idle), so it doesn't retry.
                    deadline = min(deadline, time.time() + 2)
    if hello_repeats:
        print(f"  (+{hello_repeats} identical HELLO)")
    if not finished:
        print("Stopped.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true", help="list USB devices")
    parser.add_argument("--vid", type=lambda v: int(v, 0), help="terminal vendor id, e.g. 0x1234")
    parser.add_argument("--pid", type=lambda v: int(v, 0), help="terminal product id, e.g. 0x5678")
    parser.add_argument("--sale", type=int, metavar="MINOR_UNITS",
                        help="after switching, send a sale of this amount (12500 = 12.500 LYD) to POS Link")
    args = parser.parse_args()

    if args.list or args.vid is None or args.pid is None:
        list_devices()
        if not args.list:
            print("\nPass --vid and --pid of the terminal to run the accessory-mode test.")
        return

    acc = switch_to_accessory(args.vid, args.pid)
    print(f"\nTip: add the terminal's normal id to android/app/src/main/res/xml/device_filter.xml as "
          f'<usb-device vendor-id="{args.vid}" product-id="{args.pid}" /> so the Flex grants USB permission once.')
    if args.sale:
        talk(acc, args.sale)


if __name__ == "__main__":
    main()
