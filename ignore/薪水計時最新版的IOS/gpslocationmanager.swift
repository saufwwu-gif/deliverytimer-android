import Foundation
import CoreLocation

extension Notification.Name {
    static let deliverySessionDidStop = Notification.Name("deliverySessionDidStop")
}

extension GPSLocationManager {
    func startNewDeliverySession() {
        self.todayPoints.removeAll()
        self.clearManualStayPoints()
        self.startTracking()
    }

    func stopDeliverySession() {
        self.stopTracking()
        NotificationCenter.default.post(name: .deliverySessionDidStop, object: nil)
    }
}

struct GPSPoint: Identifiable, Codable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    // 改動B:記錄當下速度(公尺/秒)，用來做「開始停留/真的離開」時間點的自動回溯判斷。
    let speedMetersPerSecond: Double

    init(id: UUID = UUID(), latitude: Double, longitude: Double, timestamp: Date = Date(), speedMetersPerSecond: Double = 0) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.speedMetersPerSecond = speedMetersPerSecond
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var speedKmh: Double {
        max(0, speedMetersPerSecond) * 3.6
    }

    enum CodingKeys: String, CodingKey {
        case id, latitude, longitude, timestamp, speedMetersPerSecond
    }

    // 舊資料沒有 speedMetersPerSecond 這個欄位，用 decodeIfPresent + 預設值 0，
    // 才不會讓舊的已存檔案整包 decode 失敗。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        speedMetersPerSecond = try c.decodeIfPresent(Double.self, forKey: .speedMetersPerSecond) ?? 0
    }
}

extension GPSLocationManager {
    var startTimeString: String {
        guard let first = todayPoints.first else { return "--:--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: first.timestamp)
    }

    var endTimeString: String {
        guard let last = todayPoints.last else { return "--:--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: last.timestamp)
    }

    var drivingTimeString: String {
        guard let first = todayPoints.first, let last = todayPoints.last else { return "0 分" }
        let totalSeconds = Int(last.timestamp.timeIntervalSince(first.timestamp))
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) 小時 \(mins) 分"
        } else {
            return "\(mins) 分"
        }
    }
}

