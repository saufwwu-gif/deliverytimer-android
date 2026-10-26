package com.example.UberDeliveryTracker.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.UberDeliveryTracker.location.GPSPoint
import com.example.UberDeliveryTracker.location.StayPoint
import com.example.UberDeliveryTracker.viewmodel.GpsMapViewModel
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.*
import java.text.SimpleDateFormat
import java.util.*
import android.Manifest
import android.content.pm.PackageManager
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import kotlin.math.abs

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GpsMapScreen(
    viewModel: GpsMapViewModel,
    modifier: Modifier = Modifier
) {
    val isTracking by viewModel.isTracking.collectAsState()
    val todayPoints by viewModel.todayPoints.collectAsState()
    val manualStayPoints by viewModel.manualStayPoints.collectAsState()

    // 在 Compose 層計算合併停留點（每次 todayPoints 或 manualStayPoints 更新時重算）
    val allStayPoints = remember(todayPoints, manualStayPoints) {
        viewModel.computeAllStayPoints()
    }

    // 地圖 Camera State — 預設台灣中心；有 GPS 點時自動移過去
    val defaultLatLng = LatLng(25.0330, 121.5654) // 台北
    val cameraPositionState = rememberCameraPositionState {
        position = CameraPosition.fromLatLngZoom(defaultLatLng, 13f)
    }
    var isFollowingUser by remember { mutableStateOf(true) }
    var showClearDialog by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val hasLocationPermission = ContextCompat.checkSelfPermission(
        context, Manifest.permission.ACCESS_FINE_LOCATION
    ) == PackageManager.PERMISSION_GRANTED
    var mapLoaded by remember { mutableStateOf(false) }
    var waitedTooLong by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        kotlinx.coroutines.delay(6000L)
        waitedTooLong = true
    }

    // 切換「俯瞰／跟隨」時，真的去移動鏡頭
    LaunchedEffect(isFollowingUser, mapLoaded) {
        if (!mapLoaded || todayPoints.isEmpty()) return@LaunchedEffect
        if (!isFollowingUser && todayPoints.size > 1) {
            val builder = com.google.android.gms.maps.model.LatLngBounds.builder()
            todayPoints.forEach { builder.include(LatLng(it.latitude, it.longitude)) }
            runCatching {
                cameraPositionState.animate(
                    CameraUpdateFactory.newLatLngBounds(builder.build(), 120)
                )
            }
        } else if (isFollowingUser) {
            val last = todayPoints.last()
            cameraPositionState.animate(
                CameraUpdateFactory.newLatLngZoom(LatLng(last.latitude, last.longitude), 15f)
            )
        }
    }
    // 當有新點位且設定為跟隨模式時，移動鏡頭
    LaunchedEffect(todayPoints) {
        val last = todayPoints.lastOrNull() ?: return@LaunchedEffect
        if (isFollowingUser) {
            cameraPositionState.animate(
                CameraUpdateFactory.newLatLngZoom(
                    LatLng(last.latitude, last.longitude), 15f
                )
            )
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("每日路線軌跡", fontWeight = FontWeight.Bold) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.onPrimaryContainer
                ),
                actions = {
                    // 鎖定/俯瞰 切換
                    FilledTonalButton(
                        onClick = {
                            isFollowingUser = !isFollowingUser
                            if (!isFollowingUser && todayPoints.size > 1) {
                                // 俯瞰模式：嘗試把整條軌跡放進視野
                                val lats = todayPoints.map { it.latitude }
                                val lngs = todayPoints.map { it.longitude }
                                val centerLat = (lats.max() + lats.min()) / 2
                                val centerLng = (lngs.max() + lngs.min()) / 2
                                // 簡易縮放估算
                                val spanLat = lats.max() - lats.min()
                                val spanLng = lngs.max() - lngs.min()
                                val zoom = when {
                                    spanLat > 0.5 || spanLng > 0.5 -> 10f
                                    spanLat > 0.1 || spanLng > 0.1 -> 12f
                                    else -> 14f
                                }
                            }
                        },
                        modifier = Modifier.padding(end = 4.dp),
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp)
                    ) {
                        Text(if (isFollowingUser) "📍 跟隨" else "🗺 俯瞰", fontSize = 12.sp)
                    }

                    // 清除按鈕
                    TextButton(
                        onClick = { showClearDialog = true },
                        contentPadding = PaddingValues(horizontal = 8.dp)
                    ) {
                        Text("清除", color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
                    }
                }
            )
        }
    ) { innerPadding ->
        Box(
            modifier = modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            // ────── 1. 地圖主體 ──────
            val routePolylinePoints = remember(todayPoints) {
                todayPoints.map { LatLng(it.latitude, it.longitude) }
            }

            GoogleMap(
                modifier = Modifier.fillMaxSize(),
                cameraPositionState = cameraPositionState,
                onMapLoaded = { mapLoaded = true },

                properties = MapProperties(
                    isMyLocationEnabled = hasLocationPermission,
                    mapType = MapType.NORMAL
                ),
                uiSettings = MapUiSettings(
                    myLocationButtonEnabled = false,
                    zoomControlsEnabled = false
                )
            ) {
                // 黃色軌跡折線（對應 iOS: MapPolyline stroke .yellow lineWidth:6）
                if (routePolylinePoints.size > 1) {
                    Polyline(
                        points = routePolylinePoints,
                        color = Color(0xFFFFEB3B),
                        width = 12f
                    )
                }

                // 出發點：綠色標記
                todayPoints.firstOrNull()?.let { firstPt ->
                    Marker(
                        state = MarkerState(LatLng(firstPt.latitude, firstPt.longitude)),
                        title = "出發 ${viewModel.startTimeStr}",
                        icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_GREEN)
                    )
                }

                // 結束點：紅色標記（需有 ≥2 點才顯示）
                if (todayPoints.size > 1) {
                    todayPoints.lastOrNull()?.let { lastPt ->
                        Marker(
                            state = MarkerState(LatLng(lastPt.latitude, lastPt.longitude)),
                            title = "結束 ${viewModel.endTimeStr}",
                            icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_RED)
                        )
                    }
                }

                // 停留點：藍色標記（對應 iOS: MinimalStayAnnotationView）
                allStayPoints.forEachIndexed { idx, stay ->
                    val durationMin = maxOf(0, ((stay.departureTimeMillis - stay.arrivalTimeMillis) / 60_000).toInt())
                    Marker(
                        state = MarkerState(LatLng(stay.latitude, stay.longitude)),
                        title = "停留 S${idx + 1}  ${durationMin} 分鐘",
                        snippet = "${formatHHmm(stay.arrivalTimeMillis)} → ${formatHHmm(stay.departureTimeMillis)}",
                        icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_AZURE)
                    )
                }
            }

            if (!mapLoaded && waitedTooLong) {
                Box(
                    modifier = Modifier
                        .align(Alignment.Center)
                        .padding(24.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color(0xFFFFF3E0))
                        .padding(16.dp)
                ) {
                    Text(
                        "地圖還沒載入成功。\n可能是金鑰、Google 地圖服務沒開，或手機（模擬器）沒有 Google Play。",
                        color = Color(0xFF8D4B00),
                        fontSize = 13.sp
                    )
                }
            }

            // ────── 2. 左上數據面板（對應 iOS: topLeftDataCenterCard）──────
            DataCenterCard(
                startTime = viewModel.startTimeStr,
                endTime = viewModel.endTimeStr,
                totalDuration = viewModel.totalDurationStr,
                stayPoints = allStayPoints,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(10.dp)
            )

            // ────── 3. 底部追蹤控制欄 ──────
            TrackingControlBar(
                isTracking = isTracking,
                pointCount = todayPoints.size,
                onToggle = {
                    if (isTracking) viewModel.stopTracking() else viewModel.startTracking()
                },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 16.dp, start = 16.dp, end = 16.dp)
            )
        }
    }

    // 清除確認對話框
    if (showClearDialog) {
        AlertDialog(
            onDismissRequest = { showClearDialog = false },
            title = { Text("清除今日軌跡？") },
            text = { Text("將清除今日所有 GPS 軌跡點與停留點紀錄，此動作無法復原。") },
            confirmButton = {
                Button(
                    onClick = {
                        viewModel.clearTodayData()
                        showClearDialog = false
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                ) { Text("確認清除") }
            },
            dismissButton = {
                TextButton(onClick = { showClearDialog = false }) { Text("取消") }
            }
        )
    }
}

