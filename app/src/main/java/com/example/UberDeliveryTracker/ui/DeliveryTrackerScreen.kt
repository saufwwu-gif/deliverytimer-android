package com.example.UberDeliveryTracker.ui

import android.content.Intent
import android.provider.Settings
import android.widget.Toast
import androidx.compose.ui.platform.LocalContext
import com.example.UberDeliveryTracker.floating.ScreenshotAccessibilityService
import com.example.UberDeliveryTracker.floating.ScreenCaptureService
import com.example.UberDeliveryTracker.floating.CapturePermissionActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import com.example.UberDeliveryTracker.model.WageRate
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.UberDeliveryTracker.location.GPSLocationManager
import com.example.UberDeliveryTracker.model.DeliveryOrder
import com.example.UberDeliveryTracker.model.WageSettings
import com.example.UberDeliveryTracker.viewmodel.DeliveryTrackerViewModel

private fun formatClock(sec: Long): String {
    val s = maxOf(0L, sec)
    val h = s / 3600
    val m = (s % 3600) / 60
    val r = s % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, r) else "%02d:%02d".format(m, r)
}

@Composable
fun DeliveryTrackerScreen(
    viewModel: DeliveryTrackerViewModel,
    onToggleFloatingWindow: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    val activeOrders by viewModel.activeOrders.collectAsState()
    val isDelivering by viewModel.isDelivering.collectAsState()
    val elapsedSeconds by viewModel.elapsedSeconds.collectAsState()
    val totalEarnings by viewModel.totalEarnings.collectAsState()
    val currentHourlyWage by viewModel.currentHourlyWage.collectAsState()
    val shift by viewModel.shift.collectAsState()

    var showEstimatorDialog by remember { mutableStateOf(false) }
    var summaryExpanded by remember { mutableStateOf(false) }
    var actionsVisible by remember { mutableStateOf(true) }
    var showWageDialog by remember { mutableStateOf(false) }
    val ctx = LocalContext.current
    val a11yOn by ScreenshotAccessibilityService.readyFlow.collectAsState()
    var showA11yOffConfirm by remember { mutableStateOf(false) }
    val captureOn by ScreenCaptureService.readyFlow.collectAsState()

    val target = shift?.takeIf { !it.isClosed }?.hourly ?: WageSettings.currentHourly
    val hasOpen = activeOrders.any { !it.isCompleted && !it.isDiscarded }

    // 沒在跑單就開始新的一趟，已在跑單就加單
    val startOrAdd: (Int) -> Unit = { n ->
        if (hasOpen) {
            viewModel.addAddOnOrders(n)
        } else {
            if (activeOrders.isNotEmpty()) viewModel.finalizeBatch()
            viewModel.startNewBatch(n)
            runCatching { GPSLocationManager.instance.startNewDeliverySession() }
        }
    }

    val sortedOrders = activeOrders.sortedWith(
        compareBy<DeliveryOrder> { it.isCompleted }
            .thenByDescending { it.endTimeMillis ?: Long.MAX_VALUE }
    )

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        // ── 超薄標題列 ──
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Text(
                "跑單",
                fontSize = 20.sp,
                fontWeight = FontWeight.ExtraBold,
                modifier = Modifier.weight(1f)
            )
            OutlinedButton(
                onClick = { showEstimatorDialog = true },
                modifier = Modifier.height(32.dp),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)
            ) { Text("⚖️ 試算", fontSize = 12.sp) }
            FilledTonalButton(
                onClick = onToggleFloatingWindow,
                modifier = Modifier.height(32.dp),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)
            ) { Text("⚡ 懸浮", fontSize = 12.sp) }
            OutlinedButton(
                onClick = {
                    if (a11yOn) {
                        showA11yOffConfirm = true
                    } else {
                        Toast.makeText(
                            ctx,
                            "請在下一頁找到「薪水計時 截圖助手」，點進去打開",
                            Toast.LENGTH_LONG
                        ).show()
                        ctx.startActivity(
                            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }
                },
                modifier = Modifier.height(32.dp),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)
            ) { Text(if (a11yOn) "🟢 無障礙" else "⚪ 無障礙", fontSize = 12.sp) }
            OutlinedButton(
                onClick = {
                    if (captureOn) {
                        ctx.startService(
                            Intent(ctx, ScreenCaptureService::class.java)
                                .setAction(ScreenCaptureService.ACTION_STOP)
                        )
                    } else {
                        Toast.makeText(
                            ctx,
                            "手機會問你要不要錄製畫面，請選「整個螢幕」再按開始",
                            Toast.LENGTH_LONG
                        ).show()
                        ctx.startActivity(Intent(ctx, CapturePermissionActivity::class.java))
                    }
                },
                modifier = Modifier.height(32.dp),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)
            ) { Text(if (captureOn) "🟢 錄影" else "⚪ 錄影", fontSize = 12.sp) }
            if (isDelivering || activeOrders.isNotEmpty()) {
                TextButton(
                    onClick = { viewModel.finalizeBatch() },
                    modifier = Modifier.height(32.dp),
                    contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp)
                ) {
                    Text("結束批次", color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
                }
            }
        }

        // ── 一條小摘要（點一下展開「這一班」詳細資料）──
        CompactSummary(
            elapsedText = viewModel.formatDuration(elapsedSeconds),
            totalEarnings = totalEarnings,
            hourly = currentHourlyWage,
            targetHourly = target,
            activeCount = activeOrders.count { !it.isCompleted && !it.isDiscarded },
            completedCount = activeOrders.count { it.isCompleted && !it.isDiscarded },
            expanded = summaryExpanded,
            onToggle = { summaryExpanded = !summaryExpanded }
        )
        if (summaryExpanded) {
            ShiftCard(
                shift = shift,
                baseHourly = WageSettings.currentHourly,
                canUndo = viewModel.canUndoEndShift,
                onEndShift = { viewModel.endShift() },
                onUndo = { viewModel.undoEndShift() },
                onOpenWageSettings = { showWageDialog = true }
            )
        }

        // ── 開始 / 加單按鈕（可收起）──
        ActionRow(
            hasOpen = hasOpen,
            visible = actionsVisible,
            onToggle = { actionsVisible = !actionsVisible },
            onPick = startOrAdd
        )

        // ── 訂單清單 ──
        if (activeOrders.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "目前沒有訂單\n點上方「開始」，或用手機截圖接單",
                    color = Color.Gray,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                )
            }
        } else {
            Text(
                text = "訂單 (${activeOrders.size})",
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = Color.Gray
            )
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = PaddingValues(bottom = 12.dp)
            ) {
                items(items = sortedOrders, key = { it.id }) { order ->
                    OrderCard(
                        order = order,
                        tick = elapsedSeconds,
                        viewModel = viewModel
                    )
                }
            }
        }
    }

    if (showA11yOffConfirm) {
        AlertDialog(
            onDismissRequest = { showA11yOffConfirm = false },
            title = { Text("關閉無障礙？") },
            text = {
                Text("關閉後，球上的相機鈕就不能用了。請改用手機自己的截圖（電源鍵＋音量下），App 會自動辨識。要再打開，需要到手機設定自己點開關。")
            },
            confirmButton = {
                Button(onClick = {
                    ScreenshotAccessibilityService.instance?.disableSelf()
                    showA11yOffConfirm = false
                    Toast.makeText(ctx, "無障礙已關閉", Toast.LENGTH_SHORT).show()
                }) { Text("關閉") }
            },
            dismissButton = {
                TextButton(onClick = { showA11yOffConfirm = false }) { Text("先不要") }
            }
        )
    }

    if (showWageDialog) {
        WageSettingsDialog(onDismiss = { showWageDialog = false })
    }
    if (showEstimatorDialog) {
        OrderEstimatorDialog(
            targetHourlyRate = target,
            onDismiss = { showEstimatorDialog = false },
            onAcceptOrder = {
                startOrAdd(1)
                showEstimatorDialog = false
            }
        )
    }
}

