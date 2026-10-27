package com.example.UberDeliveryTracker.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
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
import com.example.UberDeliveryTracker.model.DailyReport
import com.example.UberDeliveryTracker.model.DeliveryBatch
import com.example.UberDeliveryTracker.model.DeliveryOrder
import com.example.UberDeliveryTracker.viewmodel.DeliveryTrackerViewModel
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DailyReportsScreen(
    viewModel: DeliveryTrackerViewModel,
    onExportCSV: (String) -> Unit = {},
    onImportCSV: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    val dailyReports by viewModel.dailyReports.collectAsState()
    val selectedDateKey by viewModel.selectedReportDate.collectAsState()
    var showManualOrderDialog by remember { mutableStateOf(false) }

    val currentReport = dailyReports[selectedDateKey] ?: DailyReport(dateString = selectedDateKey)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("歷史日報與對帳", fontWeight = FontWeight.Bold) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.onPrimaryContainer
                ),
                actions = {
                    FilledTonalButton(
                        onClick = onImportCSV,
                        modifier = Modifier.padding(end = 4.dp),
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                    ) {
                        Text("📥 匯入CSV", fontSize = 12.sp)
                    }
                    FilledTonalButton(
                        onClick = {
                            val csvData = viewModel.exportReportsToCSV()
                            onExportCSV(csvData)
                        },
                        modifier = Modifier.padding(end = 6.dp),
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                    ) {
                        Text("📁 匯出CSV", fontSize = 12.sp)
                    }
                }
            )
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { showManualOrderDialog = true },
                containerColor = MaterialTheme.colorScheme.primary,
                contentColor = MaterialTheme.colorScheme.onPrimary
            ) {
                Icon(Icons.Default.Add, contentDescription = null)
                Spacer(modifier = Modifier.width(6.dp))
                Text("手動補單", fontWeight = FontWeight.Bold)
            }
        }
    ) { innerPadding ->
        Column(
            modifier = modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // 0. 雙週結算卡（點一下展開）
            BiweeklySummaryCard(viewModel = viewModel, selectedDateKey = selectedDateKey)
            // 1. 日期快速導航列
            DateNavigationBar(
                currentDateKey = selectedDateKey,
                onDateSelected = { viewModel.selectReportDate(it) }
            )

            // 2. 當日彙總與對帳卡片
            DailySummaryCard(
                report = currentReport,
                onUberActualChange = { viewModel.updateUberActualPayout(selectedDateKey, it) }
            )

            // 2.5 每日備註
            OutlinedTextField(
                value = currentReport.dailyNote,
                onValueChange = { viewModel.updateDailyNote(selectedDateKey, it) },
                label = { Text("📝 今日備註（例：下雨、提早收工）", fontSize = 11.sp) },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true
            )
            // 3. 批次與訂單清單
            Text(
                text = "跑單批次明細 (${currentReport.batches.size} 批 / 共 ${currentReport.totalOrdersCount} 單)",
                fontWeight = FontWeight.Bold,
                fontSize = 15.sp
            )

            if (currentReport.batches.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "此日無跑單紀錄\n可點擊右下角「手動補單」新增歷史訂單",
                        color = Color.Gray,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center
                    )
                }
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(currentReport.batches, key = { it.id }) { batch ->
                        BatchCard(batch = batch, dateKey = selectedDateKey, viewModel = viewModel)
                    }
                }
            }
        }
    }

    if (showManualOrderDialog) {
        ManualOrderDialog(
            targetDateKey = selectedDateKey,
            onDismiss = { showManualOrderDialog = false },
            onConfirm = { startMillis, endMillis, wage, tip, note ->
                viewModel.addManualOrder(selectedDateKey, startMillis, endMillis, wage, tip, note)
                showManualOrderDialog = false
            }
        )
    }
}

