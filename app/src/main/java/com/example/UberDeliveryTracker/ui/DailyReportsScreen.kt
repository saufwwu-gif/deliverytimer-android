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