// ───────────────────────── 一條小摘要 ─────────────────────────

@Composable
fun CompactSummary(
    elapsedText: String,
    totalEarnings: Double,
    hourly: Double,
    targetHourly: Double,
    activeCount: Int,
    completedCount: Int,
    expanded: Boolean,
    onToggle: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onToggle() },
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                SummaryStat("已跑", elapsedText, MaterialTheme.colorScheme.primary)
                SummaryStat("預估收入", "$${totalEarnings.toInt()}", Color(0xFF2E7D32))
                SummaryStat("時薪", "$${hourly.toInt()}", MaterialTheme.colorScheme.tertiary)
                Text(if (expanded) "▲" else "▼", color = Color.Gray, fontSize = 14.sp)
            }
            Spacer(modifier = Modifier.height(2.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    "進行中 $activeCount ｜ 已完成 $completedCount",
                    fontSize = 11.sp,
                    color = Color.DarkGray
                )
                Text(
                    "10 分鐘的單至少 ${(targetHourly / 6.0).toInt()} 元",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color(0xFFEF6C00)
                )
            }
        }
    }
}

@Composable
fun SummaryStat(label: String, value: String, valueColor: Color) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, fontSize = 10.sp, color = Color.Gray)
        Text(value, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold, color = valueColor)
    }
}

