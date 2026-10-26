package com.example.UberDeliveryTracker.floating

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.example.UberDeliveryTracker.MainActivity
import com.example.UberDeliveryTracker.ocr.DetectedInfo
import com.example.UberDeliveryTracker.ocr.OrderImageRecognizer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * 錄影截圖服務：同意之後，一直保留「最新一張螢幕畫面」，
 * 需要時就拿來辨識。不用無障礙。
 */
class ScreenCaptureService : Service() {

    companion object {
        const val EXTRA_RESULT_CODE = "extra_result_code"
        const val EXTRA_RESULT_DATA = "extra_result_data"
        const val ACTION_STOP = "com.example.UberDeliveryTracker.ACTION_STOP_CAPTURE"
        private const val CHANNEL_ID = "ScreenCaptureChannel"
        private const val NOTIFICATION_ID = 1002

        @Volatile
        var instance: ScreenCaptureService? = null

        /** 讓畫面知道錄影截圖現在是開還是關 */
        val readyFlow = MutableStateFlow(false)
    }

    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(Dispatchers.Main)
    private val lock = Any()
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var latest: Image? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            shutDown()
            return START_NOT_STICKY
        }
        val code = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        @Suppress("DEPRECATION")
        val data: Intent? = intent?.getParcelableExtra(EXTRA_RESULT_DATA)
        if (code == 0 || data == null) {
            shutDown()
            return START_NOT_STICKY
        }

        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
        } catch (e: Exception) {
            shutDown()
            return START_NOT_STICKY
        }

        cleanup()
        val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val p = try { mgr.getMediaProjection(code, data) } catch (e: Exception) { null }
        if (p == null) {
            shutDown()
            return START_NOT_STICKY
        }
        projection = p
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                handler.post { shutDown() }
            }
        }, handler)

        try {
            setupDisplay(p)
        } catch (e: Exception) {
            shutDown()
            return START_NOT_STICKY
        }
        instance = this
        readyFlow.value = true
        return START_NOT_STICKY
    }

    private fun screenSize(): Pair<Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        return if (Build.VERSION.SDK_INT >= 30) {
            val b = wm.maximumWindowMetrics.bounds
            Pair(b.width(), b.height())
        } else {
            val m = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(m)
            Pair(m.widthPixels, m.heightPixels)
        }
    }

    private fun setupDisplay(p: MediaProjection) {
        val (w, h) = screenSize()
        val dpi = resources.displayMetrics.densityDpi
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3)
        r.setOnImageAvailableListener({ rd ->
            val img = try { rd.acquireLatestImage() } catch (e: Exception) { null }
            if (img != null) {
                synchronized(lock) {
                    latest?.close()
                    latest = img
                }
            }
        }, handler)
        reader = r
        display = p.createVirtualDisplay(
            "salary_capture", w, h, dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            r.surface, null, handler
        )
    }

    /** 把「最新一張畫面」轉成圖片 */
    private fun grabBitmap(): Bitmap? {
        synchronized(lock) {
            val img = latest ?: return null
            val plane = img.planes[0]
            val buffer = plane.buffer
            buffer.rewind()
            val pixelStride = plane.pixelStride
            val rowPadding = plane.rowStride - pixelStride * img.width
            val wide = Bitmap.createBitmap(
                img.width + rowPadding / pixelStride, img.height, Bitmap.Config.ARGB_8888
            )
            wide.copyPixelsFromBuffer(buffer)
            return if (rowPadding == 0) wide
            else Bitmap.createBitmap(wide, 0, 0, img.width, img.height)
        }
    }

    /** 辨識目前畫面。成功或失敗一定會回報其中一個。 */
    fun captureAndRecognize(
        onDone: (DetectedInfo) -> Unit,
        onFail: (String) -> Unit
    ) {
        val bmp = try { grabBitmap() } catch (e: Exception) { null }
        if (bmp == null) {
            onFail("還沒拿到畫面，請稍等一下再按")
            return
        }
        scope.launch { onDone(OrderImageRecognizer.recognize(bmp)) }
    }

    private fun cleanup() {
        readyFlow.value = false
        instance = null
        runCatching { display?.release() }
        display = null
        synchronized(lock) {
            runCatching { latest?.close() }
            latest = null
        }
        runCatching {
            reader?.setOnImageAvailableListener(null, null)
            reader?.close()
        }
        reader = null
        val p = projection
        projection = null
        runCatching { p?.stop() }
    }

    private fun shutDown() {
        cleanup()
        runCatching { ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE) }
        stopSelf()
    }

    override fun onDestroy() {
        cleanup()
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, "錄影截圖", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, ScreenCaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("薪水計時 - 錄影截圖運作中")
            .setContentText("點一下回主畫面，或按「關閉」")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentIntent(open)
            .addAction(0, "關閉", stop)
            .setOngoing(true)
            .build()
    }
}