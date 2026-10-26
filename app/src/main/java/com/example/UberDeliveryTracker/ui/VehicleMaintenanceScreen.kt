package com.example.UberDeliveryTracker.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.UberDeliveryTracker.model.ConsumableStatus
import com.example.UberDeliveryTracker.model.FuelRecord
import com.example.UberDeliveryTracker.model.MaintenanceItemCategory
import com.example.UberDeliveryTracker.model.MaintenanceRecord
import com.example.UberDeliveryTracker.viewmodel.VehicleViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VehicleMaintenanceScreen(
    viewModel: VehicleViewModel,
    modifier: Modifier = Modifier
) {
    val selectedVehicle by viewModel.selectedVehicle.collectAsState()
    val maintenanceRecords by viewModel.maintenanceRecords.collectAsState()
    val fuelRecords by viewModel.fuelRecords.collectAsState()

    var selectedTab by remember { mutableStateOf(0) } // 0: 耗材健康度, 1: 保養紀錄, 2: 加油紀錄
    var showAddMaintenanceDialog by remember { mutableStateOf(false) }
    var showAddFuelDialog by remember { mutableStateOf(false) }

    val currentOdometer = viewModel.getCurrentOdometer()
    val consumableStatuses = viewModel.getConsumableStatuses()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("車輛保養與耗材", fontWeight = FontWeight.Bold) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.onPrimaryContainer
                )
            )
        },
        floatingActionButton = {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                ExtendedFloatingActionButton(
                    onClick = { showAddFuelDialog = true },
                    containerColor = MaterialTheme.colorScheme.secondaryContainer,
                    contentColor = MaterialTheme.colorScheme.onSecondaryContainer
                ) {
                    Text("⛽ 記加油", fontWeight = FontWeight.Bold)
                }
                ExtendedFloatingActionButton(
                    onClick = { showAddMaintenanceDialog = true },
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary
                ) {
                    Icon(Icons.Default.Add, contentDescription = null)
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("🔧 記保養", fontWeight = FontWeight.Bold)
                }
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
            // 1. 車輛概況資訊卡片
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column {
                            Text(
                                text = selectedVehicle?.name ?: "我的機車",
                                fontSize = 20.sp,
                                fontWeight = FontWeight.Bold
                            )
                            Text(
                                text = selectedVehicle?.type?.label ?: "",
                                fontSize = 12.sp,
                                color = Color.Gray
                            )
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text("目前總里程", fontSize = 12.sp, color = Color.Gray)
                            Text(
                                text = "${currentOdometer.toInt()} km",
                                fontSize = 24.sp,
                                fontWeight = FontWeight.ExtraBold,
                                color = MaterialTheme.colorScheme.primary
                            )
                        }
                    }

                    Spacer(modifier = Modifier.height(10.dp))
                    Divider(color = Color.LightGray.copy(alpha = 0.4f))
                    Spacer(modifier = Modifier.height(10.dp))

                    val totalMaintCost = maintenanceRecords.sumOf { it.totalCost }
                    val totalFuelCost = fuelRecords.sumOf { it.amount }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("累計保養: $${totalMaintCost.toInt()} 元", fontSize = 14.sp)
                        Text("累計加油: $${totalFuelCost.toInt()} 元", fontSize = 14.sp)
                    }
                }
            }

            // 2. 分頁切換 Tab
            TabRow(selectedTabIndex = selectedTab) {
                Tab(selected = selectedTab == 0, onClick = { selectedTab = 0 }, text = { Text("耗材壽命") })
                Tab(selected = selectedTab == 1, onClick = { selectedTab = 1 }, text = { Text("保養紀錄 (${maintenanceRecords.size})") })
                Tab(selected = selectedTab == 2, onClick = { selectedTab = 2 }, text = { Text("加油紀錄 (${fuelRecords.size})") })
            }

            // 3. 分頁內容
            when (selectedTab) {
                0 -> {
                    // 耗材健康度清單
                    LazyColumn(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        items(consumableStatuses) { status ->
                            ConsumableStatusCard(status = status)
                        }
                    }
                }
                1 -> {
                    // 保養紀錄清單
                    if (maintenanceRecords.isEmpty()) {
                        Box(modifier = Modifier.fillMaxSize().weight(1f), contentAlignment = Alignment.Center) {
                            Text("尚未有保養紀錄\n點擊右下角「🔧 記保養」開始記錄", color = Color.Gray)
                        }
                    } else {
                        LazyColumn(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f),
                            verticalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            items(maintenanceRecords, key = { it.id }) { record ->
                                MaintenanceRecordCard(
                                    record = record,
                                    dateStr = viewModel.formatDate(record.timestampMillis),
                                    onDelete = { viewModel.deleteMaintenanceRecord(record.id) }
                                )
                            }
                        }
                    }
                }
                2 -> {
                    // 加油紀錄清單
                    if (fuelRecords.isEmpty()) {
                        Box(modifier = Modifier.fillMaxSize().weight(1f), contentAlignment = Alignment.Center) {
                            Text("尚未有加油紀錄\n點擊右下角「⛽ 記加油」記錄油耗", color = Color.Gray)
                        }
                    } else {
                        LazyColumn(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f),
                            verticalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            items(fuelRecords, key = { it.id }) { record ->
                                FuelRecordCard(
                                    record = record,
                                    dateStr = viewModel.formatDate(record.timestampMillis),
                                    onDelete = { viewModel.deleteFuelRecord(record.id) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // 記保養對話框
    if (showAddMaintenanceDialog) {
        AddMaintenanceDialog(
            currentOdo = currentOdometer,
            onDismiss = { showAddMaintenanceDialog = false },
            onConfirm = { odo, items, cost, isFree, note, oilBrand ->
                viewModel.addMaintenanceRecord(odo, items, cost, isFree, note, oilBrand)
                showAddMaintenanceDialog = false
            }
        )
    }

    // 記加油對話框
    if (showAddFuelDialog) {
        AddFuelDialog(
            currentOdo = currentOdometer,
            onDismiss = { showAddFuelDialog = false },
            onConfirm = { odo, liters, amount, fuelType, note ->
                viewModel.addFuelRecord(odo, liters, amount, fuelType, note)
                showAddFuelDialog = false
            }
        )
    }
}

@Composable
fun ConsumableStatusCard(status: ConsumableStatus) {
    val progressColor = when {
        status.progress >= 1.0f -> Color.Red
        status.progress >= 0.85f -> Color(0xFFFF9800)
        else -> Color(0xFF4CAF50)
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(text = status.category.label, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                    if (status.isDue) {
                        Spacer(modifier = Modifier.width(6.dp))
                        Icon(Icons.Default.Warning, contentDescription = null, tint = Color.Red, modifier = Modifier.size(16.dp))
                        Text(" 建議更換", color = Color.Red, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    }
                }
                Text(
                    text = "建議: 每 ${status.recommendedInterval.toInt()} km",
                    fontSize = 12.sp,
                    color = Color.Gray
                )
            }

            Spacer(modifier = Modifier.height(8.dp))

            LinearProgressIndicator(
                progress = status.progress.coerceIn(0f, 1f),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(8.dp),
                color = progressColor,
                trackColor = Color.LightGray.copy(alpha = 0.4f)
            )

            Spacer(modifier = Modifier.height(6.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = "已跑: ${status.drivenDistance.toInt()} km",
                    fontSize = 13.sp,
                    color = if (status.isDue) Color.Red else Color.DarkGray
                )
                Text(
                    text = if (status.remainingDistance >= 0) "剩餘: ${status.remainingDistance.toInt()} km" else "超期: ${(-status.remainingDistance).toInt()} km",
                    fontSize = 13.sp,
                    color = if (status.isDue) Color.Red else Color.Gray,
                    fontWeight = if (status.isDue) FontWeight.Bold else FontWeight.Normal
                )
            }
        }
    }
}

@Composable
fun MaintenanceRecordCard(
    record: MaintenanceRecord,
    dateStr: String,
    onDelete: () -> Unit
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
                Text(text = "${record.odometer.toInt()} km", fontWeight = FontWeight.Bold, fontSize = 16.sp)
                Text(text = dateStr, fontSize = 12.sp, color = Color.Gray)
            }

            Spacer(modifier = Modifier.height(6.dp))
            Text(
                text = "更換項目: " + record.selectedItems.joinToString("、"),
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.primary
            )

            if (record.oilBrand.isNotEmpty()) {
                Text(text = "機油品牌: ${record.oilBrand}", fontSize = 12.sp, color = Color.DarkGray)
            }
            if (record.note.isNotEmpty()) {
                Text(text = "備註: ${record.note}", fontSize = 12.sp, color = Color.Gray)
            }

            Spacer(modifier = Modifier.height(6.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (record.isFree) "免費贈送保養" else "花費: $${record.totalCost.toInt()} 元",
                    fontWeight = FontWeight.Bold,
                    color = if (record.isFree) Color(0xFF2E7D32) else MaterialTheme.colorScheme.tertiary
                )
                IconButton(onClick = onDelete, modifier = Modifier.size(24.dp)) {
                    Icon(Icons.Default.Delete, contentDescription = null, tint = Color.Gray, modifier = Modifier.size(18.dp))
                }
            }
        }
    }
}

