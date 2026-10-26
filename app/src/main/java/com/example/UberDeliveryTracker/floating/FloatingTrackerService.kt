package com.example.UberDeliveryTracker.floating

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.example.UberDeliveryTracker.MainActivity
import com.example.UberDeliveryTracker.R
import com.example.UberDeliveryTracker.ocr.ScreenshotObserver
import com.example.UberDeliveryTracker.ocr.OrderInfoDetector

class FloatingTrackerService : Service() {

    companion object {
        // 懸浮窗 → App：取餐 / 送達（舊版：不指定哪一單）
        const val ACTION_PICKUP  = "com.example.UberDeliveryTracker.ACTION_PICKUP"
        const val ACTION_DELIVER = "com.example.UberDeliveryTracker.ACTION_DELIVER"

        // 懸浮窗 → App：取餐 / 送達（新版：指定球上顯示的那一單）
        const val ACTION_PICKUP_ORDER  = "com.example.UberDeliveryTracker.ACTION_PICKUP_ORDER"
        const val ACTION_DELIVER_ORDER = "com.example.UberDeliveryTracker.ACTION_DELIVER_ORDER"
        const val EXTRA_ORDER_ID       = "extra_order_id"

        // App → 懸浮窗（舊版顯示資料，保留名稱讓 App 端不用改）
        const val ACTION_UPDATE_DISPLAY     = "com.example.UberDeliveryTracker.UPDATE_DISPLAY"
        const val EXTRA_HOURLY_WAGE         = "extra_hourly_wage"
        const val EXTRA_ELAPSED_SECONDS     = "extra_elapsed_seconds"
        const val EXTRA_ACTIVE_ORDER_NUMBER = "extra_active_order_number"

        // App → 懸浮窗（新版：整份進行中訂單清單）
        const val ACTION_UPDATE_ORDERS  = "com.example.UberDeliveryTracker.UPDATE_ORDERS"
        const val EXTRA_LONGEST_SECONDS = "extra_longest_seconds"
        const val EXTRA_ORDER_IDS       = "extra_order_ids"
        const val EXTRA_ORDER_NUMBERS   = "extra_order_numbers"
        const val EXTRA_ORDER_NOTES     = "extra_order_notes"
        const val EXTRA_ORDER_WAGES     = "extra_order_wages"
        const val EXTRA_ORDER_CASH      = "extra_order_cash"
        const val EXTRA_ORDER_PICKED    = "extra_order_picked"

        // 截圖 → App，以及 App → 懸浮窗的提示文字
        const val ACTION_SCREENSHOT   = "com.example.UberDeliveryTracker.ACTION_SCREENSHOT"
        const val EXTRA_NOTE_TEXT     = "extra_note_text"
        const val EXTRA_ORDER_CODE    = "extra_order_code"
        const val EXTRA_IS_OFFER      = "extra_is_offer"
        const val EXTRA_IS_CASH       = "extra_is_cash"
        const val EXTRA_OFFER_SUMMARY = "extra_offer_summary"
        const val ACTION_SHOW_MESSAGE = "com.example.UberDeliveryTracker.ACTION_SHOW_MESSAGE"
        const val EXTRA_MESSAGE       = "extra_message"
    }

    // ── 配色（Z 世代潮流風：深黑底 + 螢光色）──
    private val cInk    = Color.parseColor("#14141A")
    private val cChip   = Color.parseColor("#2A2A35")
    private val cLime   = Color.parseColor("#C6FF3D")
    private val cPink   = Color.parseColor("#FF4F9A")
    private val cBlue   = Color.parseColor("#3D7BFF")
    private val cOrange = Color.parseColor("#FFA62B")
    private val cYellow = Color.parseColor("#FFE600")

    private lateinit var windowManager: WindowManager
    private var floatView: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    private lateinit var timeText: TextView
    private lateinit var countPill: TextView
    private lateinit var codeChip: TextView
    private lateinit var amountText: TextView
    private lateinit var camBtn: ImageView
    private lateinit var cashText: TextView
    private lateinit var menuRow: LinearLayout
    private lateinit var pickupBtn: TextView

    private var screenshotObserver: ScreenshotObserver? = null
    private val handler = Handler(Looper.getMainLooper())

