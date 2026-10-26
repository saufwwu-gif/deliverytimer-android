enum FocusField: Hashable {
    case uberStartHour(UUID)     // 參數是 batch.id
    case uberStartMinute(UUID)
    case uberDurationHours(UUID)
    case uberDurationMinutes(UUID)
    case uberDurationSeconds(UUID)
    case wage(UUID)               // 參數是 order.id
    case tip(UUID)
    case minutes(UUID)   // 新增:對應「累計工時」欄位
}
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import UserNotifications
import WidgetKit
import ActivityKit

// MARK: Helper to Dismiss Keyboard
extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: Widget 資料同步全域函式
func syncToWidget(startTime: Date, currentSalary: Double, hourlyRate: Double, isWorking: Bool, orderDetail: String = "") {
    if let sharedDefaults = UserDefaults(suiteName: "group.com.sauf.salary") {
        sharedDefaults.set(startTime, forKey: "startTime")
        sharedDefaults.set(currentSalary, forKey: "currentSalary")
        sharedDefaults.set(hourlyRate, forKey: "hourlyRate")
        sharedDefaults.set(isWorking, forKey: "isWorking")
        sharedDefaults.set(orderDetail, forKey: "orderDetail")
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: CSV Document Model
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String
    
    init(text: String = "") {
        self.text = text
    }
    
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let string = String(data: data, encoding: .utf8) {
            text = string
        } else {
            text = ""
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: 1. Data Models
struct OrderTimerGroup: Identifiable, Codable {
    let id: UUID
    var groupName: String
    var startTime: Date
    var orderIDs: [UUID]
    var spokenMilestones: Set<Int> = []
    
    init(groupName: String, startTime: Date = Date(), orderIDs: [UUID]) {
        self.id = UUID()
        self.groupName = groupName
        self.startTime = startTime
        self.orderIDs = orderIDs
    }
    
    var recordedSeconds: TimeInterval {
        return max(0, Date().timeIntervalSince(startTime))
    }
}



struct DeliveryBatch: Identifiable, Codable {
    let id: UUID
    var batchNumber: Int
    var orders: [DeliveryOrder]
    let createdAt: Date
    var uberStartTimeHour: String = ""
    var uberStartTimeMinute: String = ""
    var uberDurationHours: String = ""
    var uberDurationMinutes: String = ""
    var uberDurationSeconds: String = ""
    
    init(batchNumber: Int, orders: [DeliveryOrder], createdAt: Date = Date()) {
        self.id = UUID()
        self.batchNumber = batchNumber
        self.orders = orders
        self.createdAt = createdAt
    }
    
    var validOrders: [DeliveryOrder] {
        orders.filter { !$0.isDiscarded }
    }
    
    var uberTotalSeconds: TimeInterval {
        let h = Int(uberDurationHours) ?? 0
        let m = Int(uberDurationMinutes) ?? 0
        let s = Int(uberDurationSeconds) ?? 0
        return TimeInterval(h * 3600 + m * 60 + s)
    }
    
    // 實際外送騎乘時間：從第一單開始到同一批最後一單完全結束
    var appBatchDurationSeconds: TimeInterval {
        guard let start = orders.map({ $0.startTime }).min(),
              let end = orders.compactMap({ $0.endTime }).max() else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }
    
    // 每單累計工時加總 (分鐘)
    var totalSummedMinutes: Double {
        let extra = estimatedLateStartSeconds
        return validOrders.reduce(0) { $0 + Double($1.adjustedMinutes(addingExtraSec: extra)) }
    }
    
    var estimatedLateStartSeconds: Double {
        guard uberTotalSeconds > 0 else { return 0 }
        let diff = uberTotalSeconds - appBatchDurationSeconds
        return diff > 0 ? diff : 0
    }
    
    var totalRawOperationWage: Double {
        orders.reduce(0) { $0 + $1.rawOperationWage }
    }
    
    var totalAdjustedBatchWage: Double {
        let extra = estimatedLateStartSeconds
        return orders.reduce(0) { $0 + $1.calculatedAdjustedWage(addingExtraSec: extra) }
    }
    
    var totalBatchTips: Double {
        orders.reduce(0) { $0 + $1.tipAmount }
    }
    
    var startTimeDiffString: String? {
        guard let start = orders.map({ $0.startTime }).min(),
              let h = Int(uberStartTimeHour),
              let m = Int(uberStartTimeMinute) else { return nil }
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: start)
        components.hour = h
        components.minute = m
        components.second = 0
        guard let uberStartDate = calendar.date(from: components) else { return nil }
        let diffSec = Int(start.timeIntervalSince(uberStartDate))
        let absDiff = abs(diffSec)
        let sign = diffSec >= 0 ? "+" : "-"
        return "開始時間差: \(sign)\(absDiff / 60)分\(absDiff % 60)秒"
    }
    
    var autoAnalysisResult: String {
        guard uberTotalSeconds > 0 else { return "" }
        let diffSec = appBatchDurationSeconds - uberTotalSeconds
        if diffSec < -10 {
            let lateSec = Int(abs(diffSec))
            return "APP紀錄短於 Uber (晚按\(lateSec / 60)分\(lateSec % 60)秒):已自動為同批每單補足時間。"
        } else if diffSec > 10 {
            return "APP紀錄長於 Uber: 可能忘記按下結束。"
        } else {
            return "時長比對吻合。"
        }
    }
}

import SwiftUI
import Charts

// ============================================================
// MARK: - A. 資料模型擴充 (請用此區塊「取代」原始檔案中的 DailyReport 定義)
// ============================================================
// 說明：
// 為了記錄「休假 / 異常」狀態，DailyReport 需要新增幾個欄位。
// 出勤狀態改為「白天班」「晚上班」分開設定（dayShiftStatus / nightShiftStatus），
// 因為騎士常常只休其中一班，不是整天都休。
// 由於原始 struct 是靠自動合成的 Codable 運作，直接加欄位在讀取舊資料時
// 會因為找不到新 key 而 decode 失敗，所以這裡改寫成「自訂 Codable」，
// 對新欄位一律使用 decodeIfPresent + 預設值，舊資料完全相容、新資料正常寫入；
// 若舊資料是本功能更早版本存的單一 attendanceStatus，也會自動搬到白天/晚上兩欄。
// 其餘原本的計算屬性（totalRawWage...等）完全不變，只是原封不動搬過來。

enum DayAttendanceStatus: String, Codable, CaseIterable {
    case normal = "正常出勤"
    case off = "休假"
    case anomaly = "異常"
}

enum AnomalyTag: String, Codable, CaseIterable, Identifiable, Hashable {
    case rain = "雨天"
    case holiday = "假日"
    case lunarNewYear = "過年"
    case other = "其他"
    var id: String { rawValue }
}

struct DailyReport: Identifiable, Codable {
    let id: UUID
    let dateString: String
    var batches: [DeliveryBatch] = []
    var dailyUberActualPayout: String = ""
    var dailyPandaActualPayout: String = ""
    var dailyNote: String = ""
    
    // 新增：疊單率分析用狀態欄位（預設值皆為「正常出勤」，不影響既有邏輯）
    var dayShiftStatus: DayAttendanceStatus = .normal
    var nightShiftStatus: DayAttendanceStatus = .normal
    var anomalyTags: [AnomalyTag] = []
    var anomalyNote: String = ""
    
    init(dateString: String) {
        self.id = UUID()
        self.dateString = dateString
    }
    
    enum CodingKeys: String, CodingKey {
        case id, dateString, batches, dailyUberActualPayout, dailyPandaActualPayout, dailyNote
        case dayShiftStatus, nightShiftStatus, anomalyTags, anomalyNote
        case legacyAttendanceStatus = "attendanceStatus" // 相容更早版本存的單一狀態欄位
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        dateString = try c.decode(String.self, forKey: .dateString)
        batches = try c.decodeIfPresent([DeliveryBatch].self, forKey: .batches) ?? []
        dailyUberActualPayout = try c.decodeIfPresent(String.self, forKey: .dailyUberActualPayout) ?? ""
        dailyPandaActualPayout = try c.decodeIfPresent(String.self, forKey: .dailyPandaActualPayout) ?? ""
        dailyNote = try c.decodeIfPresent(String.self, forKey: .dailyNote) ?? ""
        let legacyStatus = try c.decodeIfPresent(DayAttendanceStatus.self, forKey: .legacyAttendanceStatus)
        dayShiftStatus = try c.decodeIfPresent(DayAttendanceStatus.self, forKey: .dayShiftStatus) ?? legacyStatus ?? .normal
        nightShiftStatus = try c.decodeIfPresent(DayAttendanceStatus.self, forKey: .nightShiftStatus) ?? legacyStatus ?? .normal
        anomalyTags = try c.decodeIfPresent([AnomalyTag].self, forKey: .anomalyTags) ?? []
        anomalyNote = try c.decodeIfPresent(String.self, forKey: .anomalyNote) ?? ""
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(dateString, forKey: .dateString)
        try c.encode(batches, forKey: .batches)
        try c.encode(dailyUberActualPayout, forKey: .dailyUberActualPayout)
        try c.encode(dailyPandaActualPayout, forKey: .dailyPandaActualPayout)
        try c.encode(dailyNote, forKey: .dailyNote)
        try c.encode(dayShiftStatus, forKey: .dayShiftStatus)
        try c.encode(nightShiftStatus, forKey: .nightShiftStatus)
        try c.encode(anomalyTags, forKey: .anomalyTags)
        try c.encode(anomalyNote, forKey: .anomalyNote)
    }
    
    // ---- 以下為原始檔案既有的計算屬性，原封不動保留 ----
    var totalRawWage: Double {
        batches.reduce(0) { sum, batch in
            sum + batch.validOrders.reduce(0) { $0 + $1.rawOperationWage }
        }
    }
    var totalAdjustedWage: Double {
        batches.reduce(0) { sum, batch in
            let extra = batch.estimatedLateStartSeconds
            return sum + batch.validOrders.reduce(0) { $0 + $1.calculatedAdjustedWage(addingExtraSec: extra) }
        }
    }
    var totalTips: Double { batches.reduce(0) { $0 + $1.totalBatchTips } }
    var totalDailyIncome: Double { totalAdjustedWage + totalTips }
    var totalOrdersCount: Int { batches.flatMap { $0.validOrders }.count }
    var totalSummedMinutes: Double {
        batches.reduce(0) { $0 + $1.totalSummedMinutes }
    }
    var totalActualRidingMinutes: Double {
        batches.reduce(0) { $0 + ($1.appBatchDurationSeconds / 60.0) }
    }
}

// ============================================================
// MARK: - A2. DeliveryOrder 擴充 (請用此區塊「取代」原始檔案中的 DeliveryOrder 定義)
// ============================================================
// 說明：新增 isManualEntry 欄位，標記「透過訂單補單表單手動新增」的訂單
// （非即時使用 App 計時），疊單率分析會排除這類批次的工時/騎乘時間，
// 但金額仍然照樣計入收入統計。同樣用自訂 Codable + decodeIfPresent
// 確保舊資料相容。其餘計算屬性與原始檔案完全相同。

struct DeliveryOrder: Identifiable, Codable {
    let id: UUID
    var orderNumber: Int
    var startTime: Date
    var endTime: Date?
    // 改動G:取餐完成時間，跟 endTime(送達完成)分開記錄，兩個是不同的停留事件。
    var pickupTime: Date?
    var isCompleted: Bool = false
    var isDiscarded: Bool = false
    var customWageInput: String = ""
    var tipInput: String = ""
    var userNote: String = "" // 存放平台輸入單號
    var isManualEntry: Bool = false // 新增：是否為手動補單（非即時 App 計時）
    // 改動8:允許手動覆寫「這一單累計工時(分鐘)」。
    // 用途：誤按復原/重新完成等操作把時間算錯時，可以直接修正分鐘數，
    // 車資會依照修正後的分鐘數重新計算(除非同時有設定自訂底薪，自訂底薪優先)。
    // 留空字串代表「不覆寫，照實際時間自動計算」。
    var manualMinutesOverride: String = ""
    
    var startTimeFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: startTime)
    }
    
    init(orderNumber: Int, startTime: Date = Date()) {
        self.id = UUID()
        self.orderNumber = orderNumber
        self.startTime = startTime
    }
    
    enum CodingKeys: String, CodingKey {
        case id, orderNumber, startTime, endTime, pickupTime, isCompleted, isDiscarded
        case customWageInput, tipInput, userNote, isManualEntry
        case manualMinutesOverride
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        orderNumber = try c.decode(Int.self, forKey: .orderNumber)
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(Date.self, forKey: .endTime)
        pickupTime = try c.decodeIfPresent(Date.self, forKey: .pickupTime)
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        isDiscarded = try c.decodeIfPresent(Bool.self, forKey: .isDiscarded) ?? false
        customWageInput = try c.decodeIfPresent(String.self, forKey: .customWageInput) ?? ""
        tipInput = try c.decodeIfPresent(String.self, forKey: .tipInput) ?? ""
        userNote = try c.decodeIfPresent(String.self, forKey: .userNote) ?? ""
        isManualEntry = try c.decodeIfPresent(Bool.self, forKey: .isManualEntry) ?? false
        manualMinutesOverride = try c.decodeIfPresent(String.self, forKey: .manualMinutesOverride) ?? ""
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(orderNumber, forKey: .orderNumber)
        try c.encode(startTime, forKey: .startTime)
        try c.encodeIfPresent(endTime, forKey: .endTime)
        try c.encodeIfPresent(pickupTime, forKey: .pickupTime)
        try c.encode(isCompleted, forKey: .isCompleted)
        try c.encode(isDiscarded, forKey: .isDiscarded)
        try c.encode(customWageInput, forKey: .customWageInput)
        try c.encode(tipInput, forKey: .tipInput)
        try c.encode(userNote, forKey: .userNote)
        try c.encode(isManualEntry, forKey: .isManualEntry)
        try c.encode(manualMinutesOverride, forKey: .manualMinutesOverride)
    }
    
    var recordedSeconds: TimeInterval {
        let referenceEnd = endTime ?? Date()
        return max(0, referenceEnd.timeIntervalSince(startTime))
    }
    // 改動8:實際依起訖時間算出來的分鐘數，不受手動覆寫影響。
    // 給編輯欄位當「自動估算值」的佔位文字用，方便使用者知道原本算出來是多少。
    var autoCalculatedRawOperationMinutes: Int {
        let totalSec = Int(recordedSeconds)
        let mins = totalSec / 60
        let secs = totalSec % 60
        return secs >= 30 ? mins + 1 : mins
    }
    func autoCalculatedAdjustedMinutes(addingExtraSec extraSec: Double) -> Int {
        let totalSec = Int(max(0, recordedSeconds + max(0, extraSec)))
        let mins = totalSec / 60
        let secs = totalSec % 60
        return secs >= 30 ? mins + 1 : mins
    }
    // 改動8:解析手動覆寫的分鐘數，非數字或負數一律視為「沒有覆寫」
    private var parsedMinutesOverride: Int? {
        guard let value = Int(manualMinutesOverride.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
        return value
    }
    // 改動8:是否有手動覆寫累計工時
    var hasManualMinutesOverride: Bool {
        parsedMinutesOverride != nil
    }
    var rawOperationMinutes: Int {
        if let override = parsedMinutesOverride { return override }
        return autoCalculatedRawOperationMinutes
    }
    var rawOperationWage: Double {
        if isDiscarded { return 0.0 }
        if let custom = Double(customWageInput) { return custom }
        let totalMinutes = Double(rawOperationMinutes)
        return WageSettings.wage(forMinutes: totalMinutes, at: startTime)
    }
    func adjustedMinutes(addingExtraSec extraSec: Double) -> Int {
        // 改動8:有手動覆寫時,直接採用覆寫值,不再疊加batch的補足秒數
        // (覆寫值就是使用者要的最終分鐘數)
        if let override = parsedMinutesOverride { return override }
        return autoCalculatedAdjustedMinutes(addingExtraSec: extraSec)
    }
    func calculatedAdjustedWage(addingExtraSec extraSec: Double) -> Double {
        if isDiscarded { return 0.0 }
        if let custom = Double(customWageInput) { return custom }
        let totalMinutes = Double(adjustedMinutes(addingExtraSec: extraSec))
        return WageSettings.wage(forMinutes: totalMinutes, at: startTime)
    }
    var tipAmount: Double {
        if isDiscarded { return 0.0 }
        return Double(tipInput) ?? 0.0
    }
    func totalOrderEarnings(addingExtraSec extraSec: Double = 0.0) -> Double {
        if isDiscarded { return 0.0 }
        return calculatedAdjustedWage(addingExtraSec: extraSec) + tipAmount
    }
}

// MARK: - B. 班別判斷與疊單率計算 (修改處)

extension DeliveryBatch {
    enum ShiftType: String, CaseIterable {
        case day = "白天班"
        case night = "晚上班"
    }
    
    var isManualBatch: Bool {
        !orders.isEmpty && orders.contains(where: { $0.isManualEntry })
    }
    
    var shiftReferenceTime: Date {
        orders.map { $0.startTime }.min() ?? createdAt
    }
    
    var batchStartTime: Date? {
        orders.map { $0.startTime }.min()
    }
    
    var batchEndTime: Date? {
        orders.compactMap { $0.endTime }.max()
    }
    
    var shiftType: ShiftType {
        let hour = Calendar.current.component(.hour, from: shiftReferenceTime)
        return hour < DeliveryTrackerViewModel.dayShiftEndHour ? .day : .night
    }
    
    /// 單一批次出門時間 (分鐘) = 第一張接單至最後一張結束的時間差
    var batchDepartureMinutes: Double {
        guard let start = batchStartTime, let end = batchEndTime else { return 0 }
        return max(0, end.timeIntervalSince(start) / 60.0)
    }
}

extension DailyReport {
    private var appTrackedBatches: [DeliveryBatch] {
        batches.filter { !$0.isManualBatch }
    }
    
    /// 白天班/晚上班的「實際出門時間」：
    /// 以訂單時間切成多個出門時段；相鄰訂單若相隔超過 60 分鐘，視為新的出門時段，
    /// 不把中間沒有工作的空檔算進實際出門時間。
    func departureMinutes(for shift: DeliveryBatch.ShiftType) -> Double {
        let allOrders = appTrackedBatches
            .filter { $0.shiftType == shift }
            .flatMap { $0.orders }
            .compactMap { order -> (start: Date, end: Date)? in
                guard let end = order.endTime else { return nil }
                return (start: order.startTime, end: end)
            }
            .sorted { $0.start < $1.start }

        guard let first = allOrders.first else { return 0 }

        var totalMinutes = 0.0
        var sessionStart = first.start
        var sessionEnd = first.end

        for order in allOrders.dropFirst() {
            // 超過 60 分鐘沒有新訂單，視為新的實際出門時段
            if order.start.timeIntervalSince(sessionEnd) > 3600 {
                totalMinutes += max(0, sessionEnd.timeIntervalSince(sessionStart) / 60.0)
                sessionStart = order.start
                sessionEnd = order.end
            } else {
                sessionEnd = max(sessionEnd, order.end)
            }
        }

        totalMinutes += max(0, sessionEnd.timeIntervalSince(sessionStart) / 60.0)
        return totalMinutes
    }
    
    /// 每單累計工時 (分鐘)
    func summedMinutes(for shift: DeliveryBatch.ShiftType) -> Double {
        appTrackedBatches.filter { $0.shiftType == shift }.reduce(0) { $0 + $1.totalSummedMinutes }
    }
    
    /// 騎乘時間 (原本的各批次時間加總)
    func ridingMinutes(for shift: DeliveryBatch.ShiftType) -> Double {
        appTrackedBatches.filter { $0.shiftType == shift }.reduce(0) { $0 + ($1.appBatchDurationSeconds / 60.0) }
    }
    
    /// 2. 疊單率修改為：每單累計工時 / 出門時間
    func overlapRate(for shift: DeliveryBatch.ShiftType) -> Double? {
        let dep = departureMinutes(for: shift)
        guard dep > 0 else { return nil }
        return summedMinutes(for: shift) / dep
    }
    
    /// 等單比 (純做參考)：(出門時間 - 騎乘時間) / 出門時間
    func waitingRatio(for shift: DeliveryBatch.ShiftType) -> Double? {
        let dep = departureMinutes(for: shift)
        guard dep > 0 else { return nil }
        let riding = ridingMinutes(for: shift)
        let wait = max(0, dep - riding)
        return wait / dep
    }
    
    /// 全日出門總時間 (分鐘)
    var totalDepartureMinutes: Double {
        departureMinutes(for: .day) + departureMinutes(for: .night)
    }

    /// 全日疊單率 (修改為：全日每單累計工時 / 全日出門時間)
    var overallOverlapRate: Double? {
        let totalDep = totalDepartureMinutes
        guard totalDep > 0 else { return nil }
        return effectiveSummedMinutesForEfficiency / totalDep
    }
    
    /// 全日等單比 (純做參考)
    var overallWaitingRatio: Double? {
        let totalDep = totalDepartureMinutes
        guard totalDep > 0 else { return nil }
        let totalRiding = effectiveRidingMinutesForEfficiency
        let wait = max(0, totalDep - totalRiding)
        return wait / totalDep
    }

    var effectiveSummedMinutesForEfficiency: Double {
        appTrackedBatches.reduce(0) { $0 + $1.totalSummedMinutes }
    }
    
    var effectiveRidingMinutesForEfficiency: Double {
        appTrackedBatches.reduce(0) { $0 + ($1.appBatchDurationSeconds / 60.0) }
    }
    
    func attendanceStatus(for shift: DeliveryBatch.ShiftType) -> DayAttendanceStatus {
        shift == .day ? dayShiftStatus : nightShiftStatus
    }
}

// ============================================================
// MARK: - C. 分析用資料結構
// ============================================================

struct DailyEfficiencyPoint: Identifiable {
    let id: String
    let date: Date
    let dateLabel: String
    let isWeekend: Bool
    let dayRate: Double?
    let nightRate: Double?
    let overallRate: Double?
    let dayWaitingRatio: Double?      // 新增,純參考
    let nightWaitingRatio: Double?    // 新增,純參考
    let overallWaitingRatio: Double?  // 新增,純參考
    let dayStatus: DayAttendanceStatus
    let nightStatus: DayAttendanceStatus
    let anomalyTags: [AnomalyTag]
    let dayBaseline: Double?
    let nightBaseline: Double?
    let overallBaseline: Double?
    
    var isFullyNormal: Bool { dayStatus == .normal && nightStatus == .normal }
}

struct WeeklyEfficiencyAnalysis {
    let weekStart: Date
    let weekEnd: Date
    let days: [DailyEfficiencyPoint]
    
    // 三種分析：白天 / 晚上 / 全日 各自獨立判斷好跑日、不好跑日
    // 判斷方式：高於（平日/六日各自的）比較基準的前2高 = 好跑日；
    // 低於基準的最低2位 = 建議可休假的不好跑日
    let dayGoodDays: [DailyEfficiencyPoint]
    let dayBadDays: [DailyEfficiencyPoint]
    let nightGoodDays: [DailyEfficiencyPoint]
    let nightBadDays: [DailyEfficiencyPoint]
    let overallGoodDays: [DailyEfficiencyPoint]
    let overallBadDays: [DailyEfficiencyPoint]
    
    // 比較基準（供圖表與文字說明顯示）：平日基準 / 六日(週六日)基準
    // 一律「優先用過去8週同類型的正常出勤平均，沒有過往資料才退回用當週自己的平均」
    let dayBaselineWeekday: Double?
    let dayBaselineWeekend: Double?
    let nightBaselineWeekday: Double?
    let nightBaselineWeekend: Double?
    
    let rainyDays: [DailyEfficiencyPoint]
    let rainyWeekAvgRate: Double?
}

/// 單一星期幾（例如「星期二」）在過去8週的平均疊單率
struct WeekdayRateInsight: Identifiable {
    var id: Int { weekdayIndex }
    let weekdayIndex: Int // 1=週日...7=週六
    let label: String     // "星期二"
    let rate: Double
}

/// 某個維度（白天/晚上/全日）在過去8週裡，哪幾個星期幾表現最好/最差
struct WeekdayPatternGroup {
    let best: [WeekdayRateInsight]  // 平均疊單率最高的前2個星期幾
    let worst: [WeekdayRateInsight] // 平均疊單率最低的2個星期幾
    let sampleCount: Int            // 過去8週裡，總共有幾個「星期幾」有足夠資料可供比較
    
    enum Classification {
        case good  // 歷史上適合跑滿/加班
        case bad   // 歷史上建議排休
    }
    
    /// 給定星期幾（1=週日...7=週六），判斷這天在歷史規律裡屬於「好跑」還是「建議排休」
    func classification(for weekdayIndex: Int) -> Classification? {
        if best.contains(where: { $0.weekdayIndex == weekdayIndex }) { return .good }
        if worst.contains(where: { $0.weekdayIndex == weekdayIndex }) { return .bad }
        return nil
    }
}

/// 前8週星期幾規律洞察：完全只用「當週之前」的歷史資料，不受當週實際跑況影響。
/// 當週資料要等這週結束後，才會成為未來週次計算這個洞察時的歷史資料之一。
struct WeekdayPatternAnalysis {
    let day: WeekdayPatternGroup
    let night: WeekdayPatternGroup
    let overall: WeekdayPatternGroup
    var hasAnyData: Bool { day.sampleCount > 0 || night.sampleCount > 0 || overall.sampleCount > 0 }
}

struct MonthlyEfficiencyData {
    var dayRates: [Double] = []
    var nightRates: [Double] = []
    var dayWaitingRates: [Double] = []      // 新增
    var nightWaitingRates: [Double] = []    // 新增
    var offDayCount: Int = 0
    var anomalyCounts: [AnomalyTag: Int] = [:]
    var anomalyNotes: [String] = []
    var avgDayRate: Double? { dayRates.isEmpty ? nil : dayRates.reduce(0, +) / Double(dayRates.count) }
    var avgNightRate: Double? { nightRates.isEmpty ? nil : nightRates.reduce(0, +) / Double(nightRates.count) }
    var avgDayWaitingRatio: Double? { dayWaitingRates.isEmpty ? nil : dayWaitingRates.reduce(0, +) / Double(dayWaitingRates.count) }       // 新增
    var avgNightWaitingRatio: Double? { nightWaitingRates.isEmpty ? nil : nightWaitingRates.reduce(0, +) / Double(nightWaitingRates.count) } // 新增
    var isPeakSeason: Bool { (avgDayRate ?? 0) > DeliveryTrackerViewModel.goodOverlapThreshold || (avgNightRate ?? 0) > DeliveryTrackerViewModel.goodOverlapThreshold }
}

// ============================================================
// MARK: - D. ViewModel 擴充 (計算邏輯，不新增 @Published 屬性)
// ============================================================

extension DeliveryTrackerViewModel {
    static let goodOverlapThreshold: Double = 1.4
    static let badOverlapThreshold: Double = 1.05
    /// 幾點以前開始的批次算「白天班」，之後算「晚上班」
    static let dayShiftEndHour: Int = 17
    
    /// 週一為一週的開始
    func startOfWeek(containing date: Date) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? date
    }
    
    func weekDates(offset: Int) -> [Date] {
        let thisWeekStart = startOfWeek(containing: Date())
        let targetStart = Calendar.current.date(byAdding: .weekOfYear, value: offset, to: thisWeekStart) ?? thisWeekStart
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: targetStart) }
    }
    
    func weekTitle(offset: Int) -> String {
        let dates = weekDates(offset: offset)
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        guard let first = dates.first, let last = dates.last else { return "" }
        return "\(f.string(from: first)) ~ \(f.string(from: last))"
    }
    
    /// 是否為六（週六）日（週日）
    func isWeekend(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date) // 1=週日, 7=週六
        return weekday == 1 || weekday == 7
    }
    
    /// 星期幾（1=週日...7=週六），用來抓「過去8個星期二」這種同一天的歷史資料
    func weekdayIndex(_ date: Date) -> Int {
        Calendar.current.component(.weekday, from: date)
    }
    /// 給定任意日期，換算成「離本週多少週」的 offset（跟 weekDates(offset:) 定義一致）
    func weekOffset(for date: Date) -> Int {
        let thisWeekStart = startOfWeek(containing: Date())
        let dateWeekStart = startOfWeek(containing: date)
        let comps = Calendar.current.dateComponents([.weekOfYear], from: thisWeekStart, to: dateWeekStart)
        return comps.weekOfYear ?? 0
    }
    
    func efficiencyPoint(for date: Date, weekOffset: Int) -> DailyEfficiencyPoint {
        let key = formatDateKey(date)
        let report = dailyReports[key]
        let f = DateFormatter()
        f.dateFormat = "MM/dd(E)"
        f.locale = Locale(identifier: "zh_TW")
        let weekend = isWeekend(date)
        return DailyEfficiencyPoint(
            id: key,
            date: date,
            dateLabel: f.string(from: date),
            isWeekend: weekend,
            dayRate: report?.overlapRate(for: .day),
            nightRate: report?.overlapRate(for: .night),
            overallRate: report?.overallOverlapRate,
            dayWaitingRatio: report?.waitingRatio(for: .day),
            nightWaitingRatio: report?.waitingRatio(for: .night),
            overallWaitingRatio: report?.overallWaitingRatio,
            dayStatus: report?.dayShiftStatus ?? .normal,
            nightStatus: report?.nightShiftStatus ?? .normal,
            anomalyTags: report?.anomalyTags ?? [],
            dayBaseline: preciseBaselineRate(offset: weekOffset, shift: .day, date: date),
            nightBaseline: preciseBaselineRate(offset: weekOffset, shift: .night, date: date),
            overallBaseline: preciseBaselineOverallRate(offset: weekOffset, date: date)
        )
    }
    
    /// 前 8 週「同一個星期幾」該班正常出勤日平均疊單率（例如都跟過去8個禮拜二比）
    func past8WeeksAverageBySameWeekday(beforeWeekOffset offset: Int, shift: DeliveryBatch.ShiftType, weekdayIndex: Int) -> Double? {
        var rates: [Double] = []
        for w in (offset - 8)..<offset {
            for date in weekDates(offset: w) {
                guard self.weekdayIndex(date) == weekdayIndex else { continue }
                let key = formatDateKey(date)
                guard let report = dailyReports[key] else { continue }
                guard report.attendanceStatus(for: shift) == .normal else { continue }
                if let rate = report.overlapRate(for: shift) {
                    rates.append(rate)
                }
            }
        }
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }
    
    /// 前 8 週「同一個星期幾」全日（白天晚上都正常出勤）平均疊單率
    func past8WeeksOverallAverageBySameWeekday(beforeWeekOffset offset: Int, weekdayIndex: Int) -> Double? {
        var rates: [Double] = []
        for w in (offset - 8)..<offset {
            for date in weekDates(offset: w) {
                guard self.weekdayIndex(date) == weekdayIndex else { continue }
                let key = formatDateKey(date)
                guard let report = dailyReports[key], report.dayShiftStatus == .normal, report.nightShiftStatus == .normal else { continue }
                if let rate = report.overallOverlapRate {
                    rates.append(rate)
                }
            }
        }
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }
    /// 判斷某天是否要排除於「平均每天工時/金額」的計算之外：
    /// 沒有任何紀錄（沒跑）或白天/晚上「只要有一個班」被標記為休假，該天就不列入分母。
    func isExcludedFromDailyAverage(_ date: Date) -> Bool {
        guard let report = dailyReports[formatDateKey(date)] else { return true }
        return report.dayShiftStatus == .off || report.nightShiftStatus == .off
    }
    
    /// 給定一組日期，排除休假日後，計算「平均每天工時(小時)」與「平均每天估算金額」
    /// （金額一律採用 App 自己估算的 totalDailyIncome，不使用 Uber 實發金額）。
    /// 回傳 includedDays 讓畫面可以標註「以幾天為樣本」。
    func averageDailyWorkStats(for dates: [Date]) -> (avgHours: Double?, avgIncome: Double?, includedDays: Int) {
        var hours: [Double] = []
        var incomes: [Double] = []
        for date in dates {
            guard !isExcludedFromDailyAverage(date) else { continue }
            guard let report = dailyReports[formatDateKey(date)] else { continue }
            hours.append(report.totalActualRidingMinutes / 60.0)
            incomes.append(report.totalDailyIncome)
        }
        guard !hours.isEmpty else { return (nil, nil, 0) }
        let avgH = hours.reduce(0, +) / Double(hours.count)
        let avgI = incomes.reduce(0, +) / Double(incomes.count)
        return (avgH, avgI, hours.count)
    }
    func past8WeeksDailyAverage(beforeDate date: Date) -> (avgHours: Double?, avgIncome: Double?, includedDays: Int) {
        let calendar = Calendar.current
        var hours: [Double] = []
        var incomes: [Double] = []
        
        // 往前算 8 週（56天）
        for dayOffset in 1...56 {
            guard let pastDate = calendar.date(byAdding: .day, value: -dayOffset, to: date) else { continue }
            guard !isExcludedFromDailyAverage(pastDate) else { continue }
            guard let report = dailyReports[formatDateKey(pastDate)] else { continue }
            
            hours.append(report.totalActualRidingMinutes / 60.0)
            incomes.append(report.totalDailyIncome)
        }
        
        guard !hours.isEmpty else { return (nil, nil, 0) }
        let avgH = hours.reduce(0, +) / Double(hours.count)
        let avgI = incomes.reduce(0, +) / Double(incomes.count)
        return (avgH, avgI, hours.count)
    }
    func yearlyDailyAverage(year: Int) -> (avgHours: Double?, avgIncome: Double?, includedDays: Int) {
        var hours: [Double] = []
        var incomes: [Double] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        for (dateStr, report) in dailyReports {
            guard let date = formatter.date(from: dateStr) else { continue }
            guard calendar.component(.year, from: date) == year else { continue }
            guard report.dayShiftStatus != .off && report.nightShiftStatus != .off else { continue }
            hours.append(report.totalActualRidingMinutes / 60.0)
            incomes.append(report.totalDailyIncome)
        }
        guard !hours.isEmpty else { return (nil, nil, 0) }
        let avgH = hours.reduce(0, +) / Double(hours.count)
        let avgI = incomes.reduce(0, +) / Double(incomes.count)
        return (avgH, avgI, hours.count)
    }
    
    func pastMonthsDailyAverage(monthsBack: Int) -> (avgHours: Double?, avgIncome: Double?, includedDays: Int) {
        let calendar = Calendar.current
        let today = Date()
        guard let startDate = calendar.date(byAdding: .month, value: -monthsBack, to: today) else { return (nil, nil, 0) }
        var hours: [Double] = []
        var incomes: [Double] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for (dateStr, report) in dailyReports {
            guard let date = formatter.date(from: dateStr) else { continue }
            guard date >= startDate && date <= today else { continue }
            guard report.dayShiftStatus != .off && report.nightShiftStatus != .off else { continue }
            hours.append(report.totalActualRidingMinutes / 60.0)
            incomes.append(report.totalDailyIncome)
        }
        guard !hours.isEmpty else { return (nil, nil, 0) }
        let avgH = hours.reduce(0, +) / Double(hours.count)
        let avgI = incomes.reduce(0, +) / Double(incomes.count)
        return (avgH, avgI, hours.count)
    }
    
    /// 前 8 週「全日」（白天晚上都正常出勤）平均疊單率，平日跟平日比、六日跟六日比（較粗略的大類基準）
    func past8WeeksOverallAverage(beforeWeekOffset offset: Int, weekendOnly: Bool) -> Double? {
        var rates: [Double] = []
        for w in (offset - 8)..<offset {
            for date in weekDates(offset: w) {
                guard isWeekend(date) == weekendOnly else { continue }
                let key = formatDateKey(date)
                guard let report = dailyReports[key], report.dayShiftStatus == .normal, report.nightShiftStatus == .normal else { continue }
                if let rate = report.overallOverlapRate {
                    rates.append(rate)
                }
            }
        }
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }
    /// 直接往前推 7、14、21...天，抓過去8次「同一個星期幾」的估算金額平均。
    /// 用實際天數往前推，不依賴「相對今天第幾週」的 offset，
    /// 這樣才不會把本期自己還沒過完/剛過完的資料誤算成「歷史基準」。
    /// 樣本數不到4筆就不顯示，避免資料太少卻畫出一條看似穩定的假基準線。
    func incomeBaseline(for date: Date) -> Double? {
        var amounts: [Double] = []
        let calendar = Calendar.current
        for i in 1...8 {
            guard let pastDate = calendar.date(byAdding: .day, value: -7 * i, to: date) else { continue }
            let key = formatDateKey(pastDate)
            if let report = dailyReports[key] {
                amounts.append(report.totalDailyIncome)
            }
        }
        guard amounts.count >= 4 else { return nil }
        return amounts.reduce(0, +) / Double(amounts.count)
    }    /// 較粗略的大類基準（平日／六日兩桶），供圖表圖例參考線使用。
    /// 邏輯：過去8週同大類平均，抓不到才退回當週自己同大類平均。
    func baselineRate(offset: Int, shift: DeliveryBatch.ShiftType, weekendOnly: Bool) -> Double? {
        if let past = past8WeeksAverage(beforeWeekOffset: offset, shift: shift, weekendOnly: weekendOnly) {
            return past
        }
        let rates = weekDates(offset: offset)
            .filter { isWeekend($0) == weekendOnly }
            .compactMap { date -> Double? in
                let key = formatDateKey(date)
                guard let report = dailyReports[key], report.attendanceStatus(for: shift) == .normal else { return nil }
                return report.overlapRate(for: shift)
            }
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }
    
    /// 較粗略的大類基準（全日版），邏輯同上
    func baselineOverallRate(offset: Int, weekendOnly: Bool) -> Double? {
        if let past = past8WeeksOverallAverage(beforeWeekOffset: offset, weekendOnly: weekendOnly) {
            return past
        }
        let rates = weekDates(offset: offset)
            .filter { isWeekend($0) == weekendOnly }
            .compactMap { date -> Double? in
                let key = formatDateKey(date)
                guard let report = dailyReports[key], report.dayShiftStatus == .normal, report.nightShiftStatus == .normal else { return nil }
                return report.overallOverlapRate
            }
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }
    func past8WeeksAverage(beforeWeekOffset offset: Int, shift: DeliveryBatch.ShiftType, weekendOnly: Bool) -> Double? {
        var rates: [Double] = []
        let calendar = Calendar.current
        let baseStart = getBiweeklyStart(for: offset)
        
        for week in 1...8 {
            guard let weekDate = calendar.date(byAdding: .day, value: -7 * week, to: baseStart) else { continue }
            let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekDate) }
            
            for date in dates {
                if isWeekend(date) == weekendOnly {
                    let key = formatDateKey(date)
                    if let report = dailyReports[key], report.attendanceStatus(for: shift) == .normal, let rate = report.overlapRate(for: shift) {
                        rates.append(rate)
                    }
                }
            }
        }
        
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }
    /// 好跑日/不好跑日實際使用的精準比較基準，依序退回三層：
    /// 1) 過去8週「同一個星期幾」的正常出勤平均（這禮拜二比過去8個禮拜二）－最準
    /// 2) 抓不到就退回過去8週「平日／六日」大類平均
    /// 3) 完全沒有過往資料（剛開始用）才退回當週自己「平日／六日」大類的平均
    func preciseBaselineRate(offset: Int, shift: DeliveryBatch.ShiftType, date: Date) -> Double? {
        if let sameWeekday = past8WeeksAverageBySameWeekday(beforeWeekOffset: offset, shift: shift, weekdayIndex: weekdayIndex(date)) {
            return sameWeekday
        }
        return baselineRate(offset: offset, shift: shift, weekendOnly: isWeekend(date))
    }
    
    /// 全日版精準比較基準，邏輯同上
    func preciseBaselineOverallRate(offset: Int, date: Date) -> Double? {
        let d = preciseBaselineRate(offset: offset, shift: .day, date: date)
        let n = preciseBaselineRate(offset: offset, shift: .night, date: date)
        switch (d, n) {
        case let (d?, n?): return (d + n) / 2.0
        case let (d?, nil): return d
        case let (nil, n?): return n
        default: return nil
        }
    }
    
    /// 星期幾中文標籤，weekdayIndex 對應 Calendar.weekday（1=週日...7=週六）
    func weekdayChineseLabel(_ weekdayIndex: Int) -> String {
        let names = ["", "日", "一", "二", "三", "四", "五", "六"]
        guard weekdayIndex >= 1 && weekdayIndex <= 7 else { return "" }
        return "星期\(names[weekdayIndex])"
    }
    
    /// 純粹用「offset 週之前」的過去8週資料，算出白天班在每個星期幾的平均疊單率排名
    func weekdayPatternGroup(beforeWeekOffset offset: Int, shift: DeliveryBatch.ShiftType) -> WeekdayPatternGroup {
        var items: [WeekdayRateInsight] = []
        for wd in 1...7 {
            if let rate = past8WeeksAverageBySameWeekday(beforeWeekOffset: offset, shift: shift, weekdayIndex: wd) {
                items.append(WeekdayRateInsight(weekdayIndex: wd, label: weekdayChineseLabel(wd), rate: rate))
            }
        }
        // 至少要有 4 個不同星期幾的資料，好跑 2 個、建議排休 2 個才不會互相重疊
        guard items.count >= 4 else {
            return WeekdayPatternGroup(best: [], worst: [], sampleCount: items.count)
        }
        let sorted = items.sorted { $0.rate > $1.rate }
        let best = Array(sorted.prefix(2))
        let worst = Array(sorted.suffix(2).reversed())
        return WeekdayPatternGroup(best: best, worst: worst, sampleCount: items.count)
    }
    
    /// 全日版本，邏輯同上
    func weekdayPatternOverallGroup(beforeWeekOffset offset: Int) -> WeekdayPatternGroup {
        var items: [WeekdayRateInsight] = []
        for wd in 1...7 {
            let d = past8WeeksAverageBySameWeekday(beforeWeekOffset: offset, shift: .day, weekdayIndex: wd)
            let n = past8WeeksAverageBySameWeekday(beforeWeekOffset: offset, shift: .night, weekdayIndex: wd)
            let rate: Double?
            switch (d, n) {
            case let (d?, n?): rate = (d + n) / 2.0
            case let (d?, nil): rate = d
            case let (nil, n?): rate = n
            default: rate = nil
            }
            if let rate = rate {
                items.append(WeekdayRateInsight(weekdayIndex: wd, label: weekdayChineseLabel(wd), rate: rate))
            }
        }
        guard items.count >= 4 else {
            return WeekdayPatternGroup(best: [], worst: [], sampleCount: items.count)
        }
        let sorted = items.sorted { $0.rate > $1.rate }
        let best = Array(sorted.prefix(2))
        let worst = Array(sorted.suffix(2).reversed())
        return WeekdayPatternGroup(best: best, worst: worst, sampleCount: items.count)
    }
    
    /// 前8週星期幾洞察：只看「這一週之前」的歷史資料，跟當週實際跑況完全無關。
    /// 當週資料要等這週結束、往後翻到下一週時，才會變成過去8週的一部分。
    func weekdayPatternAnalysis(beforeWeekOffset offset: Int) -> WeekdayPatternAnalysis {
        WeekdayPatternAnalysis(
            day: weekdayPatternGroup(beforeWeekOffset: offset, shift: .day),
            night: weekdayPatternGroup(beforeWeekOffset: offset, shift: .night),
            overall: weekdayPatternOverallGroup(beforeWeekOffset: offset)
        )
    }
    
    func weeklyEfficiencyAnalysis(offset: Int) -> WeeklyEfficiencyAnalysis {
        let dates = weekDates(offset: offset)
        let points = dates.map { efficiencyPoint(for: $0, weekOffset: offset) }
        
        let dayNormalPoints = points.filter { $0.dayStatus == .normal }
        let nightNormalPoints = points.filter { $0.nightStatus == .normal }
        let overallNormalPoints = points.filter { $0.isFullyNormal }
        
        // 高於（平日/六日各自）基準的前2高 = 好跑日；低於基準的最低2位 = 建議可休假
        func topGoodDays(_ pts: [DailyEfficiencyPoint], rate: (DailyEfficiencyPoint) -> Double?, baseline: (DailyEfficiencyPoint) -> Double?) -> [DailyEfficiencyPoint] {
            let aboveBaseline = pts.filter {
                guard let r = rate($0), let b = baseline($0) else { return false }
                return r > b
            }
            let sorted = aboveBaseline.sorted { (rate($0) ?? 0) > (rate($1) ?? 0) }
            return Array(sorted.prefix(2))
        }
        func bottomBadDays(_ pts: [DailyEfficiencyPoint], rate: (DailyEfficiencyPoint) -> Double?, baseline: (DailyEfficiencyPoint) -> Double?) -> [DailyEfficiencyPoint] {
            let belowBaseline = pts.filter {
                guard let r = rate($0), let b = baseline($0) else { return false }
                return r < b
            }
            let sorted = belowBaseline.sorted { (rate($0) ?? 0) < (rate($1) ?? 0) }
            return Array(sorted.prefix(2))
        }
        
        let rainyDays = points.filter { $0.anomalyTags.contains(.rain) }
        var rainyAvg: Double? = nil
        if rainyDays.count >= 3 {
            let rates = rainyDays.compactMap { $0.overallRate }
            if !rates.isEmpty { rainyAvg = rates.reduce(0, +) / Double(rates.count) }
        }
        
        return WeeklyEfficiencyAnalysis(
            weekStart: dates.first ?? Date(),
            weekEnd: dates.last ?? Date(),
            days: points,
            dayGoodDays: topGoodDays(dayNormalPoints, rate: { $0.dayRate }, baseline: { $0.dayBaseline }),
            dayBadDays: bottomBadDays(dayNormalPoints, rate: { $0.dayRate }, baseline: { $0.dayBaseline }),
            nightGoodDays: topGoodDays(nightNormalPoints, rate: { $0.nightRate }, baseline: { $0.nightBaseline }),
            nightBadDays: bottomBadDays(nightNormalPoints, rate: { $0.nightRate }, baseline: { $0.nightBaseline }),
            overallGoodDays: topGoodDays(overallNormalPoints, rate: { $0.overallRate }, baseline: { $0.overallBaseline }),
            overallBadDays: bottomBadDays(overallNormalPoints, rate: { $0.overallRate }, baseline: { $0.overallBaseline }),
            dayBaselineWeekday: baselineRate(offset: offset, shift: .day, weekendOnly: false),
            dayBaselineWeekend: baselineRate(offset: offset, shift: .day, weekendOnly: true),
            nightBaselineWeekday: baselineRate(offset: offset, shift: .night, weekendOnly: false),
            nightBaselineWeekend: baselineRate(offset: offset, shift: .night, weekendOnly: true),
            rainyDays: rainyDays,
            rainyWeekAvgRate: rainyAvg
        )
    }
    
    /// 年度／月份統計：白天/晚上分開判斷休假；異常仍計入營收與月統計，並附備註。
    /// 「當月休幾天」只計「白天晚上都休」的整天休假，不包含只休其中一班的日子。
    func monthlyEfficiencyBreakdown(year: Int) -> [Int: MonthlyEfficiencyData] {
        var result: [Int: MonthlyEfficiencyData] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        
        for (dateStr, report) in dailyReports {
            guard let date = formatter.date(from: dateStr) else { continue }
            guard calendar.component(.year, from: date) == year else { continue }
            let month = calendar.component(.month, from: date)
            var data = result[month] ?? MonthlyEfficiencyData()
            
            if report.dayShiftStatus == .off && report.nightShiftStatus == .off {
                data.offDayCount += 1
            } else {
                if report.dayShiftStatus != .off, let d = report.overlapRate(for: .day) {
                    data.dayRates.append(d)
                }
                if report.nightShiftStatus != .off, let n = report.overlapRate(for: .night) {
                    data.nightRates.append(n)
                }
                if report.dayShiftStatus != .off, let dw = report.waitingRatio(for: .day) {
                    data.dayWaitingRates.append(dw)
                }
                if report.nightShiftStatus != .off, let nw = report.waitingRatio(for: .night) {
                    data.nightWaitingRates.append(nw)
                }
                if report.dayShiftStatus == .anomaly || report.nightShiftStatus == .anomaly {
                    for tag in report.anomalyTags {
                        data.anomalyCounts[tag, default: 0] += 1
                    }
                    if !report.anomalyNote.isEmpty {
                        data.anomalyNotes.append("\(dateStr): \(report.anomalyNote)")
                    }
                }
            }
            result[month] = data
        }
        return result
    }
    
    // ---- 日狀態編輯用寫入函式 ----
    func updateDayShiftStatus(for date: Date, status: DayAttendanceStatus) {
        let key = formatDateKey(date)
        var report = dailyReports[key] ?? DailyReport(dateString: key)
        report.dayShiftStatus = status
        dailyReports[key] = report
    }
    
    func updateNightShiftStatus(for date: Date, status: DayAttendanceStatus) {
        let key = formatDateKey(date)
        var report = dailyReports[key] ?? DailyReport(dateString: key)
        report.nightShiftStatus = status
        dailyReports[key] = report
    }
    
    func toggleAnomalyTag(for date: Date, tag: AnomalyTag) {
        let key = formatDateKey(date)
        var report = dailyReports[key] ?? DailyReport(dateString: key)
        if let idx = report.anomalyTags.firstIndex(of: tag) {
            report.anomalyTags.remove(at: idx)
        } else {
            report.anomalyTags.append(tag)
        }
        dailyReports[key] = report
    }
    
    func updateAnomalyNote(for date: Date, note: String) {
        let key = formatDateKey(date)
        var report = dailyReports[key] ?? DailyReport(dateString: key)
        report.anomalyNote = note
        dailyReports[key] = report
    }
}

