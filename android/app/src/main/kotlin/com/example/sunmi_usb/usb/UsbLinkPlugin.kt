package com.example.sunmi_usb.usb

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge between Flutter and the USB transports.
 *
 * MethodChannel "sunmi_usb/link":
 *   deviceInfo, start{role: host|accessory}, stop, send{data}, reset,
 *   listDevices, connectDevice{deviceName}, forgetDevices
 * EventChannel "sunmi_usb/link/events" emits maps:
 *   {type: state, state, detail} | {type: data, data: bytes} | {type: log, message}
 */
class UsbLinkPlugin(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler, LinkListener {

    private val main = Handler(Looper.getMainLooper())
    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var transport: LinkTransport? = null
    private var writer: LinkWriter? = null
    private var lastState: Map<String, Any?> = stateEvent("stopped", null)
    private var pendingIntent: Intent? = null

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, "sunmi_usb/link").also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(messenger, "sunmi_usb/link/events").also { it.setStreamHandler(this) }
    }

    fun dispose() {
        stopTransport()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
    }

    fun onNewIntent(intent: Intent?) {
        if (intent == null) return
        val t = transport
        if (t != null) t.handleIntent(intent) else pendingIntent = intent
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceInfo" -> {
                val pm = context.packageManager
                result.success(
                    mapOf(
                        "manufacturer" to Build.MANUFACTURER,
                        "brand" to Build.BRAND,
                        "model" to Build.MODEL,
                        "device" to Build.DEVICE,
                        "sdkInt" to Build.VERSION.SDK_INT,
                        "release" to Build.VERSION.RELEASE,
                        "usbHost" to pm.hasSystemFeature(PackageManager.FEATURE_USB_HOST),
                        "usbAccessory" to pm.hasSystemFeature(PackageManager.FEATURE_USB_ACCESSORY),
                    ),
                )
            }
            "start" -> {
                val role = call.argument<String>("role")
                stopTransport()
                transport = when (role) {
                    "host" -> AoaHostTransport(context, this)
                    "accessory" -> AoaAccessoryTransport(context, this)
                    else -> {
                        result.error("bad_role", "role must be host or accessory", null)
                        return
                    }
                }
                writer = LinkWriter(main)
                transport!!.start()
                pendingIntent?.let { transport!!.handleIntent(it) }
                pendingIntent = null
                result.success(null)
            }
            "stop" -> {
                stopTransport()
                result.success(null)
            }
            "send" -> {
                val data = call.argument<ByteArray>("data")
                val t = transport
                val w = writer
                if (data == null || t == null || w == null) {
                    result.success(false)
                    return
                }
                w.submit(t, data, result)
            }
            "reset" -> {
                transport?.reset()
                result.success(null)
            }
            "listDevices" -> {
                val t = transport as? AoaHostTransport
                result.success(t?.listDevices() ?: AoaHostTransport.describeDevices(usbManager))
            }
            "connectDevice" -> {
                val t = transport as? AoaHostTransport
                val name = call.argument<String>("deviceName")
                result.success(t != null && name != null && t.connectDevice(name))
            }
            "forgetDevices" -> {
                (transport as? AoaHostTransport)?.forgetDevices()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun stopTransport() {
        transport?.stop()
        transport = null
        writer?.shutdown()
        writer = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        events?.success(lastState)
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ---- LinkListener: may be called from reader threads, so hop to the main thread ----

    override fun onState(state: String, detail: String?) {
        val event = stateEvent(state, detail)
        main.post {
            lastState = event
            sink?.success(event)
        }
    }

    override fun onData(data: ByteArray) {
        main.post { sink?.success(mapOf("type" to "data", "data" to data)) }
    }

    override fun onLog(message: String) {
        Log.d(TAG, message)
        main.post { sink?.success(mapOf("type" to "log", "message" to message)) }
    }

    private fun stateEvent(state: String, detail: String?): Map<String, Any?> =
        mapOf("type" to "state", "state" to state, "detail" to detail)

    companion object {
        private const val TAG = "UsbLink"
    }
}
