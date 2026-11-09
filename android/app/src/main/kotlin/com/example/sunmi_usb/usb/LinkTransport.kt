package com.example.sunmi_usb.usb

import android.content.Intent
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build

/**
 * Identity strings the cashier (USB host) sends during the AOA handshake.
 * The terminal (USB accessory) only accepts accessories whose manufacturer and model match,
 * and res/xml/accessory_filter.xml must use the same values.
 */
object Aoa {
    const val MANUFACTURER = "SunmiUsb"
    const val MODEL = "PosLink"
    const val DESCRIPTION = "Sunmi POS payment link"
    const val VERSION = "1.0"

    /** Shown by Android on the terminal when no installed app handles this accessory. Replace with your own page. */
    const val URI = "https://example.com/poslink"
    const val SERIAL = "0001"

    const val GOOGLE_VID = 0x18D1
    /** 0x2D00 accessory, 0x2D01 accessory+adb, 0x2D02..0x2D05 audio/hid variants. */
    val ACCESSORY_PIDS = setOf(0x2D00, 0x2D01, 0x2D02, 0x2D03, 0x2D04, 0x2D05)

    const val REQ_GET_PROTOCOL = 51
    const val REQ_SEND_STRING = 52
    const val REQ_START = 53

    /** Largest single USB bulk transfer we issue; also the accessory read buffer size. */
    const val BUFFER_SIZE = 16384

    fun isAccessoryMode(device: UsbDevice): Boolean =
        device.vendorId == GOOGLE_VID && device.productId in ACCESSORY_PIDS

    fun matches(accessory: UsbAccessory): Boolean =
        accessory.manufacturer == MANUFACTURER && accessory.model == MODEL
}

/** Callbacks from a transport. May be invoked from any thread. */
interface LinkListener {
    /** state: stopped | waiting | permission | connecting | connected | error */
    fun onState(state: String, detail: String?)
    fun onData(data: ByteArray)
    fun onLog(message: String)
}

/** A raw byte pipe to the other device. Framing and reliability live in Dart. */
interface LinkTransport {
    fun start()
    fun stop()
    /** Blocking write; call off the main thread. Returns false if the bytes could not be sent. */
    fun write(data: ByteArray): Boolean
    /** Drop the current connection and try to establish it again. */
    fun reset()
    fun handleIntent(intent: Intent) {}
}

internal const val ACTION_USB_PERMISSION = "com.example.sunmi_usb.USB_PERMISSION"

@Suppress("DEPRECATION")
internal fun Intent.usbDevice(): UsbDevice? =
    if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
    else getParcelableExtra(UsbManager.EXTRA_DEVICE)

@Suppress("DEPRECATION")
internal fun Intent.usbAccessory(): UsbAccessory? =
    if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
    else getParcelableExtra(UsbManager.EXTRA_ACCESSORY)

internal fun hex4(v: Int) = String.format("%04X", v)
