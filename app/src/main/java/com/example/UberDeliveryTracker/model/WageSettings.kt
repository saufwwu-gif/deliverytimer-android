package com.example.UberDeliveryTracker.model

import android.content.Context
import android.content.SharedPreferences
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 一筆費率：從 effectiveDateMillis 這天起，基本費與時薪是多少 */
@Serializable
data class WageRate(
    val id: String = java.util.UUID.randomUUID().toString(),
    val effectiveDateMillis: Long,   // 0 = 起始費率（更早的單都用這個）
    val baseFee: Double,             // 11 分鐘內的固定基本費
    val hourly: Double               // 超過 11 分鐘後，每小時多少
) {
    val isBase: Boolean get() = effectiveDateMillis <= 0L
}

object WageSettings {
    private const val KEY = "wageRateHistory"
    private var prefs: SharedPreferences? = null
    private val json = Json { ignoreUnknownKeys = true }
    private var cache: List<WageRate>? = null

    fun init(context: Context) {
        prefs = context.getSharedPreferences("wage_settings_prefs", Context.MODE_PRIVATE)
    }

    private fun defaultRates() =
        listOf(WageRate(effectiveDateMillis = 0L, baseFee = 45.0, hourly = 245.0))

    var rates: List<WageRate>
        get() {
            cache?.let { return it }
            val raw = prefs?.getString(KEY, null)
            val loaded = if (raw.isNullOrEmpty()) null
            else runCatching { json.decodeFromString<List<WageRate>>(raw) }.getOrNull()
            val result = if (loaded.isNullOrEmpty()) defaultRates() else loaded
            cache = result
            return result
        }
        set(value) {
            val cleaned = value
                .map { it.copy(baseFee = round2(it.baseFee), hourly = round2(it.hourly)) }
                .sortedBy { it.effectiveDateMillis }
            cache = cleaned
            prefs?.edit()?.putString(KEY, json.encodeToString(cleaned))?.apply()
        }

    fun round2(v: Double): Double = Math.round(v * 100.0) / 100.0

    /** 某個時間點適用的費率：生效日 ≤ 該時間 裡面最新的一筆 */
    fun rateAt(millis: Long): WageRate {
        val sorted = rates
        return sorted.lastOrNull { it.effectiveDateMillis <= millis } ?: sorted.first()
    }

    /** 現在適用的時薪 */
    val currentHourly: Double get() = rateAt(System.currentTimeMillis()).hourly

    /** 11 分鐘內固定基本費，超過的部分按時薪算，結果計到小數第二位 */
    fun wage(forMinutes: Double, atMillis: Long): Double {
        val r = rateAt(atMillis)
        val raw = if (forMinutes <= 11.0) r.baseFee
        else r.baseFee + r.hourly * ((forMinutes - 11.0) / 60.0)
        return round2(raw)
    }
}