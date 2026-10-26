package com.example.UberDeliveryTracker

import android.app.Application
import com.example.UberDeliveryTracker.location.GPSLocationManager
import com.example.UberDeliveryTracker.model.WageSettings

/**
 * DeliveryApp — 自訂 Application 類別
 *
 * 在 App 啟動最早時機初始化 GPSLocationManager singleton，
 * 讓整個 App 週期內任何地方都可以用 GPSLocationManager.instance 存取。
 */
class DeliveryApp : Application() {
    override fun onCreate() {
        super.onCreate()
        GPSLocationManager.init(applicationContext)
        WageSettings.init(applicationContext)
    }
}