@Composable
fun DateNavigationBar(
    currentDateKey: String,
    onDateSelected: (String) -> Unit
) {
    val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())

    fun shiftDays(days: Int) {
        try {
            val date = sdf.parse(currentDateKey) ?: Date()
            val cal = Calendar.getInstance().apply {
                time = date
                add(Calendar.DAY_OF_YEAR, days)
            }
            onDateSelected(sdf.format(cal.time))
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

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
            IconButton(onClick = { shiftDays(-1) }) {
                Icon(Icons.Default.KeyboardArrowLeft, contentDescription = "前一天")
            }

            Text(
                text = currentDateKey,
                fontWeight = FontWeight.ExtraBold,
                fontSize = 17.sp,
                color = MaterialTheme.colorScheme.primary
            )

            IconButton(onClick = { shiftDays(1) }) {
                Icon(Icons.Default.KeyboardArrowRight, contentDescription = "後一天")
            }
        }
    }
}

@Composable
fun DailySummaryCard(
    report: DailyReport,
    onUberActualChange: (String) -> Unit
) {
    val totalEarnings = report.totalDailyIncome
    val uberActual = report.dailyUberActualPayout.toDoubleOrNull() ?: 0.0
    val diff = uberActual - totalEarnings

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Column {
                    Text("當日 APP 預估總收益", fontSize = 12.sp, color = Color.Gray)
                    Text(
                        text = "$${totalEarnings.toInt()} 元",
                        fontSize = 26.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = MaterialTheme.colorScheme.primary
                    )
                }
                Column(horizontalAlignment = Alignment.End) {
                    Text("總單數 / 工時", fontSize = 12.sp, color = Color.Gray)
                    Text(
                        text = "${report.totalOrdersCount} 單",
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold
                    )
                }
            }

            Spacer(modifier = Modifier.height(10.dp))
            Divider(color = Color.LightGray.copy(alpha = 0.4f))
            Spacer(modifier = Modifier.height(10.dp))

            // Uber 對帳列
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedTextField(
                    value = report.dailyUberActualPayout,
                    onValueChange = onUberActualChange,
                    label = { Text("Uber 官方實收金額 ($)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                    singleLine = true
                )

                if (report.dailyUberActualPayout.isNotEmpty()) {
                    Column(horizontalAlignment = Alignment.End) {
                        Text("對帳差額", fontSize = 11.sp, color = Color.Gray)
                        Text(
                            text = (if (diff >= 0) "+$" else "-$") + "${kotlin.math.abs(diff).toInt()}",
                            fontWeight = FontWeight.Bold,
                            fontSize = 15.sp,
                            color = if (diff >= 0) Color(0xFF2E7D32) else Color.Red
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun BatchCard(
    batch: DeliveryBatch,
    dateKey: String,
    viewModel: DeliveryTrackerViewModel
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "批次 #${batch.batchNumber}",
                    fontWeight = FontWeight.Bold,
                    fontSize = 15.sp,
                    color = MaterialTheme.colorScheme.primary
                )
                Text(
                    text = "建立時間: ${viewModel.formatTime(batch.createdAtMillis)}",
                    fontSize = 12.sp,
                    color = Color.Gray
                )
            }

            Spacer(modifier = Modifier.height(8.dp))

            BatchSummaryCard(batch = batch, viewModel = viewModel)
            Spacer(modifier = Modifier.height(8.dp))
            UberCompareSection(batch = batch, dateKey = dateKey, viewModel = viewModel)
            Spacer(modifier = Modifier.height(8.dp))
            batch.orders.forEach { order ->
                var editing by remember { mutableStateOf(false) }
                if (editing) {
                    HistoryOrderEditDialog(
                        order = order,
                        onDismiss = { editing = false },
                        onSave = { note, wage, tip, minutes ->
                            viewModel.updateHistoryOrder(dateKey, batch.id, order.id, note, wage, tip, minutes)
                            editing = false
                        },
                        onDelete = {
                            viewModel.deleteHistoryOrder(dateKey, batch.id, order.id)
                            editing = false
                        }
                    )
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { editing = true }
                        .padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("#${order.orderNumber}", fontWeight = FontWeight.Bold, fontSize = 13.sp)
                            if (order.isManualEntry) {
                                Spacer(modifier = Modifier.width(4.dp))
                                Text("(手動補單)", fontSize = 10.sp, color = Color(0xFF1976D2))
                            }
                        }
                        if (order.userNote.isNotEmpty()) {
                            Text(order.userNote, fontSize = 11.sp, color = Color.DarkGray)
                        }
                        Text(
                            text = "${viewModel.formatTime(order.startTimeMillis)} ~ ${viewModel.formatTime(order.endTimeMillis)}",
                            fontSize = 11.sp,
                            color = Color.Gray
                        )
                    }

                    Column(horizontalAlignment = Alignment.End) {
                        val wage = order.customWageInput.toDoubleOrNull() ?: order.rawOperationWage
                        val tip = order.tipInput.toDoubleOrNull() ?: 0.0
                        Text("$${(wage + tip).toInt()} 元", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        if (tip > 0) {
                            Text("含小費 $${tip.toInt()}", fontSize = 10.sp, color = Color(0xFF388E3C))
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun ManualOrderDialog(
    targetDateKey: String,
    onDismiss: () -> Unit,
    onConfirm: (startMillis: Long, endMillis: Long, wage: String, tip: String, note: String) -> Unit
) {
    var wageText by remember { mutableStateOf("") }
    var tipText by remember { mutableStateOf("") }
    var noteText by remember { mutableStateOf("") }

    val nowMillis = System.currentTimeMillis()
    val clockFmt = remember { SimpleDateFormat("HH:mm", Locale.getDefault()) }
    var startText by remember { mutableStateOf(clockFmt.format(Date(nowMillis - 1800000L))) }
    var endText by remember { mutableStateOf(clockFmt.format(Date(nowMillis))) }
    var errorText by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("手動補記歷史訂單") },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text("補單日期: $targetDateKey", fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = startText,
                        onValueChange = { startText = it },
                        label = { Text("開始 (例 18:30)") },
                        modifier = Modifier.weight(1f),
                        singleLine = true
                    )
                    OutlinedTextField(
                        value = endText,
                        onValueChange = { endText = it },
                        label = { Text("結束 (例 19:05)") },
                        modifier = Modifier.weight(1f),
                        singleLine = true
                    )
                }
                Text(
                    "用 24 小時制。實收工資留空的話，會依時間自動估算。結束比開始早，會當作隔天。",
                    fontSize = 11.sp,
                    color = Color.Gray
                )
                if (errorText.isNotEmpty()) {
                    Text(errorText, color = Color.Red, fontSize = 12.sp)
                }

                OutlinedTextField(
                    value = wageText,
                    onValueChange = { wageText = it },
                    label = { Text("實收工資 ($)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )

                OutlinedTextField(
                    value = tipText,
                    onValueChange = { tipText = it },
                    label = { Text("顧客小費 ($)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )

                OutlinedTextField(
                    value = noteText,
                    onValueChange = { noteText = it },
                    label = { Text("平台單號 / 備註") },
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    val dayFmt = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).apply { isLenient = false }
                    val s = runCatching { dayFmt.parse("$targetDateKey ${startText.trim()}") }.getOrNull()
                    val e = runCatching { dayFmt.parse("$targetDateKey ${endText.trim()}") }.getOrNull()
                    if (s == null || e == null) {
                        errorText = "時間格式要像 18:30（24 小時制）"
                        return@Button
                    }
                    var endMillis = e.time
                    if (endMillis <= s.time) endMillis += 24L * 3600_000L
                    onConfirm(s.time, endMillis, wageText, tipText, noteText)
                }
            ) {
                Text("新增補單")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        }
    )
}
// ───────────────────────── 歷史單修改視窗 ─────────────────────────

@Composable
fun HistoryOrderEditDialog(
    order: DeliveryOrder,
    onDismiss: () -> Unit,
    onSave: (note: String, wage: String, tip: String, minutes: String) -> Unit,
    onDelete: () -> Unit
) {
    var note by remember { mutableStateOf(order.userNote) }
    var wage by remember { mutableStateOf(order.customWageInput) }
    var tip by remember { mutableStateOf(order.tipInput) }
    var minutes by remember { mutableStateOf(order.manualMinutesOverride) }
    var confirmDelete by remember { mutableStateOf(false) }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("刪除這張單？") },
            text = { Text("訂單 #${order.orderNumber} 會從日報拿掉，金額也會一起扣掉，無法復原。") },
            confirmButton = {
                Button(
                    onClick = onDelete,
                    colors = ButtonDefaults.buttonColors(containerColor = Color.Red)
                ) { Text("確定刪除") }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text("先不要") }
            }
        )
        return
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("修改訂單 #${order.orderNumber}", fontWeight = FontWeight.Bold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = note,
                    onValueChange = { note = it },
                    label = { Text("平台單號 / 備註") },
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = minutes,
                    onValueChange = { minutes = it },
                    label = { Text("累計工時（分鐘）") },
                    placeholder = { Text("自動 ${order.autoCalculatedRawOperationMinutes}") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = wage,
                        onValueChange = { wage = it },
                        label = { Text("實收工資") },
                        placeholder = { Text("自動估算") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.weight(1f),
                        singleLine = true
                    )
                    OutlinedTextField(
                        value = tip,
                        onValueChange = { tip = it },
                        label = { Text("小費") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.weight(1f),
                        singleLine = true
                    )
                }
                Text(
                    "累計工時、實收工資留空，就用 App 自動算的。填了工資，就以你填的為準。",
                    fontSize = 11.sp,
                    color = Color.Gray
                )
            }
        },
        confirmButton = {
            Button(onClick = { onSave(note.trim(), wage.trim(), tip.trim(), minutes.trim()) }) {
                Text("儲存")
            }
        },
        dismissButton = {
            Row {
                TextButton(onClick = { confirmDelete = true }) {
                    Text("刪除", color = Color.Red)
                }
                TextButton(onClick = onDismiss) { Text("取消") }
            }
        }
    )
}
// ───────────────────────── 趟次小結卡 ─────────────────────────

@Composable
fun BatchSummaryCard(
    batch: DeliveryBatch,
    viewModel: DeliveryTrackerViewModel
) {
    val valid = batch.validOrders
    if (valid.isEmpty()) return

    val extra = batch.estimatedLateStartSeconds
    val minutesList = valid.map { it.adjustedMinutes(extra) }
    val totalMins = minutesList.sum()
    val formula = minutesList.joinToString(" + ") { "${it}分" }
    val ridingMins = (batch.appBatchDurationSeconds / 60.0).toInt()
    val startText = viewModel.formatTime(batch.orders.minOfOrNull { it.startTimeMillis })
    val endText = viewModel.formatTime(batch.orders.mapNotNull { it.endTimeMillis }.maxOrNull())
    val wage = batch.totalAdjustedBatchWage
    val tips = batch.totalBatchTips

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Column(
            modifier = Modifier.padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("趟次小結", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                Text(
                    "共 ${valid.size} 單",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color(0xFFFF9800)
                )
            }

            Column(modifier = Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End) {
                Text("接單 $startText　結束 $endText", fontSize = 11.sp, color = Color.Gray)
                Text(
                    "實際外送騎乘: $ridingMins 分鐘",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color(0xFFFF9800)
                )
            }

            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                valid.chunked(3).forEach { rowOrders ->
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        rowOrders.forEach { o ->
                            val label = if (o.userNote.isEmpty()) "#${o.orderNumber}" else o.userNote
                            Column(
                                modifier = Modifier
                                    .weight(1f)
                                    .background(Color(0x1AFF9800), RoundedCornerShape(8.dp))
                                    .padding(vertical = 6.dp, horizontal = 4.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Text(
                                    label,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold,
                                    maxLines = 2,
                                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                                )
                                Text(
                                    "\$%.0f".format(o.totalOrderEarnings(extra)),
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = Color(0xFF2E7D32)
                                )
                            }
                        }
                        repeat(3 - rowOrders.size) {
                            Spacer(modifier = Modifier.weight(1f))
                        }
                    }
                }
            }

            Divider(color = Color.LightGray.copy(alpha = 0.5f))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text("本趟總收入", fontSize = 11.sp, color = Color.Gray)
                    Text(
                        "\$%.1f".format(wage + tips),
                        fontSize = 18.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = Color(0xFF2E7D32)
                    )
                }
                Text(
                    "車資\$%.1f + 小費\$%.1f".format(wage, tips),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold
                )
            }

            Divider(color = Color.LightGray.copy(alpha = 0.5f))

            Text(
                "每單累計工時: $formula = $totalMins 分鐘",
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = Color(0xFF1976D2)
            )
        }
    }
}
// ───────────────────────── Uber 紀錄對比 ─────────────────────────