// ──────────────────────────────────────────────
// 左上數據面板（對應 iOS: topLeftDataCenterCard）
// ──────────────────────────────────────────────
@Composable
private fun DataCenterCard(
    startTime: String,
    endTime: String,
    totalDuration: String,
    stayPoints: List<StayPoint>,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .widthIn(max = 180.dp)
            .heightIn(max = 260.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Color(0xBF000000)) // 75% 不透明黑（對應 iOS opacity 0.75）
            .padding(10.dp)
    ) {
        Column(
            modifier = Modifier.verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(3.dp)
        ) {
            MonoText("開始：$startTime")
            MonoText("結束：$endTime")
            MonoText("總時間：$totalDuration")

            if (stayPoints.isNotEmpty()) {
                Divider(color = Color.White.copy(alpha = 0.4f), thickness = 0.5.dp)
            }

            stayPoints.forEachIndexed { idx, stay ->
                val i = idx + 1
                val durationMin = maxOf(0, ((stay.departureTimeMillis - stay.arrivalTimeMillis) / 60_000).toInt())
                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    MonoText("S$i ${formatHHmm(stay.arrivalTimeMillis)}")
                    MonoText("E$i ${formatHHmm(stay.departureTimeMillis)}")
                    MonoText("ST$i: $durationMin MIN", bold = true)
                }
                if (idx < stayPoints.lastIndex) {
                    Spacer(modifier = Modifier.height(4.dp))
                }
            }

            if (stayPoints.isEmpty() && startTime == "--:--") {
                MonoText("尚無軌跡資料")
                MonoText("按下「開始追蹤」")
                MonoText("即開始記錄")
            }
        }
    }
}

