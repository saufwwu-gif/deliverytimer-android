package com.example.UberDeliveryTracker.location

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.location.Location
import com.google.android.gms.location.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.text.SimpleDateFormat
import java.util.*
import kotlin.math.max

// ============================================================
// GPSPoint a
// ============================================================

@Serializable
data class GPSPoint(
    val id: String = UUID.randomUUID().toString(),
    val latitude: Double,
    val longitude: Double,
    val timestampMillis: Long,
    // 記錄當下速度(公尺/秒)，用來做「開始停留/真的離開」時間點的自動回溯判斷
    val speedMetersPerSecond: Double = 0.0
) {
    val timestamp: Date get() = Date(timestampMillis)

    val speedKmh: Double
        get() = max(0.0, speedMetersPerSecond) * 3.6
}

// ============================================================
// StayPoint (對應 Swift: struct StayPoint)
// ============================================================

data class StayPoint(
    val id: String = UUID.randomUUID().toString(),
    val latitude: Double,
    val longitude: Double,
    val arrivalTimeMillis: Long,
    val departureTimeMillis: Long,
    val isManual: Boolean = false
) {
    val durationSeconds: Int
        get() = ((departureTimeMillis - arrivalTimeMillis) / 1000).toInt()

    val formattedDuration: String
        get() {
            val mins = durationSeconds / 60
            val secs = durationSeconds % 60
            return String.format("%d:%02d", mins, secs)
        }
}

/** 對應 Swift: private struct ManualStayRecord (只用來存檔，不對外曝露) */
@Serializable
private data class ManualStayRecord(
    val latitude: Double,
    val longitude: Double,
    val arrivalTimeMillis: Long,
    val departureTimeMillis: Long
)

// ============================================================
// GPSLocationManager (對應 Swift: class GPSLocationManager)
// ============================================================
// 用法：在 Application 或 MainActivity 的 onCreate 呼叫一次
// GPSLocationManager.init(applicationContext)
// 之後任何地方都用 GPSLocationManager.instance 存取（對應 Swift 的 .shared）

class GPSLocationManager private constructor(context: Context) {

