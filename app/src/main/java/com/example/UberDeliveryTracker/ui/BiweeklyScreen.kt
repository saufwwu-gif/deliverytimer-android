package com.example.UberDeliveryTracker.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.UberDeliveryTracker.model.BiweeklyCalc
import com.example.UberDeliveryTracker.model.BiweeklyDay
import com.example.UberDeliveryTracker.model.DailyAverage
import com.example.UberDeliveryTracker.viewmodel.DeliveryTrackerViewModel
import java.text.SimpleDateFormat
import java.util.Locale

@Composable
fun BiweeklyScreen(
    viewModel: DeliveryTrackerViewModel,
    modifier: Modifier = Modifier
) {
    val reports by viewModel.dailyReports.collectAsState()
    var offset by remember { mutableStateOf(0) }
    val result = remember(offset, reports) { BiweeklyCalc.build(offset, reports) }

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        contentPadding = PaddingValues(vertical = 12.dp)
    ) {
        // 週期切換
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
                    IconButton(onClick = { offset -= 1 }) {
                        Icon(Icons.Default.KeyboardArrowLeft, contentDescription = "上一期")
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("雙週對帳", fontSize = 12.sp, color = Color.Gray)
                        Text(
                            result.title,
                            fontSize = 22.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                    IconButton(onClick = { offset += 1 }) {
                        Icon(Icons.Default.KeyboardArrowRight, contentDescription = "下一期")
                    }
                }
            }
        }

        // 每週平均
        item {
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp)
            ) {
                Column(
                    modifier = Modifier.padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text("每天平均（已排除休假與沒跑的日子）", fontWeight = FontWeight.Bold, fontSize = 13.sp)
                    AverageRow("第一週", result.week1Average)
                    AverageRow("第二週", result.week2Average)
                    AverageRow("過去 8 週基準", result.past8WeeksAverage)
                }
            }
        }

        item {
            Text(
                "提醒：每期算到第二週星期日，星期一凌晨 4 點結算。",
                fontSize = 11.sp,
                color = Color.Gray
            )
        }

        item { Text("第一週", fontWeight = FontWeight.Bold, fontSize = 13.sp, color = Color.Gray) }
        items(result.week1.size) { i ->
            DayRow(result.week1[i], viewModel)
        }

        item { Text("第二週", fontWeight = FontWeight.Bold, fontSize = 13.sp, color = Color.Gray) }
        items(result.week2.size) { i ->
            DayRow(result.week2[i], viewModel)
        }

        // 總計
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
                    Text("本期總計", fontWeight = FontWeight.ExtraBold, fontSize = 15.sp)
                    TotalLine("App 估算", "$${"%.1f".format(result.totalEstimated)}")
                    TotalLine("Uber 實發", "$${"%.1f".format(result.totalUberActual)}")
                    if (result.totalPandaActual > 0) {
                        TotalLine("熊貓實發", "$${"%.1f".format(result.totalPandaActual)}")
                    }
                    val d = result.totalDiff
                    TotalLine(
                        "總差額（實發 − 估算）",
                        (if (d >= 0) "+$" else "-$") + "%.1f".format(kotlin.math.abs(d)),
                        if (d >= 0) Color(0xFF2E7D32) else Color.Red
                    )
                    TotalLine("累計工時 / 騎乘", "%.1f 小時 / %.1f 小時".format(result.totalSummedHours, result.totalRidingHours))
                }
            }
        }
    }
}

@Composable
private fun AverageRow(label: String, avg: DailyAverage) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(label, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        if (avg.avgHours != null && avg.avgIncome != null) {
            Text(
                "%.1f 小時／天　$%.0f／天　(%d 天)".format(avg.avgHours, avg.avgIncome, avg.includedDays),
                fontSize = 12.sp
            )
        } else {
            Text("尚無足夠資料", fontSize = 12.sp, color = Color.Gray)
        }
    }
}

@Composable
private fun TotalLine(label: String, value: String, valueColor: Color = Color.Unspecified) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(label, fontSize = 13.sp)
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = valueColor)
    }
}

@Composable
private fun DayRow(day: BiweeklyDay, viewModel: DeliveryTrackerViewModel) {
    val reports by viewModel.dailyReports.collectAsState()
    val report = reports[day.dateKey]
    val label = remember(day.dateKey) {
        runCatching {
            val p = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).parse(day.dateKey)
            SimpleDateFormat("MM/dd (E)", Locale.getDefault()).format(p!!)
        }.getOrDefault(day.dateKey)
    }
    val totalActual = day.uberActual + day.pandaActual

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier.padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(label, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                Text("估算 $${day.estimated.toInt()}", fontSize = 12.sp)
                Text("實發 $${totalActual.toInt()}", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                val hasActual = totalActual > 0
                Text(
                    if (hasActual) (if (day.diff >= 0) "+" else "-") + kotlin.math.abs(day.diff).toInt() else "-",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (!hasActual) Color.Gray else if (day.diff >= 0) Color(0xFF2E7D32) else Color.Red
                )
                Text(
                    "${day.summedMinutes.toInt()}工/${day.ridingMinutes.toInt()}騎",
                    fontSize = 10.sp,
                    color = Color.Gray
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = report?.dailyUberActualPayout ?: "",
                    onValueChange = { viewModel.updateUberActualPayout(day.dateKey, it) },
                    label = { Text("Uber 實發", fontSize = 10.sp) },
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                    singleLine = true
                )
                OutlinedTextField(
                    value = report?.dailyPandaActualPayout ?: "",
                    onValueChange = { viewModel.updatePandaActualPayout(day.dateKey, it) },
                    label = { Text("🐼 熊貓實發", fontSize = 10.sp) },
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                    singleLine = true
                )
            }
        }
    }
}