// ============================================================
// MARK: - E. 分頁五: 疊單率分析 View
// ============================================================

struct EfficiencyAnalysisTabView: View {
    @ObservedObject var viewModel: DeliveryTrackerViewModel
    @State private var mode: AnalysisMode = .weekly
    @State private var weekOffset: Int = 0
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    
    enum AnalysisMode: String, CaseIterable {
        case weekly = "週疊單率分析"
        case yearly = "年疊單率分析"
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("分析模式", selection: $mode) {
                        ForEach(AnalysisMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    
                    if mode == .weekly {
                        WeeklyEfficiencyView(viewModel: viewModel, weekOffset: $weekOffset)
                    } else {
                        YearlyEfficiencyView(viewModel: viewModel, selectedYear: $selectedYear)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("疊單率分析")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { hideKeyboard() }.bold().foregroundColor(.blue)
                }
            }
        }
    }
}

// MARK: E-1 週疊單率分析

struct WeeklyEfficiencyView: View {
    @ObservedObject var viewModel: DeliveryTrackerViewModel
    @Binding var weekOffset: Int
    
    private var analysis: WeeklyEfficiencyAnalysis {
        viewModel.weeklyEfficiencyAnalysis(offset: weekOffset)
    }
    
    private var weekdayInsight: WeekdayPatternAnalysis {
        viewModel.weekdayPatternAnalysis(beforeWeekOffset: weekOffset)
    }
    private var waitingChartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("白天班 / 晚上班 等單比(僅供參考)", systemImage: "hourglass")
                .font(.subheadline).bold()
            Chart {
                ForEach(analysis.days) { point in
                    if let d = point.dayWaitingRatio {
                        LineMark(x: .value("日期", shortDateLabel(point.date)), y: .value("等單比", d))
                            .foregroundStyle(by: .value("班別", "白天班"))
                            .symbol(by: .value("班別", "白天班"))
                    }
                    if let n = point.nightWaitingRatio {
                        LineMark(x: .value("日期", shortDateLabel(point.date)), y: .value("等單比", n))
                            .foregroundStyle(by: .value("班別", "晚上班"))
                            .symbol(by: .value("班別", "晚上班"))
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = value.as(Double.self) {
                            Text("\(Int(d * 100))%")
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel().font(.system(size: 10))
                }
            }
            .frame(height: 220)
            Text("等單比 = 該班從第一單開始到最後一單結束這段時間裡,手上沒有訂單在跑的比例。純參考數字,不影響好跑日/建議排休的判斷。")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    var body: some View {
        VStack(spacing: 16) {
            weekdayInsightCard
            weekPickerCard
            chartCard
            waitingChartCard
            summaryCard
            if analysis.rainyWeekAvgRate != nil {
                rainyCard
            }
            dayStatusEditorCard
        }
    }
    
    /// 置頂：純粹用「這一週之前」的過去8週資料，抓出哪幾個星期幾歷史上特別好跑/不好跑。
    /// 跟這週實際有沒有跑、跑得好不好完全無關��這是「先知道規律再排班」的建議，
    /// 不是事後對這週表現打分數。當週資料要等這週結束才會變成往後週次的歷史參考。
    private var weekdayInsightCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("前8週星期幾洞察（排班建議）", systemImage: "sparkles")
                .font(.subheadline).bold().foregroundColor(.yellow)
            Text("完全根據這一週「之前」累積的歷史資料，跟這週實際跑況無關；這週資料要等這週結束後，才會成為未來週次的參考基礎。")
                .font(.caption2).foregroundColor(.secondary)
            
            if !weekdayInsight.hasAnyData {
                Text("目前累積的歷史資料還不夠（需要過去至少出現過同一個星期幾的正常出勤紀錄），等資料多累積幾週後就會顯示建議。")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                weekdayInsightGroup(title: "🌞 白天班", color: .blue, group: weekdayInsight.day)
                Divider()
                weekdayInsightGroup(title: "🌙 晚上班", color: .orange, group: weekdayInsight.night)
                Divider()
                weekdayInsightGroup(title: "📅 全日", color: .purple, group: weekdayInsight.overall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading) // 新增這行：限制內容自適應寬度不溢出
        .padding()
        .background(Color.yellow.opacity(0.08))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.3), lineWidth: 1))
        .padding(.horizontal)
    }
    
    private func weekdayInsightGroup(title: String, color: Color, group: WeekdayPatternGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).bold().foregroundColor(color)
            if group.sampleCount == 0 {
                Text("尚無歷史資料").font(.caption2).foregroundColor(.secondary)
            } else {
                if !group.best.isEmpty {
                    Text("🔥 適合跑滿/加班：" + group.best.map { "\($0.label)（\(String(format: "%.2f", $0.rate))）" }.joined(separator: "、"))
                        .font(.caption2).foregroundColor(.green)
                }
                if !group.worst.isEmpty {
                    Text("💤 建議排休：" + group.worst.map { "\($0.label)（\(String(format: "%.2f", $0.rate))）" }.joined(separator: "、"))
                        .font(.caption2).foregroundColor(.red)
                }
                if group.sampleCount < 4 {
                    Text("（目前只有 \(group.sampleCount) 個星期幾有足夠資料，排名可能重疊，僅供參考）")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var weekPickerCard: some View {
        HStack {
            Button(action: { weekOffset -= 1 }) {
                Image(systemName: "chevron.left.circle.fill").font(.title2)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("週期範圍").font(.caption).foregroundColor(.secondary)
                Text(viewModel.weekTitle(offset: weekOffset))
                    .font(.headline).bold().foregroundColor(.blue)
            }
            Spacer()
            Button(action: { weekOffset += 1 }) {
                Image(systemName: "chevron.right.circle.fill").font(.title2)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    /// 給圖表 X 軸用的短日期格式（例："9/3"），避免長格式在窄螢幕上被裁切看不到字
    private func shortDateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: date)
    }
    
    private var chartCard: some View {
            VStack(alignment: .leading, spacing: 8) {
                Label("白天班 / 晚上班 疊單率走勢 (含沒單顧路因素)", systemImage: "chart.xyaxis.line")
                    .font(.subheadline).bold()
                
                VStack(alignment: .leading, spacing: 4) {
                    baselineLegendRow(label: "白天", color: .blue, weekday: analysis.dayBaselineWeekday, weekend: analysis.dayBaselineWeekend)
                    baselineLegendRow(label: "晚上", color: .orange, weekday: analysis.nightBaselineWeekday, weekend: analysis.nightBaselineWeekend)
                }
                
                Chart {
                    ForEach(analysis.days) { point in
                        if let d = point.dayRate {
                            LineMark(x: .value("日期", shortDateLabel(point.date)), y: .value("疊單率", d))
                                .foregroundStyle(by: .value("班別", "白天班"))
                                .symbol(by: .value("班別", "白天班"))
                        }
                        if let n = point.nightRate {
                            LineMark(x: .value("日期", shortDateLabel(point.date)), y: .value("疊單率", n))
                                .foregroundStyle(by: .value("班別", "晚上班"))
                                .symbol(by: .value("班別", "晚上班"))
                        }
                    }
                    if let dayAvg = analysis.dayBaselineWeekday {
                        RuleMark(y: .value("白天平日基準", dayAvg))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            .foregroundStyle(.blue.opacity(0.5))
                    }
                    if let nightAvg = analysis.nightBaselineWeekday {
                        RuleMark(y: .value("晚上平日基準", nightAvg))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            .foregroundStyle(.orange.opacity(0.5))
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisValueLabel().font(.system(size: 10))
                    }
                }
                .frame(height: 240)
                
                Text("分母已調整為出門時間（首單接單至尾單結束），真實反應沒單顧路的疊單效率。騎乘時間與等單比請參考下方折線圖。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    private func baselineLegendRow(label: String, color: Color, weekday: Double?, weekend: Double?) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("\(label)平日基準 \(weekday.map { String(format: "%.2f", $0) } ?? "-")")
            }
            HStack(spacing: 4) {
                Circle().stroke(color, lineWidth: 1).frame(width: 6, height: 6)
                Text("\(label)六日基準 \(weekend.map { String(format: "%.2f", $0) } ?? "-")")
            }
        }
        .font(.caption2).foregroundColor(color)
    }
    
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("本週實際表現對照", systemImage: "checklist")
                .font(.subheadline).bold().foregroundColor(.cyan)
            Text("這是回頭看這週實際發生的日子：跟過去8個同星期幾比，高於基準前2高＝表現特別好；低於基準最低2位＝表現特別差。這跟上面「排班建議」不同��上面是事前規律，這裡是事後對照。")
                .font(.caption2).foregroundColor(.secondary)
            
            analysisGroup(title: "🌞 白天班", color: .blue,
                          good: analysis.dayGoodDays, bad: analysis.dayBadDays,
                          rate: { $0.dayRate }, baseline: { $0.dayBaseline })
            Divider()
            analysisGroup(title: "🌙 晚上班", color: .orange,
                          good: analysis.nightGoodDays, bad: analysis.nightBadDays,
                          rate: { $0.nightRate }, baseline: { $0.nightBaseline })
            Divider()
            analysisGroup(title: "📅 全日", color: .purple,
                          good: analysis.overallGoodDays, bad: analysis.overallBadDays,
                          rate: { $0.overallRate }, baseline: { $0.overallBaseline })
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    /// 單一維度（白天/晚上/全日）的好跑日、不好跑日清單
    private func analysisGroup(
        title: String,
        color: Color,
        good: [DailyEfficiencyPoint],
        bad: [DailyEfficiencyPoint],
        rate: @escaping (DailyEfficiencyPoint) -> Double?,
        baseline: @escaping (DailyEfficiencyPoint) -> Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).bold().foregroundColor(color)
            if good.isEmpty && bad.isEmpty {
                Text("尚無足夠正常出勤資料可供分析").font(.caption2).foregroundColor(.secondary)
            }
            if !good.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("🔥 好跑日（建議跑滿/加班）").font(.caption2).bold().foregroundColor(.green)
                    ForEach(good) { day in
                        Text("・\(day.dateLabel)\(day.isWeekend ? "六日" : "平日")　疊單率 \(String(format: "%.2f", rate(day) ?? 0))（基準 \(String(format: "%.2f", baseline(day) ?? 0))）")
                            .font(.caption2).foregroundColor(.primary)
                    }
                }
            }
            if !bad.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("💤 不好跑日（建議排休/提早收工）").font(.caption2).bold().foregroundColor(.red)
                    ForEach(bad) { day in
                        Text("・\(day.dateLabel)\(day.isWeekend ? "六日" : "平日")　疊單率 \(String(format: "%.2f", rate(day) ?? 0))（基準 \(String(format: "%.2f", baseline(day) ?? 0))）")
                            .font(.caption2).foregroundColor(.primary)
                    }
                }
            }
        }
    }
    
    private var rainyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("雨季專案分析", systemImage: "cloud.rain.fill")
                .font(.subheadline).bold().foregroundColor(.blue)
            Text("本週有 \(analysis.rainyDays.count) 天標記為雨天，平均疊單率 \(String(format: "%.2f", analysis.rainyWeekAvgRate ?? 0))")
                .font(.caption)
            HStack(spacing: 8) {
                ForEach(analysis.rainyDays) { day in
                    Text("\(day.dateLabel): \(String(format: "%.2f", day.overallRate ?? 0))")
                        .font(.caption2).bold()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12)).cornerRadius(6)
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.06))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.25), lineWidth: 1))
        .padding(.horizontal)
    }
    
    private var dayStatusEditorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("每日出勤狀態設定", systemImage: "calendar.badge.exclamationmark")
                .font(.subheadline).bold()
            Text("白天班、晚上班分開設定，預設皆為「正常出勤」；標記休假該班完全不列入平均，標記異常則排除於週均值計算，但仍計入年度營收與月統計（當月休幾天只計白天晚上都休的整天）。")
                .font(.caption2).foregroundColor(.secondary)
            ForEach(analysis.days) { point in
                DayStatusEditorRow(viewModel: viewModel, date: point.date, point: point, insight: weekdayInsight)
                Divider()
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

struct DayStatusEditorRow: View {
    @ObservedObject var viewModel: DeliveryTrackerViewModel
    let date: Date
    let point: DailyEfficiencyPoint
    let insight: WeekdayPatternAnalysis
    
    private var key: String { viewModel.formatDateKey(date) }
    private var weekdayIdx: Int { viewModel.weekdayIndex(date) }
    
    private var dayClassification: WeekdayPatternGroup.Classification? {
        insight.day.classification(for: weekdayIdx)
    }
    private var nightClassification: WeekdayPatternGroup.Classification? {
        insight.night.classification(for: weekdayIdx)
    }
    private var overallClassification: WeekdayPatternGroup.Classification? {
        insight.overall.classification(for: weekdayIdx)
    }
    
    private func badgeColor(_ c: WeekdayPatternGroup.Classification?) -> Color? {
        switch c {
        case .good: return .green
        case .bad: return .red
        case nil: return nil
        }
    }
    
    private func badgeText(_ c: WeekdayPatternGroup.Classification?) -> String? {
        switch c {
        case .good: return "🔥 歷史好跑日"
        case .bad: return "😴 建議排休"
        case nil: return nil
        }
    }
    
    private func classificationBadge(_ c: WeekdayPatternGroup.Classification?) -> some View {
        Group {
            if let text = badgeText(c), let color = badgeColor(c) {
                Text(text)
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.18))
                    .foregroundColor(color)
                    .cornerRadius(6)
            }
        }
    }
    
    // 直接讀 viewModel，不额外建立新的 Binding 物件（避免每次刷新都產生新 Binding
    // 導致下拉選單卡住/顯示空白），改用按鈕直接呼叫 viewModel 的更新函式。
    private var currentDayStatus: DayAttendanceStatus {
        viewModel.dailyReports[key]?.dayShiftStatus ?? .normal
    }
    private var currentNightStatus: DayAttendanceStatus {
        viewModel.dailyReports[key]?.nightShiftStatus ?? .normal
    }
    
    private var noteBinding: Binding<String> {
        Binding(
            get: { viewModel.dailyReports[key]?.anomalyNote ?? "" },
            set: { viewModel.updateAnomalyNote(for: date, note: $0) }
        )
    }
    
    private func statusButtonsRow(current: DayAttendanceStatus, onSelect: @escaping (DayAttendanceStatus) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(DayAttendanceStatus.allCases, id: \.self) { s in
                let isOn = current == s
                Button(action: { onSelect(s) }) {
                    Text(s.rawValue)
                        .font(.caption).bold()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(isOn ? Color.blue : Color.gray.opacity(0.15))
                        .foregroundColor(isOn ? .white : .primary)
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(point.dateLabel)\(point.isWeekend ? "（六日）" : "")")
                        .font(.subheadline).bold()
                        .foregroundColor(badgeColor(overallClassification) ?? .primary)
                    classificationBadge(overallClassification)
                }
                HStack(spacing: 10) {
                    Text("白天 \(point.dayRate.map { String(format: "%.2f", $0) } ?? "-")／基準 \(point.dayBaseline.map { String(format: "%.2f", $0) } ?? "-")")
                        .foregroundColor(.blue)
                }
                .font(.caption2)
                HStack(spacing: 10) {
                    Text("晚上 \(point.nightRate.map { String(format: "%.2f", $0) } ?? "-")／基準 \(point.nightBaseline.map { String(format: "%.2f", $0) } ?? "-")")
                        .foregroundColor(.orange)
                }
                .font(.caption2)
                HStack(spacing: 10) {
                    Text("全日 \(point.overallRate.map { String(format: "%.2f", $0) } ?? "-")／基準 \(point.overallBaseline.map { String(format: "%.2f", $0) } ?? "-")")
                        .foregroundColor(.secondary)
                }
                .font(.caption2)
            }
            
            // 白天班、晚上班分開設定出勤狀態，直接點選按鈕，不用下拉選單
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("白天班").font(.caption2).bold().foregroundColor(badgeColor(dayClassification) ?? .blue)
                    classificationBadge(dayClassification)
                }
                statusButtonsRow(current: currentDayStatus) { viewModel.updateDayShiftStatus(for: date, status: $0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("晚上班").font(.caption2).bold().foregroundColor(badgeColor(nightClassification) ?? .orange)
                    classificationBadge(nightClassification)
                }
                statusButtonsRow(current: currentNightStatus) { viewModel.updateNightShiftStatus(for: date, status: $0) }
            }
            
            if currentDayStatus == .anomaly || currentNightStatus == .anomaly {
                HStack(spacing: 8) {
                    ForEach(AnomalyTag.allCases) { tag in
                        let isOn = viewModel.dailyReports[key]?.anomalyTags.contains(tag) ?? false
                        Button(action: { viewModel.toggleAnomalyTag(for: date, tag: tag) }) {
                            Text(tag.rawValue)
                                .font(.caption2).bold()
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(isOn ? Color.orange : Color.gray.opacity(0.15))
                                .foregroundColor(isOn ? .white : .primary)
                                .cornerRadius(6)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                DeferringTextField(
                    placeholder: "異常事件備註（例：颱風、路封）",
                    externalValue: noteBinding,
                    font: .preferredFont(forTextStyle: .caption1)
                )
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: E-2 年疊單率分析

struct YearlyEfficiencyView: View {
    @ObservedObject var viewModel: DeliveryTrackerViewModel
    @Binding var selectedYear: Int
    
    private var monthly: [Int: MonthlyEfficiencyData] {
        viewModel.monthlyEfficiencyBreakdown(year: selectedYear)
    }
    private var waitingChartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("1~12 月 白天/晚上 等單比(僅供參考)", systemImage: "hourglass")
                .font(.subheadline).bold()
            Chart {
                ForEach(1...12, id: \.self) { month in
                    let data = monthly[month] ?? MonthlyEfficiencyData()
                    if let d = data.avgDayWaitingRatio {
                        LineMark(x: .value("月份", "\(month)月"), y: .value("等單比", d))
                            .foregroundStyle(by: .value("班別", "白天班"))
                            .symbol(by: .value("班別", "白天班"))
                    }
                    if let n = data.avgNightWaitingRatio {
                        LineMark(x: .value("月份", "\(month)月"), y: .value("等單比", n))
                            .foregroundStyle(by: .value("班別", "晚上班"))
                            .symbol(by: .value("班別", "晚上班"))
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = value.as(Double.self) {
                            Text("\(Int(d * 100))%")
                        }
                    }
                }
            }
            .frame(height: 220)
            Text("純參考數字,不影響旺季/淡季或任何分析判斷。")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    var body: some View {
        VStack(spacing: 16) {
            yearPickerCard
            chartCard
            waitingChartCard
            monthlyTableCard
        }
    }
    
    private var yearPickerCard: some View {
        HStack {
            Button(action: { selectedYear -= 1 }) {
                Image(systemName: "chevron.left.circle.fill").font(.title2)
            }
            Spacer()
            Text("\(String(selectedYear)) 年度疊單率分析")
                .font(.title3).bold().foregroundColor(.blue)
            Spacer()
            Button(action: { selectedYear += 1 }) {
                Image(systemName: "chevron.right.circle.fill").font(.title2)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("1~12 月 白天/晚上 疊單率走勢（旺季/淡季）", systemImage: "chart.bar.xaxis")
                .font(.subheadline).bold()
            Chart {
                ForEach(1...12, id: \.self) { month in
                    let data = monthly[month] ?? MonthlyEfficiencyData()
                    if let d = data.avgDayRate {
                        LineMark(x: .value("月份", "\(month)月"), y: .value("疊單率", d))
                            .foregroundStyle(by: .value("班別", "白天班"))
                            .symbol(by: .value("班別", "白天班"))
                    }
                    if let n = data.avgNightRate {
                        LineMark(x: .value("月份", "\(month)月"), y: .value("疊單率", n))
                            .foregroundStyle(by: .value("班別", "晚上班"))
                            .symbol(by: .value("班別", "晚上班"))
                    }
                }
                RuleMark(y: .value("旺季門檻", DeliveryTrackerViewModel.goodOverlapThreshold))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.green.opacity(0.5))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("旺季門檻 1.4").font(.caption2).foregroundColor(.green)
                    }
                RuleMark(y: .value("淡季門檻", DeliveryTrackerViewModel.badOverlapThreshold))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.red.opacity(0.5))
                    .annotation(position: .bottom, alignment: .trailing) {
                        Text("淡季門檻 1.05").font(.caption2).foregroundColor(.red)
                    }
            }
            .frame(height: 240)
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    private var monthlyTableCard: some View {
        VStack(spacing: 0) {
            // 表頭
            HStack {
                Text("月份").font(.caption).bold().frame(width: 45, alignment: .leading)
                Spacer()
                Text("疊單率 (日/夜)").font(.caption).bold().frame(width: 95, alignment: .trailing)
                Spacer()
                Text("等單比 (日/夜)").font(.caption).bold().frame(width: 95, alignment: .trailing)
                Spacer()
                Text("休幾天").font(.caption).bold().frame(width: 45, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.15))
            
            Divider()
            
            // 列表內容
            ForEach(1...12, id: \.self) { month in
                let data = monthly[month] ?? MonthlyEfficiencyData()
                
                HStack {
                    // 月份
                    Text("\(month)月")
                        .font(.subheadline)
                        .bold()
                        .frame(width: 45, alignment: .leading)
                    
                    Spacer()
                    
                    // 疊單率 (日 / 夜)
                    Text("\(data.avgDayRate.map { String(format: "%.2f", $0) } ?? "-") / \(data.avgNightRate.map { String(format: "%.2f", $0) } ?? "-")")
                        .font(.caption)
                        .frame(width: 95, alignment: .trailing)
                    
                    Spacer()
                    
                    // 等單比 (日 / 夜)
                    Text("\(data.avgDayWaitingRatio.map { String(format: "%.0f%%", $0 * 100) } ?? "-") / \(data.avgNightWaitingRatio.map { String(format: "%.0f%%", $0 * 100) } ?? "-")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 95, alignment: .trailing)
                    
                    Spacer()
                    
                    // 休幾天
                    Text("\(data.offDayCount)天")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 45, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                if month < 12 {
                    Divider()
                }
            }
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// ============================================================
// MARK: - F. 整合說明（請對照原始檔案手動加入以下兩處）
// ============================================================
//
// 1) 將原始檔案中的 `struct DailyReport { ... }` 整段刪除，
//    改用本檔案「區塊 A」的新版本取代（欄位與計算屬性皆已包含原本內容）。
//
// 2) 在 `ContentView` 的 `TabView` 中加入第五個分頁：
//
//    struct ContentView: View {
//        @StateObject private var viewModel = DeliveryTrackerViewModel()
//        var body: some View {
//            TabView {
//                TimerMainView(viewModel: viewModel)
//                    .tabItem { Label("實時計時", systemImage: "timer") }
//                ReportAndAuditView(viewModel: viewModel)
//                    .tabItem { Label("歷史對帳", systemImage: "doc.text.magnifyingglass") }
//                BiweeklySummaryTabView(viewModel: viewModel)
//                    .tabItem { Label("雙週對帳", systemImage: "calendar.badge.clock") }
//                YearlyReportTabView(viewModel: viewModel)
//                    .tabItem { Label("年報與瘦身", systemImage: "chart.bar.doc.horizontal.fill") }
//                EfficiencyAnalysisTabView(viewModel: viewModel)          // <- 新增
//                    .tabItem { Label("疊單率分析", systemImage: "chart.line.uptrend.xyaxis") } // <- 新增
//            }
//        }
//    }
//
// 其餘檔案（DeliveryOrder、DeliveryBatch、DeliveryTrackerViewModel 本體、
// TimerMainView、ReportAndAuditView...等）完全不需要更動，
// 本檔案全部以 extension 或新 View/Struct 的方式擴充，不會破壞原本邏輯。
class DeliveryTrackerViewModel: ObservableObject {
    @Published var activeOrders: [DeliveryOrder] = [] {
        didSet {
            scheduleSave(key: "activeOrders") { self.saveActiveOrders() }
            if !self.activeOrders.isEmpty {
                self.syncToLiveActivity()
            }
        }
    }
    @Published var timerGroups: [OrderTimerGroup] = [] { didSet { scheduleSave(key: "timerGroups") { self.saveTimerGroups() } } }
    @Published var isTestModeEnabled: Bool = false
    @Published var selectedInitialCount: Int = 1
    @Published var selectedAddOnCount: Int = 1
    @Published private var currentBatchCounter: Int = 1
    @Published var dailyReports: [String: DailyReport] = [:] { didSet { scheduleSave(key: "dailyReports") { self.saveDailyReports() } } }
    @Published var selectedReportDate: Date = Date()
    @Published var selectedBiweeklyCycleOffset: Int = 0
    @Published var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @Published var timerPulse: Date = Date()
    @Published var biweeklyPayoutInputs: [String: String] = [:] { didSet { scheduleSave(key: "payoutInputs") { self.savePayoutInputs() } } }
    @Published var lastFinalizedBatch: (dateKey: String, batch: DeliveryBatch)? = nil
    // 改動7:記錄「最後一次復原」前的狀態，讓使用者可以「取消復原」，避免誤觸復原按鈕
    @Published var lastRestoredOrderSnapshot: (orderID: UUID, wasCompleted: Bool, wasDiscarded: Bool, previousEndTime: Date?)? = nil
    
    @Published var currentBatchSalary: Double = 0.0
    @Published var hourlyRate: Double = 200.0
    
    private var timer: Timer?
    private var saveTasks: [String: Task<Void, Never>] = [:]
    
    private func scheduleSave(key: String, action: @escaping () -> Void) {
        saveTasks[key]?.cancel()
        saveTasks[key] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            action()
        }
    }
    private var testTimerCounter: Int = 1
    private var liveActivityTick: Int = 0
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let reportsKey = "SavedDailyReportsData"
    private let activeOrdersKey = "SavedActiveOrdersData"
    private let timerGroupsKey = "SavedTimerGroupsData"
    private let payoutInputsKey = "SavedPayoutInputsData"
    
    // 改動7:已完成的訂單改成「最後完成的排最上面」，方便誤按完成時第一眼就看到、好復原；
    // 尚未完成的訂單維持原本依開始時間排序。
    var sortedActiveOrders: [DeliveryOrder] {
        activeOrders.sorted { o1, o2 in
            if o1.isCompleted != o2.isCompleted {
                return !o1.isCompleted
            }
            if o1.isCompleted {
                let t1 = o1.endTime ?? o1.startTime
                let t2 = o2.endTime ?? o2.startTime
                return t1 > t2
            }
            return o1.startTime < o2.startTime
        }
    }
    
    init() {
        DeliveryTrackerViewModel.current = self
        setupBackgroundAudio()
        loadAllData()
        startTimer()
        requestNotificationPermission()
    }
    
    deinit {
        timer?.invalidate()
    }
    
    func importUberCSVAndSetPayouts(csvString: String) {
        let lines = csvString.components(separatedBy: .newlines)
        guard lines.count > 1 else { return }
        var dailyTotals: [String: Double] = [:]
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy/MM/dd hh:mm a"
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")
        let keyFormatter = DateFormatter()
        keyFormatter.dateFormat = "yyyy-MM-dd"
        
        for line in lines.dropFirst() {
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 6 else { continue }
            let rawDateStr = cols[0].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            let rawAmountStr = cols[5].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            
            if rawDateStr.lowercased().contains("total") { continue }
            
            if let date = inputFormatter.date(from: rawDateStr),
               let amount = Double(rawAmountStr.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) {
                let dateKey = keyFormatter.string(from: date)
                dailyTotals[dateKey, default: 0.0] += amount
            }
        }
        
        var updatedReports = self.dailyReports
        for (dateKey, totalAmount) in dailyTotals {
            var report = updatedReports[dateKey] ?? DailyReport(dateString: dateKey)
            report.dailyUberActualPayout = String(format: "%.1f", totalAmount)
            updatedReports[dateKey] = report
        }
        self.dailyReports = updatedReports
    }
    
    private func saveDailyReports() {
        if let encoded = try? JSONEncoder().encode(dailyReports) {
            UserDefaults.standard.set(encoded, forKey: reportsKey)
        }
    }
    private func saveActiveOrders() {
        if let encoded = try? JSONEncoder().encode(activeOrders) {
            UserDefaults.standard.set(encoded, forKey: activeOrdersKey)
        }
    }
    private func saveTimerGroups() {
        if let encoded = try? JSONEncoder().encode(timerGroups) {
            UserDefaults.standard.set(encoded, forKey: timerGroupsKey)
        }
    }
    private func savePayoutInputs() {
        if let encoded = try? JSONEncoder().encode(biweeklyPayoutInputs) {
            UserDefaults.standard.set(encoded, forKey: payoutInputsKey)
        }
    }
    
    private func loadAllData() {
        if let data = UserDefaults.standard.data(forKey: reportsKey),
           let decoded = try? JSONDecoder().decode([String: DailyReport].self, from: data) {
            self.dailyReports = decoded
        }
        if let data = UserDefaults.standard.data(forKey: activeOrdersKey),
           let decoded = try? JSONDecoder().decode([DeliveryOrder].self, from: data) {
            self.activeOrders = decoded
        }
        if let data = UserDefaults.standard.data(forKey: timerGroupsKey),
           let decoded = try? JSONDecoder().decode([OrderTimerGroup].self, from: data) {
            self.timerGroups = decoded
        }
        if let data = UserDefaults.standard.data(forKey: payoutInputsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.biweeklyPayoutInputs = decoded
        }
    }
    
    private func setupBackgroundAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("背景音訊設定失敗:\(error)")
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkVoiceAnnouncements()
            }
        }
    }
    
    private func checkVoiceAnnouncements() {
        // 每 15 秒把最新數字推給 Live Activity 與桌面小工具(金額、時薪會隨時間變動)
        liveActivityTick += 1
        if liveActivityTick % 15 == 0 && !activeOrders.isEmpty {
            syncToLiveActivity()
        }
        if isTestModeEnabled {
            testTimerCounter += 1
            if testTimerCounter % 5 == 0 && !timerGroups.isEmpty {
                let title = "【測試】外送計時提醒"
                let body = "目前計時已過 \(testTimerCounter)秒"
                sendLocalNotification(title: title, body: body)
                speakText(body)
            }
        } else {
            for gIndex in timerGroups.indices {
                let group = timerGroups[gIndex]
                let elapsedSec = Int(Date().timeIntervalSince(group.startTime))
                let elapsedMin = elapsedSec / 60
                if elapsedMin == 11 && !group.spokenMilestones.contains(11) {
                    timerGroups[gIndex].spokenMilestones.insert(11)
                    let title = "外送時間提醒"
                    let body = "\(group.groupName)已滿 11 分鐘"
                    sendLocalNotification(title: title, body: body)
                    speakText(body)
                } else if elapsedMin >= 20 && elapsedMin % 10 == 0 && !group.spokenMilestones.contains(elapsedMin) {
                    timerGroups[gIndex].spokenMilestones.insert(elapsedMin)
                    let title = "外送時間提醒"
                    let body = "\(group.groupName)已滿 \(elapsedMin) 分鐘"
                    sendLocalNotification(title: title, body: body)
                    speakText(body)
                }
            }
        }
    }
    
    private func speakText(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        utterance.rate = 0.5
        speechSynthesizer.speak(utterance)
    }
    
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("通知權限請求失敗: \(error.localizedDescription)")
            }
        }
    }
    
    private func sendLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
    
    private func scheduleGroupNotifications(for group: OrderTimerGroup) {
        guard !isTestModeEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let milestones = [11, 20, 30, 40, 50, 60, 70, 80, 90]
        for m in milestones {
            let content = UNMutableNotificationContent()
            content.title = "外送計時提醒"
            content.body = "\(group.groupName)已滿\(m)分鐘!"
            content.sound = .default
            let targetDate = group.startTime.addingTimeInterval(TimeInterval(m * 60))
            let timeInterval = targetDate.timeIntervalSince(Date())
            if timeInterval > 0 {
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
                let request = UNNotificationRequest(identifier: "group_\(group.id.uuidString)_\(m)m", content: content, trigger: trigger)
                center.add(request)
            }
        }
    }
    
    func formatDateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    var todayKey: String { formatDateKey(Date()) }
    var selectedDateKey: String { formatDateKey(selectedReportDate) }
    
    var currentBatchEarnings: (completedEarnings: Double, activeWage: Double, totalBatchEarnings: Double, completedCount: Int, totalCount: Int) {
        var completedEarnings: Double = 0.0
        var activeWage: Double = 0.0
        var completedCount = 0
        for order in activeOrders {
            if order.isDiscarded { continue }
            if order.isCompleted {
                completedCount += 1
                completedEarnings += order.totalOrderEarnings()
            } else {
                activeWage += order.rawOperationWage
            }
        }
        let totalBatchEarnings = completedEarnings + activeWage
        return (completedEarnings, activeWage, totalBatchEarnings, completedCount, activeOrders.count)
    }
    
    func getBiweeklyStart(for offset: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 17
        components.hour = 4
        components.minute = 1
        components.second = 0
        let anchorDate = Calendar.current.date(from: components) ?? Date()
        let biweeklySeconds: TimeInterval = 14 * 24 * 3600
        let now = Date()
        let secondsDiff = now.timeIntervalSince(anchorDate)
        let currentCycleIndex = Int(floor(secondsDiff / biweeklySeconds))
        let targetCycleIndex = currentCycleIndex + offset
        return anchorDate.addingTimeInterval(TimeInterval(targetCycleIndex) * biweeklySeconds)
    }
    
    func biweeklyTitle(for offset: Int) -> String {
        let cycleStart = getBiweeklyStart(for: offset)
        let cycleEnd = cycleStart.addingTimeInterval(14 * 24 * 3600)
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMdd"
        return "\(displayFormatter.string(from: cycleStart))-\(displayFormatter.string(from: cycleEnd))"
    }
    
    func biweeklyCycleKey(for date: Date) -> String {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 17
        components.hour = 4
        components.minute = 0
        components.second = 1
        let anchorDate = Calendar.current.date(from: components) ?? Date()
        let secondsDiff = date.timeIntervalSince(anchorDate)
        let biweeklySeconds: TimeInterval = 14 * 24 * 3600
        let cycleIndex = Int(floor(secondsDiff / biweeklySeconds))
        let cycleStart = anchorDate.addingTimeInterval(TimeInterval(cycleIndex) * biweeklySeconds)
        let cycleEnd = cycleStart.addingTimeInterval(biweeklySeconds)
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy/MM/dd HH:mm"
        return "雙週週期(\(displayFormatter.string(from: cycleStart)) ~ \(displayFormatter.string(from: cycleEnd)))"
    }
    
    var currentBiweeklySummary: (rawWage: Double, adjustedWage: Double, totalTips: Double, totalIncome: Double, uberPayout: Double, diffWage: Double, totalSummedMinutes: Double, totalRidingMinutes: Double, totalOrders: Int) {
        let currentCycle = biweeklyCycleKey(for: selectedReportDate)
        var rawWage: Double = 0.0
        var adjustedWage: Double = 0.0
        var totalTips: Double = 0.0
        var summedMins: Double = 0.0
        var ridingMins: Double = 0.0
        var ordersCount: Int = 0
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        
        for (dateStr, report) in dailyReports {
            if let date = formatter.date(from: dateStr) {
                let noonDate = calendar.date(byAdding: .hour, value: 12, to: date) ?? date
                if biweeklyCycleKey(for: noonDate) == currentCycle {
                    rawWage += report.totalRawWage
                    adjustedWage += report.totalAdjustedWage
                    totalTips += report.totalTips
                    summedMins += report.totalSummedMinutes
                    ridingMins += report.totalActualRidingMinutes
                    ordersCount += report.totalOrdersCount
                }
            }
        }
        let totalIncome = adjustedWage + totalTips
        let uberPayoutStr = biweeklyPayoutInputs[currentCycle] ?? ""
        let uberPayout = Double(uberPayoutStr) ?? 0.0
        let diffWage = uberPayout - totalIncome
        return (rawWage, adjustedWage, totalTips, totalIncome, uberPayout, diffWage, summedMins, ridingMins, ordersCount)
    }
    
    // MARK: - Live Activity 同步輔助
    func syncToLiveActivity(statusText: String? = nil, isPaused: Bool? = nil) {
        guard !activeOrders.isEmpty else {
            LiveActivityManager.shared.endDeliveryActivity()
            return
        }
        let stats = currentBatchEarnings
        let uncompleted = activeOrders.filter { !$0.isCompleted && !$0.isDiscarded }
        let activeCount = uncompleted.count
        let completedCount = stats.completedCount
        let totalCount = activeOrders.filter { !$0.isDiscarded }.count
        let earnings = stats.totalBatchEarnings
        
        // 整理進行中的單號與備註/收取金額 (無論只打 $350、打數字、或打單號都完美支援)
        let orderDetails: [String] = uncompleted.map { order in
            var label = "#\(order.orderNumber)"
            if !order.userNote.isEmpty {
                label += "・\(order.userNote)"
            }
            if let _ = order.pickupTime {
                label += " [已取餐]"
            }
            return label
        }
        
        // 時薪、門檻:跟「接單試算」卡片用同一套算法(實際時薪;沒有班次就用 245)
        let info = liveActivityRateInfo()
        self.hourlyRate = info.hourly
        let timerStart = liveActivityTimerStart()
        let defaultStatus: String = activeCount > 0
            ? (uncompleted.allSatisfy { $0.pickupTime != nil } ? "送餐中" : "配送中")
            : "已送達"
        
        LiveActivityManager.shared.updateDeliveryActivity(
            earnings: earnings,
            hourlyRate: info.hourly,
            activeOrderCount: activeCount,
            completedOrderCount: completedCount,
            totalOrderCount: max(1, totalCount),
            statusText: statusText ?? defaultStatus,
            isPaused: isPaused ?? false,
            activeOrderDetails: orderDetails,
            tenMinuteThreshold: info.threshold,
            timerStartTime: timerStart
        )
        // 桌面小工具也一起更新
        syncToWidget(startTime: timerStart ?? Date(), currentSalary: earnings, hourlyRate: info.hourly, isWorking: true, orderDetail: orderDetails.joined(separator: " / "))
    }
    
    /// Live Activity 要顯示的實際時薪與 10 分鐘門檻(與接單試算卡片一致)
    func liveActivityRateInfo() -> (hourly: Double, threshold: Double) {
        let off = UserDefaults.standard.double(forKey: "shiftOffTimestamp")
        let offDate: Date? = off > 0 ? Date(timeIntervalSince1970: off) : nil
        var hourly = WageSettings.hourly
        if let s = currentShiftSnapshot(now: Date(), offTime: offDate), !s.isClosed, let h = s.hourly {
            hourly = h
        }
        return (hourly, hourly / 6.0)
    }
    
    /// 跳錶起點 = App 畫面上「計時組別」的起點
    func liveActivityTimerStart() -> Date? {
        timerGroups.map { $0.startTime }.min() ?? activeOrders.map { $0.startTime }.min()
    }

    func startNewBatch() {
        let now = Date()
        testTimerCounter = 0
        var newOrders: [DeliveryOrder] = []
        for i in 1...selectedInitialCount {
            let order = DeliveryOrder(orderNumber: i, startTime: now)
            newOrders.append(order)
        }
        activeOrders = newOrders
        let orderIDs = newOrders.map { $0.id }
        let group = OrderTimerGroup(groupName: "首單計時組別", startTime: now, orderIDs: orderIDs)
        timerGroups = [group]
        scheduleGroupNotifications(for: group)
        
        // 啟動 Live Activity 即時動態 (動態島與鎖定畫面跳錶)
        let nextBatchNum = (dailyReports[todayKey]?.batches.map { $0.batchNumber }.max() ?? 0) + 1
        let orderDetails = newOrders.map { "單號 #\($0.orderNumber)" }
        let info = liveActivityRateInfo()
        self.hourlyRate = info.hourly
        let threshold = info.threshold
        
        LiveActivityManager.shared.startDeliveryActivity(
            batchNumber: nextBatchNum,
            startTime: now,
            initialEarnings: currentBatchEarnings.totalBatchEarnings,
            hourlyRate: info.hourly,
            activeOrderCount: newOrders.count,
            completedOrderCount: 0,
            totalOrderCount: newOrders.count,
            statusText: "配送中",
            activeOrderDetails: orderDetails,
            tenMinuteThreshold: threshold,
            timerStartTime: now
        )
    }
    
    func addAddOnOrders(count: Int) {
        guard count > 0 else { return }
        let now = Date()
        let currentMaxNum = activeOrders.map { $0.orderNumber }.max() ?? 0
        var newAddOnOrders: [DeliveryOrder] = []
        for i in 1...count {
            let order = DeliveryOrder(orderNumber: currentMaxNum + i, startTime: now)
            newAddOnOrders.append(order)
        }
        activeOrders.append(contentsOf: newAddOnOrders)
        let groupCount = timerGroups.count + 1
        let orderIDs = newAddOnOrders.map { $0.id }
        let newGroup = OrderTimerGroup(groupName: "追加組別 #\(groupCount)", startTime: now, orderIDs: orderIDs)
        timerGroups.append(newGroup)
        scheduleGroupNotifications(for: newGroup)
        syncToLiveActivity()
    }
    
    // 改動G:「取餐完成」——跟「完成此單(送達)」是分開的事件，不影響 isCompleted/endTime，
    // 也不會觸發 checkAndStopGPSIfNoOrders(還在送的路上，GPS 不該停)。
    // 一樣會嘗試自動回溯補停留，處理「在餐廳忘記按開始停留」的情況。
    func markPickupComplete(id: UUID) {
        guard let index = activeOrders.firstIndex(where: { $0.id == id }) else { return }
        guard activeOrders[index].pickupTime == nil else { return } // 已經按過就不重複記錄，避免蓋掉原本時間
        let pickupTime = Date()
        activeOrders[index].pickupTime = pickupTime
        GPSLocationManager.shared.autoFinalizeStayOnOrderCompletion(completionTime: pickupTime)
        syncToLiveActivity(statusText: "送餐中")
    }

    func completeOrder(id: UUID) {
        guard let index = activeOrders.firstIndex(where: { $0.id == id }) else { return }
        if activeOrders[index].endTime == nil {
            activeOrders[index].endTime = Date()
        }
        activeOrders[index].isCompleted = true
        // 改動7:這張單重新被完成了，跟「復原」這個動作已經無關，取消復原的入口就該消失
        if lastRestoredOrderSnapshot?.orderID == id {
            lastRestoredOrderSnapshot = nil
        }
        // 改動B:忘記按「開始停留」的補救——按下完成時，用速度回溯自動補一筆停留紀錄
        if let completionTime = activeOrders[index].endTime {
            GPSLocationManager.shared.autoFinalizeStayOnOrderCompletion(completionTime: completionTime)
        }
        checkAndCleanGroups()
        checkAndFinalizeBatch()
        checkAndStopGPSIfNoOrders()
        if !activeOrders.isEmpty && !activeOrders.allSatisfy({ $0.isCompleted }) {
            syncToLiveActivity()
        }
    }
    
    func discardActiveOrder(id: UUID) {
            guard let index = activeOrders.firstIndex(where: { $0.id == id }) else { return }
            if activeOrders[index].endTime == nil {
                activeOrders[index].endTime = Date()
            }
            activeOrders[index].isCompleted = true
            activeOrders[index].isDiscarded = true
            // 改動7:同上，棄單後也跟原本那次復原無關了
            if lastRestoredOrderSnapshot?.orderID == id {
                lastRestoredOrderSnapshot = nil
            }
            // 改動B:棄單同樣算「結束」，一併補一次停留回溯
            if let completionTime = activeOrders[index].endTime {
                GPSLocationManager.shared.autoFinalizeStayOnOrderCompletion(completionTime: completionTime)
            }
            checkAndCleanGroups()
            checkAndFinalizeBatch()
            checkAndStopGPSIfNoOrders()
        }
    private func checkAndStopGPSIfNoOrders() {
        // 檢查是否還有任何「未完成 (isCompleted == false)」的訂單
        let hasUnfinishedOrders = activeOrders.contains(where: { !$0.isCompleted })
        
        // 只要已經完全沒有未完成的訂單（所有單都 Completed 或 Discarded）
        if !hasUnfinishedOrders {
            GPSLocationManager.shared.stopDeliverySession()
        }
    }
    func restoreOrder(id: UUID) {
        print("DEBUG: 進入 restoreOrder, ID = \(id)")
        
        guard let index = activeOrders.firstIndex(where: { $0.id == id }) else {
            print("DEBUG: 找不到訂單 ID")
            return
        }
        
        // 改動7:復原前先記下原本的狀態(是否完成/棄單、原本的結束時間)，
        // 這樣萬一是誤按復原，可以用「取消復原」精準改回去，不會多算出經過的時間。
        lastRestoredOrderSnapshot = (
            orderID: id,
            wasCompleted: activeOrders[index].isCompleted,
            wasDiscarded: activeOrders[index].isDiscarded,
            previousEndTime: activeOrders[index].endTime
        )
        
        activeOrders[index].isCompleted = false
        activeOrders[index].isDiscarded = false
        activeOrders[index].endTime = nil
        
        DispatchQueue.main.async {
            GPSLocationManager.shared.startTracking()
            print("DEBUG: 已執行 startTracking()，當前狀態 = \(GPSLocationManager.shared.isTracking)")
        }
        syncToLiveActivity()
    }
    
    // 改動7:取消上一次的「復原」動作，把該訂單精準改回復原前的狀態(含原本的結束時間)
    func undoRestoreOrder() {
        guard let snapshot = lastRestoredOrderSnapshot,
              let index = activeOrders.firstIndex(where: { $0.id == snapshot.orderID }) else {
            lastRestoredOrderSnapshot = nil
            return
        }
        activeOrders[index].isCompleted = snapshot.wasCompleted
        activeOrders[index].isDiscarded = snapshot.wasDiscarded
        activeOrders[index].endTime = snapshot.previousEndTime
        lastRestoredOrderSnapshot = nil
        checkAndCleanGroups()
        checkAndFinalizeBatch()
        checkAndStopGPSIfNoOrders()
        if !activeOrders.isEmpty && !activeOrders.allSatisfy({ $0.isCompleted }) {
            syncToLiveActivity()
        }
    }
    
    private func checkAndCleanGroups() {
        let milestones = [11, 20, 30, 40, 50, 60, 70, 80, 90]
        let center = UNUserNotificationCenter.current()
        let completedGroups = timerGroups.filter { group in
            let groupOrders = activeOrders.filter { group.orderIDs.contains($0.id) }
            return !groupOrders.isEmpty && groupOrders.allSatisfy { $0.isCompleted }
        }
        for group in completedGroups {
            let identifiersToCancel = milestones.map { m in "group_\(group.id.uuidString)_\(m)m" }
            center.removePendingNotificationRequests(withIdentifiers: identifiersToCancel)
        }
        timerGroups.removeAll { group in
            completedGroups.contains(where: { $0.id == group.id })
        }
    }
    
    private func checkAndFinalizeBatch() {
        let allFinished = !activeOrders.isEmpty && activeOrders.allSatisfy { $0.isCompleted }
        if allFinished {
            LiveActivityManager.shared.endDeliveryActivity()
            syncToWidget(startTime: Date(), currentSalary: 0, hourlyRate: hourlyRate, isWorking: false)
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            let validOrders = activeOrders.filter { !$0.isDiscarded }
            if !validOrders.isEmpty {
                let existingReport = dailyReports[todayKey]
                let currentTotalOrders = existingReport?.batches.flatMap { $0.orders }.count ?? 0
                var sortedOrders = validOrders.sorted(by: { $0.startTime < $1.startTime })
                for index in sortedOrders.indices {
                    sortedOrders[index].orderNumber = currentTotalOrders + index + 1
                }
                var report = dailyReports[todayKey] ?? DailyReport(dateString: todayKey)
                let nextBatchNumber = (report.batches.map { $0.batchNumber }.max() ?? 0) + 1
                let finalizedBatch = DeliveryBatch(batchNumber: nextBatchNumber, orders: sortedOrders)
                report.batches.append(finalizedBatch)
                dailyReports[todayKey] = report
                lastFinalizedBatch = (todayKey, finalizedBatch)
            }
            activeOrders.removeAll()
            timerGroups.removeAll()
            selectedAddOnCount = 1
        }
    }
    
    func restoreLastFinalizedBatch() {
        guard let snapshot = lastFinalizedBatch else { return }
        var report = dailyReports[snapshot.dateKey] ?? DailyReport(dateString: snapshot.dateKey)
        report.batches.removeAll { $0.id == snapshot.batch.id }
        dailyReports[snapshot.dateKey] = report
        var restoredOrders = snapshot.batch.orders
        for i in restoredOrders.indices {
            restoredOrders[i].isCompleted = false
            restoredOrders[i].isDiscarded = false
            restoredOrders[i].endTime = nil
        }
        activeOrders = restoredOrders
        let orderIDs = restoredOrders.map { $0.id }
        let groupStart = restoredOrders.map { $0.startTime }.min() ?? Date()
        let group = OrderTimerGroup(groupName: "已復原組別", startTime: groupStart, orderIDs: orderIDs)
        timerGroups = [group]
        scheduleGroupNotifications(for: group)
        DispatchQueue.main.async {
            GPSLocationManager.shared.startTracking()
        }
        lastFinalizedBatch = nil
    }
    
    func dismissLastFinalizedBatchNotice() {
        lastFinalizedBatch = nil
    }
    
    func addManualOrder(to targetDate: Date, startTime: Date, endTime: Date, customWage: String, tip: String) {
        let dateKey = formatDateKey(targetDate)
        var report = dailyReports[dateKey] ?? DailyReport(dateString: dateKey)
        let orderCount = report.batches.flatMap { $0.orders }.count
        var newOrder = DeliveryOrder(orderNumber: orderCount + 1, startTime: startTime)
        newOrder.endTime = endTime
        newOrder.isCompleted = true
        newOrder.customWageInput = customWage
        newOrder.tipInput = tip
        newOrder.isDiscarded = false
        let batchCount = report.batches.count
        let newBatch = DeliveryBatch(batchNumber: batchCount + 1, orders: [newOrder], createdAt: targetDate)
        report.batches.append(newBatch)
        dailyReports[dateKey] = report
    }
    
    func exportToCSV(forStartMonths startMonth: Int? = nil, endMonth: Int? = nil, targetYear: Int? = nil) -> String {
        var csv = "Date,BatchNumber,OrderNumber,StartTime,EndTime,IsDiscarded,CustomWage,Tip\n"
        let isoFormatter = ISO8601DateFormatter()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for (dateStr, report) in dailyReports {
            if let date = formatter.date(from: dateStr) {
                let calendar = Calendar.current
                let year = calendar.component(.year, from: date)
                let month = calendar.component(.month, from: date)
                if let tYear = targetYear, year != tYear { continue }
                if let sMonth = startMonth, let eMonth = endMonth {
                    if month < sMonth || month > eMonth { continue }
                }
                for batch in report.batches {
                    for order in batch.orders {
                        let startStr = isoFormatter.string(from: order.startTime)
                        let endStr = order.endTime != nil ? isoFormatter.string(from: order.endTime!) : ""
                        let line = "\(dateStr),\(batch.batchNumber),\(order.orderNumber),\(startStr),\(endStr),\(order.isDiscarded),\(order.customWageInput),\(order.tipInput)\n"
                        csv.append(line)
                    }
                }
            }
        }
        return csv
    }
    
    func purgeData(forStartMonths startMonth: Int, endMonth: Int, targetYear: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        var keysToRemove: [String] = []
        for (dateStr, _) in dailyReports {
            if let date = formatter.date(from: dateStr) {
                let year = calendar.component(.year, from: date)
                let month = calendar.component(.month, from: date)
                if year == targetYear && month >= startMonth && month <= endMonth {
                    keysToRemove.append(dateStr)
                }
            }
        }
        for key in keysToRemove {
            dailyReports.removeValue(forKey: key)
        }
    }
    
    func importFromCSV(csvString: String) {
        let isoFormatter = ISO8601DateFormatter()
        let lines = csvString.components(separatedBy: .newlines)
        guard lines.count > 1 else { return }
        var newReports = self.dailyReports
        for line in lines.dropFirst() {
            let cols = line.components(separatedBy: ",")
            if cols.count >= 8 {
                let dateStr = cols[0].trimmingCharacters(in: .whitespaces)
                guard !dateStr.isEmpty, let rawBatchNum = Int(cols[1]), let rawOrderNum = Int(cols[2]) else { continue }
                let startTime = isoFormatter.date(from: cols[3]) ?? Date()
                let endTime = isoFormatter.date(from: cols[4])
                let isDiscarded = (cols[5] as NSString).boolValue
                let customWage = cols[6]
                let tip = cols[7]
                
                var report = newReports[dateStr] ?? DailyReport(dateString: dateStr)
                if let batchIdx = report.batches.firstIndex(where: { $0.batchNumber == rawBatchNum }) {
                    let existingOrders = report.batches[batchIdx].orders
                    let maxOrderNum = existingOrders.map { $0.orderNumber }.max() ?? 0
                    var newOrderNum = rawOrderNum
                    if existingOrders.contains(where: { $0.orderNumber == rawOrderNum }) {
                        newOrderNum = maxOrderNum + 1
                    }
                    var order = DeliveryOrder(orderNumber: newOrderNum, startTime: startTime)
                    order.endTime = endTime
                    order.isCompleted = true
                    order.isDiscarded = isDiscarded
                    order.customWageInput = customWage
                    order.tipInput = tip
                    report.batches[batchIdx].orders.append(order)
                } else {
                    var order = DeliveryOrder(orderNumber: rawOrderNum, startTime: startTime)
                    order.endTime = endTime
                    order.isCompleted = true
                    order.isDiscarded = isDiscarded
                    order.customWageInput = customWage
                    order.tipInput = tip
                    let newBatch = DeliveryBatch(batchNumber: rawBatchNum, orders: [order])
                    report.batches.append(newBatch)
                }
                newReports[dateStr] = report
            }
        }
        self.dailyReports = newReports
    }
}
final class TimerPulseModel: ObservableObject {
    @Published var pulse: Date = Date()
    private var timer: Timer?
    
    func start(onTick: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.pulse = Date()
                onTick()
            }
        }
    }
    func stop() { timer?.invalidate() }
}
// MARK: 3. Main View
struct ContentView: View {
    @StateObject private var viewModel = DeliveryTrackerViewModel()
    @State private var selectedTab: Int = 0
    