// ───────────────────────── 開始 / 加單（可收起）─────────────────────────

@Composable
fun ActionRow(
    hasOpen: Boolean,
    visible: Boolean,
    onToggle: () -> Unit,
    onPick: (Int) -> Unit
) {
    if (!visible) {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(
                onClick = onToggle,
                modifier = Modifier.height(28.dp),
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
            ) {
                Text("▼ 展開按鈕（${if (hasOpen) "加單" else "開始"}）", fontSize = 12.sp)
            }
        }
    } else {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                if (hasOpen) "加單" else "開始",
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold
            )
            for (n in 1..3) {
                val label = if (hasOpen) "+$n 單" else "$n 單"
                FilledTonalButton(
                    onClick = { onPick(n) },
                    modifier = Modifier
                        .weight(1f)
                        .height(36.dp),
                    shape = RoundedCornerShape(10.dp),
                    contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp)
                ) {
                    Text(label, fontSize = 13.sp)
                }
            }
            TextButton(
                onClick = onToggle,
                modifier = Modifier.height(36.dp),
                contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp)
            ) {
                Text("收起 ▲", fontSize = 12.sp)
            }
        }
    }
}

// ───────────────────────── 訂單卡片（精簡版）─────────────────────────

@Composable
fun OrderCard(
    order: DeliveryOrder,
    tick: Long,            // 每秒變一次，讓金額和計時跟著跳
    viewModel: DeliveryTrackerViewModel
) {
    var editing by remember { mutableStateOf(false) }

    val cardBg = when {
        order.isDiscarded -> Color(0xFFFFEBEE)
        order.isCompleted -> Color(0xFFE8F5E9)
        else -> MaterialTheme.colorScheme.surface
    }
    val statusText = when {
        order.isDiscarded -> "已棄單"
        order.isCompleted -> "已送達"
        order.pickupTimeMillis != null -> "送餐中"
        else -> "前往取餐"
    }
    val statusColor = when {
        order.isDiscarded -> Color.Red
        order.isCompleted -> Color(0xFF2E7D32)
        else -> MaterialTheme.colorScheme.primary
    }
    val nowMillis = System.currentTimeMillis()
    val runSeconds = ((order.endTimeMillis ?: nowMillis) - order.startTimeMillis) / 1000L

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = cardBg),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(
            modifier = Modifier.padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            // 第一行：編號、狀態、已跑時間、這張單的預估金額
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Surface(
                        color = MaterialTheme.colorScheme.primary,
                        shape = RoundedCornerShape(6.dp)
                    ) {
                        Text(
                            text = "#${order.orderNumber}",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            fontSize = 13.sp,
                            modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp)
                        )
                    }
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(statusText, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = statusColor)
                    if (!order.isCompleted) {
                        Spacer(modifier = Modifier.width(6.dp))
                        Text("⏱ ${formatClock(runSeconds)}", fontSize = 13.sp, color = Color.DarkGray)
                    }
                }
                Text(
                    text = "\$%.2f".format(order.totalOrderEarnings()),
                    fontSize = 16.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = Color(0xFF2E7D32)
                )
            }

            // 第二行：單號（點一下可編輯）、預估分鐘、接單時間
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { editing = !editing },
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                val blank = order.userNote.isBlank()
                Text(
                    text = if (blank) "（尚未填單號，點這裡編輯）" else order.userNote.replace("\n", " "),
                    fontSize = 13.sp,
                    color = if (blank) Color.Gray else MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "${order.rawOperationMinutes} 分｜接單 ${viewModel.formatTime(order.startTimeMillis)}",
                    fontSize = 11.sp,
                    color = Color.Gray
                )
            }

            // 編輯區（平常收起來）
            if (editing) {
                OutlinedTextField(
                    value = order.userNote,
                    onValueChange = { viewModel.updateOrderNote(order.id, it) },
                    label = { Text("平台單號 / 顧客資訊") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedTextField(
                        value = order.customWageInput,
                        onValueChange = { viewModel.updateOrderWage(order.id, it) },
                        label = { Text("實收工資") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.weight(1f),
                        singleLine = true
                    )
                    OutlinedTextField(
                        value = order.tipInput,
                        onValueChange = { viewModel.updateOrderTip(order.id, it) },
                        label = { Text("小費") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.weight(1f),
                        singleLine = true
                    )
                }
            }

            CashFieldRow(order = order, viewModel = viewModel)
            Spacer(modifier = Modifier.height(8.dp))
            // 第三行：操作按鈕
            if (!order.isCompleted) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    if (order.pickupTimeMillis == null) {
                        Button(
                            onClick = { viewModel.markPickupComplete(order.id) },
                            modifier = Modifier
                                .weight(1f)
                                .height(38.dp),
                            shape = RoundedCornerShape(8.dp),
                            contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp)
                        ) { Text("取餐", fontSize = 13.sp) }
                    }
                    Button(
                        onClick = { viewModel.completeOrder(order.id) },
                        modifier = Modifier
                            .weight(1f)
                            .height(38.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF2E7D32)),
                        shape = RoundedCornerShape(8.dp),
                        contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp)
                    ) { Text("送達", fontSize = 13.sp) }
                    OutlinedButton(
                        onClick = { viewModel.discardOrder(order.id) },
                        modifier = Modifier
                            .weight(0.8f)
                            .height(38.dp),
                        shape = RoundedCornerShape(8.dp),
                        contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp)
                    ) { Text("棄單", fontSize = 13.sp, color = Color.Red) }
                    TextButton(
                        onClick = { editing = !editing },
                        modifier = Modifier.height(38.dp),
                        contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp)
                    ) { Text(if (editing) "收起" else "編輯", fontSize = 12.sp) }
                }
            } else {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "送達 ${viewModel.formatTime(order.endTimeMillis)}",
                        fontSize = 12.sp,
                        color = Color.DarkGray
                    )
                    Row {
                        TextButton(
                            onClick = { viewModel.restoreOrder(order.id) },
                            modifier = Modifier.height(32.dp),
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
                        ) { Text("復原", fontSize = 12.sp) }
                        TextButton(
                            onClick = { editing = !editing },
                            modifier = Modifier.height(32.dp),
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
                        ) { Text(if (editing) "收起" else "編輯", fontSize = 12.sp) }
                    }
                }
            }
        }
    }
}

