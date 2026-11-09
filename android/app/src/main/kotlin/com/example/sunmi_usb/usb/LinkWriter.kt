package com.example.sunmi_usb.usb

import android.os.Handler
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicInteger

/**
 * Writes frames for one transport on its own thread, so the platform thread never blocks.
 *
 * An accessory write blocks while the other device isn't reading (the driver holds only a few
 * packets). So the queue is bounded: past [MAX_QUEUED] the send is refused at once instead of
 * piling up stale frames. Each transport gets its own writer. A write stuck on a dead link can't
 * delay the next link, and [shutdown] answers every queued send with false.
 */
class LinkWriter(private val main: Handler) {

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "usb-link-writer").apply { isDaemon = true }
    }
    private val queued = AtomicInteger()

    fun submit(transport: LinkTransport, data: ByteArray, result: MethodChannel.Result) {
        if (queued.incrementAndGet() > MAX_QUEUED) {
            queued.decrementAndGet()
            result.success(false)
            return
        }
        val task = Task(transport, data, result)
        try {
            executor.execute(task)
        } catch (e: RejectedExecutionException) {
            task.answer(false)
        }
    }

    /** Interrupts a blocked write and answers every queued send with false. */
    fun shutdown() {
        executor.shutdownNow().forEach { (it as? Task)?.answer(false) }
    }

    private inner class Task(
        private val transport: LinkTransport,
        private val data: ByteArray,
        private val result: MethodChannel.Result,
    ) : Runnable {
        override fun run() {
            answer(runCatching { transport.write(data) }.getOrDefault(false))
        }

        fun answer(ok: Boolean) {
            queued.decrementAndGet()
            main.post { result.success(ok) }
        }
    }

    companion object {
        const val MAX_QUEUED = 32
    }
}