    private let tabs: [(title: String, icon: String)] = [
        ("即時計時", "timer"),
        ("歷史對帳", "doc.text.magnifyingglass"),
        ("雙週對帳", "calendar.badge.clock"),
        ("年報與瘦身", "chart.bar.doc.horizontal.fill"),
        ("效率分析", "chart.line.uptrend.xyaxis"),
        ("路線軌跡", "map.fill"),
        ("車輛維護", "wrench.and.screwdriver")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // 可左右滑動切換的內容區
            TabView(selection: $selectedTab) {
                TimerMainView(viewModel: viewModel)
                    .tag(0)
                ReportAndAuditView(viewModel: viewModel)
                    .tag(1)
                BiweeklySummaryTabView(viewModel: viewModel)
                    .tag(2)
                YearlyReportTabView(viewModel: viewModel)
                    .tag(3)
                EfficiencyAnalysisTabView(viewModel: viewModel)
                    .tag(4)
                DailyRouteMapView()
                    .tag(5)
                VehicleMaintenanceView()
                    .tag(6)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.default, value: selectedTab)
            
            Divider()
            
            // 自訂底部分頁列，一次顯示全部 6 個
            HStack(spacing: 0) {
                ForEach(0..<tabs.count, id: \.self) { index in
                    Button {
                        selectedTab = index
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tabs[index].icon)
                                .font(.system(size: 20))
                            Text(tabs[index].title)
                                .font(.system(size: 10))
                        }
                        .foregroundColor(selectedTab == index ? .blue : .gray)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(.ultraThinMaterial)
        }
        
    }
}

