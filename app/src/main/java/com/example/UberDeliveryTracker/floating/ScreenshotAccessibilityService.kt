package com.example.UberDeliveryTracker.floating

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.view.accessibility.AccessibilityEvent
import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import android.graphics.Bitmap
import android.os.Build
import android.view.Display
import com.example.UberDeliveryTracker.ocr.DetectedInfo
import com.example.UberDeliveryTracker.ocr.OrderImageRecognizer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * 截圖助手（無障礙服務）：
 * 1) 直接讀出畫面上的字
 * 2) 讀不到時，截圖後辨識
 * 3) 讓畫面知道它現在是開還是關
 */
class ScreenshotAccessibilityService : AccessibilityService() {

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 不需要監看畫面，留空
    }

    override fun onInterrupt() {}

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        readyFlow.value = true
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        readyFlow.value = false
        return super.onUnbind(intent)
    }

    /** 直接讀出目前畫面上所有的字，由上到下、由左到右排好 */
    fun readScreenLines(): List<String> {
        val root = rootInActiveWindow ?: return emptyList()
        val items = mutableListOf<Triple<Int, Int, String>>()
        fun walk(n: AccessibilityNodeInfo?) {
            if (n == null) return
            val t = n.text?.toString() ?: n.contentDescription?.toString()
            if (!t.isNullOrBlank()) {
                val r = Rect()
                n.getBoundsInScreen(r)
                items.add(Triple(r.top / 20, r.left, t.trim()))
            }
            for (i in 0 until n.childCount) walk(n.getChild(i))
        }
        walk(root)
        return items.sortedWith(compareBy({ it.first }, { it.second })).map { it.third }
    }

    private val scope = CoroutineScope(Dispatchers.Main)

    /** 截下目前整個畫面，讀出字，再把結果交回去。成功或失敗都一定會回報其中一個。 */
    fun captureAndRecognize(
        onDone: (DetectedInfo) -> Unit,
        onFail: (String) -> Unit
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            onFail("手機要 Android 11 以上，相機鈕才能截圖")
            return
        }
        takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
            override fun onSuccess(result: ScreenshotResult) {
                val buffer = result.hardwareBuffer
                val wrapped = Bitmap.wrapHardwareBuffer(buffer, result.colorSpace)
                val copy = wrapped?.copy(Bitmap.Config.ARGB_8888, false)
                buffer.close()
                if (copy == null) {
                    onFail("截圖讀不出來")
                    return
                }
                scope.launch { onDone(OrderImageRecognizer.recognize(copy)) }
            }

            override fun onFailure(errorCode: Int) {
                onFail("截圖失敗（代碼 $errorCode），請稍等幾秒再按")
            }
        })
    }

    companion object {
        /** 助手開著的時候，這裡就有東西；關掉就是空的 */
        @Volatile
        var instance: ScreenshotAccessibilityService? = null

        val isReady: Boolean get() = instance != null

        /** 讓畫面知道無障礙現在是開還是關 */
        val readyFlow = MutableStateFlow(false)
    }
}