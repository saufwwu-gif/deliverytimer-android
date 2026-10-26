//
//  ScreenshotImportIntent.swift
//  薪水計時
//
//  捷徑動作「截圖匯入單號」：
//  捷徑把截圖丟進來 → 用現有 OCR 辨識單號/姓名 → 自動填進「進行中訂單」的平台單號欄位。
//  ⚠️ 這個檔案只加到「薪水計時」App 的 Target，不要勾 DeliveryWidget。
//

import AppIntents
import UIKit
import UserNotifications
import UniformTypeIdentifiers

// MARK: - 結果種類
enum ScreenshotApplyOutcome {
    case applied(orderNumber: Int)
    case noActiveOrder        // 目前沒有進行中的單
    case allOrdersHaveNote    // 進行中的單都已經有單號了（不覆蓋）
}

private enum ScreenshotImportTarget {
    case index(Int)
    case noActiveOrder
    case allHaveNote
}

// MARK: - ViewModel 擴充（不改動原本邏輯）
extension DeliveryTrackerViewModel {
    /// 目前存活的 ViewModel（App 開著或在背景時，捷徑會直接改這一份）
    static weak var current: DeliveryTrackerViewModel? {
        didSet { LiveActivityForegroundWatcher.shared.touch() }
    }

    /// 選要填哪一張單：進行中、還沒填單號的單裡，最早接的那一張。
    /// 已經有單號的不會被覆蓋，避免誤改。
    private static func chooseTarget(in orders: [DeliveryOrder]) -> ScreenshotImportTarget {
        let open = orders.indices.filter { !orders[$0].isCompleted && !orders[$0].isDiscarded }
        if open.isEmpty { return .noActiveOrder }
        let sorted = open.sorted { a, b in
            if orders[a].startTime == orders[b].startTime {
                return orders[a].orderNumber < orders[b].orderNumber
            }
            return orders[a].startTime < orders[b].startTime
        }
        let emptyOne = sorted.first {
            orders[$0].userNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let i = emptyOne { return .index(i) }
        return .allHaveNote
    }

    /// App 正在執行時：直接寫進目前的訂單（畫面、Live Activity 會自動跟著更新）
    @MainActor
    func applyScannedNote(_ text: String) -> ScreenshotApplyOutcome {
        switch Self.chooseTarget(in: activeOrders) {
        case .index(let i):
            activeOrders[i].userNote = text
            return .applied(orderNumber: activeOrders[i].orderNumber)
        case .noActiveOrder:
            return .noActiveOrder
        case .allHaveNote:
            return .allOrdersHaveNote
        }
    }

    /// App 還沒有畫面（被捷徑在背景叫起來）時：直接改手機裡存的資料，
    /// 下次打開 App 就會看到。
    static func applyScannedNoteToStoredOrders(_ text: String) -> ScreenshotApplyOutcome {
        let key = "SavedActiveOrdersData"
        guard let data = UserDefaults.standard.data(forKey: key),
              var orders = try? JSONDecoder().decode([DeliveryOrder].self, from: data) else {
            return .noActiveOrder
        }
        switch chooseTarget(in: orders) {
        case .index(let i):
            orders[i].userNote = text
            if let encoded = try? JSONEncoder().encode(orders) {
                UserDefaults.standard.set(encoded, forKey: key)
            }
            return .applied(orderNumber: orders[i].orderNumber)
        case .noActiveOrder:
            return .noActiveOrder
        case .allHaveNote:
            return .allOrdersHaveNote
        }
    }
}

// MARK: - 結果通知（從小圓點/輕點背面觸發時，捷徑的對話框常常不會顯示，所以另外跳通知）
private func notifyScreenshotImportResult(success: Bool, message: String) {
    let content = UNMutableNotificationContent()
    content.title = success ? "✅ 單號已匯入" : "⚠️ 單號匯入失敗"
    content.body = message
    content.sound = .default
    let request = UNNotificationRequest(
        identifier: "screenshotImport_\(UUID().uuidString)",
        content: content,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
    )
    UNUserNotificationCenter.current().add(request)
}

// MARK: - 捷徑動作
struct ImportOrderFromScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "截圖匯入單號"
    static var description = IntentDescription("辨識接單截圖上的單號與姓名，自動填進進行中的訂單。")
    static var openAppWhenRun: Bool = false

    // inputConnectionBehavior：讓捷徑自動把「上一個動作的結果（螢幕快照）」接進來，
    // 不用手動按「選擇」去開檔案。
    @Parameter(title: "截圖",
               supportedContentTypes: [.image],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var screenshot: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let image = UIImage(data: screenshot.data) else {
            notifyScreenshotImportResult(success: false, message: "讀不到這張截圖")
            return .result(dialog: "讀不到這張截圖")
        }

        let info = await OrderScreenshotReader.read(image: image)
        guard let text = info.combinedText else {
            notifyScreenshotImportResult(success: false, message: "沒有辨識到單號或姓名，請確認截圖是接單畫面")
            return .result(dialog: "沒有辨識到單號或姓名")
        }

        let outcome: ScreenshotApplyOutcome
        if let vm = DeliveryTrackerViewModel.current {
            outcome = vm.applyScannedNote(text)
        } else {
            outcome = DeliveryTrackerViewModel.applyScannedNoteToStoredOrders(text)
        }

        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        switch outcome {
        case .applied(let n):
            notifyScreenshotImportResult(success: true, message: "已填入訂單 #\(n)：\(oneLine)")
            return .result(dialog: "已填入訂單 #\(n)：\(oneLine)")
        case .noActiveOrder:
            notifyScreenshotImportResult(success: false, message: "目前沒有進行中的訂單（辨識到：\(oneLine)）")
            return .result(dialog: "目前沒有進行中的訂單，辨識到：\(oneLine)")
        case .allOrdersHaveNote:
            notifyScreenshotImportResult(success: false, message: "進行中的訂單都已有單號，沒有覆蓋（辨識到：\(oneLine)）")
            return .result(dialog: "進行中的訂單都已有單號，沒有覆蓋。辨識到：\(oneLine)")
        }
    }
}

