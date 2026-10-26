# 《薪水計時 - Android 移植版》開發進度與交接手冊 (交接專用)

## 📌 專案背景與檔案安全規範
1. **iOS 原始碼備份目錄**：`薪水計時最新版的IOS/`（切勿修改、移動或刪除任何檔案）。
2. **Android 主專案目錄**：`app/src/main/java/com/example/UberDeliveryTracker/`。
3. **架構規範**：Kotlin + Jetpack Compose (Material 3) + StateFlow + MVVM。

---

## ✅ 已完整實現之功能清單（6 大模組）

### 1. 跑單實時計時核心
- `model/DeliveryModels.kt`：訂單、批次、薪資計算模型。
- `viewmodel/DeliveryTrackerViewModel.kt`：秒級計時、夾單/送達/棄單/復原、自動歸檔、手動補單、CSV匯出、目標時薪設定。
- `ui/DeliveryTrackerScreen.kt`：跑單儀表板 + **⚖️ 接單效益試算器**（輸入時間/單價自動換算等效時薪，可一鍵開單）。

### 2. 方案 A：內建截圖自動 OCR（免錄影權限）
- `ocr/OrderInfoDetector.kt`：100% 移植 iOS `Ordertextscanner.swift`，支援 Uber Eats / Foodpanda 雙平台單號辨識。
- `ocr/ScreenshotObserver.kt`：監聽相簿新截圖 → ML Kit OCR → 自動填入平台單號欄位。

### 3. 方案 B：跑單懸浮系統（Floating Overlay）
- `floating/FloatingTrackerService.kt`：浮在 Uber 最上層，顯示即時時薪，含【取餐】【送達】【📷 辨識單號】快捷鍵，支援拖曳。

### 4. 歷史日報、對帳與 CSV 匯出
- `ui/DailyReportsScreen.kt`：日期切換、APP 預估 vs Uber 官方差額對帳、手動補單、**📁 一鍵 CSV 匯出分享**。

### 5. 車輛保養與加油模組（100% 移植 VehicleMaintenanceView）
- `model/VehicleModels.kt`、`viewmodel/VehicleViewModel.kt`、`ui/VehicleMaintenanceScreen.kt`：
  三大分頁（耗材壽命進度條 / 保養紀錄 / 加油紀錄），綠/橘/紅警告，🔧記保養 ⛽記加油。

### 6. GPS 每日外送軌跡地圖（100% 移植 DailyRouteMapView）✅ 最新完成
- `DeliveryApp.kt`：Application 類別，App 啟動時初始化 `GPSLocationManager` singleton。
- `viewmodel/GpsMapViewModel.kt`：代理 `GPSLocationManager.instance` 的 StateFlow，對外提供追蹤控制、停留點計算、時間統計字串。
- `ui/GpsMapScreen.kt`：
  - Google Maps Compose 渲染黃色軌跡折線（對應 iOS `MapPolyline stroke .yellow`）。
  - 綠色出發標記 / 紅色結束標記 / 藍色停留點標記（含到達/離開時間 tooltip）。
  - 左上半透明黑色數據面板：開始時間、結束時間、總時長、每個停留點 S/E/ST（完全對應 iOS `topLeftDataCenterCard` 等寬字體格式）。
  - 底部追蹤控制欄：「📡 GPS 追蹤中 / ⏸ 追蹤已暫停」狀態 + 開始/停止按鈕。
  - 📍 跟隨 / 🗺 俯瞰 視角切換，清除確認對話框。
- `AndroidManifest.xml`：新增 `ACCESS_BACKGROUND_LOCATION`、`FOREGROUND_SERVICE_LOCATION`、`DeliveryApp` 指定、Google Maps API Key meta-data。
- `MainActivity.kt`：底部四頁導航（跑單 / 日報 / **地圖** / 保養），整合定位權限申請。
- `build.gradle.kts`：新增 `maps-compose:4.4.1` 與 `play-services-maps:19.0.0`。

---

## ⚠️ 使用前必做：申請 Google Maps API Key
在 `app/src/main/AndroidManifest.xml` 第 36 行，將：
```xml
android:value="YOUR_GOOGLE_MAPS_API_KEY_HERE"
```
替換為您在 [Google Cloud Console](https://console.cloud.google.com/) 申請的真實 API Key。
（啟用 Maps SDK for Android 即可）

---

## 🎯 剩餘未移植大項目（建議 Gemini 依序接手）

### 優先級 1：懸浮窗連通 ViewModel（目前懸浮窗按鈕是 Toast，尚未真正呼叫 ViewModel）
- **問題**：`FloatingTrackerService.kt` 中的【取餐】【送達】按鈕目前只顯示 Toast，沒有真的呼叫 `DeliveryTrackerViewModel`。
- **解法**：將 `DeliveryTrackerViewModel` 透過 **SharedPreferences 事件橋** 或 **BroadcastReceiver** 傳遞動作到 FloatingTrackerService，讓懸浮窗按鈕能真正觸發訂單狀態更新。
- **參考**：`viewmodel/DeliveryTrackerViewModel.kt` 的 `completeOrder()`、`markPickupComplete()`。

### 優先級 2：雙週對帳與週/年疊單率分析
- **參考原始檔**：`薪水計時最新版的IOS/ContentView.swift`，MARK - B（班別判斷）、MARK - E（疊單率分析 View）行 1149–1841。
- **目標**：
  - 建立雙週薪資週期對帳清單（按 Uber 雙週發薪週期分組）。
  - 統計週/年疊單率圖表（單量 vs 雙單夾單比例）。
  - 對應新增一個 Compose 分析頁面。

### 優先級 3：GPS 地圖背景前景定位服務
- **問題**：目前地圖頁切出去後，GPS 追蹤依賴 `GPSLocationManager` 的 `FusedLocationProvider`，但切到背景後 Android 可能砍死定位。
- **解法**：建立 `GpsTrackingService : Service()`，以 `foregroundServiceType="location"` 前景服務持續定位，在通知欄顯示「📡 GPS 軌跡記錄中」，確保切到 Uber Eats 時仍持續記錄。
- **新增 Manifest**：`<service android:foregroundServiceType="location" .../>`。