// ───────────────────────── 接單試算視窗 ─────────────────────────

@Composable
fun OrderEstimatorDialog(
    targetHourlyRate: Double,
    onDismiss: () -> Unit,
    onAcceptOrder: (wage: Double) -> Unit
) {
    var minutesText by remember { mutableStateOf("20") }
    var priceText by remember { mutableStateOf("70") }

    val minutes = minutesText.toDoubleOrNull() ?: 0.0
    val price = priceText.toDoubleOrNull() ?: 0.0

    val calculatedHourly = if (minutes > 0) (price / minutes) * 60.0 else 0.0
    val isGoodOrder = calculatedHourly >= targetHourlyRate

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text("⚖️ 接單效益試算", fontWeight = FontWeight.Bold)
        },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "目標基準時薪: $${targetHourlyRate.toInt()} /hr",
                    fontSize = 12.sp,
                    color = Color.Gray
                )

                OutlinedTextField(
                    value = minutesText,
                    onValueChange = { minutesText = it },
                    label = { Text("預估配送時間 (分鐘)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )

                OutlinedTextField(
                    value = priceText,
                    onValueChange = { priceText = it },
                    label = { Text("平台預估單價 ($)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )

                Spacer(modifier = Modifier.height(4.dp))

                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = if (isGoodOrder) Color(0xFFE8F5E9) else Color(0xFFFFEBEE)
                    ),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.padding(12.dp)) {
                        Text(
                            text = "換算等效時薪: $${calculatedHourly.toInt()} /hr",
                            fontWeight = FontWeight.ExtraBold,
                            fontSize = 18.sp,
                            color = if (isGoodOrder) Color(0xFF2E7D32) else Color.Red
                        )
                        Text(
                            text = if (isGoodOrder) "✅ 效益高於目標，推薦接單！" else "⚠️ 效益偏低（低於基準時薪），可考慮略過",
                            fontSize = 12.sp,
                            color = if (isGoodOrder) Color(0xFF2E7D32) else Color.Red
                        )
                    }
                }
            }
        },
        confirmButton = {
            Button(
                onClick = { onAcceptOrder(price) },
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (isGoodOrder) MaterialTheme.colorScheme.primary else Color.Gray
                )
            ) {
                Text("直接接下此單")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("關閉") }
        }
    )
}