@Composable
fun UberCompareSection(
    batch: DeliveryBatch,
    dateKey: String,
    viewModel: DeliveryTrackerViewModel
) {
    fun clean(s: String): String = s.filter { it.isDigit() }.take(2)

    fun save(sh: String, sm: String, dh: String, dm: String, ds: String) {
        viewModel.updateBatchUberCompare(dateKey, batch.id, sh, sm, dh, dm, ds)
    }

    val numberKeys = KeyboardOptions(keyboardType = KeyboardType.Number)
    val small = androidx.compose.ui.text.TextStyle(fontSize = 13.sp)

    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Uber 紀錄對比", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color.Gray)

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text("開始:", fontSize = 12.sp)
            OutlinedTextField(
                value = batch.uberStartTimeHour,
                onValueChange = {
                    save(clean(it), batch.uberStartTimeMinute, batch.uberDurationHours, batch.uberDurationMinutes, batch.uberDurationSeconds)
                },
                label = { Text("時", fontSize = 10.sp) },
                textStyle = small,
                keyboardOptions = numberKeys,
                singleLine = true,
                modifier = Modifier.weight(1f)
            )
            Text(":")
            OutlinedTextField(
                value = batch.uberStartTimeMinute,
                onValueChange = {
                    save(batch.uberStartTimeHour, clean(it), batch.uberDurationHours, batch.uberDurationMinutes, batch.uberDurationSeconds)
                },
                label = { Text("分", fontSize = 10.sp) },
                textStyle = small,
                keyboardOptions = numberKeys,
                singleLine = true,
                modifier = Modifier.weight(1f)
            )
            Spacer(modifier = Modifier.weight(2f))
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text("歷時:", fontSize = 12.sp)
            OutlinedTextField(
                value = batch.uberDurationHours,
                onValueChange = {
                    save(batch.uberStartTimeHour, batch.uberStartTimeMinute, clean(it), batch.uberDurationMinutes, batch.uberDurationSeconds)
                },
                label = { Text("時", fontSize = 10.sp) },
                textStyle = small,
                keyboardOptions = numberKeys,
                singleLine = true,
                modifier = Modifier.weight(1f)
            )
            Text("h", fontSize = 12.sp)
            OutlinedTextField(
                value = batch.uberDurationMinutes,
                onValueChange = {
                    save(batch.uberStartTimeHour, batch.uberStartTimeMinute, batch.uberDurationHours, clean(it), batch.uberDurationSeconds)
                },
                label = { Text("分", fontSize = 10.sp) },
                textStyle = small,
                keyboardOptions = numberKeys,
                singleLine = true,
                modifier = Modifier.weight(1f)
            )
            Text("m", fontSize = 12.sp)
            OutlinedTextField(
                value = batch.uberDurationSeconds,
                onValueChange = {
                    save(batch.uberStartTimeHour, batch.uberStartTimeMinute, batch.uberDurationHours, batch.uberDurationMinutes, clean(it))
                },
                label = { Text("秒", fontSize = 10.sp) },
                textStyle = small,
                keyboardOptions = numberKeys,
                singleLine = true,
                modifier = Modifier.weight(1f)
            )
            Text("s", fontSize = 12.sp)
        }

        batch.startTimeDiffString?.let {
            Text(it, fontSize = 11.sp, color = Color(0xFF1976D2))
        }
        val analysis = batch.autoAnalysisResult
        if (analysis.isNotEmpty()) {
            Text(analysis, fontSize = 11.sp, color = Color(0xFFFF9800))
        }
    }
}
// ───────────────────────── 雙週結算卡 ─────────────────────────