@Composable
fun FuelRecordCard(
    record: FuelRecord,
    dateStr: String,
    onDelete: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                Text(text = "${record.odometer.toInt()} km", fontWeight = FontWeight.Bold, fontSize = 16.sp)
                Text(text = "$dateStr | ${record.fuelType}", fontSize = 12.sp, color = Color.Gray)
                if (record.note.isNotEmpty()) {
                    Text(text = record.note, fontSize = 12.sp, color = Color.Gray)
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(text = "$${record.amount.toInt()} 元", fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
                Text(text = "${record.liters} L", fontSize = 13.sp, color = Color.DarkGray)
            }
            IconButton(onClick = onDelete, modifier = Modifier.size(24.dp)) {
                Icon(Icons.Default.Delete, contentDescription = null, tint = Color.Gray, modifier = Modifier.size(18.dp))
            }
        }
    }
}

@Composable
fun AddMaintenanceDialog(
    currentOdo: Double,
    onDismiss: () -> Unit,
    onConfirm: (odo: Double, items: List<String>, cost: Double, isFree: Boolean, note: String, oilBrand: String) -> Unit
) {
    var odoText by remember { mutableStateOf(if (currentOdo > 0) currentOdo.toInt().toString() else "") }
    var costText by remember { mutableStateOf("") }
    var isFree by remember { mutableStateOf(false) }
    var oilBrand by remember { mutableStateOf("") }
    var note by remember { mutableStateOf("") }

    val allCategories = MaintenanceItemCategory.values().map { it.label }
    val selectedItems = remember { mutableStateListOf("機油") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("新增保養紀錄") },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedTextField(
                    value = odoText,
                    onValueChange = { odoText = it },
                    label = { Text("保養時里程 (km)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )

                Text("勾選保養項目:", fontWeight = FontWeight.Bold, fontSize = 13.sp)
                Column {
                    allCategories.take(4).forEach { cat ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(
                                checked = selectedItems.contains(cat),
                                onCheckedChange = { checked ->
                                    if (checked) selectedItems.add(cat) else selectedItems.remove(cat)
                                }
                            )
                            Text(cat, fontSize = 13.sp)
                        }
                    }
                }

                OutlinedTextField(
                    value = oilBrand,
                    onValueChange = { oilBrand = it },
                    label = { Text("機油品牌/型號 (選填)") },
                    modifier = Modifier.fillMaxWidth()
                )

                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = isFree, onCheckedChange = { isFree = it })
                    Text("免費贈送保養 ($0)", fontSize = 13.sp)
                }

                if (!isFree) {
                    OutlinedTextField(
                        value = costText,
                        onValueChange = { costText = it },
                        label = { Text("保養金額 ($)") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth()
                    )
                }

                OutlinedTextField(
                    value = note,
                    onValueChange = { note = it },
                    label = { Text("店家名稱 / 備註") },
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    val odo = odoText.toDoubleOrNull() ?: currentOdo
                    val cost = costText.toDoubleOrNull() ?: 0.0
                    onConfirm(odo, selectedItems.toList(), cost, isFree, note, oilBrand)
                }
            ) {
                Text("儲存")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        }
    )
}

@Composable
fun AddFuelDialog(
    currentOdo: Double,
    onDismiss: () -> Unit,
    onConfirm: (odo: Double, liters: Double, amount: Double, fuelType: String, note: String) -> Unit
) {
    var odoText by remember { mutableStateOf(if (currentOdo > 0) currentOdo.toInt().toString() else "") }
    var litersText by remember { mutableStateOf("") }
    var amountText by remember { mutableStateOf("") }
    var fuelType by remember { mutableStateOf("92無鉛") }
    var note by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("新增加油紀錄") },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedTextField(
                    value = odoText,
                    onValueChange = { odoText = it },
                    label = { Text("加油時里程 (km)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = litersText,
                    onValueChange = { litersText = it },
                    label = { Text("公升數 (L)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = amountText,
                    onValueChange = { amountText = it },
                    label = { Text("加油金額 ($)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = note,
                    onValueChange = { note = it },
                    label = { Text("備註") },
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    val odo = odoText.toDoubleOrNull() ?: currentOdo
                    val liters = litersText.toDoubleOrNull() ?: 0.0
                    val amount = amountText.toDoubleOrNull() ?: 0.0
                    onConfirm(odo, liters, amount, fuelType, note)
                }
            ) {
                Text("儲存")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        }
    )
}
