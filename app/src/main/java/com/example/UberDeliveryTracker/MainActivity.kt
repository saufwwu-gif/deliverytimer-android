package com.example.UberDeliveryTracker

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import com.example.UberDeliveryTracker.floating.FloatingTrackerService
import com.example.UberDeliveryTracker.ocr.ScreenshotObserver
import com.example.UberDeliveryTracker.ui.DailyReportsScreen
import com.example.UberDeliveryTracker.ui.EfficiencyScreen
import androidx.compose.material.icons.filled.Star
import com.example.UberDeliveryTracker.ui.BiweeklyScreen
import com.example.UberDeliveryTracker.ui.YearlyScreen
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Info
import com.example.UberDeliveryTracker.ui.DeliveryTrackerScreen
import com.example.UberDeliveryTracker.ui.GpsMapScreen
import com.example.UberDeliveryTracker.ui.VehicleMaintenanceScreen
import com.example.UberDeliveryTracker.ui.theme.薪水計時Theme
import com.example.UberDeliveryTracker.viewmodel.DeliveryTrackerViewModel
import com.example.UberDeliveryTracker.viewmodel.GpsMapViewModel
import com.example.UberDeliveryTracker.viewmodel.VehicleViewModel

class MainActivity : ComponentActivity() {

    private val deliveryViewModel: DeliveryTrackerViewModel by viewModels()
    private val vehicleViewModel: VehicleViewModel by viewModels()
    private val gpsMapViewModel: GpsMapViewModel by viewModels()
    private var screenshotObserver: ScreenshotObserver? = null
    private var isFloatingServiceRunning = false

    // 一次性申請精確定位 + 背景定位權限
    private val locationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { grants ->
        val fine = grants[Manifest.permission.ACCESS_FINE_LOCATION] == true
        if (!fine) {
            Toast.makeText(this, "需要精確定位權限才能記錄軌跡", Toast.LENGTH_LONG).show()
        }
    }

    // 匯出 CSV：跳出「存到哪裡」的畫面
    private var pendingCsv: String = ""
    private var pendingOnSaved: (() -> Unit)? = null
    private val csvExportLauncher = registerForActivityResult(
        ActivityResultContracts.CreateDocument("text/csv")
    ) { uri ->
        if (uri != null) {
            val ok = runCatching {
                contentResolver.openOutputStream(uri)?.use {
                    it.write(pendingCsv.toByteArray(Charsets.UTF_8))
                }
            }.isSuccess
            Toast.makeText(this, if (ok) "✅ 備份已存好" else "存檔失敗", Toast.LENGTH_LONG).show()
            if (ok) pendingOnSaved?.invoke()
            pendingOnSaved = null
        }
    }

    // 匯入 CSV：跳出「選哪個檔案」的畫面
    private val csvImportLauncher = registerForActivityResult(
        ActivityResultContracts.GetContent()
    ) { uri ->
        if (uri != null) {
            val text = runCatching {
                contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
            }.getOrNull()
            if (text.isNullOrEmpty()) {
                Toast.makeText(this, "讀不到這個檔案", Toast.LENGTH_LONG).show()
            } else {
                val n = deliveryViewModel.importFromCSV(text)
                Toast.makeText(
                    this,
                    if (n > 0) "✅ 已匯入 $n 張單" else "沒有新增任何單（可能已經匯入過，或格式不對）",
                    Toast.LENGTH_LONG
                ).show()
            }
        }
    }

