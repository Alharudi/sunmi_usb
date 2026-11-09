package com.example.sunmi_usb.usb

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * Terminal side (e.g. P3). Acts as the USB accessory: the cashier is the USB host and has already
 * switched this device into accessory mode. We open the accessory with the public UsbManager API,
 * which needs no developer options or USB debugging.
 */
class AoaAccessoryTransport(
    private val context: Context,
    private val listener: LinkListener,
) : LinkTransport {

    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val handler = Handler(Looper.getMainLooper())
    private val writeLock = Any()

    @Volatile private var running = false
    @Volatile private var pfd: ParcelFileDescriptor? = null

    // Channels, not plain streams: closing a channel wakes a thread blocked in read/write on it.
    @Volatile private var output: FileChannel? = null
    @Volatile private var input: FileChannel? = null
    private var openFailures = 0
    private var permissionRequested = false
    private var receiverRegistered = false
    private var lastState: String? = null
    private var lastDetail: String? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                    permissionRequested = false
                    close("Cable disconnected")
                }
                ACTION_USB_PERMISSION -> {
                    permissionRequested = false
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    log("USB accessory permission ${if (granted) "granted" else "denied"}")
                    if (granted) scan() else state("error", "USB permission denied. Unplug and replug the cable to ask again.")
                }
            }
        }
    }

    private val poll = object : Runnable {
        override fun run() {
            if (!running) return
            if (pfd == null) scan()
            handler.postDelayed(this, 1000)
        }
    }

    override fun start() {
        if (running) return
        running = true
        registerReceiver()
        state("waiting", "Connect the USB cable to the cashier")
        handler.post(poll)
    }

    override fun stop() {
        running = false
        handler.removeCallbacksAndMessages(null)
        close(null)
        if (receiverRegistered) {
            runCatching { context.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        state("stopped", null)
    }

    /**
     * Re-opening an accessory without a replug is unreliable on many Android builds, and the host
     * re-opens its side on its own, so a reset on this side only logs.
     */
    override fun reset() {
        log("Reset requested; waiting for the cashier to reconnect")
    }

    override fun handleIntent(intent: Intent) {
        if (intent.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) handler.postDelayed({ scan() }, 100)
    }

    /**
     * Blocks while the cashier isn't reading, once the driver's few packet buffers are full.
     * [close] never takes [writeLock]: it closes the channel instead, which ends a blocked write.
     */
    override fun write(data: ByteArray): Boolean {
        val out = output ?: return false
        return try {
            synchronized(writeLock) {
                val buf = ByteBuffer.wrap(data)
                while (buf.hasRemaining()) out.write(buf)
            }
            true
        } catch (e: IOException) {
            if (output === out) {
                log("USB write failed: ${e.message}")
                handler.post { if (output === out) close("Connection lost") }
            }
            false
        }
    }

    private fun scan() {
        if (!running || pfd != null) return
        val accessories = usbManager.accessoryList ?: emptyArray()
        if (accessories.isEmpty()) {
            state("waiting", "Connect the USB cable to the cashier")
            return
        }
        val acc = accessories.firstOrNull { Aoa.matches(it) }
        if (acc == null) {
            val other = accessories.first()
            state("error", "Unknown USB accessory: ${other.manufacturer} ${other.model}")
            return
        }
        if (!usbManager.hasPermission(acc)) {
            requestPermission(acc)
            return
        }
        open(acc)
    }

    private fun open(acc: UsbAccessory) {
        state("connecting", "Opening USB link…")
        val fd = try {
            usbManager.openAccessory(acc)
        } catch (e: Exception) {
            log("openAccessory failed: ${e.message}")
            null
        }
        if (fd == null) {
            // The driver allows one open at a time; right after a close the old one can take a
            // moment to be released, so only report after a few tries (the poll retries each second).
            if (++openFailures >= 3) state("error", "Cannot open the USB link. Replug the cable.")
            return
        }
        openFailures = 0
        val inChannel = FileInputStream(fd.fileDescriptor).channel
        output = FileOutputStream(fd.fileDescriptor).channel
        input = inChannel
        pfd = fd
        state("connected", "Connected to cashier (${acc.manufacturer} ${acc.model} ${acc.version})")
        startReader(fd, inChannel)
    }

    private fun startReader(fd: ParcelFileDescriptor, inChannel: FileChannel) {
        Thread({
            // Accessory reads must use a buffer of at least 16 KB or packets can be lost.
            val buf = ByteBuffer.allocate(Aoa.BUFFER_SIZE)
            try {
                while (running && pfd === fd) {
                    buf.clear()
                    val n = inChannel.read(buf)
                    if (n < 0) break
                    if (n > 0) listener.onData(buf.array().copyOf(n))
                }
            } catch (e: IOException) {
                if (pfd === fd) log("USB read ended: ${e.message}")
            }
            handler.post { if (pfd === fd) close("Connection lost") }
        }, "aoa-accessory-reader").apply { isDaemon = true }.start()
    }

    private fun close(reason: String?) {
        val fd = pfd ?: return
        pfd = null
        val out = output
        val inChannel = input
        output = null
        input = null
        // Closing the channels wakes the reader and any write that is blocked because the cashier
        // stopped reading. That waits for those threads, so do it off the main thread.
        Thread({
            runCatching { out?.close() }
            runCatching { inChannel?.close() }
            runCatching { fd.close() }
        }, "aoa-accessory-close").apply { isDaemon = true }.start()
        if (reason != null && running) state("waiting", reason)
    }

    private fun requestPermission(acc: UsbAccessory) {
        if (!permissionRequested) {
            permissionRequested = true
            val intent = Intent(ACTION_USB_PERMISSION).setPackage(context.packageName)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            usbManager.requestPermission(acc, PendingIntent.getBroadcast(context, 1, intent, flags))
            log("Asking for USB accessory permission")
        }
        state("permission", "Allow USB access on the screen")
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
            addAction(ACTION_USB_PERMISSION)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    private fun state(state: String, detail: String?) {
        if (state == lastState && detail == lastDetail) return
        lastState = state
        lastDetail = detail
        listener.onState(state, detail)
        if (detail != null) log(detail)
    }

    private fun log(message: String) = listener.onLog(message)
}
