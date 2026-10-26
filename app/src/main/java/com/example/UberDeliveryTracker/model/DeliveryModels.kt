package com.example.UberDeliveryTracker.model

import kotlinx.serialization.Serializable
import java.util.Date
import java.util.UUID

// ============================================================
// 出勤狀態 / 異常標籤 (對應 Swift: DayAttendanceStatus, AnomalyTag)
// ============================================================

@Serializable
enum class DayAttendanceStatus(val label: String) {
    NORMAL("正常出勤"),
    OFF("休假"),
    ANOMALY("異常");

    companion object {
        val DEFAULT = NORMAL
    }
}

@Serializable
enum class AnomalyTag(val label: String) {
    RAIN("雨天"),
    HOLIDAY("假日"),
    LUNAR_NEW_YEAR("過年"),
    OTHER("其他")
}

// ============================================================
// DeliveryOrder (對應 Swift: struct DeliveryOrder)
// ============================================================

@Serializable
data class DeliveryOrder(
    val id: String = UUID.randomUUID().toString(),
    var orderNumber: Int,
    var startTimeMillis: Long = System.currentTimeMillis(),
    var endTimeMillis: Long? = null,
    // 取餐完成時間，跟 endTime(送達完成)分開記錄
    var pickupTimeMillis: Long? = null,
    var isCompleted: Boolean = false,
    var isDiscarded: Boolean = false,
    var customWageInput: String = "",
    var tipInput: String = "",
    var userNote: String = "", // 存放平台輸入單號
    var isManualEntry: Boolean = false, // 是否為手動補單（非即時 App 計時）
    // 允許手動覆寫「這一單累計工時(分鐘)」。留空字串代表「不覆寫」。
    var manualMinutesOverride: String = "",
    // 現金單：是否為現金單、要跟客人收多少錢（先手動輸入，之後再加截圖規則）
    var isCashOrder: Boolean = false,
    var cashToCollect: String = ""
) {
    val startTime: Date get() = Date(startTimeMillis)
    val endTime: Date? get() = endTimeMillis?.let { Date(it) }
    val pickupTime: Date? get() = pickupTimeMillis?.let { Date(it) }

    /** 已花費的秒數：若尚未結束，用目前時間計算 */
    val recordedSeconds: Double
        get() {
            val referenceEnd = endTimeMillis ?: System.currentTimeMillis()
            return maxOf(0.0, (referenceEnd - startTimeMillis) / 1000.0)
        }

    /** 依實際起訖時間自動算出的分鐘數，不受手動覆寫影響（四捨五入：秒數>=30進位） */
    val autoCalculatedRawOperationMinutes: Int
        get() {
            val totalSec = recordedSeconds.toInt()
            val mins = totalSec / 60
            val secs = totalSec % 60
            return if (secs >= 30) mins + 1 else mins
        }

    fun autoCalculatedAdjustedMinutes(extraSec: Double): Int {
        val totalSec = maxOf(0.0, recordedSeconds + maxOf(0.0, extraSec)).toInt()
        val mins = totalSec / 60
        val secs = totalSec % 60
        return if (secs >= 30) mins + 1 else mins
    }

    /** 解析手動覆寫的分鐘數，非數字或負數一律視為「沒有覆寫」 */
    private val parsedMinutesOverride: Int?
        get() {
            val value = manualMinutesOverride.trim().toIntOrNull() ?: return null
            return if (value >= 0) value else null
        }

    val hasManualMinutesOverride: Boolean
        get() = parsedMinutesOverride != null

    val rawOperationMinutes: Int
        get() = parsedMinutesOverride ?: autoCalculatedRawOperationMinutes

    /** 計費規則：依「接單當天」適用的費率計算（費率可調整，舊單不會被改到） */
    private fun wageForMinutes(totalMinutes: Double): Double {
        return WageSettings.wage(totalMinutes, startTimeMillis)
    }

    val rawOperationWage: Double
        get() {
            if (isDiscarded) return 0.0
            customWageInput.toDoubleOrNull()?.let { return it }
            return wageForMinutes(rawOperationMinutes.toDouble())
        }

    fun adjustedMinutes(extraSec: Double): Int {
        // 有手動覆寫時，直接採用覆寫值，不再疊加batch的補足秒數
        return parsedMinutesOverride ?: autoCalculatedAdjustedMinutes(extraSec)
    }

    fun calculatedAdjustedWage(extraSec: Double): Double {
        if (isDiscarded) return 0.0
        customWageInput.toDoubleOrNull()?.let { return it }
        return wageForMinutes(adjustedMinutes(extraSec).toDouble())
    }

    val tipAmount: Double
        get() {
            if (isDiscarded) return 0.0
            return tipInput.toDoubleOrNull() ?: 0.0
        }

    fun totalOrderEarnings(extraSec: Double = 0.0): Double {
        if (isDiscarded) return 0.0
        return calculatedAdjustedWage(extraSec) + tipAmount
    }
}

// ============================================================
// DeliveryBatch (對應 Swift: struct DeliveryBatch)
// ============================================================

