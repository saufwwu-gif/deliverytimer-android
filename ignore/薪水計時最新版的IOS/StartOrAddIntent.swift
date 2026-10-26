//
//  StartOrAddIntent.swift
//  薪水計時
//
//  捷徑動作「截圖開始 / 加單」：
//  - 目前沒有計時中的單 → 開始計時（1/2/3 單）
//  - 目前已有計時中的單 → 順風加單（1/2/3 單）
//  - 再把截圖辨識到的單號/姓名，填進「你選的那一張新單」
//  - 辨識到的單號如果已經在別張進行中的單裡，不會重複填入
//  ⚠️ 這個檔案只加到「薪水計時」App 的 Target，不要勾 DeliveryWidget。
//  ⚠️ 需要 ScreenshotImportIntent.swift 一起在專案裡（會用到裡面的函式）。
//

import ActivityKit
import AppIntents
import UIKit
import UserNotifications
import UniformTypeIdentifiers

// MARK: - 單數 + 單號要填給第幾張（一次選完，只問一次）
enum StartAddOption: String, AppEnum {
    case n1
    case n2k1
    case n2k2
    case n3k1
    case n3k2
    case n3k3

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "單數"

    static var caseDisplayRepresentations: [StartAddOption: DisplayRepresentation] = [
        .n1:   DisplayRepresentation(title: "1 單"),
        .n2k1: DisplayRepresentation(title: "2 單・單號填第 1 單"),
        .n2k2: DisplayRepresentation(title: "2 單・單號填第 2 單"),
        .n3k1: DisplayRepresentation(title: "3 單・單號填第 1 單"),
        .n3k2: DisplayRepresentation(title: "3 單・單號填第 2 單"),
        .n3k3: DisplayRepresentation(title: "3 單・單號填第 3 單")
    ]

    /// 這次要開始/加幾單
    var count: Int {
        switch self {
        case .n1: return 1
        case .n2k1, .n2k2: return 2
        case .n3k1, .n3k2, .n3k3: return 3
        }
    }

    /// 單號要填進「這次新增的單」裡的第幾張（從 0 開始）
    var slotIndex: Int {
        switch self {
        case .n1, .n2k1, .n3k1: return 0
        case .n2k2, .n3k2: return 1
        case .n3k3: return 2
        }
    }
}

// MARK: - ViewModel 擴充（不改動原本邏輯，只是幫捷徑按「開始」/「+單」）
extension DeliveryTrackerViewModel {
    /// 沒有進行中的單 → 開始新趟次；已有進行中的單 → 順風加單。
    /// 做的事跟畫面上的「一鍵開始」「+1/2/3單」按鈕一樣。
    /// 回傳這次「新增」的訂單 ID（依單號順序）。
    @MainActor
    func startOrAddFromShortcut(count: Int) -> (isStart: Bool, newIDs: [UUID]) {
        let before = Set(activeOrders.map { $0.id })
        let isStart = activeOrders.isEmpty

        if isStart {
            selectedInitialCount = count
            startNewBatch()
            syncToWidget(startTime: Date(), currentSalary: currentBatchSalary, hourlyRate: hourlyRate, isWorking: true)
            GPSLocationManager.shared.startNewDeliverySession()
        } else {
            addAddOnOrders(count: count)
        }

        // 計時卡沒成功啟動（背景不允許）→ 記下來，等 App 回到前景再補開
        if Activity<DeliveryActivityAttributes>.activities.isEmpty {
            Self.liveActivityRestorePending = true
        }

        let newIDs = activeOrders
            .filter { !before.contains($0.id) }
            .sorted { $0.orderNumber < $1.orderNumber }
            .map { $0.id }
        return (isStart, newIDs)
    }

    /// 進行中的單裡，有沒有哪一張已經填了這個單號（排除這次剛新增的單）
    func activeOrderNumber(containing code: String, excluding ids: Set<UUID>) -> Int? {
        activeOrders.first {
            !ids.contains($0.id) && !$0.isDiscarded && $0.userNote.localizedCaseInsensitiveContains(code)
        }?.orderNumber
    }
}

// MARK: - 鎖定畫面計時卡（Live Activity）補開
// iOS 規定：Live Activity 只能在 App 在前景時「啟動」。
// 從背景捷徑開始計時時，計時照常開始，但鎖定畫面的計時卡會被系統拒絕。
// 所以這裡記一個「待補開」旗標，等你下次打開薪水計時 App，就自動補開。
extension DeliveryTrackerViewModel {
    static var liveActivityRestorePending = false