struct StayPoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let arrivalTime: Date
    let departureTime: Date
    var isManual: Bool = false

    var durationSeconds: Int {
        Int(departureTime.timeIntervalSince(arrivalTime))
    }

    var formattedDuration: String {
        let mins = durationSeconds / 60
        let secs = durationSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

private struct ManualStayRecord: Codable {
    let latitude: Double
    let longitude: Double
    let arrivalTime: Date
    let departureTime: Date
}

class GPSLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = GPSLocationManager()

    private let manager = CLLocationManager()
    @Published var isTracking = false
    @Published var todayPoints: [GPSPoint] = []

    @Published var isManualStayActive: Bool = false
    @Published var manualStayPoints: [StayPoint] = []
    private var manualStayStartTime: Date?
    private var manualStayAnchorCoordinate: CLLocationCoordinate2D?

    private let storageKey = "SavedGPSPoints_Today"
    private let manualStayStorageKey = "SavedManualStayPoints_Today"

    // 改動C:手動停留點「真的離開」的判定門檻。
    // 距離出發點超過這個值「而且」速度也持續超過門檻，才算真的離開(不是在附近走動，例如百貨公司內閒晃)。
    private let manualStayDepartureDistanceMeters: Double = 200.0
    private let manualStayDepartureSpeedThresholdKmh: Double = 12.0
    // 判定「已經停下來了」的速度門檻，用來回溯找出忘記按「開始停留」時的真正停留起點。
    private let stationarySpeedThresholdKmh: Double = 3.0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = true
        manager.activityType = .automotiveNavigation
        loadPoints()
        loadManualStayPoints()
    }

    func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func startTracking() {
        requestAuthorization()
        applyPowerMode() // 改動D:一開始一定是「騎乘中」狀態，先確保 activityType 正確
        manager.startUpdatingLocation()
        DispatchQueue.main.async {
            self.isTracking = true
        }
    }

    // 改動D:省電模式。
    // 騎乘移動時維持 .automotiveNavigation，確保路線/速度資料不中斷。
    // 進入「停留」時改成 .otherNavigation——因為 .automotiveNavigation 這個 activityType
    // 本來就是設計給「開車等紅燈也不要暫停定位」用的，所以停留時如果還留著它，
    // pausesLocationUpdatesAutomatically 幾乎不會真的生效，等於一直耗電。
    // 切成 .otherNavigation 後，靜止不動時系統才會真的暫停 GPS 省電，
    // 一偵測到你開始移動又會自動恢復，不影響離開停留點的判斷。
    private func applyPowerMode() {
        manager.activityType = isManualStayActive ? .otherNavigation : .automotiveNavigation
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        isTracking = false
        // 改動A:停止追蹤時,如果手動停留還在計時中,直接強制收尾(不管距離),避免整筆消失
        if isManualStayActive {
            finalizeManualStay(departureTime: Date())
        }
    }

    func startManualStayPoint() {
        guard !isManualStayActive else { return }
        guard let anchor = manager.location?.coordinate ?? todayPoints.last?.coordinate else { return }
        isManualStayActive = true
        manualStayStartTime = Date()
        manualStayAnchorCoordinate = anchor
        applyPowerMode() // 進入停留，切換省電模式
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // 改動B:用 CLLocation 本身的 timestamp(定位當下時間)而不是 Date()(callback 執行時間)，
        // 並記錄當下速度，讓後面的回溯判斷更準。speed < 0 代表無效，當作靜止(0)處理。
        let newPoint = GPSPoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            speedMetersPerSecond: max(0, location.speed)
        )

        DispatchQueue.main.async {
            self.todayPoints.append(newPoint)
            self.savePoints()
            self.checkManualStayDeparture(currentLocation: location)
        }
    }

    // 改動C:忘記按「結束停留」的補救。
    // 距離出發點超過 200m「而且」速度持續超過 12km/h，兩個條件都成立才算真的離開，
    // 避免在百貨公司/店內走動被誤判成已經出發。
    // 判定成立後，不是拿「現在」當結束時間，而是往回找「真正開始加速離開」的那一刻，
    // 這樣 ST 停留時長才會準。
    private func checkManualStayDeparture(currentLocation: CLLocation) {
        guard isManualStayActive,
              let anchor = manualStayAnchorCoordinate else { return }
        let anchorLocation = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
        let distance = currentLocation.distance(from: anchorLocation)
        let speedKmh = max(0, currentLocation.speed) * 3.6

        guard distance >= manualStayDepartureDistanceMeters,
              speedKmh > manualStayDepartureSpeedThresholdKmh else { return }

        let departureTime = backtrackAccelerationStart(
            before: currentLocation.timestamp,
            speedThresholdKmh: manualStayDepartureSpeedThresholdKmh
        ) ?? currentLocation.timestamp

        finalizeManualStay(departureTime: departureTime)
    }

    /// 從指定時間點往前搜尋，找到速度「開始超過」門檻、真正踩下油門離開的那一刻，作為結束停留時間 E。
    /// 找不到就回傳 nil，呼叫端會退回用「現在」當結束時間。
    func backtrackAccelerationStart(before referenceTime: Date, speedThresholdKmh: Double) -> Date? {
        let priorPoints = todayPoints.filter { $0.timestamp <= referenceTime }
        guard !priorPoints.isEmpty else { return nil }

        var accelerationStart: Date? = nil
        for point in priorPoints.reversed() {
            if point.speedKmh >= speedThresholdKmh {
                accelerationStart = point.timestamp
            } else {
                break
            }
        }
        return accelerationStart
    }

    /// 從指定時間點往前搜尋，找到速度真正掉到門檻以下的那一刻，作為「開始停留」時間 S。
    /// 用在使用者忘記按「開始停留」，直接按下「取餐/送餐完成」的情況。
    func backtrackStationaryStart(before referenceTime: Date, speedThresholdKmh: Double = 3.0) -> Date? {
        let priorPoints = todayPoints.filter { $0.timestamp <= referenceTime }
        guard !priorPoints.isEmpty else { return nil }

        var stationaryStart: Date? = nil
        for point in priorPoints.reversed() {
            if point.speedKmh < speedThresholdKmh {
                stationaryStart = point.timestamp
            } else {
                break
            }
        }
        // 找不到「曾經加速過」的分界點，代表整段軌跡從頭到 referenceTime 都是慢速，
        // 就用最早的那個點當起點。
        return stationaryStart ?? priorPoints.first?.timestamp
    }

    /// 改動B:給「取餐/送餐完成」按鈕呼叫的自動補救。
    /// 如果使用者這趟根本沒按「開始停留」(isManualStayActive == false)，
    /// 就用速度回溯出真正的停留起點，自動幫忙補一筆停留紀錄，讓 ST 時長不會整個消失不見。
    /// 如果同一次停留有好幾張訂單陸續完成(例如一次拿好幾單)，會合併進上一筆紀錄，
    /// 不會每完成一張單就多開一筆重疊的停留。
    func autoFinalizeStayOnOrderCompletion(completionTime: Date = Date()) {
        guard !isManualStayActive else { return } // 使用者有手動按「開始停留」，走原本離開回溯的流程即可，這裡不重複處理
        guard let stationaryStart = backtrackStationaryStart(before: completionTime, speedThresholdKmh: stationarySpeedThresholdKmh),
              completionTime.timeIntervalSince(stationaryStart) >= 60 else { return } // 停不到 1 分鐘就不算數，避免紅燈也被補一筆

        if let lastIndex = manualStayPoints.indices.last,
           stationaryStart <= manualStayPoints[lastIndex].departureTime {
            // 跟上一筆重疊，代表是同一次停留的另一張訂單，延伸更新既有那筆就好
            let old = manualStayPoints[lastIndex]
            manualStayPoints[lastIndex] = StayPoint(
                coordinate: old.coordinate,
                arrivalTime: min(old.arrivalTime, stationaryStart),
                departureTime: max(old.departureTime, completionTime),
                isManual: true
            )
        } else {
            guard let coordinate = (todayPoints.last(where: { $0.timestamp <= completionTime }) ?? todayPoints.last)?.coordinate else { return }
            let stay = StayPoint(coordinate: coordinate, arrivalTime: stationaryStart, departureTime: completionTime, isManual: true)
            manualStayPoints.append(stay)
        }
        saveManualStayPoints()
    }

    private func finalizeManualStay(departureTime: Date) {
        guard let anchor = manualStayAnchorCoordinate,
              let startTime = manualStayStartTime else { return }

        let stay = StayPoint(coordinate: anchor, arrivalTime: startTime, departureTime: departureTime, isManual: true)
        manualStayPoints.append(stay)
        saveManualStayPoints()

        isManualStayActive = false
        manualStayStartTime = nil
        manualStayAnchorCoordinate = nil
        applyPowerMode() // 離開停留了，切回騎乘模式
    }

    private func savePoints() {
        if let encoded = try? JSONEncoder().encode(todayPoints) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    private func loadPoints() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([GPSPoint].self, from: data) {
            self.todayPoints = decoded
        }
    }

    private func saveManualStayPoints() {
        let records = manualStayPoints.map {
            ManualStayRecord(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                arrivalTime: $0.arrivalTime,
                departureTime: $0.departureTime
            )
        }
        if let encoded = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(encoded, forKey: manualStayStorageKey)
        }
    }

    private func loadManualStayPoints() {
        if let data = UserDefaults.standard.data(forKey: manualStayStorageKey),
           let decoded = try? JSONDecoder().decode([ManualStayRecord].self, from: data) {
            self.manualStayPoints = decoded.map {
                StayPoint(
                    coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                    arrivalTime: $0.arrivalTime,
                    departureTime: $0.departureTime,
                    isManual: true
                )
            }
        }
    }

    func clearManualStayPoints() {
        manualStayPoints.removeAll()
        UserDefaults.standard.removeObject(forKey: manualStayStorageKey)
    }

    func clearTodayData() {
        todayPoints.removeAll()
        clearManualStayPoints()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    func calculateStayPoints(distanceThresholdMeter: Double = 30.0, minDurationMinutes: Double = 3.0) -> [StayPoint] {
        guard todayPoints.count > 1 else { return [] }

        var stays: [StayPoint] = []
        var group: [GPSPoint] = [todayPoints[0]]

        for i in 1..<todayPoints.count {
            let p1 = group.first!
            let p2 = todayPoints[i]
            let loc1 = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
            let loc2 = CLLocation(latitude: p2.latitude, longitude: p2.longitude)

            if loc1.distance(from: loc2) <= distanceThresholdMeter {
                group.append(p2)
            } else {
                if let stay = processGroupToStay(group: group, minMinutes: minDurationMinutes) {
                    stays.append(stay)
                }
                group = [p2]
            }
        }

        if let stay = processGroupToStay(group: group, minMinutes: minDurationMinutes) {
            stays.append(stay)
        }

        return stays
    }

    private func processGroupToStay(group: [GPSPoint], minMinutes: Double) -> StayPoint? {
        guard let start = group.first, let end = group.last else { return nil }
        let duration = end.timestamp.timeIntervalSince(start.timestamp) / 60.0

        if duration >= minMinutes {
            let avgLat = group.map { $0.latitude }.reduce(0, +) / Double(group.count)
            let avgLng = group.map { $0.longitude }.reduce(0, +) / Double(group.count)
            return StayPoint(
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLng),
                arrivalTime: start.timestamp,
                departureTime: end.timestamp
            )
        }
        return nil
    }
}