@Serializable
data class DeliveryBatch(
    val id: String = UUID.randomUUID().toString(),
    var batchNumber: Int,
    var orders: List<DeliveryOrder>,
    val createdAtMillis: Long = System.currentTimeMillis(),
    var uberStartTimeHour: String = "",
    var uberStartTimeMinute: String = "",
    var uberDurationHours: String = "",
    var uberDurationMinutes: String = "",
    var uberDurationSeconds: String = ""
) {
    val createdAt: Date get() = Date(createdAtMillis)

    val validOrders: List<DeliveryOrder>
        get() = orders.filter { !it.isDiscarded }

    val uberTotalSeconds: Double
        get() {
            val h = uberDurationHours.toIntOrNull() ?: 0
            val m = uberDurationMinutes.toIntOrNull() ?: 0
            val s = uberDurationSeconds.toIntOrNull() ?: 0
            return (h * 3600 + m * 60 + s).toDouble()
        }

    /** 實際外送騎乘時間：從第一單開始到同一批最後一單完全結束 */
    val appBatchDurationSeconds: Double
        get() {
            val start = orders.minOfOrNull { it.startTimeMillis } ?: return 0.0
            val end = orders.mapNotNull { it.endTimeMillis }.maxOrNull() ?: return 0.0
            return maxOf(0.0, (end - start) / 1000.0)
        }

    /** 每單累計工時加總 (分鐘) */
    val totalSummedMinutes: Double
        get() {
            val extra = estimatedLateStartSeconds
            return validOrders.sumOf { it.adjustedMinutes(extra).toDouble() }
        }

    val estimatedLateStartSeconds: Double
        get() {
            if (uberTotalSeconds <= 0) return 0.0
            val diff = uberTotalSeconds - appBatchDurationSeconds
            return if (diff > 0) diff else 0.0
        }

    val totalRawOperationWage: Double
        get() = orders.sumOf { it.rawOperationWage }

    val totalAdjustedBatchWage: Double
        get() {
            val extra = estimatedLateStartSeconds
            return orders.sumOf { it.calculatedAdjustedWage(extra) }
        }

    val totalBatchTips: Double
        get() = orders.sumOf { it.tipAmount }

    /** 開始時間差字串，例如 "開始時間差: +1分30秒" */
    val startTimeDiffString: String?
        get() {
            val start = orders.minOfOrNull { it.startTimeMillis } ?: return null
            val h = uberStartTimeHour.toIntOrNull() ?: return null
            val m = uberStartTimeMinute.toIntOrNull() ?: return null
            val cal = java.util.Calendar.getInstance().apply {
                timeInMillis = start
                set(java.util.Calendar.HOUR_OF_DAY, h)
                set(java.util.Calendar.MINUTE, m)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }
            val diffSec = ((start - cal.timeInMillis) / 1000.0).toInt()
            val absDiff = kotlin.math.abs(diffSec)
            val sign = if (diffSec >= 0) "+" else "-"
            return "開始時間差: $sign${absDiff / 60}分${absDiff % 60}秒"
        }

    val autoAnalysisResult: String
        get() {
            if (uberTotalSeconds <= 0) return ""
            val diffSec = appBatchDurationSeconds - uberTotalSeconds
            return when {
                diffSec < -10 -> {
                    val lateSec = kotlin.math.abs(diffSec).toInt()
                    "APP紀錄短於 Uber (晚按${lateSec / 60}分${lateSec % 60}秒):已自動為同批每單補足時間。"
                }
                diffSec > 10 -> "APP紀錄長於 Uber: 可能忘記按下結束。"
                else -> "時長比對吻合。"
            }
        }
}

// ============================================================
// DailyReport (對應 Swift: struct DailyReport)
// ============================================================

@Serializable
data class DailyReport(
    val id: String = UUID.randomUUID().toString(),
    val dateString: String,
    var batches: List<DeliveryBatch> = emptyList(),
    var dailyUberActualPayout: String = "",
    var dailyPandaActualPayout: String = "",
    var dailyNote: String = "",
    var dayShiftStatus: DayAttendanceStatus = DayAttendanceStatus.NORMAL,
    var nightShiftStatus: DayAttendanceStatus = DayAttendanceStatus.NORMAL,
    var anomalyTags: List<AnomalyTag> = emptyList(),
    var anomalyNote: String = ""
) {
    val totalRawWage: Double
        get() = batches.sumOf { batch -> batch.validOrders.sumOf { it.rawOperationWage } }

    val totalAdjustedWage: Double
        get() = batches.sumOf { batch ->
            val extra = batch.estimatedLateStartSeconds
            batch.validOrders.sumOf { it.calculatedAdjustedWage(extra) }
        }

    val totalTips: Double
        get() = batches.sumOf { it.totalBatchTips }

    val totalDailyIncome: Double
        get() = totalAdjustedWage + totalTips

    val totalOrdersCount: Int
        get() = batches.sumOf { it.validOrders.size }

    val totalSummedMinutes: Double
        get() = batches.sumOf { it.totalSummedMinutes }

    val totalActualRidingMinutes: Double
        get() = batches.sumOf { it.appBatchDurationSeconds / 60.0 }
}

// ============================================================
// OrderTimerGroup (對應 Swift: struct OrderTimerGroup)
// ============================================================

@Serializable
data class OrderTimerGroup(
    val id: String = UUID.randomUUID().toString(),
    var groupName: String,
    var startTimeMillis: Long = System.currentTimeMillis(),
    var orderIds: List<String>,
    var spokenMilestones: Set<Int> = emptySet()
) {
    val startTime: Date get() = Date(startTimeMillis)

    val recordedSeconds: Double
        get() = maxOf(0.0, (System.currentTimeMillis() - startTimeMillis) / 1000.0)
}
