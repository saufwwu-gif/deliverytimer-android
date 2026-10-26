package com.example.UberDeliveryTracker.model

import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** 雙週表裡的「一天」 */
data class BiweeklyDay(
    val dateKey: String,        // 例如 2026-10-25
    val estimated: Double,      // App 估算的收入
    val uberActual: Double,     // Uber 實發（沒填就是 0）
    val pandaActual: Double,    // 熊貓實發（沒填就是 0）
    val diff: Double,           // 實發 - 估算
    val summedMinutes: Double,  // 每單累計工時（分鐘）
    val ridingMinutes: Double,  // 實際騎乘（分鐘）
    val hasReport: Boolean
)

/** 每天平均：幾小時、賺多少、用了幾天算 */
data class DailyAverage(
    val avgHours: Double?,
    val avgIncome: Double?,
    val includedDays: Int
)

/** 一整期（14 天）的結果 */
data class BiweeklyResult(
    val title: String,              // 例如 0817-0831
    val cycleStartMillis: Long,
    val week1: List<BiweeklyDay>,
    val week2: List<BiweeklyDay>,
    val totalEstimated: Double,
    val totalUberActual: Double,
    val totalPandaActual: Double,
    val totalDiff: Double,
    val totalSummedHours: Double,
    val totalRidingHours: Double,
    val week1Average: DailyAverage,
    val week2Average: DailyAverage,
    val past8WeeksAverage: DailyAverage
)

object BiweeklyCalc {

    private const val DAY_MS = 24L * 3600_000L
    private const val CYCLE_MS = 14L * DAY_MS

    private fun dateKey(millis: Long): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date(millis))

    /** 第一期的起點：2026/8/17 04:01 */
    private fun anchorMillis(): Long =
        Calendar.getInstance().apply {
            clear()
            set(2026, Calendar.AUGUST, 17, 4, 1, 0)
        }.timeInMillis

    /** offset = 0 是這一期，-1 是上一期，1 是下一期 */
    fun cycleStart(offset: Int, nowMillis: Long = System.currentTimeMillis()): Long {
        val index = Math.floorDiv(nowMillis - anchorMillis(), CYCLE_MS)
        return anchorMillis() + (index + offset) * CYCLE_MS
    }

    fun title(offset: Int, nowMillis: Long = System.currentTimeMillis()): String {
        val start = cycleStart(offset, nowMillis)
        val fmt = SimpleDateFormat("MMdd", Locale.getDefault())
        return "${fmt.format(Date(start))}-${fmt.format(Date(start + CYCLE_MS))}"
    }

    /** 這天有沒有被排除在「平均」之外：沒紀錄，或白天／晚上有一班是休假 */
    private fun isExcluded(report: DailyReport?): Boolean =
        report == null ||
                report.dayShiftStatus == DayAttendanceStatus.OFF ||
                report.nightShiftStatus == DayAttendanceStatus.OFF

    fun averageOf(keys: List<String>, reports: Map<String, DailyReport>): DailyAverage {
        val hours = mutableListOf<Double>()
        val incomes = mutableListOf<Double>()
        for (k in keys) {
            val r = reports[k]
            if (isExcluded(r)) continue
            hours.add(r!!.totalActualRidingMinutes / 60.0)
            incomes.add(r.totalDailyIncome)
        }
        if (hours.isEmpty()) return DailyAverage(null, null, 0)
        return DailyAverage(hours.average(), incomes.average(), hours.size)
    }

    private fun toDay(key: String, reports: Map<String, DailyReport>): BiweeklyDay {
        val r = reports[key]
        val est = r?.totalDailyIncome ?: 0.0
        val actual = r?.dailyUberActualPayout?.toDoubleOrNull() ?: 0.0
        val panda = r?.dailyPandaActualPayout?.toDoubleOrNull() ?: 0.0
        return BiweeklyDay(
            dateKey = key,
            estimated = est,
            uberActual = actual,
            pandaActual = panda,
            diff = actual + panda - est,
            summedMinutes = r?.totalSummedMinutes ?: 0.0,
            ridingMinutes = r?.totalActualRidingMinutes ?: 0.0,
            hasReport = r != null
        )
    }

    fun build(
        offset: Int,
        reports: Map<String, DailyReport>,
        nowMillis: Long = System.currentTimeMillis()
    ): BiweeklyResult {
        val start = cycleStart(offset, nowMillis)
        val keys = (0 until 14).map { dateKey(start + it * DAY_MS) }
        val days = keys.map { toDay(it, reports) }
        val w1 = days.take(7)
        val w2 = days.drop(7)

        // 過去 8 週基準：從這一期起點往前 56 天
        val pastKeys = (1..56).map { dateKey(start - it * DAY_MS) }

        val totalEst = days.sumOf { it.estimated }
        val totalActual = days.sumOf { it.uberActual }
        val totalPanda = days.sumOf { it.pandaActual }
        return BiweeklyResult(
            title = title(offset, nowMillis),
            cycleStartMillis = start,
            week1 = w1,
            week2 = w2,
            totalEstimated = totalEst,
            totalUberActual = totalActual,
            totalPandaActual = totalPanda,
            totalDiff = totalActual + totalPanda - totalEst,
            totalSummedHours = days.sumOf { it.summedMinutes } / 60.0,
            totalRidingHours = days.sumOf { it.ridingMinutes } / 60.0,
            week1Average = averageOf(keys.take(7), reports),
            week2Average = averageOf(keys.drop(7), reports),
            past8WeeksAverage = averageOf(pastKeys, reports)
        )
    }
}