    private fun saveCSVFile(csvContent: String) {
        if (csvContent.lines().size <= 2) {
            Toast.makeText(this, "目前尚無歷史跑單資料可匯出", Toast.LENGTH_SHORT).show()
            return
        }
        pendingCsv = csvContent
        pendingOnSaved = null
        val day = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault())
            .format(java.util.Date())
        csvExportLauncher.launch("DeliveryBackup_$day.csv")
    }

    // 年報匯出並瘦身：存檔成功後才會呼叫 onSaved
    private fun saveRangeCsv(csvContent: String, fileName: String, onSaved: () -> Unit) {
        pendingCsv = csvContent
        pendingOnSaved = onSaved
        csvExportLauncher.launch(fileName)
    }

    // 匯入 Uber 收入明細 CSV：跳出「選哪個檔案」的畫面
    private val uberCsvImportLauncher = registerForActivityResult(
        ActivityResultContracts.GetContent()
    ) { uri ->
        if (uri != null) {
            val text = runCatching {
                contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
            }.getOrNull()
            if (text.isNullOrEmpty()) {
                Toast.makeText(this, "讀不到這個檔案", Toast.LENGTH_LONG).show()
            } else {
                val days = deliveryViewModel.importUberCSV(text)
                Toast.makeText(
                    this,
                    if (days > 0) "✅ 已填入 $days 天的 Uber 實發金額" else "沒讀到任何金額（檔案格式可能不對）",
                    Toast.LENGTH_LONG
                ).show()
            }
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        requestLocationPermissionsIfNeeded()


        setContent {
            薪水計時Theme {
                // 0: 跑單, 1: 日報, 2: 地圖, 3: 保養
                var currentTab by remember { mutableStateOf(0) }

                Scaffold(
                    bottomBar = {
                        NavigationBar {
                            NavigationBarItem(
                                selected = currentTab == 0,
                                onClick = { currentTab = 0 },
                                icon = { Icon(Icons.Default.PlayArrow, contentDescription = null) },
                                label = { Text("跑單") }
                            )
                            NavigationBarItem(
                                selected = currentTab == 1,
                                onClick = { currentTab = 1 },
                                icon = { Icon(Icons.Default.DateRange, contentDescription = null) },
                                label = { Text("日報") }
                            )

                            NavigationBarItem(
                                selected = currentTab == 4,
                                onClick = { currentTab = 4 },
                                icon = { Icon(Icons.Default.Menu, contentDescription = null) },
                                label = { Text("雙週") }
                            )
                            NavigationBarItem(
                                selected = currentTab == 5,
                                onClick = { currentTab = 5 },
                                icon = { Icon(Icons.Default.Info, contentDescription = null) },
                                label = { Text("年報") }
                            )
                            NavigationBarItem(
                                selected = currentTab == 6,
                                onClick = { currentTab = 6 },
                                icon = { Icon(Icons.Default.Star, contentDescription = null) },
                                label = { Text("分析") }
                            )
                        }
                    }
                ) { innerPadding ->
                    when (currentTab) {
                        0 -> DeliveryTrackerScreen(
                            viewModel = deliveryViewModel,
                            onToggleFloatingWindow = { toggleFloatingWindow() },
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(innerPadding)
                        )
                        1 -> DailyReportsScreen(
                            viewModel = deliveryViewModel,
                            onExportCSV = { csvText -> saveCSVFile(csvText) },
                            onImportCSV = { csvImportLauncher.launch("*/*") },
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(innerPadding)
                        )
                        2 -> GpsMapScreen(
                            viewModel = gpsMapViewModel,
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(innerPadding)
                        )
                        4 -> BiweeklyScreen(
                            onImportUberCSV = { uberCsvImportLauncher.launch("*/*") },
                            viewModel = deliveryViewModel,
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(innerPadding)
                        )
                        5 -> YearlyScreen(
                            onSaveRangeCsv = { csv, name, done -> saveRangeCsv(csv, name, done) },
                            viewModel = deliveryViewModel,
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(innerPadding)
                        )
                        6 -> EfficiencyScreen(
                            viewModel = deliveryViewModel,
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(innerPadding)
                        )
                        3 -> VehicleMaintenanceScreen(
                            viewModel = vehicleViewModel,
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(innerPadding)
                        )
                    }
                }
            }
        }
    }

    private fun requestLocationPermissionsIfNeeded() {
        val perms = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
        // 讀相簿（辨識截圖用）與顯示通知
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms.add(Manifest.permission.READ_MEDIA_IMAGES)
            perms.add(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            perms.add(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        locationPermissionLauncher.launch(perms.toTypedArray())
    }

    private fun initScreenshotObserver() {
        screenshotObserver = ScreenshotObserver(this) { detected ->
            val text = detected.combinedText
            if (!text.isNullOrEmpty()) {
                val success = deliveryViewModel.applyScannedNoteToFirstEmptyOrder(text)
                if (success) {
                    Toast.makeText(this, "✅ 已自動填入單號: $text", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun toggleFloatingWindow() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            Toast.makeText(this, "請先開啟「顯示在其他應用程式上層」懸浮窗權限", Toast.LENGTH_LONG).show()
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
            return
        }
        val serviceIntent = Intent(this, FloatingTrackerService::class.java)
        if (!isFloatingServiceRunning) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(serviceIntent)
            else startService(serviceIntent)
            isFloatingServiceRunning = true
            Toast.makeText(this, "⚡ 跑單懸浮窗已啟動", Toast.LENGTH_SHORT).show()
        } else {
            stopService(serviceIntent)
            isFloatingServiceRunning = false
            Toast.makeText(this, "懸浮窗已關閉", Toast.LENGTH_SHORT).show()
        }
    }

    private fun shareCSV(csvContent: String) {
        if (csvContent.lines().size <= 1) {
            Toast.makeText(this, "目前尚無歷史跑單資料可匯出", Toast.LENGTH_SHORT).show()
            return
        }
        startActivity(Intent.createChooser(Intent().apply {
            action = Intent.ACTION_SEND
            putExtra(Intent.EXTRA_TEXT, csvContent)
            type = "text/plain"
        }, "匯出跑單報表 CSV"))
    }

    override fun onResume() {
        super.onResume()
        screenshotObserver?.register()
    }

    override fun onPause() {
        super.onPause()
        screenshotObserver?.unregister()
    }
}
