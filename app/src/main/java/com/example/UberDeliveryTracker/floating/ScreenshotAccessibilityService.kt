package com.example.UberDeliveryTracker.floating

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.example.UberDeliveryTracker.ocr.DetectedInfo
import com.example.UberDeliveryTracker.ocr.OrderImageRecognizer
import com.example.UberDeliveryTracker.ocr.OrderInfoDetector
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * 截圖助手（無障礙服務）：
 * 1) 平常盯著 Uber / 熊貓的畫面，自動做三件事（可用開關暫停）：
 *    按「接受」→ 開始計時；讀到單號姓名 → 帶入；讀到現金金額 → 填入
 * 2) 球上相機鈕：直接讀出畫面上的字，讀不到時截圖後辨識
 * 3) 讓畫面知道它現在是開還是關
 */
class ScreenshotAccessibilityService : AccessibilityService() {

    private val scope = CoroutineScope(Dispatchers.Main)
    private val uiHandler = Handler(Looper.getMainLooper())
    private val readRunnable = Runnable { readAndReport() }

    // 自動帶入用的記憶
    private var lastOffer: DetectedInfo? = null   // 最近看到的新來單卡片
    private var lastOfferAt = 0L
    private var lastOrderKey = ""                 // 最近送出的單號，同一個不重複
    private var lastCashKey = ""                  // 最近送出的現金金額，同一個不重複
    private var lastAcceptAt = 0L

    /** 跑單頁的「無障礙自動帶入」開關（預設開） */
    private fun autoOn(): Boolean =
        getSharedPreferences("uber_delivery_tracker_prefs", Context.MODE_PRIVATE)
            .getBoolean("AutoFillEnabled", true)

    /** 只看 Uber 和熊貓，其他 App、自己的 App 都不讀 */
    private fun isDeliveryApp(pkg: String): Boolean {
        if (pkg == packageName) return false
        val p = pkg.lowercase()
        return p.contains("uber") || p.contains("foodpanda")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null || !autoOn()) return
        val pkg = event.packageName?.toString() ?: return
        if (!isDeliveryApp(pkg)) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> handleClick(event)
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> {
                // 畫面一直在變，等 0.6 秒穩定了才讀一次
                uiHandler.removeCallbacks(readRunnable)
                uiHandler.postDelayed(readRunnable, 600L)
            }
        }
    }

    /** 收集被按的那個東西上面的字（含它裡面的小字） */
    private fun collectText(n: AccessibilityNodeInfo?, sb: StringBuilder, depth: Int) {
        if (n == null || depth > 3) return
        n.text?.let { sb.append(it).append(' ') }
        n.contentDescription?.let { sb.append(it).append(' ') }
        for (i in 0 until n.childCount) collectText(n.getChild(i), sb, depth + 1)
    }

    /** 你按了按鈕：如果是「接受／配對」，而且剛剛看過新來單卡片，就開始計時 */
    private fun handleClick(event: AccessibilityEvent) {
        val sb = StringBuilder()
        event.text?.forEach { sb.append(it).append(' ') }
        event.contentDescription?.let { sb.append(it).append(' ') }
        collectText(event.source, sb, 0)
        val t = sb.toString().trim()
        // 按鈕上的字很短；太長代表按到的是整張大卡片，不算
        if (t.isEmpty() || t.length > 20) return
        if (!(t.contains("接受") || t.contains("配對"))) return

        val now = System.currentTimeMillis()
        val offer = lastOffer ?: return
        if (now - lastOfferAt > 60_000L) return
        if (now - lastAcceptAt < 5_000L) return
        lastAcceptAt = now
        lastOffer = null
        lastOrderKey = ""
        lastCashKey = ""
        sendToApp(offer)
    }

    /** 讀目前畫面，判斷是新來單／現金金額／單號畫面 */
    private fun readAndReport() {
        if (!autoOn()) return
        val lines = readScreenLines()
        if (lines.size < 3) return
        val d = OrderInfoDetector.detect(lines)
        val now = System.currentTimeMillis()

        // 1) 新來單卡片：只先記起來，等你按「接受」才開始計時
        if (d.isNewOffer) {
            lastOffer = d
            lastOfferAt = now
            return
        }

        // 2) 收取費用畫面：要收的現金金額
        val amount = d.cashAmount
        if (amount != null) {
            val key = "cash:" + "%.2f".format(amount)
            if (key != lastCashKey) {
                lastCashKey = key
                sendToApp(d)
            }
            return
        }

        // 3) 單號畫面
        val code = d.fullOrderNumber ?: d.orderCode
        if (code != null) {
            // 備用：沒偵測到你按「接受」，但接單後的畫面出現了（25 秒內）→ 補開始計時
            val pending = lastOffer
            if (pending != null && now - lastOfferAt < 25_000L) {
                lastOffer = null
                lastOrderKey = ""
                lastCashKey = ""
                sendToApp(pending)
            }
            // 同一個單號只送一次，讀到不一樣的才再送
            if (code != lastOrderKey) {
                lastOrderKey = code
                sendToApp(d)
            }
        }
    }

    /** 把讀到的東西交給主程式處理（標記為「自動」） */
    private fun sendToApp(d: DetectedInfo) {
        LocalBroadcastManager.getInstance(this).sendBroadcast(
            Intent(FloatingTrackerService.ACTION_SCREENSHOT).apply {
                putExtra(FloatingTrackerService.EXTRA_NOTE_TEXT, d.combinedText ?: "")
                putExtra(FloatingTrackerService.EXTRA_ORDER_CODE, d.orderCode ?: d.fullOrderNumber ?: "")
                putExtra(FloatingTrackerService.EXTRA_IS_OFFER, d.isNewOffer)
                putExtra(FloatingTrackerService.EXTRA_IS_CASH, d.isCash)
                putExtra(FloatingTrackerService.EXTRA_OFFER_SUMMARY, d.offerSummary)
                putExtra(FloatingTrackerService.EXTRA_CASH_AMOUNT, d.cashAmount ?: -1.0)
                putExtra(FloatingTrackerService.EXTRA_IS_AUTO, true)
            }
        )
    }

    override fun onInterrupt() {}

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        readyFlow.value = true
        lastOffer = null
        lastOrderKey = ""
        lastCashKey = ""
    }

    override fun onUnbind(intent: Intent?): Boolean {
        uiHandler.removeCallbacksAndMessages(null)
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