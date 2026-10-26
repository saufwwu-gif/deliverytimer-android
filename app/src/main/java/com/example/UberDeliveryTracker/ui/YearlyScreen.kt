
package com.example.UberDeliveryTracker.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.UberDeliveryTracker.model.BiweeklyCalc
import com.example.UberDeliveryTracker.model.DailyAverage
import com.example.UberDeliveryTracker.viewmodel.DeliveryTrackerViewModel
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** 一個月的統計 */
private data class MonthRow(
    val month: Int,
    val estimated: Double,
    val uber: Double,
    val panda: Double,
    val orders: Int,
    val summedHours: Double,
    val ridingHours: Double
) {
    val diff: Double get() = uber + panda - estimated
}

@Composable
fun YearlyScreen(
    viewModel: DeliveryTrackerViewModel,
    modifier: Modifier = Modifier
) {
    val reports by viewModel.dailyReports.collectAsState()
    var year by remember { mutableStateOf(Calendar.getInstance().get(Calendar.YEAR)) }

    val rows = remember(year, reports) {
        (1..12).map { m ->
            val prefix = "%04d-%02d-".format(year, m)
            val list = reports.filterKeys { it.startsWith(prefix) }.values
            MonthRow(
                month = m,
                estimated = list.sumOf { it.totalDailyIncome },
                uber = list.sumOf { it.dailyUberActualPayout.toDoubleOrNull() ?: 0.0 },
                panda = list.sumOf { it.dailyPandaActualPayout.toDoubleOrNull() ?: 0.0 },
                orders = list.sumOf { it.totalOrdersCount },
                summedHours = list.sumOf { it.totalSummedMinutes } / 60.0,
                ridingHours = list.sumOf { it.totalActualRidingMinutes } / 60.0
            )
        }
    }

    val yearAverage = remember(year, reports) {
        BiweeklyCalc.averageOf(reports.keys.filter { it.startsWith("$year-") }, reports)
    }
    val recentAverage = remember(reports) {
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
        val today = fmt.format(Date())
        val cutoff = fmt.format(
            Calendar.getInstance().apply { add(Calendar.MONTH, -3) }.time
        )
        BiweeklyCalc.averageOf(reports.keys.filter { it >= cutoff && it <= today }, reports)
    }

    val totalEst = rows.sumOf { it.estimated }
    val totalUber = rows.sumOf { it.uber }
    val totalPanda = rows.sumOf { it.panda }
    val totalDiff = totalUber + totalPanda - totalEst

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        contentPadding = PaddingValues(vertical = 12.dp)
    ) {
        // 年份切換
        item {
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    IconButton(onClick = { year -= 1 }) {
                        Icon(Icons.Default.KeyboardArrowLeft, contentDescription = "前一年")
                    }
                    Text(
                        "$year 年度對帳",
                        fontSize = 20.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = MaterialTheme.colorScheme.primary
                    )
                    IconButton(onClick = { year += 1 }) {
                        Icon(Icons.Default.KeyboardArrowRight, contentDescription = "後一年")
                    }
                }
            }
        }

        // 每天平均
        item {
            Card(modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp)) {
                Column(
                    modifier = Modifier.padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text("每天平均（已排除休假與沒跑的日子）", fontWeight = FontWeight.Bold, fontSize = 13.sp)
                    AvgLine("$year 年平均", yearAverage)
                    AvgLine("近 3 個月基準", recentAverage)
                }
            }
        }

        // 全年總計
        item {
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)
            ) {
                Column(
                    modifier = Modifier.padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("$year 全年總計", fontWeight = FontWeight.ExtraBold, fontSize = 15.sp)
                    YLine("App 估算總收入", "\$%.0f".format(totalEst))
                    YLine("Uber 實發", "\$%.0f".format(totalUber))
                    if (totalPanda > 0) YLine("熊貓實發", "\$%.0f".format(totalPanda))
                    YLine("全年總單數", "${rows.sumOf { it.orders }} 單")
                    YLine(
                        "累計工時 / 騎乘",
                        "%.1f 小時 / %.1f 小時".format(rows.sumOf { it.summedHours }, rows.sumOf { it.ridingHours })
                    )
                    YLine(
                        "全年差額（實發 − 估算）",
                        (if (totalDiff >= 0) "+\$" else "-\$") + "%.0f".format(kotlin.math.abs(totalDiff)),
                        if (totalDiff >= 0) Color(0xFF2E7D32) else Color.Red
                    )
                }
            }
        }

        // 12 個月
        items(rows.size) { i ->
            MonthCard(rows[i])
        }
    }
}

@Composable
private fun MonthCard(row: MonthRow) {
    val actual = row.uber + row.panda
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(10.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("%02d月".format(row.month), fontWeight = FontWeight.Bold, fontSize = 15.sp)
            Column(horizontalAlignment = Alignment.End) {
                Text("估算 \$%.0f".format(row.estimated), fontSize = 12.sp)
                Text("實發 \$%.0f".format(actual), fontSize = 12.sp, fontWeight = FontWeight.Bold)
                if (row.panda > 0) {
                    Text("🐼 \$%.0f".format(row.panda), fontSize = 10.sp, color = Color(0xFF00897B))
                }
            }
            Text(
                if (actual > 0) (if (row.diff >= 0) "+" else "-") + "%.0f".format(kotlin.math.abs(row.diff)) else "-",
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                color = if (actual <= 0) Color.Gray else if (row.diff >= 0) Color(0xFF2E7D32) else Color.Red
            )
            Column(horizontalAlignment = Alignment.End) {
                Text("${row.orders} 單", fontSize = 11.sp)
                Text("%.1f 工".format(row.summedHours), fontSize = 10.sp, color = Color(0xFF1976D2))
                Text("%.1f 騎".format(row.ridingHours), fontSize = 10.sp, color = Color(0xFFEF6C00))
            }
        }
    }
}

@Composable
private fun AvgLine(label: String, avg: DailyAverage) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        if (avg.avgHours != null && avg.avgIncome != null) {
            Text(
                "%.1f 小時／天　\$%.0f／天　(%d 天)".format(avg.avgHours, avg.avgIncome, avg.includedDays),
                fontSize = 12.sp
            )
        } else {
            Text("尚無足夠資料", fontSize = 12.sp, color = Color.Gray)
        }
    }
}

@Composable
private fun YLine(label: String, value: String, valueColor: Color = Color.Unspecified) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, fontSize = 13.sp)
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = valueColor)
    }
}