// MARK: 4. 分頁一：實時計時主畫面
struct TimerMainView: View {
    @ObservedObject var viewModel: DeliveryTrackerViewModel
    @StateObject private var pulseModel = TimerPulseModel()
    @ObservedObject private var gpsManager = GPSLocationManager.shared   // 改動1新增
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {   // 改這裡:LazyVStack → VStack
                    testModeToggleCard
                    OrderQuoteCard(viewModel: viewModel)
                    if gpsManager.isTracking {
                        manualStayPointCard
                    }
                    if !viewModel.activeOrders.isEmpty {
                        mainGroupTimerHeaderCard.padding(.top, 4)
                        currentBatchEarningsCard
                        currentActiveBatchCard
                    } else {
                        if viewModel.lastFinalizedBatch != nil {
                            lastBatchRecoveryCard.padding(.top, 10)
                        }
                        batchStartControlCard.padding(.top, viewModel.lastFinalizedBatch != nil ? 0 : 10)
                    }
                    WageSettingsCard()          // ← 加在這裡
                                            .padding(.bottom, 20)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("實時計時")
        }
        .onAppear { pulseModel.start {} }
        .onDisappear { pulseModel.stop() }
    }
    
    // 改動1新增:手動停留點按鈕卡片
    private var manualStayPointCard: some View {
        HStack {
            Image(systemName: gpsManager.isManualStayActive ? "mappin.circle.fill" : "mappin.circle")
                .foregroundColor(gpsManager.isManualStayActive ? .orange : .gray)
                .font(.title3)
            Text(gpsManager.isManualStayActive ? "停留記錄中�(移動後自動結束)" : "在目前位置標記停留點")
                .font(.subheadline).bold()
            Spacer()
            Button(action: {
                gpsManager.startManualStayPoint()
            }) {
                Text(gpsManager.isManualStayActive ? "記錄中" : "開始停留")
                    .font(.caption).bold()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(gpsManager.isManualStayActive ? Color.gray.opacity(0.3) : Color.orange)
                    .foregroundColor(gpsManager.isManualStayActive ? .gray : .white)
                    .cornerRadius(8)
            }
            .disabled(gpsManager.isManualStayActive)
        }
        .padding()
        .background(gpsManager.isManualStayActive ? Color.orange.opacity(0.1) : Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    private var lastBatchRecoveryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "clock.arrow.circlepath").foregroundColor(.blue).font(.title3)
                Text("上一趟已結束").font(.headline)
            }
            Text("若剛才誤觸完成/棄單導致趟次提前結算,可點擊下方按鈕復原,計時會精準補回經過的時間。")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button(action: { viewModel.dismissLastFinalizedBatchNotice() }) {
                    Text("忽略").font(.subheadline).bold().foregroundColor(.gray)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.gray.opacity(0.15)).cornerRadius(8)
                }
                Button(action: { viewModel.restoreLastFinalizedBatch() }) {
                    HStack {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                        Text("復原此趟")
                    }
                    .font(.subheadline).bold().foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.blue).cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.08))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.25), lineWidth: 1))
        .padding(.horizontal)
    }
    
    private var testModeToggleCard: some View {
        HStack {
            Image(systemName: viewModel.isTestModeEnabled ? "gearshape.fill" : "gearshape")
                .foregroundColor(viewModel.isTestModeEnabled ? .orange : .gray)
            Toggle("開啟5秒測試通知/語音", isOn: $viewModel.isTestModeEnabled)
                .font(.subheadline).bold()
        }
        .padding()
        .background(viewModel.isTestModeEnabled ? Color.orange.opacity(0.12) : Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    private var mainGroupTimerHeaderCard: some View {
        VStack(spacing: 12) {
            ForEach(viewModel.timerGroups) { group in
                let totalSec = Int(group.recordedSeconds)
                let mins = totalSec / 60
                let secs = totalSec % 60
                HStack {
                    Image(systemName: "clock.fill").foregroundColor(.blue).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.groupName).font(.headline)
                        let groupOrders = viewModel.activeOrders.filter { group.orderIDs.contains($0.id) }
                        let numsStr = groupOrders.map { "#\($0.orderNumber)" }.joined(separator: ",")
                        Text("包含單號:\(numsStr)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%02d:%02d", mins, secs))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.blue)
                }
                if group.id != viewModel.timerGroups.last?.id {
                    Divider()
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        .padding(.horizontal)
    }
    
    private var currentBatchEarningsCard: some View {
        let stats = viewModel.currentBatchEarnings
        return VStack(spacing: 10) {
            HStack {
                Image(systemName: "shippingbox.circle.fill").foregroundColor(.orange).font(.title2)
                Text("本趟當前總金額").font(.headline)
                Spacer()
                Text("進度:\(stats.completedCount)/\(stats.totalCount)單")
                    .font(.caption).bold()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12)).foregroundColor(.orange).cornerRadius(8)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("$\(stats.totalBatchEarnings, specifier: "%.1f")")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.green)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("已完成鎖定:$\(stats.completedEarnings, specifier: "%.1f")")
                        .font(.caption).bold().foregroundColor(.blue)
                    if stats.activeWage > 0 {
                        Text("進行中估算:+$\(stats.activeWage, specifier: "%.1f")")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        .padding(.horizontal)
    }
    
    private var batchStartControlCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("開始新趟次(批次)").font(.headline)
            HStack {
                Text("預計接單數量:")
                Spacer()
                Picker("單數", selection: $viewModel.selectedInitialCount) {
                    Text("1單").tag(1)
                    Text("2單").tag(2)
                    Text("3單").tag(3)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 160)
            }
            Button(action: {
                viewModel.startNewBatch()
                syncToWidget(startTime: Date(), currentSalary: viewModel.currentBatchSalary, hourlyRate: viewModel.hourlyRate, isWorking: true)
                GPSLocationManager.shared.startNewDeliverySession()
            }) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("一鍵開始此批次(\(viewModel.selectedInitialCount)單)")
                }
                .font(.headline).foregroundColor(.white)
                .frame(maxWidth: .infinity).padding()
                .background(Color.blue).cornerRadius(12)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }
    
    private var currentActiveBatchCard: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("當前趟次單號與進度").font(.headline)
                HStack(spacing: 10) {
                    ForEach([1, 2, 3], id: \.self) { count in
                        Button(action: { viewModel.addAddOnOrders(count: count) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.circle.fill")
                                Text("+\(count)單")
                            }
                            .font(.subheadline).bold()
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Color.orange.opacity(0.15)).foregroundColor(.orange).cornerRadius(10)
                        }
                    }
                }
            }
            .padding(.horizontal)
            
            ForEach(viewModel.sortedActiveOrders) { order in
                if let index = viewModel.activeOrders.firstIndex(where: { $0.id == order.id }) {
                    ActiveOrderCard(
                        orderBinding: $viewModel.activeOrders[index],
                        pulseDate: pulseModel.pulse,
                        onComplete: { viewModel.completeOrder(id: order.id) },
                        onDiscard: { viewModel.discardActiveOrder(id: order.id) },
                        onRestore: { viewModel.restoreOrder(id: order.id) },
                        onPickupComplete: { viewModel.markPickupComplete(id: order.id) },
                        // 改動7:只有「剛剛被復原的那一單」才會顯示「取消復原」
                        canUndoRestore: viewModel.lastRestoredOrderSnapshot?.orderID == order.id,
                        onUndoRestore: { viewModel.undoRestoreOrder() }
                    )
                }
            }
        }
    }
}

