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
                            onExportCSV = { csvText -> shareCSV(csvText) },
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
                            viewModel = deliveryViewModel,
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(innerPadding)
                        )
                        5 -> YearlyScreen(
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