// ───────────────────────── 這一班的時薪卡（點摘要條才會展開）─────────────────────────

@Composable
fun ShiftCard(
    shift: DeliveryTrackerViewModel.ShiftSnapshot?,
    baseHourly: Double,
    canUndo: Boolean,
    onEndShift: () -> Unit,
    onUndo: () -> Unit,
    onOpenWageSettings: () -> Unit = {}
) {
    val openShift = shift?.takeIf { !it.isClosed }
    val target = openShift?.hourly ?: baseHourly
    val tenMinPrice = target / 6.0

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            if (openShift != null) {
                val mins = ((openShift.endMillis - openShift.startMillis) / 60000L).toInt()
                Text(
                    "本班已跑 ${mins / 60} 小時 ${mins % 60} 分，車資 $${"%.2f".format(openShift.wage)}（含進行中估算）",
                    fontSize = 12.sp,
                    color = Color.DarkGray
                )
                Text(
                    "目前實際時薪：${target.toInt()} 元/小時",
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary
                )
            } else if (shift != null) {
                Text("目前不在班次中（接新單會自動開新的一班）", fontSize = 12.sp, color = Color.DarkGray)
                val h = shift.hourly
                if (h != null) {
                    val why = if (shift.closedByUser) "你按了下班" else "超過 60 分鐘沒跑，自動結束"
                    Text(
                        "上一班結算時薪：${h.toInt()} 元/小時（$why）",
                        fontWeight = FontWeight.Bold,
                        color = Color(0xFF2E7D32)
                    )
                }
                if (shift.closedByUser && canUndo) {
                    TextButton(onClick = onUndo) { Text("誤觸下班？取消下班，繼續計算") }
                }
                Text("新班次尚未開始，以 ${baseHourly.toInt()} 元/小時為基準", fontSize = 12.sp, color = Color.Gray)
            } else {
                Text("尚無單，以 ${baseHourly.toInt()} 元/小時為基準", fontSize = 12.sp, color = Color.Gray)
            }

            Text(
                "10 分鐘的單至少要：${tenMinPrice.toInt()} 元",
                fontWeight = FontWeight.Bold,
                color = Color(0xFFEF6C00)
            )
            TextButton(onClick = onOpenWageSettings) { Text("⚙️ 調整基本費與時薪（費率表）") }

            if (openShift != null) {
                Button(
                    onClick = onEndShift,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD32F2F))
                ) {
                    Text("下班（停止計算時薪）")
                }
            }
        }
    }
}

@Composable
fun CashFieldRow(order: DeliveryOrder, viewModel: DeliveryTrackerViewModel) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        OutlinedButton(
            onClick = { viewModel.toggleCashOrder(order.id) },
            shape = RoundedCornerShape(8.dp),
            colors = if (order.isCashOrder)
                ButtonDefaults.outlinedButtonColors(containerColor = Color(0xFFFFE0EC))
            else ButtonDefaults.outlinedButtonColors()
        ) {
            Text(if (order.isCashOrder) "💵 現金單 ✓" else "💵 現金單？", fontSize = 13.sp)
        }
        OutlinedTextField(
            value = order.cashToCollect,
            onValueChange = { viewModel.updateOrderCash(order.id, it) },
            label = { Text("要收多少 ($)") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.weight(1f),
            singleLine = true
        )
    }
}
// ───────────────────────── 費率設定視窗 ─────────────────────────