    @MainActor
    func restoreLiveActivityIfNeeded() {
        guard Self.liveActivityRestorePending else { return }
        let uncompleted = activeOrders.filter { !$0.isCompleted && !$0.isDiscarded }
        // 沒有進行中的單，或計時卡已經存在 → 不用補
        guard !uncompleted.isEmpty,
              Activity<DeliveryActivityAttributes>.activities.isEmpty else {
            Self.liveActivityRestorePending = false
            return
        }

        let stats = currentBatchEarnings
        let info = liveActivityRateInfo()
        let startTime = liveActivityTimerStart() ?? Date()
        let nextBatchNum = (dailyReports[todayKey]?.batches.map { $0.batchNumber }.max() ?? 0) + 1
        let details: [String] = uncompleted.map { order in
            var label = "#\(order.orderNumber)"
            if !order.userNote.isEmpty { label += "・\(order.userNote)" }
            if order.pickupTime != nil { label += " [已取餐]" }
            return label
        }
        let status = uncompleted.allSatisfy { $0.pickupTime != nil } ? "送餐中" : "配送中"

        LiveActivityManager.shared.startDeliveryActivity(
            batchNumber: nextBatchNum,
            startTime: startTime,
            initialEarnings: stats.totalBatchEarnings,
            hourlyRate: info.hourly,
            activeOrderCount: uncompleted.count,
            completedOrderCount: stats.completedCount,
            totalOrderCount: max(1, activeOrders.filter { !$0.isDiscarded }.count),
            statusText: status,
            activeOrderDetails: details,
            tenMinuteThreshold: info.threshold,
            timerStartTime: startTime
        )

        // 成功補開了才清旗標；失敗的話下次回到前景再試
        if !Activity<DeliveryActivityAttributes>.activities.isEmpty {
            Self.liveActivityRestorePending = false
        }
    }
}

/// App 每次回到前景時，檢查要不要補開鎖定畫面計時卡
final class LiveActivityForegroundWatcher {
    static let shared = LiveActivityForegroundWatcher()

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                DeliveryTrackerViewModel.current?.restoreLiveActivityIfNeeded()
            }
        }
    }

    /// 只是用來讓這個物件在 App 啟動時被建立
    func touch() {}
}

private func notifyStartAdd(success: Bool, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = success ? "✅ \(title)" : "⚠️ \(title)"
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(
        identifier: "startAdd_\(UUID().uuidString)",
        content: content,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
    )
    UNUserNotificationCenter.current().add(request)
}

// MARK: - 捷徑動作
struct StartOrAddFromScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "截圖開始 / 加單"
    static var description = IntentDescription("沒有計時中的單就開始計時，已有就順風加單，並把截圖上的單號填進你選的那一張新單。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "截圖",
               supportedContentTypes: [.image],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var screenshot: IntentFile

    @Parameter(title: "單數", requestValueDialog: "這次接了幾單？（沒計時就開始，已有計時就順風加單）")
    var option: StartAddOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // App 沒有在背景執行 → 不亂開始（避免計時器、定位狀態不一致）
        guard let vm = DeliveryTrackerViewModel.current else {
            notifyStartAdd(success: false, title: "沒有開始計時",
                           body: "薪水計時 App 目前沒有在背景執行，請先打開 App 一次再試")
            return .result(dialog: "薪水計時 App 沒有在背景執行，請先打開一次")
        }

        // 1) 先開始/加單：計時優先，不被辨識拖慢
        let result = vm.startOrAddFromShortcut(count: option.count)
        let action = result.isStart ? "已開始計時 \(option.count) 單" : "已順風加 \(option.count) 單"

        // 2) 再辨識截圖，把單號填進你選的那一張新單
        var detail = ""
        var allOK = true

        if let image = UIImage(data: screenshot.data) {
            let info = await OrderScreenshotReader.read(image: image)
            if let text = info.combinedText {
                let oneLine = text.replacingOccurrences(of: "\n", with: " ")
                if let code = info.orderCode,
                   let dup = vm.activeOrderNumber(containing: code, excluding: Set(result.newIDs)) {
                    detail = "單號 \(code) 已經在訂單 #\(dup)，沒有重複填入"
                    allOK = false
                } else if option.slotIndex < result.newIDs.count,
                          case .applied(let n) = vm.applyScannedNote(text, toOrderID: result.newIDs[option.slotIndex]) {
                    detail = "單號填入訂單 #\(n)：\(oneLine)"
                } else {
                    detail = "單號沒有填入成功"
                    allOK = false
                }
            } else {
                detail = "沒有辨識到單號或姓名"
                allOK = false
            }
        } else {
            detail = "讀不到截圖"
            allOK = false
        }

        var message = "\(action)。\(detail)"
        if DeliveryTrackerViewModel.liveActivityRestorePending {
            message += "（鎖定畫面計時卡：下次打開 App 時自動補上）"
        }
        notifyStartAdd(success: allOK, title: allOK ? "計時與單號完成" : "已計時，單號未填入", body: message)
        return .result(dialog: "\(message)")
    }
}