@Composable
private fun MonoText(text: String, bold: Boolean = false) {
    Text(
        text = text,
        fontFamily = FontFamily.Monospace,
        fontWeight = if (bold) FontWeight.Bold else FontWeight.Medium,
        fontSize = 11.sp,
        color = Color.White
    )
}

// ──────────────────────────────────────────────
// 底部追蹤控制欄
// ──────────────────────────────────────────────
@Composable
private fun TrackingControlBar(
    isTracking: Boolean,
    pointCount: Int,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (isTracking) Color(0xFFB71C1C) else Color(0xFF1B5E20)
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = 6.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 14.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                Text(
                    text = if (isTracking) "📡 GPS 追蹤中" else "⏸ 追蹤已暫停",
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                    fontSize = 15.sp
                )
                Text(
                    text = "已記錄 $pointCount 個點位",
                    color = Color.White.copy(alpha = 0.8f),
                    fontSize = 12.sp
                )
            }

            Button(
                onClick = onToggle,
                colors = ButtonDefaults.buttonColors(containerColor = Color.White),
                shape = RoundedCornerShape(12.dp)
            ) {
                Icon(
                    if (isTracking) Icons.Default.Refresh else Icons.Default.PlayArrow,
                    contentDescription = null,
                    tint = if (isTracking) Color(0xFFB71C1C) else Color(0xFF1B5E20)
                )
                Spacer(modifier = Modifier.width(4.dp))
                Text(
                    text = if (isTracking) "停止" else "開始追蹤",
                    color = if (isTracking) Color(0xFFB71C1C) else Color(0xFF1B5E20),
                    fontWeight = FontWeight.Bold
                )
            }
        }
    }
}

// ──────────────────────────────────────────────
// 工具函式
// ──────────────────────────────────────────────
private fun formatHHmm(millis: Long): String {
    return SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(millis))
}