// MARK: 5. 計時卡片元件
struct ActiveOrderCard: View {
    @Binding var orderBinding: DeliveryOrder
    let pulseDate: Date
    let onComplete: () -> Void
    let onDiscard: () -> Void
    let onRestore: () -> Void
    // 改動G:取餐完成，跟送達完成(onComplete)分開的獨立事件
    var onPickupComplete: () -> Void = {}
    // 改動7:這張單是不是剛被復原(還來得及一鍵撤銷)
    var canUndoRestore: Bool = false
    var onUndoRestore: () -> Void = {}
    // 改動Q:控制截圖辨識彈出視窗的顯示
    @State private var showScanSheet = false
    
    var body: some View {
        let order = orderBinding
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text("訂單 #\(order.orderNumber)").font(.title2).bold()
                // 改動Q/R:平台單號欄位改成會隨內容自動長高的版本，旁邊加一顆「掃描」按鈕，
                // 可以從截圖(相簿/貼上)自動偵測單號/姓名，或用手指直接在截圖上選字。
                DeferringTextEditor(
                    placeholder: "平台單號",
                    externalValue: $orderBinding.userNote,
                    font: .boldSystemFont(ofSize: 22)   // 對應原本的 .font(.title2).bold()
                )
                .frame(width: 120)
                if #available(iOS 16.0, *) {
                    Button {
                        showScanSheet = true
                    } label: {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 18))
                            .foregroundColor(.blue)
                    }
                    .padding(.top, 4)
                }
                Text("(\(order.startTimeFormatted) 成)").font(.caption).foregroundColor(.secondary)
                if let pickupTime = order.pickupTime {
                    Text("(取餐 \(DateFormatter.localizedString(from: pickupTime, dateStyle: .none, timeStyle: .short)))")
                        .font(.caption).foregroundColor(.orange)
                }
                if order.isCompleted {
                    Text(order.isDiscarded ? "(已棄單)" : "(已完成)")
                        .font(.caption).bold()
                        .foregroundColor(order.isDiscarded ? .gray : .green)
                }
                Spacer()
            }
            
            HStack {
                Text("預估工時: \(order.rawOperationMinutes)分鐘").font(.subheadline)
                Spacer()
                Text("本單小計: $\(order.totalOrderEarnings(), specifier: "%.1f")")
                    .font(.headline).bold().foregroundColor(.green)
            }
            
            if !order.isCompleted {
                // 改動G:取餐完成按鈕，按過一次之後(pickupTime 有值)就不再顯示，避免誤觸覆蓋掉取餐時間
                if order.pickupTime == nil {
                    Button(action: {
                        onPickupComplete()
                    }) {
                        HStack {
                            Image(systemName: "bag.fill")
                            Text("取餐完成")
                        }
                        .font(.subheadline).bold().foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.orange).cornerRadius(8)
                    }
                }
                HStack(spacing: 12) {
                    Button(action: {
                        onDiscard()
                    }) {
                        Text("棄單(0元)").font(.subheadline).bold().foregroundColor(.red)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.red.opacity(0.15)).cornerRadius(8)
                    }
                    
                    Button(action: {
                        onComplete()
                    }) {
                        Text("完成此單").font(.subheadline).bold().foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.green).cornerRadius(8)
                    }
                }
                // 改動7:剛復原這一單時，多給一個「取消復原」，誤按可以立刻改回去
                if canUndoRestore {
                    UndoRestoreButton(onConfirm: onUndoRestore)
                }
            } else {
                Button(action: {
                    print("DEBUG: 畫面復原按鈕被實體點擊！")
                    onRestore()
                }) {
                    HStack {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                        Text(order.isDiscarded ? "復原此單(取消棄單)" : "復原此單(取消完成)")
                    }
                    .font(.subheadline).bold().foregroundColor(.blue)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.blue.opacity(0.12)).cornerRadius(8)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
        .modifier(ScanSheetModifier(isPresented: $showScanSheet, onApply: { text in
            orderBinding.userNote = text
        }))
    }
}

// 改動Q:iOS 16 以下裝置沒有 Live Text API，用一個 ViewModifier 包起來做版本判斷，
// 避免每個呼叫端都要自己寫 if #available。
private struct ScanSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    var onApply: (String) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.sheet(isPresented: $isPresented) {
                OrderTextScanSheet(onApply: onApply)
            }
        } else {
            content
        }
    }
}

// 改動7:「取消復原」按鈕，點下去會先跳確認，避免又是一次誤按
private struct UndoRestoreButton: View {
    let onConfirm: () -> Void
    @State private var showConfirm = false
    
    var body: some View {
        Button(action: { showConfirm = true }) {
            HStack {
                Image(systemName: "xmark.circle.fill")
                Text("取消復原(改回剛才完成的狀態)")
            }
            .font(.caption).bold().foregroundColor(.gray)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(Color.gray.opacity(0.12)).cornerRadius(8)
        }
        .buttonStyle(BorderlessButtonStyle())
        .padding(.top, 2)
        .confirmationDialog("確定要取消剛才的復原嗎？", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("取消復原", role: .destructive) { onConfirm() }
            Button("再想一下", role: .cancel) { }
        } message: {
            Text("這一單會改回復原前的完成狀態，並恢復原本的結束時間。")
        }
    }
}

