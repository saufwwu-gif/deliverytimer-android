package com.example.UberDeliveryTracker.ocr

import android.content.ContentResolver
import android.content.Context
import android.database.ContentObserver
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class ScreenshotObserver(
    private val context: Context,
    private val onOrderDetected: (DetectedInfo) -> Unit
) : ContentObserver(Handler(Looper.getMainLooper())) {

    private val scope = CoroutineScope(Dispatchers.IO)
    private var lastHandledUri: Uri? = null

    override fun onChange(selfChange: Boolean, uri: Uri?) {
        super.onChange(selfChange, uri)
        val targetUri = uri ?: MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        scope.launch {
            handleLatestImage(targetUri)
        }
    }

    private suspend fun handleLatestImage(contentUri: Uri) {
        val resolver: ContentResolver = context.contentResolver
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DATA,
            MediaStore.Images.Media.DATE_ADDED
        )
        val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC"

        try {
            val cursor = resolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection, null, null, sortOrder
            )

            var imageUri: Uri? = null
            cursor?.use {
                if (it.moveToFirst()) {
                    val id = it.getLong(it.getColumnIndexOrThrow(MediaStore.Images.Media._ID))
                    val path = it.getString(it.getColumnIndexOrThrow(MediaStore.Images.Media.DATA)) ?: ""
                    val dateAdded = it.getLong(it.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED))

                    // 只收「截圖」資料夾裡、15 秒內剛產生的圖（拍照、下載的圖不理）
                    val isScreenshot = path.contains("screenshot", ignoreCase = true) || path.contains("截")
                    val isFresh = System.currentTimeMillis() / 1000 - dateAdded <= 15

                    if (isScreenshot && isFresh) {
                        val candidate = Uri.withAppendedPath(
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id.toString()
                        )
                        // 同一張圖只處理一次（系統會連續通知好幾次）
                        val firstTime = synchronized(this@ScreenshotObserver) {
                            if (candidate == lastHandledUri) false
                            else { lastHandledUri = candidate; true }
                        }
                        if (firstTime) imageUri = candidate
                    }
                }
            }

            val target = imageUri ?: return
            Log.d("ScreenshotObserver", "偵測到新截圖: $target")

            // 辨識失敗也要通知，因為截圖本身就代表接單
            var detected = DetectedInfo()
            try {
                resolver.openInputStream(target)?.use { stream ->
                    val bitmap = BitmapFactory.decodeStream(stream)
                    if (bitmap != null) detected = OrderImageRecognizer.recognize(bitmap)
                }
            } catch (e: Exception) {
                Log.e("ScreenshotObserver", "辨識失敗，仍當作接單", e)
            }

            withContext(Dispatchers.Main) { onOrderDetected(detected) }
        } catch (e: Exception) {
            Log.e("ScreenshotObserver", "讀取截圖失敗", e)
        }
    }

    fun register() {
        try {
            context.contentResolver.registerContentObserver(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                true,
                this
            )
        } catch (e: Exception) {
            Log.e("ScreenshotObserver", "註冊失敗", e)
        }
    }

    fun unregister() {
        try {
            context.contentResolver.unregisterContentObserver(this)
        } catch (e: Exception) {
            Log.e("ScreenshotObserver", "解除註冊失敗", e)
        }
    }
}