    private val appContext = context.applicationContext
    private val fusedClient: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(appContext)
    private val prefs: SharedPreferences =
        appContext.getSharedPreferences("gps_location_manager", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(Dispatchers.Main)
    private val ioScope = CoroutineScope(Dispatchers.IO)
    // 軌跡點改成「一點一行」寫進檔案，只追加新的一行，不再每次整份重寫
    private val pointsFile: java.io.File by lazy {
        java.io.File(appContext.filesDir, "gps_points_today.jsonl")
    }
    private val json = Json { ignoreUnknownKeys = true }

    private val storageKey = "SavedGPSPoints_Today"
    private val manualStayStorageKey = "SavedManualStayPoints_Today"

    // 手動停留點「真的離開」的判定門檻：距離超過這個值「而且」速度也持續超過門檻，才算真的離開
    private val manualStayDepartureDistanceMeters = 200.0
    private val manualStayDepartureSpeedThresholdKmh = 12.0
    // 判定「已經停下來了」的速度門檻，用來回溯找出忘記按「開始停留」時的真正停留起點
    private val stationarySpeedThresholdKmh = 3.0

    private val _isTracking = MutableStateFlow(false)
    val isTracking: StateFlow<Boolean> = _isTracking.asStateFlow()

    private val _todayPoints = MutableStateFlow<List<GPSPoint>>(emptyList())
    val todayPoints: StateFlow<List<GPSPoint>> = _todayPoints.asStateFlow()

    private val _isManualStayActive = MutableStateFlow(false)
    val isManualStayActive: StateFlow<Boolean> = _isManualStayActive.asStateFlow()

    private val _manualStayPoints = MutableStateFlow<List<StayPoint>>(emptyList())
    val manualStayPoints: StateFlow<List<StayPoint>> = _manualStayPoints.asStateFlow()

    private var manualStayStartTimeMillis: Long? = null
    private var manualStayAnchorLat: Double? = null
    private var manualStayAnchorLng: Double? = null

    private val locationCallback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            val location = result.lastLocation ?: return
            onNewLocation(location)
        }
    }

    init {
        loadPoints()
        loadManualStayPoints()
    }

    companion object {
        @Volatile private var _instance: GPSLocationManager? = null

        /** 對應 Swift: GPSLocationManager.shared 的初始化，App啟動時呼叫一次 */
        fun init(context: Context) {
            if (_instance == null) {
                synchronized(this) {
                    if (_instance == null) {
                        _instance = GPSLocationManager(context)
                    }
                }
            }
        }

        /** 對應 Swift: GPSLocationManager.shared */
        val instance: GPSLocationManager
            get() = _instance
                ?: throw IllegalStateException("GPSLocationManager.init(context) 尚未呼叫過")
    }

    // ------------------------------------------------------------
    // 對應 Swift extension: startNewDeliverySession / stopDeliverySession
    // ------------------------------------------------------------

    fun startNewDeliverySession() {
        deletePointsFile()
        _todayPoints.value = emptyList()
        clearManualStayPoints()
        startTracking()
    }

    /** 停止外送並廣播事件；對應 Swift 的 NotificationCenter deliverySessionDidStop */
    fun stopDeliverySession(onStopped: () -> Unit = {}) {
        stopTracking()
        onStopped()
    }

    // ------------------------------------------------------------
    // 追蹤開關
    // 注意：實際能不能定位，取決於 App 是否已經取得「精確位置」+「背景位置」權限，
    // 這兩個權限必須在 Activity 用 ActivityResultContracts 跟使用者要，
    // 這個class本身不負責跳權限視窗（跟原本Swift的CLLocationManager行為不一樣，
    // Android規定權限請求一定要在Activity層級做）。
    // ------------------------------------------------------------

    @SuppressLint("MissingPermission") // 呼叫端要先確認權限已授予
    fun startTracking() {
        val granted = androidx.core.content.ContextCompat.checkSelfPermission(
            appContext, android.Manifest.permission.ACCESS_FINE_LOCATION
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!granted) return
        applyPowerMode()
        fusedClient.requestLocationUpdates(
            buildLocationRequest(),
            locationCallback,
            android.os.Looper.getMainLooper()
        )
        _isTracking.value = true
    }

    fun stopTracking() {
        fusedClient.removeLocationUpdates(locationCallback)
        _isTracking.value = false
        // 停止追蹤時，如果手動停留還在計時中，直接強制收尾（不管距離），避免整筆消失
        if (_isManualStayActive.value) {
            finalizeManualStay(System.currentTimeMillis())
        }
    }

    /**
     * 省電模式：騎乘移動時用高精度、短間隔；進入「停留」時放寬間隔省電。
     * 對應 Swift 用 activityType 在 .automotiveNavigation / .otherNavigation 之間切換的用意。
     */
    private fun applyPowerMode() {
        if (_isTracking.value) {
            // 重新套用目前模式對應的LocationRequest
            fusedClient.removeLocationUpdates(locationCallback)
            fusedClient.requestLocationUpdates(
                buildLocationRequest(),
                locationCallback,
                android.os.Looper.getMainLooper()
            )
        }
    }

    @SuppressLint("MissingPermission")
    private fun buildLocationRequest(): LocationRequest {
        val priority = if (_isManualStayActive.value) {
            Priority.PRIORITY_BALANCED_POWER_ACCURACY
        } else {
            Priority.PRIORITY_HIGH_ACCURACY
        }
        val intervalMillis = if (_isManualStayActive.value) 30_000L else 8_000L
        return LocationRequest.Builder(priority, intervalMillis)
            .setMinUpdateDistanceMeters(50f)
            .build()
    }

    fun startManualStayPoint(lastKnownLat: Double?, lastKnownLng: Double?) {
        if (_isManualStayActive.value) return
        val anchorLat = lastKnownLat ?: _todayPoints.value.lastOrNull()?.latitude ?: return
        val anchorLng = lastKnownLng ?: _todayPoints.value.lastOrNull()?.longitude ?: return
        _isManualStayActive.value = true
        manualStayStartTimeMillis = System.currentTimeMillis()
        manualStayAnchorLat = anchorLat
        manualStayAnchorLng = anchorLng
        applyPowerMode() // 進入停留，切換省電模式
    }

    private fun onNewLocation(location: Location) {
        val newPoint = GPSPoint(
            latitude = location.latitude,
            longitude = location.longitude,
            timestampMillis = location.time,
            speedMetersPerSecond = max(0.0, location.speed.toDouble())
        )
        _todayPoints.value = _todayPoints.value + newPoint
        appendPoint(newPoint)
        checkManualStayDeparture(location)
    }

    /**
     * 忘記按「結束停留」的補救。距離出發點超過門檻「而且」速度持續超過門檻，
     * 兩個條件都成立才算真的離開，避免在店內走動被誤判成已經出發。
     */
    private fun checkManualStayDeparture(currentLocation: Location) {
        if (!_isManualStayActive.value) return
        val anchorLat = manualStayAnchorLat ?: return
        val anchorLng = manualStayAnchorLng ?: return

        val results = FloatArray(1)
        Location.distanceBetween(anchorLat, anchorLng, currentLocation.latitude, currentLocation.longitude, results)
        val distance = results[0]
        val speedKmh = max(0.0, currentLocation.speed.toDouble()) * 3.6

        if (distance < manualStayDepartureDistanceMeters || speedKmh <= manualStayDepartureSpeedThresholdKmh) return

        val departureTime = backtrackAccelerationStart(
            beforeMillis = currentLocation.time,
            speedThresholdKmh = manualStayDepartureSpeedThresholdKmh
        ) ?: currentLocation.time

        finalizeManualStay(departureTime)
    }

    /** 從指定時間點往前搜尋，找到速度「開始超過」門檻、真正踩下油門離開的那一刻 */
    fun backtrackAccelerationStart(beforeMillis: Long, speedThresholdKmh: Double): Long? {
        val priorPoints = _todayPoints.value.filter { it.timestampMillis <= beforeMillis }
        if (priorPoints.isEmpty()) return null

        var accelerationStart: Long? = null
        for (point in priorPoints.asReversed()) {
            if (point.speedKmh >= speedThresholdKmh) {
                accelerationStart = point.timestampMillis
            } else {
                break
            }
        }
        return accelerationStart
    }

    /** 從指定時間點往前搜尋，找到速度真正掉到門檻以下的那一刻，作為「開始停留」時間 */
    fun backtrackStationaryStart(beforeMillis: Long, speedThresholdKmh: Double = 3.0): Long? {
        val priorPoints = _todayPoints.value.filter { it.timestampMillis <= beforeMillis }
        if (priorPoints.isEmpty()) return null

        var stationaryStart: Long? = null
        for (point in priorPoints.asReversed()) {
            if (point.speedKmh < speedThresholdKmh) {
                stationaryStart = point.timestampMillis
            } else {
                break
            }
        }
        // 找不到「曾經加速過」的分界點，代表整段軌跡都是慢速，用最早的點當起點
        return stationaryStart ?: priorPoints.firstOrNull()?.timestampMillis
    }

    /**
     * 給「取餐/送餐完成」按鈕呼叫的自動補救。如果使用者這趟根本沒按「開始停留」，
     * 就用速度回溯出真正的停留起點，自動幫忙補一筆停留紀錄。
     * 如果同一次停留有好幾張訂單陸續完成，會合併進上一筆紀錄，不會重複開新的一筆。
     */
    fun autoFinalizeStayOnOrderCompletion(completionTimeMillis: Long = System.currentTimeMillis()) {
        if (_isManualStayActive.value) return // 使用者有手動按「開始停留」，走原本離開回溯流程即可

        val stationaryStart = backtrackStationaryStart(completionTimeMillis, stationarySpeedThresholdKmh) ?: return
        if (completionTimeMillis - stationaryStart < 60_000L) return // 停不到1分鐘就不算數，避免紅燈也被補一筆

        val current = _manualStayPoints.value
        val lastIndex = current.lastIndex
        if (lastIndex >= 0 && stationaryStart <= current[lastIndex].departureTimeMillis) {
            // 跟上一筆重疊，代表是同一次停留的另一張訂單，延伸更新既有那筆就好
            val old = current[lastIndex]
            val updated = old.copy(
                arrivalTimeMillis = minOf(old.arrivalTimeMillis, stationaryStart),
                departureTimeMillis = maxOf(old.departureTimeMillis, completionTimeMillis)
            )
            _manualStayPoints.value = current.toMutableList().also { it[lastIndex] = updated }
        } else {
            val point = _todayPoints.value.lastOrNull { it.timestampMillis <= completionTimeMillis }
                ?: _todayPoints.value.lastOrNull() ?: return
            val stay = StayPoint(
                latitude = point.latitude,
                longitude = point.longitude,
                arrivalTimeMillis = stationaryStart,
                departureTimeMillis = completionTimeMillis,
                isManual = true
            )
            _manualStayPoints.value = current + stay
        }
        saveManualStayPoints()
    }

    private fun finalizeManualStay(departureTimeMillis: Long) {
        val anchorLat = manualStayAnchorLat ?: return
        val anchorLng = manualStayAnchorLng ?: return
        val startTime = manualStayStartTimeMillis ?: return

        val stay = StayPoint(
            latitude = anchorLat,
            longitude = anchorLng,
            arrivalTimeMillis = startTime,
            departureTimeMillis = departureTimeMillis,
            isManual = true
        )
        _manualStayPoints.value = _manualStayPoints.value + stay
        saveManualStayPoints()

        _isManualStayActive.value = false
        manualStayStartTimeMillis = null
        manualStayAnchorLat = null
        manualStayAnchorLng = null
        applyPowerMode() // 離開停留了，切回騎乘模式
    }

    // ------------------------------------------------------------
    // 本機儲存（對應 Swift 的 UserDefaults + JSONEncoder/Decoder）
    // ------------------------------------------------------------

    /** 新增一個點：只在檔案最後加一行（在背景做，不卡畫面） */
    private fun appendPoint(point: GPSPoint) {
        val line = json.encodeToString(point)
        ioScope.launch {
            runCatching { pointsFile.appendText(line + "\n") }
        }
    }

    private fun deletePointsFile() {
        runCatching { if (pointsFile.exists()) pointsFile.delete() }
    }

    private fun loadPoints() {
        val fromFile = if (pointsFile.exists()) {
            pointsFile.readLines().mapNotNull { line ->
                if (line.isBlank()) null
                else runCatching { json.decodeFromString<GPSPoint>(line) }.getOrNull()
            }
        } else emptyList()
        if (fromFile.isNotEmpty()) {
            _todayPoints.value = fromFile
            return
        }
        // 舊版存在小抽屜裡的點，搬過來一次
        val raw = prefs.getString(storageKey, null) ?: return
        runCatching { json.decodeFromString<List<GPSPoint>>(raw) }.onSuccess { old ->
            _todayPoints.value = old
            runCatching {
                pointsFile.writeText(old.joinToString("\n") { json.encodeToString(it) } + "\n")
            }
            prefs.edit().remove(storageKey).apply()
        }
    }

    private fun saveManualStayPoints() {
        val records = _manualStayPoints.value.map {
            ManualStayRecord(it.latitude, it.longitude, it.arrivalTimeMillis, it.departureTimeMillis)
        }
        val encoded = json.encodeToString(records)
        prefs.edit().putString(manualStayStorageKey, encoded).apply()
    }

    private fun loadManualStayPoints() {
        val raw = prefs.getString(manualStayStorageKey, null) ?: return
        runCatching { json.decodeFromString<List<ManualStayRecord>>(raw) }
            .onSuccess { records ->
                _manualStayPoints.value = records.map {
                    StayPoint(
                        latitude = it.latitude,
                        longitude = it.longitude,
                        arrivalTimeMillis = it.arrivalTimeMillis,
                        departureTimeMillis = it.departureTimeMillis,
                        isManual = true
                    )
                }
            }
    }

    fun clearManualStayPoints() {
        _manualStayPoints.value = emptyList()
        prefs.edit().remove(manualStayStorageKey).apply()
    }

    fun clearTodayData() {
        deletePointsFile()
        _todayPoints.value = emptyList()
        clearManualStayPoints()
        prefs.edit().remove(storageKey).apply()
    }

    // ------------------------------------------------------------
    // 停留點分群計算（純邏輯，跟平台無關，邏輯與Swift版本完全相同）
    // ------------------------------------------------------------

    fun calculateStayPoints(distanceThresholdMeter: Double = 30.0, minDurationMinutes: Double = 3.0): List<StayPoint> {
        val points = _todayPoints.value
        if (points.size <= 1) return emptyList()

        val stays = mutableListOf<StayPoint>()
        var group = mutableListOf(points[0])

        for (i in 1 until points.size) {
            val p1 = group.first()
            val p2 = points[i]
            val results = FloatArray(1)
            Location.distanceBetween(p1.latitude, p1.longitude, p2.latitude, p2.longitude, results)

            if (results[0] <= distanceThresholdMeter) {
                group.add(p2)
            } else {
                processGroupToStay(group, minDurationMinutes)?.let { stays.add(it) }
                group = mutableListOf(p2)
            }
        }
        processGroupToStay(group, minDurationMinutes)?.let { stays.add(it) }

        return stays
    }

    private fun processGroupToStay(group: List<GPSPoint>, minMinutes: Double): StayPoint? {
        val start = group.firstOrNull() ?: return null
        val end = group.lastOrNull() ?: return null
        val durationMinutes = (end.timestampMillis - start.timestampMillis) / 1000.0 / 60.0

        if (durationMinutes >= minMinutes) {
            val avgLat = group.sumOf { it.latitude } / group.size
            val avgLng = group.sumOf { it.longitude } / group.size
            return StayPoint(
                latitude = avgLat,
                longitude = avgLng,
                arrivalTimeMillis = start.timestampMillis,
                departureTimeMillis = end.timestampMillis
            )
        }
        return null
    }

    // ------------------------------------------------------------
    // 顯示用字串（對應 Swift extension: startTimeString / endTimeString / drivingTimeString）
    // ------------------------------------------------------------

    val startTimeString: String
        get() {
            val first = _todayPoints.value.firstOrNull() ?: return "--:--"
            return SimpleDateFormat("HH:mm", Locale.getDefault()).format(first.timestamp)
        }

    val endTimeString: String
        get() {
            val last = _todayPoints.value.lastOrNull() ?: return "--:--"
            return SimpleDateFormat("HH:mm", Locale.getDefault()).format(last.timestamp)
        }

    val drivingTimeString: String
        get() {
            val first = _todayPoints.value.firstOrNull() ?: return "0 分"
            val last = _todayPoints.value.lastOrNull() ?: return "0 分"
            val totalSeconds = ((last.timestampMillis - first.timestampMillis) / 1000).toInt()
            val hours = totalSeconds / 3600
            val mins = (totalSeconds % 3600) / 60
            return if (hours > 0) "$hours 小時 $mins 分" else "$mins 分"
        }
}