// MARK: 6. 分頁二: 報表與對帳畫面
struct ReportAndAuditView: View {
    @ObservedObject var viewModel: DeliveryTrackerViewModel
    @State private var showManualOrderSheet = false
    @State private var isExportingCSV = false
    @State private var isImportingCSV = false
    @State private var csvDocument = CSVDocument()
    @FocusState private var focusedField: FocusField?
    // 1. 新增一個 State 紀錄鍵盤是否顯示
    @State private var isKeyboardVisible = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                        if !isKeyboardVisible {
                            biweeklySummaryCard
                            Divider().padding(.vertical, 6)
                            dailyReportHeader
                        }
                        dailyReportListView
                    }
                    .animation(.easeInOut(duration: 0.25), value: isKeyboardVisible)
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                        isKeyboardVisible = true
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                        isKeyboardVisible = false
                    }
            .navigationTitle("歷史對帳與雙週結算")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { showManualOrderSheet = true }) {
                            Label("訂單補單", systemImage: "plus.circle")
                        }
                        Button(action: {
                            csvDocument = CSVDocument(text: viewModel.exportToCSV())
                            isExportingCSV = true
                        }) {
                            Label("匯出 CSV 備份", systemImage: "square.and.arrow.up")
                        }
                        Button(action: { isImportingCSV = true }) {
                            Label("匯入 CSV 追加累加", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil; hideKeyboard() }.bold().foregroundColor(.blue)
                }
            }
            .sheet(isPresented: $showManualOrderSheet) {
                ManualOrderSheet(viewModel: viewModel, initialDate: viewModel.selectedReportDate)
            }
            .fileExporter(
                isPresented: $isExportingCSV,
                document: csvDocument,
                contentType: .commaSeparatedText,
                defaultFilename: "DeliveryBackup_\(viewModel.formatDateKey(Date())).csv"
            ) { _ in }
                .fileImporter(
                    isPresented: $isImportingCSV,
                    allowedContentTypes: [.commaSeparatedText, .plainText]
                ) { result in
                    if case .success(let url) = result {
                        if url.startAccessingSecurityScopedResource() {
                            defer { url.stopAccessingSecurityScopedResource() }
                            if let content = try? String(contentsOf: url, encoding: .utf8) {
                                viewModel.importFromCSV(csvString: content)
                            }
                        }
                    }
                }
                .onTapGesture { hideKeyboard() }
        }
    }
    
    private var biweeklySummaryCard: some View {
        let summary = viewModel.currentBiweeklySummary
        let cycleTitle = viewModel.biweeklyCycleKey(for: viewModel.selectedReportDate)
        let payoutBinding = Binding<String>(
            get: { viewModel.biweeklyPayoutInputs[cycleTitle] ?? "" },
            set: { viewModel.biweeklyPayoutInputs[cycleTitle] = $0 }
        )
        
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "chart.bar.doc.horizontal").foregroundColor(.purple)
                Text("雙週統計結算(週一 04:00 交界)").font(.headline)
                Spacer()
                Text(cycleTitle).font(.caption).bold().foregroundColor(.purple)
            }
            Divider()
            VStack(spacing: 10) {
                HStack {
                    Text("完成單數: \(summary.totalOrders)單").font(.subheadline)
                    Spacer()
                    Text("每單累計工時: \(Int(summary.totalSummedMinutes))分").font(.caption).bold().foregroundColor(.blue)
                    Spacer()
                    Text("外送騎乘: \(Int(summary.totalRidingMinutes))分").font(.caption).bold().foregroundColor(.orange)
                }
                Divider()
                HStack(spacing: 8) {
                    VStack(alignment: .leading) {
                        Text("操作估算").font(.caption2).foregroundColor(.secondary)
                        Text("$\(summary.rawWage, specifier: "%.1f")").font(.subheadline).bold().foregroundColor(.gray)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("補足估算").font(.caption2).foregroundColor(.secondary)
                        Text("$\(summary.adjustedWage, specifier: "%.1f")").font(.subheadline).bold().foregroundColor(.green)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("顧客小費").font(.caption2).foregroundColor(.secondary)
                        Text("+$\(summary.totalTips, specifier: "%.1f")").font(.subheadline).bold().foregroundColor(.orange)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("App預估總額").font(.caption2).foregroundColor(.secondary)
                        Text("$\(summary.totalIncome, specifier: "%.1f")").font(.subheadline).bold().foregroundColor(.blue)
                    }
                }
                HStack {
                    Text("Uber實際入帳:").font(.subheadline).bold()
                    TextField("輸入金額", text: payoutBinding)
                        .keyboardType(.decimalPad).textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 100)
                    Spacer()
                    if summary.uberPayout > 0 {
                        Text("對帳差額: $\(summary.diffWage, specifier: "%.1f")")
                            .font(.subheadline).bold().foregroundColor(summary.diffWage >= 0 ? .green : .red)
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    private var dailyReportHeader: some View {
        let report = viewModel.dailyReports[viewModel.selectedDateKey]
        let totalIncome = report?.totalDailyIncome ?? 0.0
        let summedMins = Int(report?.totalSummedMinutes ?? 0)
        let ridingMins = Int(report?.totalActualRidingMinutes ?? 0)

        let totalDepartureMins: Int = {
            guard let report = report, !report.batches.isEmpty else {
                return 0
            }

            // 1. 抓出當天所有有完整起訖時間的訂單，並依接單時間排序
            let allOrders = report.batches
                .flatMap { $0.orders }
                .compactMap { (order: DeliveryOrder) -> (start: Date, end: Date)? in
                    guard let endTime = order.endTime else {
                        return nil
                    }

                    return (
                        start: order.startTime,
                        end: endTime
                    )
                }
                .sorted { $0.start < $1.start }

            guard let firstOrder = allOrders.first else {
                return 0
            }

            // 2. 自動切分出門時段
            // 兩單之間間隔超過 60 分鐘，就視為不同時段
            var totalMinutes = 0
            var currentSessionStart = firstOrder.start
            var currentSessionEnd = firstOrder.end

            for order in allOrders.dropFirst() {
                if order.start.timeIntervalSince(currentSessionEnd) > 3600 {

                    // 結算上一個出門時段
                    let sessionMins = Int(
                        currentSessionEnd.timeIntervalSince(currentSessionStart) / 60
                    )

                    totalMinutes += max(0, sessionMins)

                    // 開啟新的出門時段
                    currentSessionStart = order.start
                    currentSessionEnd = order.end

                } else {
                    // 同一時段內，更新最晚結束時間
                    if order.end > currentSessionEnd {
                        currentSessionEnd = order.end
                    }
                }
            }

            // 3. 加總最後一個出門時段
            let lastSessionMins = Int(
                currentSessionEnd.timeIntervalSince(currentSessionStart) / 60
            )

            totalMinutes += max(0, lastSessionMins)

            return totalMinutes
        }()
        let overlapRate = report?.overallOverlapRate
        let offset = viewModel.weekOffset(for: viewModel.selectedReportDate)
        let baseline = viewModel.preciseBaselineOverallRate(offset: offset, date: viewModel.selectedReportDate)
        let rateColor: Color = {
            guard let r = overlapRate, let b = baseline else { return .purple }
            return r >= b ? .green : .red
        }()
        return VStack(spacing: 6) {
            HStack {
                DatePicker("選擇日期", selection: $viewModel.selectedReportDate, displayedComponents: .date)
                    .labelsHidden()
                Spacer()
                Text("日小計: $\(totalIncome, specifier: "%.1f")")
                    .font(.headline).foregroundColor(.green)
            }
            HStack {
                Text("每單累計工時: \(summedMins) 分鐘")
                    .font(.caption).bold().foregroundColor(.blue)
                Spacer()
                Text("實際外送騎乘: \(ridingMins) 分鐘")
                    .font(.caption).bold().foregroundColor(.orange)
                Spacer()
                Text("實際出門: \(totalDepartureMins) 分鐘")
                    .font(.caption).bold().foregroundColor(.cyan)
            }
            HStack {
                Text("疊單率: \(overlapRate.map { String(format: "%.2f", $0) } ?? "-")")
                    .font(.caption).bold().foregroundColor(rateColor)
                Spacer()
                Text("過去8週基準(同星期幾): \(baseline.map { String(format: "%.2f", $0) } ?? "-")")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }
    
    private var dailyReportListView: some View {
        let key = viewModel.selectedDateKey
        let report = viewModel.dailyReports[key]
        return Group {
            if let report = report, !report.batches.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(report.batches.sorted(by: { $0.createdAt > $1.createdAt })) { batch in
                                BatchDetailSection(
                                    batchBinding: Binding(
                                        get: {
                                            viewModel.dailyReports[key]?.batches.first(where: { $0.id == batch.id }) ?? batch
                                        },
                                        set: { newValue in
                                            if let idx = viewModel.dailyReports[key]?.batches.firstIndex(where: { $0.id == batch.id }) {
                                                viewModel.dailyReports[key]?.batches[idx] = newValue
                                            }
                                        }
                                    ),
                                    dailyTotalDepartureMinutes: report.totalDepartureMinutes,
                                    focusedField: $focusedField
                                )
                                .id(batch.id)
                            }
                        }
                        .padding(.vertical)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: focusedField) { _, newValue in
                        // ScrollView本身就會自動避開鍵盤,這段scrollTo只是錦上添花,
                        // 讓目標欄位盡量置中而不只是貼在鍵盤邊緣
                        guard let newValue, let targetID = scrollTargetID(for: newValue, in: report) else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation {
                                proxy.scrollTo(targetID, anchor: .center)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundColor(.gray)
                    Text("當日無對帳紀錄").foregroundColor(.gray)
                    Spacer()
                }
            }
        }
    }
    
    private func scrollTargetID(for field: FocusField, in report: DailyReport) -> UUID? {
        switch field {
        case .uberStartHour(let id), .uberStartMinute(let id),
                .uberDurationHours(let id), .uberDurationMinutes(let id), .uberDurationSeconds(let id):
            return id
        case .wage(let orderID), .tip(let orderID),.minutes(let orderID):
            return report.batches.first(where: { $0.orders.contains(where: { $0.id == orderID }) })?.id
        }
    }
}

// MARK: 7. 批次詳細檢視與輸入卡片
struct BatchDetailSection: View {
    @Binding var batchBinding: DeliveryBatch
    var dailyTotalDepartureMinutes: Double
    var focusedField: FocusState<FocusField?>.Binding
    
    private func batchTimeText(_ date: Date?) -> String {
        guard let date = date else { return "--:--" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("趟次#\(batchBinding.batchNumber)")
                .font(.caption).bold()
                .foregroundColor(.secondary)
            
            batchSummaryCard
           
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Uber 紀錄對比").font(.caption).bold().foregroundColor(.secondary)
                HStack(spacing: 4) {
                    Text("開始:")
                    TextField("時", text: $batchBinding.uberStartTimeHour)
                        .keyboardType(.numberPad).frame(width: 35).textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused(focusedField, equals: .uberStartHour(batchBinding.id))
                    Text(":")
                    TextField("分", text: $batchBinding.uberStartTimeMinute)
                        .keyboardType(.numberPad).frame(width: 35).textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused(focusedField, equals: .uberStartMinute(batchBinding.id))
                    Spacer()
                    Text("歷時:")
                    TextField("時", text: $batchBinding.uberDurationHours)
                        .keyboardType(.numberPad).frame(width: 30).textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused(focusedField, equals: .uberDurationHours(batchBinding.id))
                    Text("h")
                    TextField("分", text: $batchBinding.uberDurationMinutes)
                        .keyboardType(.numberPad).frame(width: 30).textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused(focusedField, equals: .uberDurationMinutes(batchBinding.id))
                    Text("m")
                    TextField("秒", text: $batchBinding.uberDurationSeconds)
                        .keyboardType(.numberPad).frame(width: 30).textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused(focusedField, equals: .uberDurationSeconds(batchBinding.id))
                    Text("s")
                }
                .font(.caption)
                if let diffStr = batchBinding.startTimeDiffString {
                    Text(diffStr).font(.caption2).foregroundColor(.blue)
                }
                let analysis = batchBinding.autoAnalysisResult
                if !analysis.isEmpty {
                    Text(analysis).font(.caption2).foregroundColor(.orange)
                }
            }
            .padding(.vertical, 4)
            Divider()
            
            ForEach(batchBinding.orders.indices, id: \.self) { orderIdx in
                OrderReportRow(
                    orderBinding: $batchBinding.orders[orderIdx],
                    extraSeconds: batchBinding.estimatedLateStartSeconds,
                    focusedField: focusedField
                )
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    private var batchSummaryCard: some View {
        // 完全不變,原封不動保留
        let validOrders = batchBinding.validOrders
        let extraSec = batchBinding.estimatedLateStartSeconds
        let minutesList = validOrders.map { $0.adjustedMinutes(addingExtraSec: extraSec) }
        let totalMins = minutesList.reduce(0, +)
        let formulaString = minutesList.map { "\($0)分" }.joined(separator: " + ")
        let timeSummaryText = minutesList.isEmpty ? "0分鐘" : "\(formulaString) = \(totalMins)分鐘"
        let ridingMins = Int(batchBinding.appBatchDurationSeconds / 60.0)
        let startTimeText = batchTimeText(batchBinding.batchStartTime)
        let endTimeText = batchTimeText(batchBinding.batchEndTime)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sum").foregroundColor(.orange).font(.subheadline)
                Text("趟次小結").font(.subheadline).bold()
                Spacer()
                Text("共 \(validOrders.count)單")
                    .font(.caption).bold()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15)).foregroundColor(.orange).cornerRadius(6)
            }
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("接單 \(startTimeText) 結束 \(endTimeText)")
                        .font(.caption2).foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "figure.walk").font(.caption2).foregroundColor(.orange)
                        Text("實際外送騎乘: \(ridingMins) 分鐘")
                            .font(.caption).bold().foregroundColor(.orange)
                    }
                }
            }
            if !validOrders.isEmpty {
                orderAmountGrid(validOrders: validOrders, extraSec: extraSec)
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本趟總收入").font(.caption2).foregroundColor(.secondary)
                        Text("$\(batchBinding.totalAdjustedBatchWage + batchBinding.totalBatchTips, specifier: "%.1f")")
                            .font(.title3).bold().foregroundColor(.green)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("車資$\(batchBinding.totalAdjustedBatchWage, specifier: "%.1f") + 小費$\(batchBinding.totalBatchTips, specifier: "%.1f")")
                            .font(.caption).bold().foregroundColor(.primary)
                    }
                }
                Divider()
                HStack {
                    Image(systemName: "clock").font(.caption).foregroundColor(.blue)
                    Text("每單累計工時:").font(.caption).bold().foregroundColor(.secondary)
                    Text(timeSummaryText).font(.caption).bold().foregroundColor(.blue)
                }
            }
        }
        .padding(10)
        .background(Color(UIColor.tertiarySystemGroupedBackground))
        .cornerRadius(10)
    }
    
    private func orderAmountGrid(validOrders: [DeliveryOrder], extraSec: Double) -> some View {
        // 完全不變,原封不動保留
        let columns = [GridItem(.adaptive(minimum: 74, maximum: 110), spacing: 8, alignment: .top)]
        return LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
            ForEach(validOrders) { order in
                let displayLabel = order.userNote.isEmpty ? "#\(order.orderNumber)" : order.userNote
                let amount = order.totalOrderEarnings(addingExtraSec: extraSec)
                VStack(spacing: 3) {
                    Text(displayLabel)
                        .font(.caption).bold().lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .minimumScaleFactor(1.0)
                    Text("$\(amount, specifier: "%.0f")")
                        .font(.caption).bold().foregroundColor(.green)
                        .lineLimit(1).minimumScaleFactor(1.0)
                }
                .padding(.vertical, 6).padding(.horizontal, 4)
                .frame(minWidth: 74)
                .background(Color.orange.opacity(0.10))
                .cornerRadius(8)
            }
        }
    }
}

// MARK: 8. 單筆訂單報表列
struct OrderReportRow: View {
    @Binding var orderBinding: DeliveryOrder
    let extraSeconds: Double
    var focusedField: FocusState<FocusField?>.Binding

    // 新增:把 focusedField 換算成各欄位自己專屬的 Bool Binding
    private var minutesFocusBinding: Binding<Bool> {
        Binding(
            get: { focusedField.wrappedValue == .minutes(orderBinding.id) },
            set: { newValue in
                if newValue { focusedField.wrappedValue = .minutes(orderBinding.id) }
                else if focusedField.wrappedValue == .minutes(orderBinding.id) { focusedField.wrappedValue = nil }
            }
        )
    }
    private var wageFocusBinding: Binding<Bool> {
        Binding(
            get: { focusedField.wrappedValue == .wage(orderBinding.id) },
            set: { newValue in
                if newValue { focusedField.wrappedValue = .wage(orderBinding.id) }
                else if focusedField.wrappedValue == .wage(orderBinding.id) { focusedField.wrappedValue = nil }
            }
        )
    }
    private var tipFocusBinding: Binding<Bool> {
        Binding(
            get: { focusedField.wrappedValue == .tip(orderBinding.id) },
            set: { newValue in
                if newValue { focusedField.wrappedValue = .tip(orderBinding.id) }
                else if focusedField.wrappedValue == .tip(orderBinding.id) { focusedField.wrappedValue = nil }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("單號#\(orderBinding.orderNumber)").font(.subheadline).bold()
                if !orderBinding.userNote.isEmpty {
                    Text("(\(orderBinding.userNote))").font(.subheadline).bold().foregroundColor(.blue)
                }
                Text("(\(orderBinding.startTimeFormatted))").font(.caption).foregroundColor(.gray)
                if orderBinding.isDiscarded {
                    Text("(棄單)").font(.caption).foregroundColor(.red)
                }
                Spacer()
            }
            HStack {
                Text("累計工時:").font(.caption)
                DeferringTextField(
                    placeholder: "\(orderBinding.autoCalculatedAdjustedMinutes(addingExtraSec: extraSeconds))",
                    externalValue: $orderBinding.manualMinutesOverride,
                    isFocused: minutesFocusBinding   // 新增
                )
                .frame(width: 60)
                Text("分鐘").font(.caption)
                if orderBinding.hasManualMinutesOverride {
                    Text("(已手動修正)").font(.caption2).foregroundColor(.orange)
                    Button(action: { orderBinding.manualMinutesOverride = "" }) {
                        Text("還原自動").font(.caption2).foregroundColor(.blue)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                Spacer()
            }
            HStack {
                Text("自訂底薪:").font(.caption)
                DeferringTextField(
                    placeholder: "預設估算",
                    externalValue: $orderBinding.customWageInput,
                    isFocused: wageFocusBinding   // 新增
                )
                .frame(width: 80)
                Spacer()
                Text("小費:").font(.caption)
                DeferringTextField(
                    placeholder: "0",
                    externalValue: $orderBinding.tipInput,
                    isFocused: tipFocusBinding   // 新增
                )
                .frame(width: 70)
            }
            HStack {
                Spacer()
                let wage = orderBinding.calculatedAdjustedWage(addingExtraSec: extraSeconds)
                let tip = orderBinding.tipAmount
                Text("小計: $\(wage + tip, specifier: "%.1f") (車資$\(wage, specifier: "%.1f") + 小費 $\(tip, specifier: "%.1f"))")
                    .font(.caption).bold().foregroundColor(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: 9. 手動補單彈窗
struct ManualOrderSheet: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var viewModel: DeliveryTrackerViewModel
    @State var targetDate: Date
    @State private var startTime = Date()
    @State private var endTime = Date()
    @State private var customWage = ""
    @State private var tip = ""
    
    init(viewModel: DeliveryTrackerViewModel, initialDate: Date) {
        self.viewModel = viewModel
        _targetDate = State(initialValue: initialDate)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("補單日期與時間")) {
                    DatePicker("日期", selection: $targetDate, displayedComponents: .date)
                    DatePicker("開始時間", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("結束時間", selection: $endTime, displayedComponents: .hourAndMinute)
                }
                Section(header: Text("金額設定")) {
                    HStack {
                        Text("自訂金額/底薪")
                        Spacer()
                        TextField("自動計算", text: $customWage).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("顧客小費")
                        Spacer()
                        TextField("0", text: $tip).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("手動新增補單")
            .navigationBarItems(
                leading: Button("取消") { presentationMode.wrappedValue.dismiss() },
                trailing: Button("儲存") {
                    viewModel.addManualOrder(to: targetDate, startTime: startTime, endTime: endTime, customWage: customWage, tip: tip)
                    presentationMode.wrappedValue.dismiss()
                }.bold()
            )
        }
    }
}

// MARK: 10. 分頁三: 雙週對帳明細(包含累計工時與實際外送騎乘時間)
struct BiweeklySummaryTabView: View {
    @ObservedObject var viewModel: DeliveryTrackerViewModel
    @State private var isImportingUberCSV = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    cyclePickerCard
                    weeklyAverageCard      // <- 新增這一行
                    noticeCard
                    biweeklyTableView
                    pastWeeksChartCard
                }
                .padding(.vertical)
            }
            .navigationTitle("雙週對帳明細")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { isImportingUberCSV = true }) {
                            Label("匯入 Uber CSV 填入實發金額", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { hideKeyboard() }.bold().foregroundColor(.blue)
                }
            }
            .fileImporter(
                isPresented: $isImportingUberCSV,
                allowedContentTypes: [.commaSeparatedText, .plainText]
            ) { result in
                if case .success(let url) = result {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let content = try? String(contentsOf: url, encoding: .utf8) {
                            viewModel.importUberCSVAndSetPayouts(csvString: content)
                        }
                    }
                }
            }
        }
    }
    
    private var cyclePickerCard: some View {
        HStack {
            Button(action: { viewModel.selectedBiweeklyCycleOffset -= 1 }) {
                Image(systemName: "chevron.left.circle.fill").font(.title2)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("雙週週期選項").font(.caption).foregroundColor(.secondary)
                Text(viewModel.biweeklyTitle(for: viewModel.selectedBiweeklyCycleOffset))
                    .font(.title2).bold().foregroundColor(.blue)
            }
            Spacer()
            Button(action: { viewModel.selectedBiweeklyCycleOffset += 1 }) {
                Image(systemName: "chevron.right.circle.fill").font(.title2)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    private var weeklyAverageCard: some View {
        let cycleStart = viewModel.getBiweeklyStart(for: viewModel.selectedBiweeklyCycleOffset)
        let datesWeek1 = (0..<7).map { cycleStart.addingTimeInterval(Double($0) * 86400) }
        let datesWeek2 = (7..<14).map { cycleStart.addingTimeInterval(Double($0) * 86400) }
        let week1Stats = viewModel.averageDailyWorkStats(for: datesWeek1)
        let week2Stats = viewModel.averageDailyWorkStats(for: datesWeek2)
        let past8Stats = viewModel.past8WeeksDailyAverage(beforeDate: cycleStart)
        
        func row(_ label: String, _ stats: (avgHours: Double?, avgIncome: Double?, includedDays: Int), color: Color) -> some View {
            HStack(alignment: .top) {
                Text(label).font(.caption).bold().foregroundColor(color).frame(width: 78, alignment: .leading)
                if let h = stats.avgHours, let inc = stats.avgIncome {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(h, specifier: "%.1f") 小時/天").font(.caption)
                        Text("$\(inc, specifier: "%.0f") /天").font(.caption)
                    }
                    Spacer()
                    Text("(\(stats.includedDays)天採入)").font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("尚無足夠資料").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        
        return VStack(alignment: .leading, spacing: 8) {
            Text("每週平均(已排除休假日)").font(.subheadline).bold()
            Divider()
            row("第一週", week1Stats, color: .blue)
            row("第二週", week2Stats, color: .blue)
            Divider()
            row("過去8週基準", past8Stats, color: .purple)
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    private var noticeCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.headline)
            Text("注意星期一 salaried 都是到凌晨四點結算,所以我只會跑到第二週星期日的單。")
        }
        .font(.footnote).bold()
        .foregroundColor(.primary).lineSpacing(4)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.12)).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.3), lineWidth: 1))
        .padding(.horizontal)
    }
    
