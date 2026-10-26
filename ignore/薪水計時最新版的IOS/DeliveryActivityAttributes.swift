//
//  DeliveryActivityAttributes.swift
//  DeliveryWidget
//

import Foundation
import ActivityKit

public struct DeliveryActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 當前累計收入 (元)
        public var currentEarnings: Double
        /// 當前即時時薪 (元/小時)
        public var hourlyRate: Double
        /// 正在進行中(尚未送達)的單數
        public var activeOrderCount: Int
        /// 本趟次已完成送達的單數
        public var completedOrderCount: Int
        /// 本趟次總單數
        public var totalOrderCount: Int
        /// 狀態文字 (例如: "配送中", "取餐中", "已送達")
        public var statusText: String
        /// 是否處於暫停/休息狀態
        public var isPaused: Bool
        /// 進行中訂單明細（包含平台單號、OCR辨識字串、收取金額）
        public var activeOrderDetails: [String]
        /// 10 分鐘接單效益門檻 (每10分鐘要賺多少才值得接)
        public var tenMinuteThreshold: Double
        /// App 裡「計時組別」的起點(跳錶要從這裡算,跟 App 一致)
        public var timerStartTime: Date?
        
        public init(
            currentEarnings: Double = 0.0,
            hourlyRate: Double = 0.0,
            activeOrderCount: Int = 1,
            completedOrderCount: Int = 0,
            totalOrderCount: Int = 1,
            statusText: String = "配送中",
            isPaused: Bool = false,
            activeOrderDetails: [String] = [],
            tenMinuteThreshold: Double = 40.0,
            timerStartTime: Date? = nil
        ) {
            self.currentEarnings = currentEarnings
            self.hourlyRate = hourlyRate
            self.activeOrderCount = activeOrderCount
            self.completedOrderCount = completedOrderCount
            self.totalOrderCount = totalOrderCount
            self.statusText = statusText
            self.isPaused = isPaused
            self.activeOrderDetails = activeOrderDetails
            self.tenMinuteThreshold = tenMinuteThreshold
            self.timerStartTime = timerStartTime
        }
    }

    /// 本趟次開始時間 (供系統原生 Timer 自動跳錶，極度省電)
    public var batchStartTime: Date
    /// 趟次編號 (例如第 1 趟)
    public var batchNumber: Int
    
    public init(batchStartTime: Date, batchNumber: Int = 1) {
        self.batchStartTime = batchStartTime
        self.batchNumber = batchNumber
    }
}
