package com.example.UberDeliveryTracker.viewmodel

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import com.example.UberDeliveryTracker.location.GPSLocationManager
import com.example.UberDeliveryTracker.location.GPSPoint
import com.example.UberDeliveryTracker.location.StayPoint
import kotlinx.coroutines.flow.StateFlow

/**
 * GpsMapViewModel
 *
 * 對應 iOS DailyRouteMapView 的 @StateObject locationManager = GPSLocationManager.shared
 * 直接代理 GPSLocationManager.instance 的 StateFlow，讓 Compose 地圖畫面可以 collectAsState()。
 *
 * 額外職責：
 *  - computeAllStayPoints()：自動停留 + 手動停留合併排序（對應 refreshStayPoints）
 *  - startTracking / stopTracking：包裝 manager 呼叫
 *  - clearTodayData：地圖清除按鈕
 *  - 統計字串（startTimeStr / endTimeStr / totalDurationStr）
 */
class GpsMapViewModel(application: Application) : AndroidViewModel(application) {

    private val manager: GPSLocationManager by lazy {
        // 確保 singleton 已被 Application 初始化
        GPSLocationManager.instance
    }

    val isTracking: StateFlow<Boolean> get() = manager.isTracking
    val todayPoints: StateFlow<List<GPSPoint>> get() = manager.todayPoints
    val manualStayPoints: StateFlow<List<StayPoint>> get() = manager.manualStayPoints

    /** 合併自動 + 手動停留點，依到達時間排序 */
    fun computeAllStayPoints(): List<StayPoint> {
        val auto = manager.calculateStayPoints()
        val manual = manager.manualStayPoints.value
        return (auto + manual).sortedBy { it.arrivalTimeMillis }
    }

    fun startTracking() = manager.startTracking()
    fun stopTracking()  = manager.stopTracking()

    fun clearTodayData() = manager.clearTodayData()

    val startTimeStr: String get() = manager.startTimeString
    val endTimeStr:   String get() = manager.endTimeString
    val totalDurationStr: String get() = manager.drivingTimeString
}
