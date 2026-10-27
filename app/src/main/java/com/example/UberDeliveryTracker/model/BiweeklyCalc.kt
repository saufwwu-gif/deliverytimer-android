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
    /** 某一期的合計（給日報頂部的結算卡用） */
    data class CycleSummary(
        val cycleKey: String,
        val title: String,
        val orderCount: Int,
        val summedMinutes: Double,
        val ridingMinutes: Double,
        val rawWage: Double,
        val adjustedWage: Double,
        val tips: Double
    ) {
        val totalIncome: Double get() = adjustedWage + tips
    }

    /** 某個時間點落在哪一期，回傳那一期的起點 */
    fun cycleStartContaining(millis: Long): Long {
        val index = Math.floorDiv(millis - anchorMillis(), CYCLE_MS)
        return anchorMillis() + index * CYCLE_MS
    }

    /** 算出「選到的那一天」所屬的雙週，整期到目前為止的合計 */
    fun summarize(selectedDateKey: String, reports: Map<String, DailyReport>): CycleSummary {
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
        val half = 12L * 3600_000L
        val selMillis = runCatching { fmt.parse(selectedDateKey)!!.time }
            .getOrDefault(System.currentTimeMillis()) + half
        val start = cycleStartContaining(selMillis)

        var orders = 0
        var summed = 0.0
        var riding = 0.0
        var raw = 0.0
        var adjusted = 0.0
        var tips = 0.0
        for ((key, r) in reports) {
            val t = runCatching { fmt.parse(key)!!.time }.getOrNull() ?: continue
            if (cycleStartContaining(t + half) != start) continue
            orders += r.totalOrdersCount
            summed += r.totalSummedMinutes
            riding += r.totalActualRidingMinutes
            raw += r.totalRawWage
            adjusted += r.totalAdjustedWage
            tips += r.totalTips
        }
        val mmdd = SimpleDateFormat("MMdd", Locale.getDefault())
        return CycleSummary(
            cycleKey = start.toString(),
            title = "${mmdd.format(Date(start))}-${mmdd.format(Date(start + CYCLE_MS))}",
            orderCount = orders,
            summedMinutes = summed,
            ridingMinutes = riding,
            rawWage = raw,
            adjustedWage = adjusted,
            tips = tips
        )
    }

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

    /**
     * 某一天的「過去 8 週同星期幾基準」：
     * 往前推 7、14、21…56 天，把那些天的估算收入取平均。
     * 有紀錄的天數不到 4 天就不畫基準線（資料太少，免得畫出看起來很準的假線）。
     * （跟 iPhone 版 incomeBaseline 一樣）
     */
    fun incomeBaseline(dateKey: String, reports: Map<String, DailyReport>): Double? {
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
        val base = runCatching { fmt.parse(dateKey)!!.time }.getOrNull() ?: return null
        val amounts = mutableListOf<Double>()
        for (i in 1..8) {
            val key = fmt.format(Date(base + 12L * 3600_000L - 7L * i * DAY_MS))
            reports[key]?.let { amounts.add(it.totalDailyIncome) }
        }
        if (amounts.size < 4) return null
        return amounts.average()
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