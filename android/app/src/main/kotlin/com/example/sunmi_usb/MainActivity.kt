package com.example.sunmi_usb

import android.content.Intent
import com.example.sunmi_usb.usb.UsbLinkPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var usbLink: UsbLinkPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbLink = UsbLinkPlugin(applicationContext).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
            // Launched by a USB attach intent (see the intent filters in AndroidManifest.xml).
            it.onNewIntent(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        usbLink?.onNewIntent(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        usbLink?.dispose()
        usbLink = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
