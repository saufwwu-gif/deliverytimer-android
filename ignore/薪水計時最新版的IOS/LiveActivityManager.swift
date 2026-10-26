//
//  LiveActivityManager.swift
//  薪水計時
//

import Foundation
import ActivityKit

final class LiveActivityManager {
    static let shared = LiveActivityManager()
    
    private var currentActivity: Activity<DeliveryActivityAttributes>?
    
    private init() {}
    
    /// 檢查設備與使用者是否允許 Live Activities
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }
    
    /// 啟動外送趟次 Live Activity (動態島與鎖定畫面跳錶)
    func startDeliveryActivity(
        batchNumber: Int,
        startTime: Date,
        initialEarnings: Double,
        hourlyRate: Double,
        activeOrderCount: Int,
        completedOrderCount: Int = 0,
        totalOrderCount: Int = 1,
        statusText: String = "配送中",
        activeOrderDetails: [String] = [],
        tenMinuteThreshold: Double = 40.0,
        timerStartTime: Date? = nil
    ) {
        guard areActivitiesEnabled else {
            print("⚠️ [LiveActivity] 設備未啟用 Live Activities 權限")
            return
        }
        
        // 若已有先前的活動在執行，先結束
        endDeliveryActivity(dismissImmediately: true)
        
        let attributes = DeliveryActivityAttributes(batchStartTime: startTime, batchNumber: batchNumber)
        let initialState = DeliveryActivityAttributes.ContentState(
            currentEarnings: initialEarnings,
            hourlyRate: hourlyRate,
            activeOrderCount: activeOrderCount,
            completedOrderCount: completedOrderCount,
            totalOrderCount: totalOrderCount,
            statusText: statusText,
            isPaused: false,
            activeOrderDetails: activeOrderDetails,
            tenMinuteThreshold: tenMinuteThreshold,
            timerStartTime: timerStartTime
        )
        
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            self.currentActivity = activity
            print("✅ [LiveActivity] 成功啟動，ID: \(activity.id)")
        } catch {
            print("❌ [LiveActivity] 啟動失敗: \(error.localizedDescription)")
        }
    }
    
    /// 更新外送趟次數據 (收入變更、送達一單、加單、單號/收取金額更新等)
    func updateDeliveryActivity(
        earnings: Double,
        hourlyRate: Double,
        activeOrderCount: Int,
        completedOrderCount: Int,
        totalOrderCount: Int,
        statusText: String = "配送中",
        isPaused: Bool = false,
        activeOrderDetails: [String] = [],
        tenMinuteThreshold: Double = 40.0,
        timerStartTime: Date? = nil
    ) {
        guard let activity = currentActivity else { return }
        
        let updatedState = DeliveryActivityAttributes.ContentState(
            currentEarnings: earnings,
            hourlyRate: hourlyRate,
            activeOrderCount: activeOrderCount,
            completedOrderCount: completedOrderCount,
            totalOrderCount: totalOrderCount,
            statusText: statusText,
            isPaused: isPaused,
            activeOrderDetails: activeOrderDetails,
            tenMinuteThreshold: tenMinuteThreshold,
            timerStartTime: timerStartTime
        )
        
        Task {
            await activity.update(.init(state: updatedState, staleDate: nil))
            print("🔄 [LiveActivity] 更新完成: 收入 $\(Int(earnings)), 門檻 10分$\(Int(tenMinuteThreshold)), 進行中 \(activeOrderCount) 單, 明細: \(activeOrderDetails)")
        }
    }
    
    /// 結束外送趟次 Live Activity
    func endDeliveryActivity(dismissImmediately: Bool = false) {
        guard let activity = currentActivity else { return }
        
        Task {
            let dismissalPolicy: ActivityUIDismissalPolicy = dismissImmediately ? .immediate : .after(Date().addingTimeInterval(4))
            await activity.end(nil, dismissalPolicy: dismissalPolicy)
            self.currentActivity = nil
            print("🛑 [LiveActivity] 已結束")
        }
    }
}