    private var biweeklyTableView: some View {
        let cycleStart = viewModel.getBiweeklyStart(for: viewModel.selectedBiweeklyCycleOffset)
        let datesWeek1 = (0..<7).map { cycleStart.addingTimeInterval(Double($0) * 86400) }
        let datesWeek2 = (7..<14).map { cycleStart.addingTimeInterval(Double($0) * 86400) }
        
        var totalEstWeek1: Double = 0
        var totalActualWeek1: Double = 0
        var totalPandaWeek1: Double = 0
        var totalSummedMinsWeek1: Double = 0
        var totalRidingMinsWeek1: Double = 0
        
        var totalEstWeek2: Double = 0
        var totalActualWeek2: Double = 0
        var totalPandaWeek2: Double = 0
        var totalSummedMinsWeek2: Double = 0
        var totalRidingMinsWeek2: Double = 0
        
        for date in datesWeek1 {
            let key = viewModel.formatDateKey(date)
            let report = viewModel.dailyReports[key]
            totalEstWeek1 += report?.totalDailyIncome ?? 0
            totalActualWeek1 += Double(report?.dailyUberActualPayout ?? "") ?? 0
            totalPandaWeek1 += Double(report?.dailyPandaActualPayout ?? "") ?? 0
            totalSummedMinsWeek1 += report?.totalSummedMinutes ?? 0
            totalRidingMinsWeek1 += report?.totalActualRidingMinutes ?? 0
        }
        
        for date in datesWeek2 {
            let key = viewModel.formatDateKey(date)
            let report = viewModel.dailyReports[key]
            totalEstWeek2 += report?.totalDailyIncome ?? 0
            totalActualWeek2 += Double(report?.dailyUberActualPayout ?? "") ?? 0
            totalPandaWeek2 += Double(report?.dailyPandaActualPayout ?? "") ?? 0
            totalSummedMinsWeek2 += report?.totalSummedMinutes ?? 0
            totalRidingMinsWeek2 += report?.totalActualRidingMinutes ?? 0
        }
        
        let grandTotalEst = totalEstWeek1 + totalEstWeek2
        let grandTotalUber = totalActualWeek1 + totalActualWeek2
        let grandTotalPanda = totalPandaWeek1 + totalPandaWeek2
        let grandTotalActual = grandTotalUber + grandTotalPanda
        let grandTotalDiff = grandTotalActual - grandTotalEst
        let grandTotalUberDiff = grandTotalUber - grandTotalEst
        let grandSummedHours = (totalSummedMinsWeek1 + totalSummedMinsWeek2) / 60.0
        let grandRidingHours = (totalRidingMinsWeek1 + totalRidingMinsWeek2) / 60.0
        
        return VStack(spacing: 0) {
            HStack {
                Text("日期").font(.caption).bold().frame(width: 76, alignment: .leading)
                Spacer()
                Text("APP估算").font(.caption).bold().frame(width: 58, alignment: .trailing)
                Spacer()
                Text("實收合計").font(.caption).bold().frame(width: 62, alignment: .trailing)
                Spacer()
                Text("總差額").font(.caption).bold().frame(width: 60, alignment: .trailing)
                Spacer()
                Text("工時/騎乘").font(.caption).bold().frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.2))
            Divider()
            
            VStack(alignment: .leading, spacing: 0) {
                Text("第一週").font(.caption2).bold().foregroundColor(.secondary).padding(.horizontal).padding(.top, 8)
                ForEach(datesWeek1, id: \.self) { date in
                    BiweeklyDailyRow(date: date, viewModel: viewModel)
                    Divider()
                }
                Text("第二週").font(.caption2).bold().foregroundColor(.secondary).padding(.horizontal).padding(.top, 8)
                ForEach(datesWeek2, id: \.self) { date in
                    BiweeklyDailyRow(date: date, viewModel: viewModel)
                    Divider()
                }
            }
            VStack(spacing: 6) {
                if grandTotalPanda > 0 {
                    HStack {
                        Text("細項:").font(.caption2).foregroundColor(.secondary)
                        Text("UE實發 $\(grandTotalUber, specifier: "%.1f")").font(.caption2).foregroundColor(.secondary)
                        Text("+").font(.caption2).foregroundColor(.secondary)
                        Text("🐼熊貓 $\(grandTotalPanda, specifier: "%.1f")").font(.caption2).bold().foregroundColor(.teal)
                        Spacer()
                        Text("原UE差額 $\(grandTotalUberDiff, specifier: "%.1f")").font(.caption2).foregroundColor(.secondary)
                    }
                    Divider()
                }
                HStack {
                    Text("總計").font(.subheadline).bold().frame(width: 76, alignment: .leading)
                    Spacer()
                    Text("$\(grandTotalEst, specifier: "%.1f")").font(.caption).bold().frame(width: 58, alignment: .trailing)
                    Spacer()
                    Text("$\(grandTotalActual, specifier: "%.1f")")
                        .font(.caption).bold()
                        .foregroundColor(grandTotalPanda > 0 ? .teal : .primary)
                        .frame(width: 62, alignment: .trailing)
                    Spacer()
                    Text("$\(grandTotalDiff, specifier: "%.1f")")
                        .font(.caption).bold()
                        .foregroundColor(grandTotalDiff >= 0 ? (grandTotalDiff == 0 ? .primary : .red) : .green)
                        .frame(width: 60, alignment: .trailing)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(grandSummedHours, specifier: "%.1f")h工").font(.caption2).bold().foregroundColor(.blue)
                        Text("\(grandRidingHours, specifier: "%.1f")h騎").font(.caption2).bold().foregroundColor(.orange)
                    }
                    .frame(width: 56, alignment: .trailing)
                }
            }
            .padding()
            .background(Color(UIColor.tertiarySystemGroupedBackground))
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
        .padding(.horizontal)
    }
    private func chartDateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: date)
    }
    
    private var pastWeeksChartCard: some View {
        let cycleStart = viewModel.getBiweeklyStart(for: viewModel.selectedBiweeklyCycleOffset)
        let allDates = (0..<14).map { cycleStart.addingTimeInterval(Double($0) * 86400) }
        return VStack(alignment: .leading, spacing: 8) {
            Label("本期估算金額 vs 過去8週同星期幾基準", systemImage: "chart.xyaxis.line")
                .font(.subheadline).bold()
            Chart {
                ForEach(allDates, id: \.self) { date in
                    let key = viewModel.formatDateKey(date)
                    let income = viewModel.dailyReports[key]?.totalDailyIncome ?? 0
                    let label = chartDateLabel(date)
                    LineMark(x: .value("日期", label), y: .value("金額", income))
                        .foregroundStyle(by: .value("類型", "本期估算"))
                        .symbol(by: .value("類型", "本期估算"))
                    if let baseline = viewModel.incomeBaseline(for: date) {
                        LineMark(x: .value("日期", label), y: .value("金額", baseline))
                            .foregroundStyle(by: .value("類型", "過去8週基準"))
                            .symbol(by: .value("類型", "過去8週基準"))
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel().font(.system(size: 9))
                }
            }
            .frame(height: 240)
            Text("圖例「本期估算」為這14天每日App估算金額；「過去8週基準」為過去8週同一個星期幾的估算金額平均，可比較本期哪幾天優於/低於過去同星期幾的行情。")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: 11. 雙週對帳單日明細列
struct BiweeklyDailyRow: View {
    let date: Date
    @ObservedObject var viewModel: DeliveryTrackerViewModel
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd (E)"
        formatter.locale = Locale(identifier: "zh_TW")
        return formatter
    }
    
    var body: some View {
        let dateKey = viewModel.formatDateKey(date)
        let report = viewModel.dailyReports[dateKey] ?? DailyReport(dateString: dateKey)
        let estWage = report.totalDailyIncome
        let uberPayout = Double(report.dailyUberActualPayout) ?? 0.0
        let pandaPayout = Double(report.dailyPandaActualPayout) ?? 0.0
        let totalActualPayout = uberPayout + pandaPayout
        // 總差額 = (Uber實發 + 熊貓實發) - APP估算
        let diff = totalActualPayout - estWage
        let ueDiff = uberPayout - estWage
        let summedMins = Int(report.totalSummedMinutes)
        let ridingMins = Int(report.totalActualRidingMinutes)
        
        let payoutBinding = Binding<String>(
            get: { viewModel.dailyReports[dateKey]?.dailyUberActualPayout ?? "" },
            set: { newValue in
                var r = viewModel.dailyReports[dateKey] ?? DailyReport(dateString: dateKey)
                r.dailyUberActualPayout = newValue
                viewModel.dailyReports[dateKey] = r
            }
        )
        let noteBinding = Binding<String>(
            get: { viewModel.dailyReports[dateKey]?.dailyNote ?? "" },
            set: { newValue in
                var r = viewModel.dailyReports[dateKey] ?? DailyReport(dateString: dateKey)
                r.dailyNote = newValue
                viewModel.dailyReports[dateKey] = r
            }
        )
        let pandaBinding = Binding<String>(
            get: { viewModel.dailyReports[dateKey]?.dailyPandaActualPayout ?? "" },
            set: { newValue in
                var r = viewModel.dailyReports[dateKey] ?? DailyReport(dateString: dateKey)
                r.dailyPandaActualPayout = newValue
                viewModel.dailyReports[dateKey] = r
            }
        )
        let dateLabel = dateFormatter.string(from: date)
        
        return VStack(spacing: 6) {
            // 第 1 列：數據摘要成果
            HStack {
                Text(dateLabel).font(.caption).bold().frame(width: 76, alignment: .leading)
                Spacer()
                Text("$\(estWage, specifier: "%.1f")")
                    .font(.caption)
                    .frame(width: 58, alignment: .trailing)
                Spacer()
                Text("$\(totalActualPayout, specifier: "%.1f")")
                    .font(.caption).bold()
                    .foregroundColor(pandaPayout > 0 ? .teal : .primary)
                    .frame(width: 62, alignment: .trailing)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("$\(diff, specifier: "%.1f")")
                        .font(.caption).bold()
                        .foregroundColor(diff >= 0 ? (diff == 0 ? .primary : .red) : .green)
                    if pandaPayout > 0 {
                        Text("(UE $\(ueDiff, specifier: "%.0f"))")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 60, alignment: .trailing)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(summedMins)m工").font(.caption2).foregroundColor(.blue)
                    Text("\(ridingMins)m騎").font(.caption2).foregroundColor(.orange)
                }
                .frame(width: 56, alignment: .trailing)
            }
            
            // 第 2 列：三個橫向對齊輸入欄位（UE實發、熊貓實發、備註）
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Text("🟢UE:").font(.system(size: 10)).foregroundColor(.secondary)
                    DeferringTextField(
                        placeholder: "$0.0",
                        externalValue: payoutBinding,
                        keyboardType: .decimalPad,
                        font: .preferredFont(forTextStyle: .caption2),
                        textAlignment: .center
                    )
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(Color(UIColor.tertiarySystemGroupedBackground))
                .cornerRadius(6)
                .frame(maxWidth: .infinity)
                
                HStack(spacing: 2) {
                    Text("🐼:").font(.system(size: 10)).foregroundColor(.teal)
                    DeferringTextField(
                        placeholder: "熊貓",
                        externalValue: pandaBinding,
                        keyboardType: .decimalPad,
                        font: .preferredFont(forTextStyle: .caption2),
                        textAlignment: .center
                    )
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(Color(UIColor.tertiarySystemGroupedBackground))
                .cornerRadius(6)
                .frame(maxWidth: .infinity)
                
                HStack(spacing: 2) {
                    Text("📝").font(.system(size: 10))
                    DeferringTextField(
                        placeholder: "備註",
                        externalValue: noteBinding,
                        font: .preferredFont(forTextStyle: .caption2)
                    )
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(Color(UIColor.tertiarySystemGroupedBackground))
                .cornerRadius(6)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal).padding(.vertical, 6)
    }
}

// MARK: 12. 分頁四: 年報與資料瘦身
struct YearlyReportTabView: View {
    @ObservedObject var viewModel: DeliveryTrackerViewModel
    @State private var isExportingCSV = false
    @State private var csvDocument = CSVDocument()
    @State private var showPurgeAlert = false
    @State private var purgeTargetTitle = ""
    @State private var purgeRangeMonths: (start: Int, end: Int) = (1, 12)
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    yearPickerCard
                    monthlyAverageCard
                    yearlySummaryCard
                    exportAndArchiveMenuCard
                    yearlyTableView
                }
                .padding(.vertical)
            }
            .navigationTitle("年報與備份瘦身")
            .fileExporter(
                isPresented: $isExportingCSV,
                document: csvDocument,
                contentType: .commaSeparatedText,
                defaultFilename: "\(viewModel.selectedYear)_\(purgeTargetTitle)_備份.csv"
            ) { result in
                if case .success = result {
                    viewModel.purgeData(forStartMonths: purgeRangeMonths.start, endMonth: purgeRangeMonths.end, targetYear: viewModel.selectedYear)
                }
            }
            .alert(isPresented: $showPurgeAlert) {
                Alert(
                    title: Text("確定要匯出並清空 \(viewModel.selectedYear) \(purgeTargetTitle) 數據?"),
                    message: Text("此動作將會將該期間的數據導出為 CSV檔,並【清空瘦身】 App 內該區間的每日紀錄。\n\n若未來需要重新對帳,可透過歷史對帳頁面『匯入CSV』還原。"),
                    primaryButton: .destructive(Text("確定匯出並瘦身")) {
                        let csvContent = viewModel.exportToCSV(forStartMonths: purgeRangeMonths.start, endMonth: purgeRangeMonths.end, targetYear: viewModel.selectedYear)
                        csvDocument = CSVDocument(text: csvContent)
                        isExportingCSV = true
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }
    
    private var yearPickerCard: some View {
        HStack {
            Button(action: { viewModel.selectedYear -= 1 }) {
                Image(systemName: "chevron.left.circle.fill").font(.title2)
            }
            Spacer()
            Text("\(String(viewModel.selectedYear))年度對帳")
                .font(.title2).bold().foregroundColor(.blue)
            Spacer()
            Button(action: { viewModel.selectedYear += 1 }) {
                Image(systemName: "chevron.right.circle.fill").font(.title2)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    private var monthlyAverageCard: some View {
        let yearStats = viewModel.yearlyDailyAverage(year: viewModel.selectedYear)
        let recentMonthsBack = 3
        let recentStats = viewModel.pastMonthsDailyAverage(monthsBack: recentMonthsBack)
        
        func row(_ label: String, _ stats: (avgHours: Double?, avgIncome: Double?, includedDays: Int), color: Color) -> some View {
            HStack(alignment: .top) {
                Text(label).font(.caption).bold().foregroundColor(color).frame(width: 100, alignment: .leading)
                if let h = stats.avgHours, let inc = stats.avgIncome {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(h, specifier: "%.1f") 小時/天").font(.caption)
                        Text("$\(inc, specifier: "%.0f") /天").font(.caption)
                    }
                    Spacer()
                    Text("(\(stats.includedDays)天採入)").font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("尚無足夠資料").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        
        return VStack(alignment: .leading, spacing: 8) {
            Text("每月平均(已排除休假日)").font(.subheadline).bold()
            Divider()
            row("\(String(viewModel.selectedYear))年平均", yearStats, color: .blue)
            Divider()
            row("近\(recentMonthsBack)個月基準", recentStats, color: .purple)
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    private var yearlySummaryCard: some View {
        let stats = yearlyCalculatedStats
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(String(viewModel.selectedYear)) 全年總計概覽").font(.headline)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("預估總收入: $\(stats.totalEst, specifier: "%.1f")")
                    Text("Uber實發總額: $\(stats.totalActual, specifier: "%.1f")")
                    let pandaYear = monthlyPandaTotals().values.reduce(0, +)
                    if pandaYear > 0 {
                        Text("熊貓實發總額: $\(pandaYear, specifier: "%.1f")").foregroundColor(.teal)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("全年總單數: \(stats.totalOrders)單")
                    Text("每單累計工時: \(stats.totalSummedHours, specifier: "%.1f")小時").foregroundColor(.blue)
                    Text("實際騎乘時間: \(stats.totalRidingHours, specifier: "%.1f")小時").foregroundColor(.orange)
                }
            }
            .font(.subheadline)
            Divider()
            HStack {
                Text("全年對帳差額:").font(.subheadline).bold()
                Spacer()
                Text("$\(stats.totalDiff, specifier: "%.1f")")
                    .font(.title3).bold()
                    .foregroundColor(stats.totalDiff >= 0 ? (stats.totalDiff == 0 ? .primary : .red) : .green)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    private var exportAndArchiveMenuCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("資料備份與 App 瘦身專區", systemImage: "archivebox.fill")
                .font(.headline).foregroundColor(.orange)
            Text("備份導出 CSV檔後,系統將自動清空該區間 App 內之歷史紀錄以節省空間。")
                .font(.caption).foregroundColor(.secondary)
            
            Menu {
                Menu("單月匯出並瘦身 (1~12月)") {
                    ForEach(1...12, id: \.self) { m in
                        Button("匯出 \(m)月 並瘦身") { triggerPurge(title: "\(m)月", start: m, end: m) }
                    }
                }
                Section(header: Text("季報匯出(Q1~Q4)")) {
                    Button("匯出 Q1 (1~3月) 並瘦身") { triggerPurge(title: "Q1", start: 1, end: 3) }
                    Button("匯出 Q2 (4~6月) 並瘦身") { triggerPurge(title: "Q2", start: 4, end: 6) }
                    Button("匯出 Q3 (7~9月) 並瘦身") { triggerPurge(title: "Q3", start: 7, end: 9) }
                    Button("匯出 Q4 (10~12月) 並瘦身") { triggerPurge(title: "Q4", start: 10, end: 12) }
                }
                Section(header: Text("半年報匯出(H1/H2)")) {
                    Button("匯出 上半年 H1 (1~6月) 並瘦身") { triggerPurge(title: "上半年H1", start: 1, end: 6) }
                    Button("匯出 下半年 H2 (7~12月) 並瘦身") { triggerPurge(title: "下半年H2", start: 7, end: 12) }
                }
                Section(header: Text("年報匯出")) {
                    Button("匯出 全年報 (1~12月) 並瘦身") { triggerPurge(title: "全年報", start: 1, end: 12) }
                }
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "square.and.arrow.up.fill")
                    Text("選擇匯出與瘦身區間(單月/季報/半年報/年報)")
                    Spacer()
                }
                .font(.subheadline).bold().foregroundColor(.white).padding()
                .background(Color.orange).cornerRadius(10)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    private func monthlyPandaTotals() -> [Int: Double] {
        var result: [Int: Double] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        for (dateStr, report) in viewModel.dailyReports {
            guard let date = formatter.date(from: dateStr),
                  calendar.component(.year, from: date) == viewModel.selectedYear,
                  let amount = Double(report.dailyPandaActualPayout) else { continue }
            let month = calendar.component(.month, from: date)
            result[month, default: 0] += amount
        }
        return result
    }
    private func triggerPurge(title: String, start: Int, end: Int) {
        purgeTargetTitle = title
        purgeRangeMonths = (start, end)
        showPurgeAlert = true
    }
    
    private var yearlyTableView: some View {
        let monthlyData = getMonthlyBreakdown()
        let pandaMonthly = monthlyPandaTotals()
        return VStack(spacing: 0) {
            HStack {
                Text("月份").font(.caption).bold().frame(width: 40, alignment: .leading)
                Spacer()
                Text("APP估算").font(.caption).bold().frame(width: 60, alignment: .trailing)
                Spacer()
                Text("ue實發").font(.caption).bold().frame(width: 60, alignment: .center)
                Spacer()
                Text("差額").font(.caption).bold().frame(width: 50, alignment: .trailing)
                Spacer()
                Text("單數/工時/騎乘").font(.caption).bold().frame(width: 95, alignment: .trailing)
            }
            .padding()
            .background(Color.blue.opacity(0.2))
            Divider()
            
            ForEach(1...12, id: \.self) { month in
                let mData = monthlyData[month] ?? (est: 0.0, actual: 0.0, diff: 0.0, orders: 0, summedHours: 0.0, ridingHours: 0.0)
                HStack {
                    Text("\(String(format: "%02d", month))月")
                        .font(.subheadline).bold().frame(width: 40, alignment: .leading)
                    Spacer()
                    Text("$\(mData.est, specifier: "%.0f")").font(.caption).frame(width: 60, alignment: .trailing)
                    Spacer()
                    VStack(spacing: 1) {
                        Text("$\(mData.actual, specifier: "%.0f")").font(.caption)
                        if let p = pandaMonthly[month], p > 0 {
                            Text("🐼$\(p, specifier: "%.0f")").font(.system(size: 9)).foregroundColor(.teal)
                        }
                    }
                    .frame(width: 60, alignment: .center)
                    Spacer()
                    Text("$\(mData.diff, specifier: "%.0f")")
                        .font(.caption).bold()
                        .foregroundColor(mData.diff >= 0 ? (mData.diff == 0 ? .primary : .red) : .green)
                        .frame(width: 50, alignment: .trailing)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(mData.orders)單").font(.caption2)
                        Text("\(mData.summedHours, specifier: "%.1f")h工").font(.caption2).foregroundColor(.blue)
                        Text("\(mData.ridingHours, specifier: "%.1f")h騎").font(.caption2).foregroundColor(.orange)
                    }
                    .frame(width: 95, alignment: .trailing)
                }
                .padding(.horizontal).padding(.vertical, 8)
                .contextMenu {
                    Button(role: .destructive) {
                        triggerPurge(title: "\(month)月", start: month, end: month)
                    } label: {
                        Label("匯出 \(month)月 並瘦身", systemImage: "square.and.arrow.up")
                    }
                }
                Divider()
            }
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
        .padding(.horizontal)
    }
    
    private var yearlyCalculatedStats: (totalEst: Double, totalActual: Double, totalDiff: Double, totalOrders: Int, totalSummedHours: Double, totalRidingHours: Double) {
        let monthly = getMonthlyBreakdown()
        var est = 0.0, act = 0.0, diff = 0.0, ord = 0, sumHrs = 0.0, rideHrs = 0.0
        for m in 1...12 {
            if let data = monthly[m] {
                est += data.est
                act += data.actual
                diff += data.diff
                ord += data.orders
                sumHrs += data.summedHours
                rideHrs += data.ridingHours
            }
        }
        return (est, act, diff, ord, sumHrs, rideHrs)
    }
    
    private func getMonthlyBreakdown() -> [Int: (est: Double, actual: Double, diff: Double, orders: Int, summedHours: Double, ridingHours: Double)] {
        var result: [Int: (est: Double, actual: Double, diff: Double, orders: Int, summedHours: Double, ridingHours: Double)] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        
        for (dateStr, report) in viewModel.dailyReports {
            if let date = formatter.date(from: dateStr) {
                let year = calendar.component(.year, from: date)
                let month = calendar.component(.month, from: date)
                if year == viewModel.selectedYear {
                    let est = report.totalDailyIncome
                    let actual = Double(report.dailyUberActualPayout) ?? 0.0
                    let diff = actual - est
                    let orders = report.totalOrdersCount
                    let sHours = report.totalSummedMinutes / 60.0
                    let rHours = report.totalActualRidingMinutes / 60.0
                    
                    let current = result[month] ?? (est: 0.0, actual: 0.0, diff: 0.0, orders: 0, summedHours: 0.0, ridingHours: 0.0)
                    result[month] = (
                        est: current.est + est,
                        actual: current.actual + actual,
                        diff: current.diff + diff,
                        orders: current.orders + orders,
                        summedHours: current.summedHours + sHours,
                        ridingHours: current.ridingHours + rHours
                    )
                }
            }
        }
        return result
    }
}

// MARK: 13. Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
extension DailyReport {
    
    /// 某班別的「總時長／訂單覆蓋時長(聯集,重疊只算一次)／等待時長」
    func waitingStats(for shift: DeliveryBatch.ShiftType) -> (span: Double, covered: Double, idle: Double)? {
        let shiftBatches = appTrackedBatches.filter { $0.shiftType == shift }
        let intervals: [(Date, Date)] = shiftBatches.flatMap { batch in
            batch.validOrders.compactMap { order -> (Date, Date)? in
                guard let end = order.endTime, end > order.startTime else { return nil }
                return (order.startTime, end)
            }
        }
        guard let spanStart = intervals.map({ $0.0 }).min(),
              let spanEnd = intervals.map({ $0.1 }).max() else { return nil }
        let span = spanEnd.timeIntervalSince(spanStart)
        guard span > 0 else { return nil }
        
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var covered: Double = 0
        var curStart: Date? = nil
        var curEnd: Date? = nil
        for (s, e) in sorted {
            if let cs = curStart, let ce = curEnd {
                if s <= ce {
                    if e > ce { curEnd = e }
                } else {
                    covered += ce.timeIntervalSince(cs)
                    curStart = s
                    curEnd = e
                }
            } else {
                curStart = s
                curEnd = e
            }
        }
        if let cs = curStart, let ce = curEnd {
            covered += ce.timeIntervalSince(cs)
        }
        let idle = max(0, span - covered)
        return (span, covered, idle)
    }
    
    
}
import SwiftUI
import UIKit

// MARK: - 防卡頓延遲輸入框 (完整相容 textAlignment 與 alignment 參數)
struct DeferringTextField: View {
    let placeholder: String
    @Binding var externalValue: String
    var keyboardType: UIKeyboardType = .default
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var alignment: NSTextAlignment = .left

    // ⭕ 新增這個 init，讓傳入 textAlignment: 或 alignment: 都能通過編譯
    init(
        placeholder: String,
        externalValue: Binding<String>,
        keyboardType: UIKeyboardType = .default,
        font: UIFont = .preferredFont(forTextStyle: .body),
        alignment: NSTextAlignment = .left,
        textAlignment: NSTextAlignment? = nil, // 相容舊寫法 textAlignment
        isFocused: Any? = nil                  // 忽略舊寫法 isFocused
    ) {
        self.placeholder = placeholder
        self._externalValue = externalValue
        self.keyboardType = keyboardType
        self.font = font
        self.alignment = textAlignment ?? alignment
    }

    var body: some View {
        UIKitTextFieldRepresentable(
            placeholder: placeholder,
            text: $externalValue,
            keyboardType: keyboardType,
            font: font,
            alignment: alignment
        )
        .frame(height: 36)
    }
}

// MARK: - 底層極簡 UIKit 封裝
private struct UIKitTextFieldRepresentable: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType
    var font: UIFont
    var alignment: NSTextAlignment

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.placeholder = placeholder
        textField.borderStyle = .roundedRect
        textField.keyboardType = keyboardType
        textField.font = font
        textField.textAlignment = alignment
        textField.delegate = context.coordinator
        textField.returnKeyType = .done
        textField.autocorrectionType = .no
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if !uiView.isFirstResponder && uiView.text != text {
            uiView.text = text
            context.coordinator.localText = text
        }
        uiView.font = font
        uiView.textAlignment = alignment
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: UIKitTextFieldRepresentable
        var localText: String = ""

        init(_ parent: UIKitTextFieldRepresentable) {
            self.parent = parent
            self.localText = parent.text
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            localText = textField.text ?? ""
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if let currentText = textField.text as NSString? {
                localText = currentText.replacingCharacters(in: range, with: string)
            }
            return true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.text != localText {
                parent.text = localText
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
// MARK: - 接單試算（第一分頁用）

struct ShiftSnapshot {
    let start: Date          // 這一班開始時間
    let end: Date            // 計算用結束時間（進行中 = 現在；已結束 = 凍結的時間）
    let isClosed: Bool       // 這一班是否已結束
    let closedByUser: Bool   // true = 你按了下班；false = 超過60分鐘自動結束
    let wage: Double         // 這一班車資（含進行中估算，不含小費）
    let overlapRate: Double? // 疊單率，只當參考
    let orders: [DeliveryOrder] // 這一班所有的單

    var hours: Double { max(0, end.timeIntervalSince(start)) / 3600.0 }
    var hourly: Double? { hours > 0 ? wage / hours : nil }
}

extension DeliveryTrackerViewModel {
    /// 算出「目前這一班」的狀態。
    /// 班次規則：兩單之間空檔超過 60 分鐘，或你按過下班之後才開始的單，就算新的一班。
    func currentShiftSnapshot(now: Date, offTime: Date?) -> ShiftSnapshot? {
        let calendar = Calendar.current

        var keys = [todayKey]
        if let y = calendar.date(byAdding: .day, value: -1, to: now) {
            keys.append(formatDateKey(y))
        }

        var all: [DeliveryOrder] = []
        for key in keys {
            guard let report = dailyReports[key] else { continue }
            for batch in report.batches {
                all.append(contentsOf: batch.orders.filter {
                    !$0.isDiscarded && !$0.isManualEntry && $0.endTime != nil
                })
            }
        }
        // 目前趟次：已完成的 + 進行中的都算
        all.append(contentsOf: activeOrders.filter { !$0.isDiscarded })

        // 進行中的單，結束時間至少算「接單後 11 分鐘」（對應 11 分鐘內固定 45 元）
        func endOf(_ o: DeliveryOrder) -> Date {
            o.endTime ?? max(now, o.startTime.addingTimeInterval(11 * 60))
        }

        let sorted = all.sorted { $0.startTime < $1.startTime }
        guard let first = sorted.first else { return nil }

        var session: [DeliveryOrder] = [first]
        var sessionStart = first.startTime
        var sessionEnd = endOf(first)

        for order in sorted.dropFirst() {
            let gapBreak = order.startTime.timeIntervalSince(sessionEnd) > 3600
            var offBreak = false
            if let off = offTime, off >= sessionStart, order.startTime > off {
                offBreak = true
            }
            if gapBreak || offBreak {
                session = [order]
                sessionStart = order.startTime
                sessionEnd = endOf(order)
            } else {
                session.append(order)
                sessionEnd = max(sessionEnd, endOf(order))
            }
        }

        let wage = session.reduce(0.0) { $0 + $1.rawOperationWage }
        let summedMinutes = session.reduce(0.0) { $0 + Double($1.rawOperationMinutes) }
        let spanMinutes = sessionEnd.timeIntervalSince(sessionStart) / 60.0
        let rate: Double? = spanMinutes > 0 ? summedMinutes / spanMinutes : nil

        // 1) 你按了下班
        if let off = offTime, off >= sessionStart {
            return ShiftSnapshot(start: sessionStart, end: max(off, sessionEnd),
                                 isClosed: true, closedByUser: true,
                                 wage: wage, overlapRate: rate, orders: session)
        }

        // 2) 忘了按下班：最後一張單完成超過 60 分鐘 → 自動結束
        if now.timeIntervalSince(sessionEnd) > 3600 {
            return ShiftSnapshot(start: sessionStart, end: sessionEnd,
                                 isClosed: true, closedByUser: false,
                                 wage: wage, overlapRate: rate, orders: session)
        }

        // 3) 進行中
        return ShiftSnapshot(start: sessionStart, end: max(now, sessionEnd),
                             isClosed: false, closedByUser: false,
                             wage: wage, overlapRate: rate, orders: session)
    }

    /// 讀取某一單的「自訂金額」（就是歷史對帳頁的「自訂底薪」，同一個欄位）
    func customWage(forOrder id: UUID) -> String {
        if let o = activeOrders.first(where: { $0.id == id }) {
            return o.customWageInput
        }
        for (_, report) in dailyReports {
            for batch in report.batches {
                if let o = batch.orders.first(where: { $0.id == id }) {
                    return o.customWageInput
                }
            }
        }
        return ""
    }

    /// 修改某一單的自訂金額（單子還在目前趟次，或已經存進歷史，都找得到）
    func setCustomWage(forOrder id: UUID, value: String) {
        if let i = activeOrders.firstIndex(where: { $0.id == id }) {
            activeOrders[i].customWageInput = value
            return
        }
        for (key, report) in dailyReports {
            for (bi, batch) in report.batches.enumerated() {
                if let oi = batch.orders.firstIndex(where: { $0.id == id }) {
                    dailyReports[key]?.batches[bi].orders[oi].customWageInput = value
                    return
                }
            }
        }
    }

    /// 讀取某一單的小費
    func tip(forOrder id: UUID) -> String {
        if let o = activeOrders.first(where: { $0.id == id }) {
            return o.tipInput
        }
        for (_, report) in dailyReports {
            for batch in report.batches {
                if let o = batch.orders.first(where: { $0.id == id }) {
                    return o.tipInput
                }
            }
        }
        return ""
    }

    /// 修改某一單的小費（單子還在目前趟次，或已經存進歷史，都找得到）
    func setTip(forOrder id: UUID, value: String) {
        if let i = activeOrders.firstIndex(where: { $0.id == id }) {
            activeOrders[i].tipInput = value
            return
        }
        for (key, report) in dailyReports {
            for (bi, batch) in report.batches.enumerated() {
                if let oi = batch.orders.firstIndex(where: { $0.id == id }) {
                    dailyReports[key]?.batches[bi].orders[oi].tipInput = value
                    return
                }
            }
        }
    }
}

struct OrderQuoteCard: View {
    @ObservedObject var viewModel: DeliveryTrackerViewModel
    @State private var minutesText = ""
    @State private var priceText = ""
    @FocusState private var isFocused: Bool
    // 記住你按下班的時間（0 = 沒按過），以及按之前的值（給「取消下班」用）
    @AppStorage("shiftOffTimestamp") private var shiftOffTimestamp: Double = 0
    @AppStorage("shiftOffPrevious") private var shiftOffPrevious: Double = 0

    private var baseHourly: Double { WageSettings.hourly }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var offDate: Date? {
        shiftOffTimestamp > 0 ? Date(timeIntervalSince1970: shiftOffTimestamp) : nil
    }

    /// 拿來比較的目標時薪：班次進行中用實際時薪，否則用 245
    private func targetHourly(_ s: ShiftSnapshot?) -> Double {
        if let s = s, !s.isClosed, let h = s.hourly { return h }
        return baseHourly
    }

    private func durationText(_ s: ShiftSnapshot) -> String {
        let m = Int(max(0, s.end.timeIntervalSince(s.start)) / 60)
        return "\(m / 60)小時\(m % 60)分"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "scalemass.fill").foregroundColor(.purple)
                Text("接單試算").font(.headline)
                Spacer()
                Button("收鍵盤") {
                    isFocused = false
                    hideKeyboard()
                }
                .font(.caption).bold()
            }

            // 時薪區：每秒更新
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let snap = viewModel.currentShiftSnapshot(now: context.date, offTime: offDate)
                ratesBlock(snap)
            }

            Divider()

            HStack {
                Text("Uber 預估時間").font(.subheadline)
                Spacer()
                TextField("例：22", text: $minutesText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 90)
                    .focused($isFocused)
                Text("分鐘").font(.caption)
            }
            HStack {
                Text("Uber 單價").font(.subheadline)
                Spacer()
                TextField("例：50", text: $priceText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 90)
                    .focused($isFocused)
                Text("元").font(.caption)
            }

            // 結果區：每秒更新
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let snap = viewModel.currentShiftSnapshot(now: context.date, offTime: offDate)
                resultBlock(snap)
            }

            // 已完成的單：可以改金額
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let snap = viewModel.currentShiftSnapshot(now: context.date, offTime: offDate)
                ordersBlock(snap)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    @ViewBuilder
    private func ratesBlock(_ snap: ShiftSnapshot?) -> some View {
        let target = targetHourly(snap)
        let min10Price = target / 60.0 * 10.0

        VStack(alignment: .leading, spacing: 4) {
            if let s = snap, !s.isClosed {
                Text("本班已跑 \(durationText(s))，車資 $\(String(format: "%.0f", s.wage))（含進行中估算）")
                    .font(.caption).foregroundColor(.secondary)
                Text("目前實際時薪：\(String(format: "%.0f", target)) 元/小時")
                    .font(.subheadline).bold().foregroundColor(.blue)
                Text("10 分鐘的單至少要：\(String(format: "%.0f", min10Price)) 元")
                    .font(.subheadline).bold().foregroundColor(.orange)
                if let r = s.overlapRate {
                    Text("疊單率（參考）：\(String(format: "%.2f", r))")
                        .font(.caption).foregroundColor(.purple)
                }
                Button(action: {
                    shiftOffPrevious = shiftOffTimestamp
                    shiftOffTimestamp = Date().timeIntervalSince1970
                }) {
                    Text("下班（停止計算時薪）")
                        .font(.subheadline).bold().foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Color.red).cornerRadius(8)
                }
                .buttonStyle(BorderlessButtonStyle())
                .padding(.top, 4)
            } else if let s = snap, s.isClosed {
                Text("目前不在班次中（接新單會自動開新的一班）")
                    .font(.caption).foregroundColor(.secondary)
                if let h = s.hourly {
                    Text("上一班結算時薪：\(String(format: "%.0f", h)) 元/小時（\(s.closedByUser ? "你按了下班" : "超過60分鐘沒跑，自動結束")）")
                        .font(.subheadline).bold().foregroundColor(.green)
                    Text("上一班共 \(durationText(s))，車資 $\(String(format: "%.0f", s.wage))")
                        .font(.caption).foregroundColor(.secondary)
                }
                if s.closedByUser, Date().timeIntervalSince(Date(timeIntervalSince1970: shiftOffTimestamp)) < 10 * 60 {
                    Button(action: {
                        shiftOffTimestamp = shiftOffPrevious
                        shiftOffPrevious = 0
                    }) {
                        Text("誤觸下班 取消下班，繼續計算")
                            .font(.caption).bold().foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(Color.gray).cornerRadius(8)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                Text("新班次尚未開始，以 \(String(format: "%.0f", baseHourly)) 元/小時為基準")
                    .font(.caption).foregroundColor(.blue)
                Text("10 分鐘的單至少要：\(String(format: "%.0f", min10Price)) 元")
                    .font(.subheadline).bold().foregroundColor(.orange)
            } else {
                Text("尚無單，以 \(String(format: "%.0f", baseHourly)) 元/小時為基準")
                    .font(.subheadline).bold().foregroundColor(.blue)
                Text("10 分鐘的單至少要：\(String(format: "%.0f", min10Price)) 元")
                    .font(.subheadline).bold().foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private func resultBlock(_ snap: ShiftSnapshot?) -> some View {
        let target = targetHourly(snap)
        let uberMinutes = Double(minutesText.trimmingCharacters(in: .whitespaces))
        let uberPrice = Double(priceText.trimmingCharacters(in: .whitespaces))

        if let m = uberMinutes, m > 0, let p = uberPrice, p >= 0 {
            let orderHourly = p / m * 60.0
            let diff = orderHourly - target
            let ok = diff >= 0
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text("這張單預估時薪：\(String(format: "%.0f", orderHourly)) 元/小時")
                    .font(.subheadline).bold()
                Text("目前實際時薪：\(String(format: "%.0f", target)) 元/小時")
                    .font(.caption).foregroundColor(.secondary)
                Text("差距：\(diff >= 0 ? "+" : "")\(String(format: "%.0f", diff)) 元/小時")
                    .font(.caption).foregroundColor(.secondary)
                Text(ok ? "✅ 可以接" : "❌ 不划算")
                    .font(.title3).bold()
                    .foregroundColor(ok ? .green : .red)
            }
        }
    }

    @ViewBuilder
    private func ordersBlock(_ snap: ShiftSnapshot?) -> some View {
        // 只在「趟次還沒結束」時顯示：目前趟次裡已經按完成的單
        let done = viewModel.activeOrders
            .filter { $0.isCompleted && !$0.isDiscarded && $0.endTime != nil }
            .sorted { ($0.endTime ?? .distantPast) > ($1.endTime ?? .distantPast) }
        if !done.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("本趟已完成的單（可改金額）")
                    .font(.caption).bold()
                Text("Uber 實際金額跟估算不同，在這裡直接填；留空就用自動估算。整趟結束後，請到第二分頁「歷史對帳」修改。")
                    .font(.caption2).foregroundColor(.secondary)
                ForEach(done) { order in
                    orderRow(order)
                }
            }
        }
    }

    private func orderRow(_ order: DeliveryOrder) -> some View {
        var auto = order
        auto.customWageInput = ""
        let autoWage = auto.rawOperationWage
        let shownWage = order.rawOperationWage
        let isEdited = Double(order.customWageInput) != nil
        let label = order.userNote.isEmpty ? "單#\(order.orderNumber)" : order.userNote
        let timeText = order.endTime.map { Self.timeFormatter.string(from: $0) } ?? "--:--"
        let orderID = order.id
        let binding = Binding<String>(
            get: { viewModel.customWage(forOrder: orderID) },
            set: { viewModel.setCustomWage(forOrder: orderID, value: $0) }
        )
        let tipBinding = Binding<String>(
            get: { viewModel.tip(forOrder: orderID) },
            set: { viewModel.setTip(forOrder: orderID, value: $0) }
        )
        let tipAmount = order.tipAmount

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline).bold()
                Text("\(timeText)完成・\(order.rawOperationMinutes)分")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                if tipAmount > 0 {
                    Text("$\(String(format: "%.0f", shownWage)) + 小費$\(String(format: "%.0f", tipAmount))")
                        .font(.subheadline).bold().foregroundColor(.green)
                } else {
                    Text("$\(String(format: "%.0f", shownWage))")
                        .font(.subheadline).bold().foregroundColor(.green)
                }
            }
            HStack(spacing: 8) {
                Text("改金額").font(.caption)
                DeferringTextField(
                    placeholder: "自動 $\(String(format: "%.0f", autoWage))",
                    externalValue: binding,
                    keyboardType: .decimalPad
                )
                .frame(width: 85)

                Text("小費").font(.caption)
                DeferringTextField(
                    placeholder: "0",
                    externalValue: tipBinding,
                    keyboardType: .decimalPad
                )
                .frame(width: 55)

                if isEdited {
                    Button(action: { viewModel.setCustomWage(forOrder: orderID, value: "") }) {
                        Text("還原金額").font(.caption2).foregroundColor(.blue)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                if !order.tipInput.isEmpty && (Double(order.tipInput) ?? 0) > 0 {
                    Button(action: { viewModel.setTip(forOrder: orderID, value: "") }) {
                        Text("清空小費").font(.caption2).foregroundColor(.blue)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }
}
// 一筆費率：從 effectiveDate 起，基本費與時薪是多少
struct WageRate: Codable, Identifiable, Hashable {
    var id = UUID()
    var effectiveDate: Date
    var baseFee: Double
    var hourly: Double
    // 1970 年當作「最早起始費率」，舊單都適用
    var isBase: Bool { effectiveDate.timeIntervalSince1970 <= 0 }
}

enum WageSettings {
    private static let key = "wageRateHistory"
    private static var cache: [WageRate]?

    static var rates: [WageRate] {
        get {
            if let c = cache { return c }
            if let data = UserDefaults.standard.data(forKey: key),
               let decoded = try? JSONDecoder().decode([WageRate].self, from: data),
               !decoded.isEmpty {
                cache = decoded
                return decoded
            }
            // 第一次使用：若上一版有填過數字就沿用，否則用 45 / 245
            let oldFee = UserDefaults.standard.object(forKey: "wageBaseFee") as? Double ?? 45.0
            let oldHourly = UserDefaults.standard.object(forKey: "wageBaseHourly") as? Double ?? 245.0
            let initial = [WageRate(effectiveDate: Date(timeIntervalSince1970: 0), baseFee: oldFee, hourly: oldHourly)]
            cache = initial
            return initial
        }
        set {
            cache = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    // 找出某個日期適用的費率：生效日 ≤ 該日期 裡面最新的一筆
    static func rate(at date: Date) -> WageRate {
        let sorted = rates.sorted { $0.effectiveDate < $1.effectiveDate }
        return sorted.last(where: { $0.effectiveDate <= date }) ?? sorted.first!
    }

    // 「現在」適用的數字（接單試算、動態島用）
    static var baseFee: Double { rate(at: Date()).baseFee }
    static var hourly: Double { rate(at: Date()).hourly }

    // 11分鐘內固定基本費，超過的部分按時薪算
    static func wage(forMinutes m: Double, at date: Date) -> Double {
        let r = rate(at: date)
        if m <= 11.0 { return r.baseFee }
        return r.baseFee + r.hourly * ((m - 11.0) / 60.0)
    }
}

struct WageSettingsCard: View {
    @State private var rates: [WageRate] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "dollarsign.circle.fill").foregroundColor(.green)
                Text("薪資設定（含生效日期）").font(.headline)
                Spacer()
                Button("完成") { focused = false }.font(.caption).bold()
            }
            Text("每張單用「接單當天」適用的費率計算，調漲後舊單不會被改到。")
                .font(.caption2).foregroundColor(.secondary)

            ForEach($rates) { $rate in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if rate.isBase {
                            Text("起始費率（更早的單都用這個）").font(.caption).bold()
                        } else {
                            DatePicker("生效日", selection: $rate.effectiveDate, displayedComponents: .date)
                                .font(.caption)
                            Button(action: { rates.removeAll { $0.id == rate.id } }) {
                                Image(systemName: "trash").foregroundColor(.red)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    HStack {
                        Text("基本費").font(.caption)
                        TextField("45", value: $rate.baseFee, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 80)
                            .focused($focused)
                        Spacer()
                        Text("時薪").font(.caption)
                        TextField("245", value: $rate.hourly, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 80)
                            .focused($focused)
                    }
                }
                .padding(8)
                .background(Color(UIColor.tertiarySystemGroupedBackground))
                .cornerRadius(8)
            }

            Button(action: addRate) {
                Label("新增費率調整", systemImage: "plus.circle.fill")
                    .font(.subheadline).bold()
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(Color.green.opacity(0.15)).foregroundColor(.green).cornerRadius(8)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
        .onAppear { rates = WageSettings.rates }
        .onChange(of: rates) { _, newValue in
            // 小數點第二位四捨五入、生效日對齊到當天 00:00
            let cal = Calendar.current
            let normalized = newValue.map { r -> WageRate in
                var x = r
                x.baseFee = (r.baseFee * 100).rounded() / 100
                x.hourly = (r.hourly * 100).rounded() / 100
                if !r.isBase { x.effectiveDate = cal.startOfDay(for: r.effectiveDate) }
                return x
            }
            if normalized != newValue { rates = normalized }
            WageSettings.rates = normalized
        }
    }

    private func addRate() {
        let latest = rates.max(by: { $0.effectiveDate < $1.effectiveDate })
        let new = WageRate(effectiveDate: Calendar.current.startOfDay(for: Date()),
                           baseFee: latest?.baseFee ?? 45, hourly: latest?.hourly ?? 245)
        rates.append(new)
        rates.sort { $0.effectiveDate < $1.effectiveDate }
    }
}