// ============================================================
// MARK: - 選擇版：自己挑要填哪一張訂單
// ============================================================

extension DeliveryTrackerViewModel {
    /// 填進「指定」的那一張單（你自己選的，所以就算它已經有單號也會覆蓋）
    @MainActor
    func applyScannedNote(_ text: String, toOrderID id: UUID) -> ScreenshotApplyOutcome {
        guard let i = activeOrders.firstIndex(where: { $0.id == id && !$0.isCompleted && !$0.isDiscarded }) else {
            return .noActiveOrder
        }
        activeOrders[i].userNote = text
        return .applied(orderNumber: activeOrders[i].orderNumber)
    }

    /// App 沒有畫面時，直接改手機裡存的資料
    static func applyScannedNoteToStoredOrders(_ text: String, toOrderID id: UUID) -> ScreenshotApplyOutcome {
        let key = "SavedActiveOrdersData"
        guard let data = UserDefaults.standard.data(forKey: key),
              var orders = try? JSONDecoder().decode([DeliveryOrder].self, from: data),
              let i = orders.firstIndex(where: { $0.id == id && !$0.isCompleted && !$0.isDiscarded }) else {
            return .noActiveOrder
        }
        orders[i].userNote = text
        if let encoded = try? JSONEncoder().encode(orders) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
        return .applied(orderNumber: orders[i].orderNumber)
    }
}

/// 捷徑選單裡顯示的「進行中訂單」
struct ActiveOrderEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "進行中訂單"
    static var defaultQuery = ActiveOrderQuery()

    var id: UUID
    var orderNumber: Int
    var note: String

    var displayRepresentation: DisplayRepresentation {
        let oneLine = note.replacingOccurrences(of: "\n", with: " ")
        let sub: LocalizedStringResource = note.isEmpty ? "尚未填單號" : "\(oneLine)"
        return DisplayRepresentation(title: "訂單 #\(orderNumber)", subtitle: sub)
    }

    /// 目前進行中（沒完成、沒棄單）的訂單，依接單順序
    @MainActor
    static func openOrders() -> [ActiveOrderEntity] {
        var orders: [DeliveryOrder] = []
        if let vm = DeliveryTrackerViewModel.current {
            orders = vm.activeOrders
        } else if let data = UserDefaults.standard.data(forKey: "SavedActiveOrdersData"),
                  let decoded = try? JSONDecoder().decode([DeliveryOrder].self, from: data) {
            orders = decoded
        }
        return orders
            .filter { !$0.isCompleted && !$0.isDiscarded }
            .sorted {
                if $0.startTime == $1.startTime { return $0.orderNumber < $1.orderNumber }
                return $0.startTime < $1.startTime
            }
            .map { ActiveOrderEntity(id: $0.id, orderNumber: $0.orderNumber, note: $0.userNote) }
    }
}

struct ActiveOrderQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ActiveOrderEntity] {
        await MainActor.run {
            ActiveOrderEntity.openOrders().filter { identifiers.contains($0.id) }
        }
    }

    func suggestedEntities() async throws -> [ActiveOrderEntity] {
        await MainActor.run { ActiveOrderEntity.openOrders() }
    }
}

/// 捷徑動作：截圖匯入單號（選擇訂單）— 執行時跳出清單，讓你點要填哪一張
struct ImportOrderToChosenOrderIntent: AppIntent {
    static var title: LocalizedStringResource = "截圖匯入單號（選擇訂單）"
    static var description = IntentDescription("辨識接單截圖，並讓你自己選要填進哪一張進行中的訂單。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "截圖",
               supportedContentTypes: [.image],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var screenshot: IntentFile

    @Parameter(title: "訂單", requestValueDialog: "要填入哪一張訂單？")
    var order: ActiveOrderEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let image = UIImage(data: screenshot.data) else {
            notifyScreenshotImportResult(success: false, message: "讀不到這張截圖")
            return .result(dialog: "讀不到這張截圖")
        }

        let info = await OrderScreenshotReader.read(image: image)
        guard let text = info.combinedText else {
            notifyScreenshotImportResult(success: false, message: "沒有辨識到單號或姓名，請確認截圖是接單畫面")
            return .result(dialog: "沒有辨識到單號或姓名")
        }

        let outcome: ScreenshotApplyOutcome
        if let vm = DeliveryTrackerViewModel.current {
            outcome = vm.applyScannedNote(text, toOrderID: order.id)
        } else {
            outcome = DeliveryTrackerViewModel.applyScannedNoteToStoredOrders(text, toOrderID: order.id)
        }

        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        switch outcome {
        case .applied(let n):
            notifyScreenshotImportResult(success: true, message: "已填入訂單 #\(n)：\(oneLine)")
            return .result(dialog: "已填入訂單 #\(n)：\(oneLine)")
        default:
            notifyScreenshotImportResult(success: false, message: "找不到這張訂單，可能已經完成或棄單（辨識到：\(oneLine)）")
            return .result(dialog: "找不到這張訂單，可能已經完成或棄單")
        }
    }
}