private class WageRowState(
    val id: String,
    val isBase: Boolean,
    date: String,
    fee: String,
    hourly: String
) {
    var date by mutableStateOf(date)
    var fee by mutableStateOf(fee)
    var hourly by mutableStateOf(hourly)
}

@Composable
fun WageSettingsDialog(onDismiss: () -> Unit) {
    val fmt = remember {
        java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply { isLenient = false }
    }
    fun numText(d: Double): String = if (d % 1.0 == 0.0) d.toInt().toString() else d.toString()

    val rows = remember {
        mutableStateListOf<WageRowState>().apply {
            WageSettings.rates.forEach { r ->
                add(
                    WageRowState(
                        id = r.id,
                        isBase = r.isBase,
                        date = if (r.isBase) "" else fmt.format(java.util.Date(r.effectiveDateMillis)),
                        fee = numText(r.baseFee),
                        hourly = numText(r.hourly)
                    )
                )
            }
        }
    }
    var error by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("⚙️ 費率表", fontWeight = FontWeight.Bold) },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 420.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    "每張單用「接單當天」適用的費率計算。調漲時請新增一行並填生效日，舊單不會被改到。",
                    fontSize = 12.sp,
                    color = Color.Gray
                )
                rows.forEach { row ->
                    Card(
                        shape = RoundedCornerShape(10.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
                    ) {
                        Column(
                            modifier = Modifier.padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            if (row.isBase) {
                                Text("起始費率（更早的單都用這個）", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                            } else {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    OutlinedTextField(
                                        value = row.date,
                                        onValueChange = { row.date = it },
                                        label = { Text("生效日 (年-月-日)") },
                                        modifier = Modifier.weight(1f),
                                        singleLine = true
                                    )
                                    TextButton(onClick = { rows.remove(row) }) {
                                        Text("刪除", color = Color.Red)
                                    }
                                }
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                OutlinedTextField(
                                    value = row.fee,
                                    onValueChange = { row.fee = it },
                                    label = { Text("基本費") },
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                    modifier = Modifier.weight(1f),
                                    singleLine = true
                                )
                                OutlinedTextField(
                                    value = row.hourly,
                                    onValueChange = { row.hourly = it },
                                    label = { Text("時薪") },
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                    modifier = Modifier.weight(1f),
                                    singleLine = true
                                )
                            }
                        }
                    }
                }
                OutlinedButton(
                    onClick = {
                        val last = rows.lastOrNull()
                        rows.add(
                            WageRowState(
                                id = java.util.UUID.randomUUID().toString(),
                                isBase = false,
                                date = fmt.format(java.util.Date()),
                                fee = last?.fee ?: "45",
                                hourly = last?.hourly ?: "245"
                            )
                        )
                    },
                    modifier = Modifier.fillMaxWidth()
                ) { Text("＋ 新增費率調整") }
                if (error.isNotEmpty()) {
                    Text(error, color = Color.Red, fontSize = 12.sp)
                }
            }
        },
        confirmButton = {
            Button(onClick = {
                val result = mutableListOf<WageRate>()
                for (row in rows) {
                    val fee = row.fee.trim().toDoubleOrNull()
                    val hourly = row.hourly.trim().toDoubleOrNull()
                    if (fee == null || hourly == null || fee < 0 || hourly < 0) {
                        error = "基本費和時薪要填數字"
                        return@Button
                    }
                    val millis: Long = if (row.isBase) {
                        0L
                    } else {
                        val parsed = runCatching { fmt.parse(row.date.trim()) }.getOrNull()
                        if (parsed == null) {
                            error = "生效日格式要像 2026-11-01"
                            return@Button
                        }
                        parsed.time
                    }
                    result.add(WageRate(id = row.id, effectiveDateMillis = millis, baseFee = fee, hourly = hourly))
                }
                if (result.none { it.isBase }) {
                    error = "至少要保留一筆起始費率"
                    return@Button
                }
                WageSettings.rates = result
                onDismiss()
            }) { Text("儲存") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        }
    )
}