    private val CHANNEL_ID = "FloatingTrackerChannel"
    private val NOTIFICATION_ID = 1001

    // ── 目前進行中的單（由 App 每秒推來）──
    private var ids: List<String> = emptyList()
    private var numbers: IntArray = IntArray(0)
    private var notes: List<String> = emptyList()
    private var wages: DoubleArray = DoubleArray(0)
    private var cashes: List<String> = emptyList()
    private var picked: BooleanArray = BooleanArray(0)
    private var longestSeconds: Long = 0L
    private var selectedId: String? = null
    private var lastUpdateMillis: Long = 0L

    // 拖曳用
    private var downX = 0
    private var downY = 0
    private var touchX = 0f
    private var touchY = 0f
    private var dragging = false
    private val touchSlop by lazy { ViewConfiguration.get(this).scaledTouchSlop }

    // 接收 App 推來的「進行中訂單清單」
    private val ordersReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent == null) return
            ids = intent.getStringArrayExtra(EXTRA_ORDER_IDS)?.toList() ?: emptyList()
            numbers = intent.getIntArrayExtra(EXTRA_ORDER_NUMBERS) ?: IntArray(0)
            notes = intent.getStringArrayExtra(EXTRA_ORDER_NOTES)?.toList() ?: emptyList()
            wages = intent.getDoubleArrayExtra(EXTRA_ORDER_WAGES) ?: DoubleArray(0)
            cashes = intent.getStringArrayExtra(EXTRA_ORDER_CASH)?.toList() ?: emptyList()
            picked = intent.getBooleanArrayExtra(EXTRA_ORDER_PICKED) ?: BooleanArray(0)
            longestSeconds = intent.getLongExtra(EXTRA_LONGEST_SECONDS, 0L)
            lastUpdateMillis = System.currentTimeMillis()
            renderBall()
        }
    }

    // 接收 App 回報的結果（例如「已開始計時」），用小提示顯示
    private val messageReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val msg = intent?.getStringExtra(EXTRA_MESSAGE) ?: return
            Toast.makeText(this@FloatingTrackerService, msg, Toast.LENGTH_LONG).show()
        }
    }

    // 4 秒沒收到 App 的更新（例如單都結束了），球回到待命狀態
    private val watchdog = object : Runnable {
        override fun run() {
            if (ids.isNotEmpty() && System.currentTimeMillis() - lastUpdateMillis > 4000L) {
                ids = emptyList(); notes = emptyList(); cashes = emptyList()
                numbers = IntArray(0); wages = DoubleArray(0); picked = BooleanArray(0)
                longestSeconds = 0L
                selectedId = null
                renderBall()
            }
            handler.postDelayed(this, 1000L)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        try {
            startForeground(NOTIFICATION_ID, createNotification())
        } catch (e: Exception) {
            Toast.makeText(this, "需要先允許定位權限，才能開懸浮窗", Toast.LENGTH_LONG).show()
            stopSelf()
            return
        }
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        initFloatingView()
        initScreenshotObserver()

        val lbm = LocalBroadcastManager.getInstance(this)
        lbm.registerReceiver(ordersReceiver, IntentFilter(ACTION_UPDATE_ORDERS))
        lbm.registerReceiver(messageReceiver, IntentFilter(ACTION_SHOW_MESSAGE))
        handler.post(watchdog)
    }

    // ───────────────────────── 小工具 ─────────────────────────

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density + 0.5f).toInt()

    private fun roundBg(fill: Int, radiusDp: Int, strokeColor: Int? = null, strokeDp: Int = 0): GradientDrawable =
        GradientDrawable().apply {
            setColor(fill)
            cornerRadius = dp(radiusDp).toFloat()
            if (strokeColor != null && strokeDp > 0) setStroke(dp(strokeDp), strokeColor)
        }

    private fun pill(label: String, bg: Int, fg: Int, onClick: () -> Unit): TextView =
        TextView(this).apply {
            text = label
            setTextColor(fg)
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(6), dp(12), dp(6))
            background = roundBg(bg, 14)
            setOnClickListener { onClick() }
        }

    // ───────────────────────── 建立小球 ─────────────────────────

    private fun initFloatingView() {
        val wrap = LinearLayout.LayoutParams.WRAP_CONTENT

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(10))
            background = roundBg(cInk, 22, Color.WHITE, 2)
            alpha = 0.97f
        }

        // 第一行：最長計時 + 單數藥丸
        val topRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        timeText = TextView(this).apply {
            text = "⏱ --:--"
            setTextColor(Color.WHITE)
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
        }
        countPill = TextView(this).apply {
            text = "×2"
            setTextColor(Color.BLACK)
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            paint.isFakeBoldText = true
            setPadding(dp(9), dp(1), dp(9), dp(1))
            background = roundBg(cYellow, 10)
            visibility = View.GONE
        }
        topRow.addView(timeText)
        topRow.addView(countPill, LinearLayout.LayoutParams(wrap, wrap).apply { marginStart = dp(8) })

        // 點一下「開App」回到薪水計時主畫面
        topRow.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f))
        val appBtn = ImageView(this).apply {
            setImageResource(R.drawable.ic_home_flat)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(5), dp(5), dp(5), dp(5))
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.WHITE)
                setStroke(dp(2), Color.BLACK)
            }
            setOnClickListener { openMainApp() }
        }
        topRow.addView(appBtn, LinearLayout.LayoutParams(dp(30), dp(30)).apply { marginStart = dp(10) })

        // 第二行：單號末三碼 | 累計車資 | 相機
        val midRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        codeChip = TextView(this).apply {
            text = "---"
            setTextColor(Color.WHITE)
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            paint.isFakeBoldText = true
            gravity = Gravity.CENTER
            minWidth = dp(46)
            setPadding(dp(8), dp(4), dp(8), dp(4))
            background = roundBg(cChip, 10)
        }
        amountText = TextView(this).apply {
            text = "\$0"
            setTextColor(cLime)
            textSize = 28f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
        }
        camBtn = ImageView(this).apply {
            setImageResource(android.R.drawable.ic_menu_camera)
            setColorFilter(Color.BLACK)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(7), dp(7), dp(7), dp(7))
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.WHITE)
                setStroke(dp(2), Color.BLACK)
            }
            setOnClickListener {
                onCameraClicked()
            }
        }
        midRow.addView(codeChip)
        midRow.addView(amountText, LinearLayout.LayoutParams(wrap, wrap).apply {
            marginStart = dp(10); marginEnd = dp(10)
        })
        midRow.addView(camBtn, LinearLayout.LayoutParams(dp(36), dp(36)))

        // 第三行：現金單要收多少
        cashText = TextView(this).apply {
            text = ""
            setTextColor(cPink)
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            visibility = View.GONE
        }

        // 長按才出現的選單：取餐 / 送達 / 收起
        menuRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            visibility = View.GONE
        }
        pickupBtn = pill("取餐", cOrange, cInk) { sendOrderAction(ACTION_PICKUP_ORDER, "🍱 已標記取餐") }
        val deliverBtn = pill("送達", cLime, cInk) { sendOrderAction(ACTION_DELIVER_ORDER, "✅ 已標記送達") }
        val closeBtn = pill("✕", cChip, Color.WHITE) { hideMenu() }
        menuRow.addView(pickupBtn, LinearLayout.LayoutParams(wrap, wrap).apply { marginEnd = dp(6) })
        menuRow.addView(deliverBtn, LinearLayout.LayoutParams(wrap, wrap).apply { marginEnd = dp(6) })
        menuRow.addView(closeBtn)

        container.addView(topRow)
        container.addView(midRow, LinearLayout.LayoutParams(wrap, wrap).apply { topMargin = dp(4) })
        container.addView(cashText, LinearLayout.LayoutParams(wrap, wrap).apply { topMargin = dp(2) })
        container.addView(menuRow, LinearLayout.LayoutParams(wrap, wrap).apply { topMargin = dp(8) })
        floatView = container

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else WindowManager.LayoutParams.TYPE_PHONE

        layoutParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 40
            y = 300
        }

        setupGestures(container)
        windowManager.addView(floatView, layoutParams)
        renderBall()
    }

    // ───────────────────────── 手勢：點一下切換 / 長按選單 / 拖曳 ─────────────────────────

    private fun setupGestures(view: View) {
        val detector = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean = true
            override fun onSingleTapUp(e: MotionEvent): Boolean {
                cycleOrder()
                return true
            }
            override fun onLongPress(e: MotionEvent) {
                toggleMenu()
            }
        })

        view.setOnTouchListener { _, event ->
            val params = layoutParams
            if (params != null) {
                when (event.action) {
                    MotionEvent.ACTION_DOWN -> {
                        downX = params.x
                        downY = params.y
                        touchX = event.rawX
                        touchY = event.rawY
                        dragging = false
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val dx = event.rawX - touchX
                        val dy = event.rawY - touchY
                        if (!dragging && (Math.abs(dx) > touchSlop || Math.abs(dy) > touchSlop)) {
                            dragging = true
                        }
                        if (dragging) {
                            params.x = downX + dx.toInt()
                            params.y = downY + dy.toInt()
                            windowManager.updateViewLayout(floatView, params)
                        }
                    }
                }
            }
            detector.onTouchEvent(event)
            true
        }
    }

    // ───────────────────────── 切換 / 選單 / 動作 ─────────────────────────

    private fun currentIndex(): Int {
        if (ids.isEmpty()) return -1
        val i = ids.indexOf(selectedId)
        return if (i >= 0) i else 0
    }

    private fun cycleOrder() {
        if (ids.size < 2) return
        val idx = currentIndex()
        selectedId = ids[(idx + 1) % ids.size]
        renderBall()
    }

    private val hideMenuRunnable = Runnable { menuRow.visibility = View.GONE }

    private fun hideMenu() {
        handler.removeCallbacks(hideMenuRunnable)
        menuRow.visibility = View.GONE
    }

    private fun toggleMenu() {
        if (currentIndex() < 0) {
            Toast.makeText(this, "目前沒有進行中的單", Toast.LENGTH_SHORT).show()
            return
        }
        if (menuRow.visibility == View.VISIBLE) {
            hideMenu()
        } else {
            menuRow.visibility = View.VISIBLE
            handler.removeCallbacks(hideMenuRunnable)
            handler.postDelayed(hideMenuRunnable, 6000L)
        }
    }

    /** 點「開App」：把薪水計時主畫面拉到最前面 */
    private fun openMainApp() {
        try {
            startActivity(
                Intent(this, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
            )
        } catch (e: Exception) {
            Toast.makeText(this, "打不開 App，請從通知列點「薪水計時」回去", Toast.LENGTH_LONG).show()
        }
    }
    private fun sendOrderAction(action: String, doneMessage: String) {
        val id = ids.getOrNull(currentIndex()) ?: return
        LocalBroadcastManager.getInstance(this).sendBroadcast(
            Intent(action).apply { putExtra(EXTRA_ORDER_ID, id) }
        )
        Toast.makeText(this, doneMessage, Toast.LENGTH_SHORT).show()
        hideMenu()
    }

    // ───────────────────────── 把資料畫到球上 ─────────────────────────

    private fun codeTail(note: String): String {
        val first = note.lines().firstOrNull { it.isNotBlank() }?.trim() ?: return "---"
        val compact = first.replace(" ", "").replace("#", "")
        if (compact.isEmpty()) return "---"
        return if (compact.length <= 3) compact else compact.takeLast(3)
    }

    private fun renderBall() {
        val idx = currentIndex()
        if (idx < 0) {
            timeText.text = "⏱ --:--"
            countPill.visibility = View.GONE
            codeChip.text = "---"
            amountText.text = "\$0"
            cashText.visibility = View.GONE
            menuRow.visibility = View.GONE
            return
        }
        selectedId = ids[idx]

        val secs = longestSeconds
        val h = secs / 3600
        val m = (secs % 3600) / 60
        val s = secs % 60
        val timeStr = if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
        timeText.text = "⏱ $timeStr"

        if (ids.size >= 2) {
            countPill.text = "×${ids.size}"
            countPill.visibility = View.VISIBLE
        } else {
            countPill.visibility = View.GONE
        }

        codeChip.text = codeTail(notes.getOrNull(idx) ?: "")
        amountText.text = "\$" + "%.0f".format(wages.getOrNull(idx) ?: 0.0)

        val cash = cashes.getOrNull(idx)?.trim().orEmpty()
        if (cash.isNotEmpty()) {
            cashText.text = if (cash == "?") "💵 現金單・記得收錢" else "💵 收 \$$cash"
            cashText.visibility = View.VISIBLE
        } else {
            cashText.visibility = View.GONE
        }

        // 已經取餐的單，「取餐」藥丸變淡
        pickupBtn.alpha = if (picked.getOrNull(idx) == true) 0.35f else 1f
    }

    // ───────────────────────── 截圖偵測 / 通知 ─────────────────────────

    private fun initScreenshotObserver() {
        screenshotObserver = ScreenshotObserver(this) { detected ->
            LocalBroadcastManager.getInstance(this).sendBroadcast(
                Intent(ACTION_SCREENSHOT).apply {
                    putExtra(EXTRA_NOTE_TEXT, detected.combinedText ?: "")
                    putExtra(EXTRA_ORDER_CODE, detected.orderCode ?: detected.fullOrderNumber ?: "")
                    putExtra(EXTRA_IS_OFFER, detected.isNewOffer)
                    putExtra(EXTRA_IS_CASH, detected.isCash)
                    putExtra(EXTRA_OFFER_SUMMARY, detected.offerSummary)
                }
            )
        }
        screenshotObserver?.register()
    }

    /** 按下相機鈕：先試著直接讀畫面文字；讀不到再截圖辨識 */
    private fun onCameraClicked() {
        val helper = ScreenshotAccessibilityService.instance
        if (helper == null) {
            Toast.makeText(
                this,
                "無障礙目前是關閉的。請用手機截圖（電源鍵＋音量下），App 會自動辨識",
                Toast.LENGTH_LONG
            ).show()
            return
        }
        val ball = floatView ?: return

        // 先直接讀畫面上的字；讀得到就不用截圖
        val lines = helper.readScreenLines()
        val direct = if (lines.size >= 3) OrderInfoDetector.detect(lines) else null
        if (direct != null && direct.hasAnything) {
            val detected = direct
            LocalBroadcastManager.getInstance(this).sendBroadcast(
                Intent(ACTION_SCREENSHOT).apply {
                    putExtra(EXTRA_NOTE_TEXT, detected.combinedText ?: "")
                    putExtra(EXTRA_ORDER_CODE, detected.orderCode ?: detected.fullOrderNumber ?: "")
                    putExtra(EXTRA_IS_OFFER, detected.isNewOffer)
                    putExtra(EXTRA_IS_CASH, detected.isCash)
                    putExtra(EXTRA_OFFER_SUMMARY, detected.offerSummary)
                }
            )
            return
        }

        // 讀不到字 → 把球藏起來，截圖辨識，再把球顯示回來
        ball.visibility = View.INVISIBLE
        handler.postDelayed({
            helper.captureAndRecognize(
                onDone = { detected ->
                    ball.visibility = View.VISIBLE
                    LocalBroadcastManager.getInstance(this).sendBroadcast(
                        Intent(ACTION_SCREENSHOT).apply {
                            putExtra(EXTRA_NOTE_TEXT, detected.combinedText ?: "")
                            putExtra(EXTRA_ORDER_CODE, detected.orderCode ?: detected.fullOrderNumber ?: "")
                            putExtra(EXTRA_IS_OFFER, detected.isNewOffer)
                            putExtra(EXTRA_IS_CASH, detected.isCash)
                            putExtra(EXTRA_OFFER_SUMMARY, detected.offerSummary)
                        }
                    )
                },
                onFail = { msg ->
                    ball.visibility = View.VISIBLE
                    Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
                }
            )
        }, 250L)
    }
    private fun createNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, "跑單懸浮窗", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("薪水計時 - 跑單服務運作中")
            .setContentText("點擊返回主畫面")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        super.onDestroy()
        handler.removeCallbacksAndMessages(null)
        screenshotObserver?.unregister()
        val lbm = LocalBroadcastManager.getInstance(this)
        lbm.unregisterReceiver(ordersReceiver)
        lbm.unregisterReceiver(messageReceiver)
        floatView?.let { windowManager.removeView(it) }
    }
}