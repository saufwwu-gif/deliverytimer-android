package com.example.UberDeliveryTracker.viewmodel

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.speech.tts.TextToSpeech
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.example.UberDeliveryTracker.MainActivity
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.example.UberDeliveryTracker.floating.FloatingTrackerService
import com.example.UberDeliveryTracker.location.GPSLocationManager
import com.example.UberDeliveryTracker.model.DailyReport
import com.example.UberDeliveryTracker.model.AnomalyTag
import com.example.UberDeliveryTracker.model.DayAttendanceStatus
import com.example.UberDeliveryTracker.model.DeliveryBatch
import com.example.UberDeliveryTracker.model.DeliveryOrder
import com.example.UberDeliveryTracker.model.WageSettings
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class DeliveryTrackerViewModel(application: Application) : AndroidViewModel(application) {

    private val prefs: SharedPreferences =
        application.getSharedPreferences("uber_delivery_tracker_prefs", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }
    private val lbm = LocalBroadcastManager.getInstance(application)

    private val KEY_ACTIVE_ORDERS = "SavedActiveOrdersData"
    private val KEY_BATCH_START_TIME = "SavedBatchStartTime"
    private val KEY_HOURLY_RATE = "SavedHourlyRate"
    private val KEY_DAILY_REPORTS = "SavedDailyReportsData"
    private val KEY_PAYOUTS = "SavedBiweeklyPayouts"

    // 接收懸浮窗廣播：取餐 / 送達
    private val floatingActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                FloatingTrackerService.ACTION_SCREENSHOT -> {
                    handleScreenshotFromFloating(
                        noteText = intent?.getStringExtra(FloatingTrackerService.EXTRA_NOTE_TEXT) ?: "",
                        orderCode = intent?.getStringExtra(FloatingTrackerService.EXTRA_ORDER_CODE) ?: "",
                        isOffer = intent?.getBooleanExtra(FloatingTrackerService.EXTRA_IS_OFFER, false) ?: false,
                        isCash = intent?.getBooleanExtra(FloatingTrackerService.EXTRA_IS_CASH, false) ?: false,
                        offerSummary = intent?.getStringExtra(FloatingTrackerService.EXTRA_OFFER_SUMMARY) ?: "",
                        cashAmount = intent?.getDoubleExtra(FloatingTrackerService.EXTRA_CASH_AMOUNT, -1.0) ?: -1.0
                    )
                }
                FloatingTrackerService.ACTION_PICKUP_ORDER -> {
                    intent?.getStringExtra(FloatingTrackerService.EXTRA_ORDER_ID)?.let { markPickupComplete(it) }
                }
                FloatingTrackerService.ACTION_DELIVER_ORDER -> {
                    intent?.getStringExtra(FloatingTrackerService.EXTRA_ORDER_ID)?.let { completeOrder(it) }
                }
                FloatingTrackerService.ACTION_PICKUP -> {
                    // 對最早的未取餐、未完成訂單執行取餐
                    val target = _activeOrders.value
                        .filter { !it.isCompleted && !it.isDiscarded && it.pickupTimeMillis == null }
                        .minByOrNull { it.startTimeMillis }
                    target?.let { markPickupComplete(it.id) }
                }
                FloatingTrackerService.ACTION_DELIVER -> {
                    // 對最早的已取餐但未完成訂單執行送達
                    val target = _activeOrders.value
                        .filter { !it.isCompleted && !it.isDiscarded }
                        .minByOrNull { it.startTimeMillis }
                    target?.let { completeOrder(it.id) }
                }
            }
        }
    }

    // 進行中的訂單清單
    private val _activeOrders = MutableStateFlow<List<DeliveryOrder>>(emptyList())
    val activeOrders: StateFlow<List<DeliveryOrder>> = _activeOrders.asStateFlow()
    // 最後一次「復原」之前的樣子，讓誤按復原可以撤銷
    data class RestoreSnapshot(
        val orderId: String,
        val wasCompleted: Boolean,
        val wasDiscarded: Boolean,
        val previousEndTimeMillis: Long?
    )
    private val _lastRestore = MutableStateFlow<RestoreSnapshot?>(null)
    val lastRestore: StateFlow<RestoreSnapshot?> = _lastRestore.asStateFlow()

    // 上一趟結束前的樣子，讓誤觸結束可以「復原上一趟」
    data class FinalizedSnapshot(
        val dateKey: String,
        val batchId: String?,
        val orders: List<DeliveryOrder>,
        val reopenOrderId: String?,
        val orderCount: Int,
        val total: Double
    )
    private val _lastFinalized = MutableStateFlow<FinalizedSnapshot?>(null)
    val lastFinalized: StateFlow<FinalizedSnapshot?> = _lastFinalized.asStateFlow()

    // 歷史每日報表集合 (Key: "yyyy-MM-dd")
    private val _dailyReports = MutableStateFlow<Map<String, DailyReport>>(emptyMap())
    val dailyReports: StateFlow<Map<String, DailyReport>> = _dailyReports.asStateFlow()

    // 每個雙週期的 Uber 實際入帳（Key: 該期起點的毫秒數）
    private val _biweeklyPayouts = MutableStateFlow<Map<String, String>>(emptyMap())
    val biweeklyPayouts: StateFlow<Map<String, String>> = _biweeklyPayouts.asStateFlow()

    // 歷史報表目前選取的日期 (預設今天)
    private val _selectedReportDate = MutableStateFlow(getTodayDateKey())
    val selectedReportDate: StateFlow<String> = _selectedReportDate.asStateFlow()

    // 計時器秒數
    private val _elapsedSeconds = MutableStateFlow(0L)
    val elapsedSeconds: StateFlow<Long> = _elapsedSeconds.asStateFlow()

    // 是否跑單中
    private val _isDelivering = MutableStateFlow(false)
    val isDelivering: StateFlow<Boolean> = _isDelivering.asStateFlow()

    // 時薪設定 (預設 200.0)
    private val _hourlyRate = MutableStateFlow(200.0)
    val hourlyRate: StateFlow<Double> = _hourlyRate.asStateFlow()

    // 即時預估總收入 (工資 + 小費 + 自訂工資)
    private val _totalEarnings = MutableStateFlow(0.0)
    val totalEarnings: StateFlow<Double> = _totalEarnings.asStateFlow()

    // 即時換算時薪 (每小時效益)
    private val _currentHourlyWage = MutableStateFlow(0.0)
    val currentHourlyWage: StateFlow<Double> = _currentHourlyWage.asStateFlow()

    // 批次開始時間戳
    private var batchStartTimeMillis: Long = 0L
    private var timerJob: Job? = null

    // ───────── 一班（上班到下班）的時薪 ─────────
    data class ShiftSnapshot(
        val startMillis: Long,
        val endMillis: Long,
        val isClosed: Boolean,
        val closedByUser: Boolean,
        val wage: Double,
        val orderCount: Int
    ) {
        val hours: Double get() = maxOf(0L, endMillis - startMillis) / 3600000.0
        val hourly: Double? get() = if (hours > 0) wage / hours else null
    }

    private val _shift = MutableStateFlow<ShiftSnapshot?>(null)
    val shift: StateFlow<ShiftSnapshot?> = _shift.asStateFlow()

    private val KEY_SHIFT_OFF = "ShiftOffTimestamp"
    private val KEY_SHIFT_OFF_PREV = "ShiftOffPrevious"
    private var shiftOffMillis: Long = 0L
    private var shiftOffPreviousMillis: Long = 0L
    private var shiftJob: Job? = null
    // ───────── 計時提醒用的小格子（要放在 init 前面）─────────
    private val spokenMilestones = mutableSetOf<String>()
    private var lastTestSecond = -1L
    private val reminderNotifIds = mutableListOf<Int>()
    private var speech: TextToSpeech? = null
    private var speechReady = false

    private val _testMode = MutableStateFlow(false)
    val testMode: StateFlow<Boolean> = _testMode.asStateFlow()

    init {
        loadSavedData()
        // 監聽懸浮窗動作廣播
        val filter = IntentFilter().apply {
            addAction(FloatingTrackerService.ACTION_PICKUP)
            addAction(FloatingTrackerService.ACTION_DELIVER)
            addAction(FloatingTrackerService.ACTION_PICKUP_ORDER)
            addAction(FloatingTrackerService.ACTION_DELIVER_ORDER)
            addAction(FloatingTrackerService.ACTION_SCREENSHOT)
        }
        lbm.registerReceiver(floatingActionReceiver, filter)
        loadShiftOff()
        startShiftTicker()
        initSpeech()
    }

    private fun loadSavedData() {
        val savedRate = prefs.getFloat(KEY_HOURLY_RATE, 200.0f).toDouble()
        _hourlyRate.value = savedRate

        val ordersJson = prefs.getString(KEY_ACTIVE_ORDERS, null)
        if (!ordersJson.isNullOrEmpty()) {
            try {
                val orders = json.decodeFromString<List<DeliveryOrder>>(ordersJson)
                _activeOrders.value = orders
                batchStartTimeMillis = prefs.getLong(KEY_BATCH_START_TIME, 0L)
                val hasUnfinished = orders.any { !it.isCompleted && !it.isDiscarded }
                if (hasUnfinished && batchStartTimeMillis > 0L) {
                    _isDelivering.value = true
                    startTimer()
                } else {
                    recalculateStats()
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        prefs.getString(KEY_PAYOUTS, null)?.let { s ->
            try {
                _biweeklyPayouts.value = json.decodeFromString<Map<String, String>>(s)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        val reportsJson = prefs.getString(KEY_DAILY_REPORTS, null)
        if (!reportsJson.isNullOrEmpty()) {
            try {
                val reports = json.decodeFromString<Map<String, DailyReport>>(reportsJson)
                _dailyReports.value = reports
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    private fun saveData() {
        try {
            val ordersJson = json.encodeToString(_activeOrders.value)
            val reportsJson = json.encodeToString(_dailyReports.value)
            prefs.edit()
                .putString(KEY_ACTIVE_ORDERS, ordersJson)
                .putString(KEY_DAILY_REPORTS, reportsJson)
                .putLong(KEY_BATCH_START_TIME, batchStartTimeMillis)
                .putFloat(KEY_HOURLY_RATE, _hourlyRate.value.toFloat())
                .apply()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    // ───────── 計時提醒：滿 11 分鐘、之後每 10 分鐘，用通知加聲音提醒 ─────────

    /** 5 秒測試：打開後每 5 秒提醒一次 */
    fun setTestMode(on: Boolean) {
        _testMode.value = on
        lastTestSecond = -1L
    }

    private fun initSpeech() {
        speech = TextToSpeech(getApplication<Application>()) { status ->
            if (status == TextToSpeech.SUCCESS) {
                val r = speech?.setLanguage(Locale.TAIWAN) ?: TextToSpeech.ERROR
                speechReady = r != TextToSpeech.LANG_MISSING_DATA && r != TextToSpeech.LANG_NOT_SUPPORTED
            }
        }
    }

    private fun checkReminders() {
        val open = _activeOrders.value.filter { !it.isCompleted && !it.isDiscarded }
        if (open.isEmpty()) return

        // 測試模式：每 5 秒提醒一次
        if (_testMode.value) {
            val sec = _elapsedSeconds.value
            if (sec > 0 && sec % 5L == 0L && sec != lastTestSecond) {
                lastTestSecond = sec
                remind("【測試】外送計時提醒", "目前計時已過 $sec 秒")
            }
            return
        }

        // 同一時間按下去的單算一組：滿 11 分鐘，之後 20、30、40… 分鐘各提醒一次
        val now = System.currentTimeMillis()
        for ((startMillis, group) in open.groupBy { it.startTimeMillis }) {
            val min = ((now - startMillis) / 60_000L).toInt()
            val hit = min == 11 || (min >= 20 && min % 10 == 0)
            if (hit && spokenMilestones.add("$startMillis:$min")) {
                val nums = group.map { it.orderNumber }.sorted().joinToString("、")
                remind("外送時間提醒", "第${nums}單已滿 $min 分鐘")
            }
        }
    }

    private fun remind(title: String, body: String) {
        sendReminderNotification(title, body)
        if (speechReady) speech?.speak(body, TextToSpeech.QUEUE_FLUSH, null, "remind")
    }

    @android.annotation.SuppressLint("MissingPermission")
    private fun sendReminderNotification(title: String, body: String) {
        val app = getApplication<Application>()
        runCatching {
            val channelId = "RemindChannel"
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                val ch = NotificationChannel(channelId, "計時提醒", NotificationManager.IMPORTANCE_HIGH)
                app.getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
            }
            val pi = PendingIntent.getActivity(
                app, 0, Intent(app, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
            )
            val n = NotificationCompat.Builder(app, channelId)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(pi)
                .setAutoCancel(true)
                .build()
            val nid = 2000 + (System.currentTimeMillis() % 100000).toInt()
            reminderNotifIds.add(nid)
            NotificationManagerCompat.from(app).notify(nid, n)
        }
    }

    /** 整趟結束時：把還沒說完的語音和掛著的提醒通知都清掉 */
    private fun stopReminders() {
        speech?.stop()
        val app = getApplication<Application>()
        reminderNotifIds.forEach {
            runCatching { NotificationManagerCompat.from(app).cancel(it) }
        }
        reminderNotifIds.clear()
        spokenMilestones.clear()
        lastTestSecond = -1L
    }

    override fun onCleared() {
        speech?.stop()
        speech?.shutdown()
        super.onCleared()
    }
    private fun startTimer() {
        timerJob?.cancel()
        timerJob = viewModelScope.launch {
            while (isActive) {
                if (batchStartTimeMillis > 0L) {
                    val now = System.currentTimeMillis()
                    _elapsedSeconds.value = maxOf(0L, (now - batchStartTimeMillis) / 1000L)
                    recalculateStats()
                    checkReminders()
                    // 每秒推送即時數據給懸浮窗
                    pushDisplayUpdateToFloating()
                }
                delay(1000L)
            }
        }
    }

    /** 推送即時時薪、計時秒數、進行中最新單號給懸浮窗 */
    private fun pushDisplayUpdateToFloating() {
        val activeOrderNumber = _activeOrders.value
            .filter { !it.isCompleted && !it.isDiscarded }
            .minByOrNull { it.startTimeMillis }
            ?.orderNumber ?: 0
        val intent = Intent(FloatingTrackerService.ACTION_UPDATE_DISPLAY).apply {
            putExtra(FloatingTrackerService.EXTRA_HOURLY_WAGE, _currentHourlyWage.value.toInt())
            putExtra(FloatingTrackerService.EXTRA_ELAPSED_SECONDS, _elapsedSeconds.value)
            putExtra(FloatingTrackerService.EXTRA_ACTIVE_ORDER_NUMBER, activeOrderNumber)
        }
        pushOrderListToFloating()
        lbm.sendBroadcast(intent)
    }

    // ───────── 一班時薪：計算與下班 ─────────

    private fun loadShiftOff() {
        shiftOffMillis = prefs.getLong(KEY_SHIFT_OFF, 0L)
        shiftOffPreviousMillis = prefs.getLong(KEY_SHIFT_OFF_PREV, 0L)
    }

    /** 每秒重算一次這一班的時薪（就算批次碼表停了，這一班還沒下班就繼續算） */
    private fun startShiftTicker() {
        shiftJob?.cancel()
        shiftJob = viewModelScope.launch {
            while (isActive) {
                refreshShift()
                if (timerJob?.isActive != true) pushDisplayUpdateToFloating()
                delay(1000L)
            }
        }
    }

    private fun dateKeyOf(millis: Long): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date(millis))

    /**
     * 算出「目前這一班」：
     * 兩單之間空檔超過 60 分鐘，或你按過下班之後才接的單，就算新的一班。
     */
    private fun computeShift(now: Long): ShiftSnapshot? {
        val all = mutableListOf<DeliveryOrder>()
        for (key in listOf(dateKeyOf(now - 24L * 3600_000L), dateKeyOf(now))) {
            val report = _dailyReports.value[key] ?: continue
            for (batch in report.batches) {
                all.addAll(batch.orders.filter {
                    !it.isDiscarded && !it.isManualEntry && it.endTimeMillis != null
                })
            }
        }
        all.addAll(_activeOrders.value.filter { !it.isDiscarded })

        // 進行中的單，結束時間至少算「接單後 11 分鐘」
        fun endOf(o: DeliveryOrder): Long =
            maxOf(o.endTimeMillis ?: now, o.startTimeMillis + 11 * 60_000L)

        val sorted = all.sortedBy { it.startTimeMillis }
        val first = sorted.firstOrNull() ?: return null

        var session = mutableListOf(first)
        var sessionStart = first.startTimeMillis
        var sessionEnd = endOf(first)

        for (order in sorted.drop(1)) {
            val gapBreak = order.startTimeMillis - sessionEnd > 3_600_000L
            val offBreak = shiftOffMillis > 0L &&
                    shiftOffMillis >= sessionStart &&
                    order.startTimeMillis > shiftOffMillis
            if (gapBreak || offBreak) {
                session = mutableListOf(order)
                sessionStart = order.startTimeMillis
                sessionEnd = endOf(order)
            } else {
                session.add(order)
                sessionEnd = maxOf(sessionEnd, endOf(order))
            }
        }

        val wage = session.sumOf { it.rawOperationWage }

        // 1) 你按了下班
        if (shiftOffMillis > 0L && shiftOffMillis >= sessionStart) {
            return ShiftSnapshot(
                sessionStart, maxOf(shiftOffMillis, sessionEnd),
                isClosed = true, closedByUser = true,
                wage = wage, orderCount = session.size
            )
        }
        // 2) 忘了按下班：最後一張單結束超過 60 分鐘，自動下班
        if (now - sessionEnd > 3_600_000L) {
            return ShiftSnapshot(
                sessionStart, sessionEnd,
                isClosed = true, closedByUser = false,
                wage = wage, orderCount = session.size
            )
        }
        // 3) 這一班進行中
        return ShiftSnapshot(
            sessionStart, maxOf(now, sessionEnd),
            isClosed = false, closedByUser = false,
            wage = wage, orderCount = session.size
        )
    }

    private fun refreshShift() {
        val snap = computeShift(System.currentTimeMillis())
        _shift.value = snap
        _currentHourlyWage.value = snap?.hourly ?: WageSettings.currentHourly
    }

    /** 按下班：停止這一班的時薪計算 */
    fun endShift() {
        shiftOffPreviousMillis = shiftOffMillis
        shiftOffMillis = System.currentTimeMillis()
        prefs.edit()
            .putLong(KEY_SHIFT_OFF, shiftOffMillis)
            .putLong(KEY_SHIFT_OFF_PREV, shiftOffPreviousMillis)
            .apply()
        refreshShift()
    }

    val canUndoEndShift: Boolean
        get() = shiftOffMillis > 0L && System.currentTimeMillis() - shiftOffMillis < 10 * 60_000L

    /** 誤觸下班：10 分鐘內可以取消，繼續計算 */
    fun undoEndShift() {
        if (!canUndoEndShift) return
        shiftOffMillis = shiftOffPreviousMillis
        shiftOffPreviousMillis = 0L
        prefs.edit()
            .putLong(KEY_SHIFT_OFF, shiftOffMillis)
            .putLong(KEY_SHIFT_OFF_PREV, 0L)
            .apply()
        refreshShift()
    }

    /** 把「進行中的單」整份清單推給懸浮球（球上點一下可以切換顯示哪一張） */
    private fun pushOrderListToFloating() {
        val now = System.currentTimeMillis()
        // 有現金單的排最前面，其他依接單順序
        val open = _activeOrders.value
            .filter { !it.isCompleted && !it.isDiscarded }
            .sortedWith(
                compareByDescending<DeliveryOrder> { it.isCashOrder || it.cashToCollect.isNotBlank() }
                    .thenBy { it.startTimeMillis }
            )
        val longest = open.maxOfOrNull { (now - it.startTimeMillis) / 1000L } ?: 0L

        lbm.sendBroadcast(Intent(FloatingTrackerService.ACTION_UPDATE_ORDERS).apply {
            putExtra(FloatingTrackerService.EXTRA_LONGEST_SECONDS, longest)
            putExtra(FloatingTrackerService.EXTRA_TOTAL_EARNINGS, _totalEarnings.value)
            putExtra(FloatingTrackerService.EXTRA_HOURLY_WAGE, _currentHourlyWage.value.toInt())
            putExtra(FloatingTrackerService.EXTRA_ORDER_IDS, open.map { it.id }.toTypedArray())
            putExtra(FloatingTrackerService.EXTRA_ORDER_NUMBERS, open.map { it.orderNumber }.toIntArray())
            putExtra(FloatingTrackerService.EXTRA_ORDER_NOTES, open.map { it.userNote }.toTypedArray())
            putExtra(FloatingTrackerService.EXTRA_ORDER_WAGES, open.map { it.rawOperationWage }.toDoubleArray())
            putExtra(
                FloatingTrackerService.EXTRA_ORDER_CASH,
                open.map {
                    when {
                        it.cashToCollect.isNotBlank() -> it.cashToCollect.trim()
                        it.isCashOrder -> "?"
                        else -> ""
                    }
                }.toTypedArray()
            )
            putExtra(FloatingTrackerService.EXTRA_ORDER_PICKED, open.map { it.pickupTimeMillis != null }.toBooleanArray())
        })
    }
    private fun recalculateStats() {
        val orders = _activeOrders.value
        val validOrders = orders.filter { !it.isDiscarded }

        var earned = 0.0
        for (order in validOrders) {
            val customWage = order.customWageInput.toDoubleOrNull()
            val tip = order.tipInput.toDoubleOrNull() ?: 0.0
            val wage = customWage ?: order.rawOperationWage
            earned += wage + tip
        }

        _totalEarnings.value = earned

        refreshShift()
    }

    /** 沒在跑單就開始計時，已在跑單就加一單，回傳（是不是剛開始、新的那張單） */
    private fun startOrAddOne(): Pair<Boolean, DeliveryOrder?> {
        val all = _activeOrders.value
        val isStart = all.none { !it.isCompleted && !it.isDiscarded }
        if (isStart) {
            if (all.isNotEmpty()) finalizeBatch() // 上一趟先收進日報
            startNewBatch(1)
            // runCatching { GPSLocationManager.instance.startNewDeliverySession() }
        } else {
            addAddOnOrders(1)
        }
        return Pair(isStart, _activeOrders.value.maxByOrNull { it.orderNumber })
    }

    /**
     * 懸浮窗偵測到截圖：
     * 1) 新來單 → 一定是新的一張單，開始計時 / 加單，現金單會提醒
     * 2) 單號畫面 → 補給最早那張還沒單號的單
     * 3) 什麼都沒辨識到 → 還是當作接單，照樣計時
     */
    private fun handleScreenshotFromFloating(
        noteText: String,
        orderCode: String,
        isOffer: Boolean = false,
        isCash: Boolean = false,
        offerSummary: String = "",
        cashAmount: Double = -1.0
    ) {
        val all = _activeOrders.value
        val open = all.filter { !it.isCompleted && !it.isDiscarded }
        val oneLine = noteText.replace("\n", " ")

        // 0) 收取費用畫面：把金額填進現金單
        if (cashAmount > 0) {
            handleCashCollect(cashAmount)
            return
        }

        // 1) 新來單
        if (isOffer) {
            val (isStart, newOrder) = startOrAddOne()
            val head = if (isStart) "⏱ 已開始計時" else "➕ 已加一單"
            val info = if (offerSummary.isNotEmpty()) "（$offerSummary）" else ""
            val cashTip = if (isCash) "\n💵 這是現金單！記得跟客人收錢" else ""
            sendMessageToFloating("$head 訂單 #${newOrder?.orderNumber ?: 1}$info$cashTip")
            return
        }

        // 2) 同一個單號已經在某張單裡 → 不重複
        if (orderCode.isNotEmpty() &&
            all.any { !it.isDiscarded && it.userNote.contains(orderCode, ignoreCase = true) }
        ) {
            sendMessageToFloating("單號 $orderCode 已經在訂單裡了，沒有重複新增")
            return
        }

        // 3) 讀到單號，而且有一張單還沒填單號 → 補給最早那一張
        val emptyOrder = open.sortedBy { it.startTimeMillis }.firstOrNull { it.userNote.trim().isEmpty() }
        if (noteText.isNotEmpty() && emptyOrder != null) {
            updateOrderNote(emptyOrder.id, noteText)
            sendMessageToFloating("✅ 單號填入訂單 #${emptyOrder.orderNumber}：$oneLine")
            return
        }

        // 4) 其他情況：這張截圖就是「接了一張新單」
        val (isStart, newOrder) = startOrAddOne()
        if (newOrder != null && noteText.isNotEmpty()) updateOrderNote(newOrder.id, noteText)

        val head = if (isStart) "⏱ 已開始計時" else "➕ 已加一單"
        val tail = if (noteText.isNotEmpty()) "，單號：$oneLine"
        else "（沒辨識到內容，之後再截有單號的畫面補上）"
        sendMessageToFloating("$head 訂單 #${newOrder?.orderNumber ?: 1}$tail")
    }
    /** 收取費用畫面：把要收的金額填進現金單 */
    private fun handleCashCollect(amount: Double) {
        val text = if (amount % 1.0 == 0.0) amount.toInt().toString() else "%.2f".format(amount)
        val all = _activeOrders.value.filter { !it.isDiscarded }
        if (all.isEmpty()) {
            sendMessageToFloating("💵 讀到要收 \$$text，但目前沒有單，沒有填入")
            return
        }
        // 同樣的金額已經在某張單裡 → 不重複
        all.firstOrNull { it.cashToCollect.trim() == text }?.let {
            sendMessageToFloating("💵 要收 \$$text 已經在訂單 #${it.orderNumber} 裡了")
            return
        }
        val open = all.filter { !it.isCompleted }.sortedBy { it.startTimeMillis }
        val done = all.filter { it.isCompleted }.sortedByDescending { it.endTimeMillis ?: 0L }
        val target =
            open.firstOrNull { it.isCashOrder && it.cashToCollect.isBlank() }
                ?: done.firstOrNull { it.isCashOrder && it.cashToCollect.isBlank() }
                ?: open.firstOrNull { it.cashToCollect.isBlank() }
                ?: done.firstOrNull { it.cashToCollect.isBlank() }
        if (target == null) {
            sendMessageToFloating("💵 讀到要收 \$$text，但每張單都已經有金額，沒有蓋掉")
            return
        }
        updateOrderCash(target.id, text)
        sendMessageToFloating("💵 已填入訂單 #${target.orderNumber} 要收 \$$text")
    }
    private fun sendMessageToFloating(message: String) {
        lbm.sendBroadcast(Intent(FloatingTrackerService.ACTION_SHOW_MESSAGE).apply {
            putExtra(FloatingTrackerService.EXTRA_MESSAGE, message)
        })
    }

    fun startNewBatch(initialOrderCount: Int = 1) {
        // runCatching { com.example.UberDeliveryTracker.location.GPSLocationManager.instance.startNewDeliverySession() }
        val now = System.currentTimeMillis()
        batchStartTimeMillis = now
        _lastFinalized.value = null

        val newOrders = (1..initialOrderCount).map { i ->
            DeliveryOrder(
                orderNumber = i,
                startTimeMillis = now
            )
        }

        _activeOrders.value = newOrders
        _isDelivering.value = true
        _elapsedSeconds.value = 0L

        startTimer()
        saveData()
    }

    fun addAddOnOrders(count: Int = 1) {
        if (count <= 0) return
        val now = System.currentTimeMillis()
        val currentMax = _activeOrders.value.maxOfOrNull { it.orderNumber } ?: 0
        val newOrders = (1..count).map { i ->
            DeliveryOrder(
                orderNumber = currentMax + i,
                startTimeMillis = now
            )
        }
        _activeOrders.value = _activeOrders.value + newOrders
        recalculateStats()
        saveData()
    }

    fun markPickupComplete(orderId: String) {
        val current = _activeOrders.value.toMutableList()
        val index = current.indexOfFirst { it.id == orderId }
        if (index != -1 && current[index].pickupTimeMillis == null) {
            current[index] = current[index].copy(pickupTimeMillis = System.currentTimeMillis())
            _activeOrders.value = current
            saveData()
        }
    }

    fun completeOrder(orderId: String) {
        val current = _activeOrders.value.toMutableList()
        val index = current.indexOfFirst { it.id == orderId }
        if (index != -1) {
            val now = System.currentTimeMillis()
            val target = current[index]
            current[index] = target.copy(
                isCompleted = true,
                endTimeMillis = target.endTimeMillis ?: now
            )
            _activeOrders.value = current
            checkIfAllOrdersDone()
            recalculateStats()
            saveData()
        }
    }

    fun discardOrder(orderId: String) {
        val current = _activeOrders.value.toMutableList()
        val index = current.indexOfFirst { it.id == orderId }
        if (index != -1) {
            val target = current[index]
            current[index] = target.copy(
                isCompleted = true,
                isDiscarded = true,
                endTimeMillis = target.endTimeMillis ?: System.currentTimeMillis()
            )
            _activeOrders.value = current
            checkIfAllOrdersDone()
            recalculateStats()
            saveData()
        }
    }

    fun restoreOrder(orderId: String) {
        val current = _activeOrders.value.toMutableList()
        val index = current.indexOfFirst { it.id == orderId }
        if (index != -1) {
            val target = current[index]
            current[index] = target.copy(
                isCompleted = false,
                isDiscarded = false,
                endTimeMillis = null
            )
            _lastRestore.value = RestoreSnapshot(
                orderId = target.id,
                wasCompleted = target.isCompleted,
                wasDiscarded = target.isDiscarded,
                previousEndTimeMillis = target.endTimeMillis
            )
            _activeOrders.value = current
            _isDelivering.value = true
            // 復原後軌跡也要繼續記錄（不清掉原本的點）
            // runCatching { com.example.UberDeliveryTracker.location.GPSLocationManager.instance.startTracking() }
            if (timerJob == null || !timerJob!!.isActive) {
                startTimer()
            }
            recalculateStats()
            saveData()
        }
    }

    /** 取消上一次的「復原」：那一單改回復原前的樣子（含原本的結束時間） */
    fun undoRestoreOrder() {
        val snap = _lastRestore.value ?: return
        val current = _activeOrders.value.toMutableList()
        val index = current.indexOfFirst { it.id == snap.orderId }
        if (index == -1) {
            _lastRestore.value = null
            return
        }
        current[index] = current[index].copy(
            isCompleted = snap.wasCompleted,
            isDiscarded = snap.wasDiscarded,
            endTimeMillis = snap.previousEndTimeMillis
        )
        _activeOrders.value = current
        _lastRestore.value = null
        checkIfAllOrdersDone()
        recalculateStats()
        saveData()
    }
    fun updateOrderNote(orderId: String, note: String) {
        val current = _activeOrders.value.toMutableList()
        val index = current.indexOfFirst { it.id == orderId }
        if (index != -1) {
            current[index] = current[index].copy(userNote = note)
            _activeOrders.value = current
            saveData()
        }
    }

    fun applyScannedNoteToFirstEmptyOrder(scannedText: String): Boolean {
        val openOrders = _activeOrders.value.filter { !it.isCompleted && !it.isDiscarded }
        val target = openOrders.firstOrNull { it.userNote.trim().isEmpty() }
        return if (target != null) {
            updateOrderNote(target.id, scannedText)
            true
        } else {
            false
        }
    }

    fun updateOrderWage(orderId: String, wage: String) {
        val current = _activeOrders.value.toMutableList()
        val index = current.indexOfFirst { it.id == orderId }
        if (index != -1) {
            current[index] = current[index].copy(customWageInput = wage)
            _activeOrders.value = current
            recalculateStats()
            saveData()
        }
    }

    /** 現金單：要跟客人收多少錢（手動輸入）。填了金額就當作現金單 */
    fun updateOrderCash(orderId: String, cash: String) {
        val current = _activeOrders.value.toMutableList()
        val index = current.indexOfFirst { it.id == orderId }
        if (index != -1) {
            val o = current[index]
            current[index] = o.copy(
                cashToCollect = cash,
                isCashOrder = cash.isNotBlank() || o.isCashOrder
            )
            _activeOrders.value = current
            saveData()
        }
    }

    /** 切換「這是現金單」（金額還不知道時先標記） */
    fun toggleCashOrder(orderId: String) {
        val current = _activeOrders.value.toMutableList()
        val index = current.indexOfFirst { it.id == orderId }
        if (index != -1) {
            val o = current[index]
            current[index] = o.copy(
                isCashOrder = !o.isCashOrder,
                cashToCollect = if (o.isCashOrder) "" else o.cashToCollect
            )
            _activeOrders.value = current
            saveData()
        }
    }
    fun updateOrderTip(orderId: String, tip: String) {
        val current = _activeOrders.value.toMutableList()
        val index = current.indexOfFirst { it.id == orderId }
        if (index != -1) {
            current[index] = current[index].copy(tipInput = tip)
            _activeOrders.value = current
            recalculateStats()
            saveData()
        }
    }

    /**
     * 結束批次並自動歸檔至歷史日報 (DailyReport)
     */
    fun finalizeBatch() {
        val orders = _activeOrders.value
        val validOrders = orders.filter { !it.isDiscarded }
        val todayKey = getTodayDateKey()
        var savedBatchId: String? = null

        if (validOrders.isNotEmpty()) {
            val reports = _dailyReports.value.toMutableMap()
            val existingReport = reports[todayKey] ?: DailyReport(dateString = todayKey)

            val nextBatchNum = (existingReport.batches.maxOfOrNull { it.batchNumber } ?: 0) + 1
            val newBatch = DeliveryBatch(
                batchNumber = nextBatchNum,
                orders = validOrders,
                createdAtMillis = System.currentTimeMillis()
            )
            savedBatchId = newBatch.id

            val updatedBatches = existingReport.batches + newBatch
            reports[todayKey] = existingReport.copy(batches = updatedBatches)
            _dailyReports.value = reports
        }

        if (orders.isNotEmpty()) {
            // 全部單都結束的話，最後結束的那一單，就是復原時要重新打開的那一單
            val allClosed = orders.all { it.isCompleted }
            _lastFinalized.value = FinalizedSnapshot(
                dateKey = todayKey,
                batchId = savedBatchId,
                orders = orders,
                reopenOrderId = if (allClosed) orders.maxByOrNull { it.endTimeMillis ?: 0L }?.id else null,
                orderCount = validOrders.size,
                total = validOrders.sumOf { it.totalOrderEarnings() }
            )
        }

        timerJob?.cancel()
        _isDelivering.value = false
        _activeOrders.value = emptyList()
        _elapsedSeconds.value = 0L
        _totalEarnings.value = 0.0
        _currentHourlyWage.value = 0.0
        stopReminders()
        batchStartTimeMillis = 0L

        saveData()
    }

    /**
     * 手動補單 (加入到指定歷史日期的報表中)
     */
    fun addManualOrder(
        dateKey: String,
        startTimeMillis: Long,
        endTimeMillis: Long,
        customWage: String,
        tip: String,
        note: String
    ) {
        val reports = _dailyReports.value.toMutableMap()
        val report = reports[dateKey] ?: DailyReport(dateString = dateKey)

        val totalOrdersCount = report.batches.sumOf { it.orders.size }
        val newOrder = DeliveryOrder(
            orderNumber = totalOrdersCount + 1,
            startTimeMillis = startTimeMillis,
            endTimeMillis = endTimeMillis,
            isCompleted = true,
            isDiscarded = false,
            customWageInput = customWage,
            tipInput = tip,
            userNote = note,
            isManualEntry = true
        )

        val nextBatchNum = (report.batches.maxOfOrNull { it.batchNumber } ?: 0) + 1
        val newBatch = DeliveryBatch(
            batchNumber = nextBatchNum,
            orders = listOf(newOrder),
            createdAtMillis = startTimeMillis
        )

        reports[dateKey] = report.copy(batches = report.batches + newBatch)
        _dailyReports.value = reports
        saveData()
    }

    /**
     * 更新 Uber 官方實際匯入金額 (供對帳比對)
     */
    fun updateUberActualPayout(dateKey: String, amount: String) {
        val reports = _dailyReports.value.toMutableMap()
        val report = reports[dateKey] ?: DailyReport(dateString = dateKey)
        reports[dateKey] = report.copy(dailyUberActualPayout = amount)
        _dailyReports.value = reports
        saveData()
    }

    /** 修改日報裡某一張歷史單（單號、工資、小費、累計工時） */
    fun updateHistoryOrder(
        dateKey: String,
        batchId: String,
        orderId: String,
        note: String,
        wage: String,
        tip: String,
        minutes: String
    ) {
        val reports = _dailyReports.value.toMutableMap()
        val report = reports[dateKey] ?: return
        reports[dateKey] = report.copy(
            batches = report.batches.map { b ->
                if (b.id != batchId) b else b.copy(
                    orders = b.orders.map { o ->
                        if (o.id != orderId) o else o.copy(
                            userNote = note,
                            customWageInput = wage,
                            tipInput = tip,
                            manualMinutesOverride = minutes
                        )
                    }
                )
            }
        )
        _dailyReports.value = reports
        saveData()
    }

    /** 記下 Uber 那邊顯示的開始時間與歷時（用來比對、補足時間） */
    fun updateBatchUberCompare(
        dateKey: String,
        batchId: String,
        startHour: String,
        startMinute: String,
        durHours: String,
        durMinutes: String,
        durSeconds: String
    ) {
        val reports = _dailyReports.value.toMutableMap()
        val report = reports[dateKey] ?: return
        reports[dateKey] = report.copy(
            batches = report.batches.map { b ->
                if (b.id != batchId) b else b.copy(
                    uberStartTimeHour = startHour,
                    uberStartTimeMinute = startMinute,
                    uberDurationHours = durHours,
                    uberDurationMinutes = durMinutes,
                    uberDurationSeconds = durSeconds
                )
            }
        )
        _dailyReports.value = reports
        saveData()
    }
    /** 刪掉日報裡某一張歷史單；那一批如果空了，整批一起拿掉 */
    fun deleteHistoryOrder(dateKey: String, batchId: String, orderId: String) {
        val reports = _dailyReports.value.toMutableMap()
        val report = reports[dateKey] ?: return
        reports[dateKey] = report.copy(
            batches = report.batches
                .map { b ->
                    if (b.id != batchId) b
                    else b.copy(orders = b.orders.filter { it.id != orderId })
                }
                .filter { it.orders.isNotEmpty() }
        )
        _dailyReports.value = reports
        saveData()
    }

    /** 記下某一個雙週期 Uber 整期實際入帳金額 */
    fun updateBiweeklyPayout(cycleKey: String, amount: String) {
        _biweeklyPayouts.value = _biweeklyPayouts.value + (cycleKey to amount)
        prefs.edit()
            .putString(KEY_PAYOUTS, json.encodeToString(_biweeklyPayouts.value))
            .apply()
    }
    /** 設定某一天「白天班」的出勤狀態 */
    fun updateDayShiftStatus(dateKey: String, status: DayAttendanceStatus) {
        val reports = _dailyReports.value.toMutableMap()
        val old = reports[dateKey]
        // 這天本來沒紀錄、又選「正常」，就什麼都不用存（避免產生空的一天）
        if (old == null && status == DayAttendanceStatus.NORMAL) return
        val report = old ?: DailyReport(dateString = dateKey)
        reports[dateKey] = report.copy(dayShiftStatus = status)
        _dailyReports.value = reports
        saveData()
    }

    /** 設定某一天「晚上班」的出勤狀態 */
    fun updateNightShiftStatus(dateKey: String, status: DayAttendanceStatus) {
        val reports = _dailyReports.value.toMutableMap()
        val old = reports[dateKey]
        if (old == null && status == DayAttendanceStatus.NORMAL) return
        val report = old ?: DailyReport(dateString = dateKey)
        reports[dateKey] = report.copy(nightShiftStatus = status)
        _dailyReports.value = reports
        saveData()
    }

    /** 異常標籤：點一下勾選，再點一下取消 */
    fun toggleAnomalyTag(dateKey: String, tag: AnomalyTag) {
        val reports = _dailyReports.value.toMutableMap()
        val report = reports[dateKey] ?: DailyReport(dateString = dateKey)
        val tags = if (tag in report.anomalyTags) report.anomalyTags - tag
        else report.anomalyTags + tag
        reports[dateKey] = report.copy(anomalyTags = tags)
        _dailyReports.value = reports
        saveData()
    }

    /** 異常事件備註（例：颱風、路封） */
    fun updateAnomalyNote(dateKey: String, note: String) {
        val reports = _dailyReports.value.toMutableMap()
        val report = reports[dateKey] ?: DailyReport(dateString = dateKey)
        reports[dateKey] = report.copy(anomalyNote = note)
        _dailyReports.value = reports
        saveData()
    }

    /** 記下某一天的備註 */
    fun updateDailyNote(dateKey: String, note: String) {
        val reports = _dailyReports.value.toMutableMap()
        val report = reports[dateKey] ?: DailyReport(dateString = dateKey)
        reports[dateKey] = report.copy(dailyNote = note)
        _dailyReports.value = reports
        saveData()
    }

    /** 把一行 CSV 拆成欄位（引號裡的逗號不當分隔） */
    private fun splitCsvLine(line: String): List<String> {
        val out = mutableListOf<String>()
        val sb = StringBuilder()
        var inQuote = false
        for (c in line) {
            when {
                c == '"' -> inQuote = !inQuote
                c == ',' && !inQuote -> { out.add(sb.toString()); sb.clear() }
                else -> sb.append(c)
            }
        }
        out.add(sb.toString())
        return out
    }

    /** 匯入 Uber 收入明細 CSV，把每天的總額填進「Uber 實發」；回傳更新了幾天 */
    fun importUberCSV(csv: String): Int {
        val formats = listOf(
            "yyyy/MM/dd hh:mm a",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd HH:mm:ss"
        ).map { SimpleDateFormat(it, Locale.US).apply { isLenient = false } }
        val keyFmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)

        val dailyTotals = mutableMapOf<String, Double>()
        for (line in csv.removePrefix("\uFEFF").lines().drop(1)) {
            val cols = splitCsvLine(line)
            if (cols.size < 6) continue
            val rawDate = cols[0].trim()
                .replace("上午", "AM").replace("下午", "PM")
            if (rawDate.lowercase().contains("total")) continue
            val amount = cols[5].trim()
                .replace("$", "").replace(",", "").toDoubleOrNull() ?: continue
            val date = formats.firstNotNullOfOrNull { f ->
                runCatching { f.parse(rawDate) }.getOrNull()
            } ?: continue
            val key = keyFmt.format(date)
            dailyTotals[key] = (dailyTotals[key] ?: 0.0) + amount
        }

        if (dailyTotals.isEmpty()) return 0
        val reports = _dailyReports.value.toMutableMap()
        for ((key, total) in dailyTotals) {
            val r = reports[key] ?: DailyReport(dateString = key)
            reports[key] = r.copy(dailyUberActualPayout = "%.1f".format(Locale.US, total))
        }
        _dailyReports.value = reports
        saveData()
        return dailyTotals.size
    }
    /** 更新熊貓實際入帳金額 */
    fun updatePandaActualPayout(dateKey: String, amount: String) {
        val reports = _dailyReports.value.toMutableMap()
        val report = reports[dateKey] ?: DailyReport(dateString = dateKey)
        reports[dateKey] = report.copy(dailyPandaActualPayout = amount)
        _dailyReports.value = reports
        saveData()
    }
    /** 復原上一趟：把剛結束的那一趟從日報拿出來，放回跑單頁繼續計時 */
    fun restoreLastFinalized() {
        val snap = _lastFinalized.value ?: return
        // 從日報拿掉剛存進去的那一批
        val batchId = snap.batchId
        if (batchId != null) {
            val reports = _dailyReports.value.toMutableMap()
            val report = reports[snap.dateKey]
            if (report != null) {
                reports[snap.dateKey] = report.copy(
                    batches = report.batches.filter { it.id != batchId }
                )
                _dailyReports.value = reports
            }
        }
        // 放回跑單頁，最後結束的那一單重新打開
        val restored = snap.orders.map { o ->
            if (o.id == snap.reopenOrderId) {
                o.copy(isCompleted = false, isDiscarded = false, endTimeMillis = null)
            } else o
        }
        _activeOrders.value = restored
        batchStartTimeMillis = restored.minOfOrNull { it.startTimeMillis } ?: System.currentTimeMillis()
        _isDelivering.value = restored.any { !it.isCompleted }
        _lastFinalized.value = null
        _lastRestore.value = null
        // runCatching { GPSLocationManager.instance.startTracking() }
        startTimer()
        recalculateStats()
        saveData()
    }

    /** 不要復原了，把提示收起來 */
    fun dismissLastFinalized() {
        _lastFinalized.value = null
    }
    fun selectReportDate(dateKey: String) {
        _selectedReportDate.value = dateKey
    }

    private fun checkIfAllOrdersDone() {
        val unfinished = _activeOrders.value.any { !it.isCompleted }
        if (!unfinished) {
            _isDelivering.value = false
            // 全部單都結束了，把碼表按停
            timerJob?.cancel()
            timerJob = null
            // 全部單都結束了，軌跡也停止（不再耗電）
            runCatching { com.example.UberDeliveryTracker.location.GPSLocationManager.instance.stopDeliverySession() }
            // 全部單都結束了，自動收進今天的日報（跟 iPhone 版一樣）
            if (_activeOrders.value.isNotEmpty()) finalizeBatch()
        }
    }

    fun setHourlyRate(newRate: Double) {
        if (newRate > 0) {
            _hourlyRate.value = newRate
            recalculateStats()
            saveData()
        }
    }

    /**
     * 將所有歷史報表匯出成標準 CSV 格式字串 (對應 iOS: exportToCSV)
     */
    fun exportReportsToCSVOld(): String {
        val sb = StringBuilder()
        sb.append("日期,批次號,訂單號,開始時間,送達時間,狀態,實收工資,小費,平台單號備註\n")
        val sdf = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())

        val sortedReports = _dailyReports.value.toSortedMap()
        for ((dateKey, report) in sortedReports) {
            for (batch in report.batches) {
                for (order in batch.orders) {
                    val startStr = sdf.format(Date(order.startTimeMillis))
                    val endStr = order.endTimeMillis?.let { sdf.format(Date(it)) } ?: "--"
                    val status = if (order.isDiscarded) "已棄單" else if (order.isCompleted) "已送達" else "未完成"
                    val wage = order.customWageInput.ifEmpty { order.rawOperationWage.toInt().toString() }
                    val tip = order.tipInput.ifEmpty { "0" }
                    val note = order.userNote.replace(",", " ")

                    sb.append("$dateKey,${batch.batchNumber},#${order.orderNumber},$startStr,$endStr,$status,$wage,$tip,$note\n")
                }
            }
        }
        return sb.toString()
    }

    // ───────── CSV 匯出／匯入（格式跟 iPhone 相同） ─────────

    private fun isoFormat() = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
        timeZone = java.util.TimeZone.getTimeZone("UTC")
    }

    /** 匯出全部日報成 CSV 文字（跟 iPhone 版同欄位） */
    fun exportReportsToCSV(): String {
        val sb = StringBuilder("Date,BatchNumber,OrderNumber,StartTime,EndTime,IsDiscarded,CustomWage,Tip\n")
        val iso = isoFormat()
        for ((dateKey, report) in _dailyReports.value.toSortedMap()) {
            for (batch in report.batches) {
                for (order in batch.orders) {
                    val s = iso.format(Date(order.startTimeMillis))
                    val e = order.endTimeMillis?.let { iso.format(Date(it)) } ?: ""
                    val wage = order.customWageInput.replace(",", "")
                    val tip = order.tipInput.replace(",", "")
                    sb.append("$dateKey,${batch.batchNumber},${order.orderNumber},$s,$e,${order.isDiscarded},$wage,$tip\n")
                }
            }
        }
        return sb.toString()
    }

    /** 匯入 CSV，把單子追加進日報；回傳新增了幾張單 */
    fun importFromCSV(csv: String): Int {
        val iso = isoFormat()
        val reports = _dailyReports.value.toMutableMap()
        var added = 0
        for (line in csv.removePrefix("\uFEFF").lines().drop(1)) {
            val cols = line.split(",")
            if (cols.size < 8) continue
            val dateKey = cols[0].trim().replace("\"", "")
            if (dateKey.isEmpty()) continue
            val batchNum = cols[1].trim().toIntOrNull() ?: continue
            val orderNum = cols[2].trim().toIntOrNull() ?: continue
            val start = runCatching { iso.parse(cols[3].trim())!!.time }.getOrNull() ?: continue
            val end = cols[4].trim().takeIf { it.isNotEmpty() }
                ?.let { runCatching { iso.parse(it)!!.time }.getOrNull() }
            val discarded = cols[5].trim().equals("true", ignoreCase = true)
            val wage = cols[6].trim()
            val tip = cols[7].trim()

            val report = reports[dateKey] ?: DailyReport(dateString = dateKey)
            // 同一天已經有開始、結束時間一模一樣的單，就不重複加
            if (report.batches.any { b ->
                    b.orders.any { it.startTimeMillis == start && it.endTimeMillis == end }
                }) continue

            val idx = report.batches.indexOfFirst { it.batchNumber == batchNum }
            val newBatches = if (idx >= 0) {
                val b = report.batches[idx]
                val maxNum = b.orders.maxOfOrNull { it.orderNumber } ?: 0
                val num = if (b.orders.any { it.orderNumber == orderNum }) maxNum + 1 else orderNum
                val o = DeliveryOrder(
                    orderNumber = num, startTimeMillis = start, endTimeMillis = end,
                    isCompleted = true, isDiscarded = discarded,
                    customWageInput = wage, tipInput = tip
                )
                report.batches.toMutableList().also { it[idx] = b.copy(orders = b.orders + o) }
            } else {
                val o = DeliveryOrder(
                    orderNumber = orderNum, startTimeMillis = start, endTimeMillis = end,
                    isCompleted = true, isDiscarded = discarded,
                    customWageInput = wage, tipInput = tip
                )
                report.batches + DeliveryBatch(
                    batchNumber = batchNum, orders = listOf(o), createdAtMillis = start
                )
            }
            reports[dateKey] = report.copy(batches = newBatches)
            added++
        }
        if (added > 0) {
            _dailyReports.value = reports
            saveData()
        }
        return added
    }
    // ───────── 年報：匯出並瘦身 ─────────

    /** 某年某幾個月裡「有單的日子」（今天不算） */
    private fun keysWithOrders(year: Int, startMonth: Int, endMonth: Int): List<String> {
        val today = getTodayDateKey()
        return _dailyReports.value.filter { (key, report) ->
            val y = key.take(4).toIntOrNull()
            val m = key.drop(5).take(2).toIntOrNull()
            key != today && y == year && m != null && m in startMonth..endMonth &&
                    report.batches.any { it.orders.isNotEmpty() }
        }.keys.sorted()
    }

    /** 這段期間有幾天、幾張單（天數, 單數） */
    fun rangeSummary(year: Int, startMonth: Int, endMonth: Int): Pair<Int, Int> {
        val keys = keysWithOrders(year, startMonth, endMonth)
        val orders = keys.sumOf { k ->
            _dailyReports.value[k]?.batches?.sumOf { it.orders.size } ?: 0
        }
        return Pair(keys.size, orders)
    }

    /** 把這段期間的單匯出成 CSV 文字（格式跟整份備份一樣） */
    fun exportRangeToCSV(year: Int, startMonth: Int, endMonth: Int): String {
        val sb = StringBuilder("Date,BatchNumber,OrderNumber,StartTime,EndTime,IsDiscarded,CustomWage,Tip\n")
        val iso = isoFormat()
        for (dateKey in keysWithOrders(year, startMonth, endMonth)) {
            val report = _dailyReports.value[dateKey] ?: continue
            for (batch in report.batches) {
                for (order in batch.orders) {
                    val s = iso.format(Date(order.startTimeMillis))
                    val e = order.endTimeMillis?.let { iso.format(Date(it)) } ?: ""
                    val wage = order.customWageInput.replace(",", "")
                    val tip = order.tipInput.replace(",", "")
                    sb.append("$dateKey,${batch.batchNumber},${order.orderNumber},$s,$e,${order.isDiscarded},$wage,$tip\n")
                }
            }
        }
        return sb.toString()
    }

    /** 刪掉這段期間「有單的日子」；回傳刪了幾天 */
    fun purgeRange(year: Int, startMonth: Int, endMonth: Int): Int {
        val keys = keysWithOrders(year, startMonth, endMonth)
        if (keys.isEmpty()) return 0
        val reports = _dailyReports.value.toMutableMap()
        keys.forEach { reports.remove(it) }
        _dailyReports.value = reports
        saveData()
        return keys.size
    }

    fun getTodayDateKey(): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
        return sdf.format(Date())
    }

    fun formatDuration(totalSec: Long): String {
        val h = totalSec / 3600
        val m = (totalSec % 3600) / 60
        val s = totalSec % 60
        return if (h > 0) {
            String.format(Locale.getDefault(), "%02d:%02d:%02d", h, m, s)
        } else {
            String.format(Locale.getDefault(), "%02d:%02d", m, s)
        }
    }

    fun formatTime(millis: Long?): String {
        if (millis == null) return "--:--"
        val sdf = SimpleDateFormat("HH:mm", Locale.getDefault())
        return sdf.format(Date(millis))
    }
}