@Composable
fun BiweeklySummaryCard(
    viewModel: DeliveryTrackerViewModel,
    selectedDateKey: String
) {
    val reports by viewModel.dailyReports.collectAsState()
    val payouts by viewModel.biweeklyPayouts.collectAsState()
    val s = remember(selectedDateKey, reports) { BiweeklyCalc.summarize(selectedDateKey, reports) }
    val payoutText = payouts[s.cycleKey] ?: ""
    val payout = payoutText.toDoubleOrNull() ?: 0.0
    val diff = payout - s.totalIncome
    var expanded by remember { mutableStateOf(false) }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { expanded = !expanded },
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("雙週結算 ${s.title}", fontWeight = FontWeight.Bold, fontSize = 13.sp)
                Text(
                    "App預估 \$%.0f".format(s.totalIncome),
                    fontWeight = FontWeight.Bold,
                    fontSize = 13.sp,
                    color = Color(0xFF1976D2)
                )
                Text(if (expanded) "▲" else "▼", fontSize = 12.sp, color = Color.Gray)
            }

            if (expanded) {
                Divider(color = Color.LightGray.copy(alpha = 0.5f))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("完成單數: ${s.orderCount} 單", fontSize = 12.sp)
                    Text(
                        "累計工時: ${s.summedMinutes.toInt()}分",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color(0xFF1976D2)
                    )
                    Text(
                        "騎乘: ${s.ridingMinutes.toInt()}分",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color(0xFFFF9800)
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column {
                        Text("操作估算", fontSize = 10.sp, color = Color.Gray)
                        Text("\$%.1f".format(s.rawWage), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Color.Gray)
                    }
                    Column {
                        Text("補足估算", fontSize = 10.sp, color = Color.Gray)
                        Text("\$%.1f".format(s.adjustedWage), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Color(0xFF2E7D32))
                    }
                    Column {
                        Text("顧客小費", fontSize = 10.sp, color = Color.Gray)
                        Text("+\$%.1f".format(s.tips), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Color(0xFFFF9800))
                    }
                    Column {
                        Text("App預估總額", fontSize = 10.sp, color = Color.Gray)
                        Text("\$%.1f".format(s.totalIncome), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Color(0xFF1976D2))
                    }
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    OutlinedTextField(
                        value = payoutText,
                        onValueChange = { viewModel.updateBiweeklyPayout(s.cycleKey, it) },
                        label = { Text("Uber 整期實際入帳 ($)", fontSize = 11.sp) },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                    if (payout > 0) {
                        Column(horizontalAlignment = Alignment.End) {
                            Text("對帳差額", fontSize = 10.sp, color = Color.Gray)
                            Text(
                                (if (diff >= 0) "+\$" else "-\$") + "%.1f".format(kotlin.math.abs(diff)),
                                fontWeight = FontWeight.Bold,
                                fontSize = 14.sp,
                                color = if (diff >= 0) Color(0xFF2E7D32) else Color.Red
                            )
                        }
                    }
                }
            }
        }
    }
}