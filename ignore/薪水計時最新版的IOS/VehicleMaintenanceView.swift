import SwiftUI
import PhotosUI
import Vision
import UniformTypeIdentifiers
import Charts
import CryptoKit
import CoreImage
import CoreImage.CIFilterBuiltins

// 這個畫面被放在外層 ContentView 的 TabView(.page 樣式) 裡面 swipe 切換，
// 在這種環境下 SwiftUI 回報的 safeAreaInsets 常常不可靠（會被上層吃掉、變成 0），
// 導致自己手刻的頂部標題列貼齊螢幕最上緣、被狀態列蓋住一部分。
// 這裡改成直接問 UIKit 拿「真正的」safe area 高度，不透過 SwiftUI 的環境值，
// 這樣才不會被外層的 TabView / NavigationView 設定影響。
extension UIApplication {
    var keyWindowSafeAreaTopInset: CGFloat {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
    }
}

// MARK: - 0. 共用相機元件 (CameraPicker)
// PhotosPicker 只能開相簿，沒有相機選項；用 UIImagePickerController 另外包一個拍照入口。
struct CameraPicker: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - 0.5 共用 OCR 輔助工具
// 加油紀錄跟保養紀錄都需要「拍儀表板帶入里程」，把辨識邏輯抽成共用工具給兩邊呼叫。
enum OCRHelper {
    
    struct TextItem {
        let text: String
        let box: CGRect
        var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
        var height: CGFloat { box.height }
    }
    
    // 從文字中取出第一個數字（支援小數）
    static func extractNumber(from text: String) -> Double? {
        let pattern = "[0-9]+\\.?[0-9]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        return Double(text[r])
    }
    
    // OCR 前先做一次對比度/去彩色雜訊處理，LCD 數字（像加油機、儀表板）常因為玻璃反光、
    // 對比不夠而整段辨識不到（不是辨識錯，是完全沒被判斷成文字），這一步能提升辨識成功率，
    // 但不保證每張照片都能讀到——反光太嚴重、太模糊的照片還是可能讀不到，這時候用手動輸入就好。
    static func preprocessForOCR(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        
        // 先放大 2 倍——像小數點這種只佔幾個像素的小元素，放大後才有足夠的像素讓 Vision
        // 判斷「這是一個有意義的符號」，不然常常因為太小、信心度不夠，連同整段文字一起被丟棄
        var workingImage = ciImage
        if let scaleFilter = CIFilter(name: "CILanczosScaleTransform") {
            scaleFilter.setValue(workingImage, forKey: kCIInputImageKey)
            scaleFilter.setValue(2.0, forKey: kCIInputScaleKey)
            scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let scaledOutput = scaleFilter.outputImage {
                workingImage = scaledOutput
            }
        }
        
        guard let filter = CIFilter(name: "CIColorControls") else {
            let context = CIContext()
            guard let cgImage = context.createCGImage(workingImage, from: workingImage.extent) else { return image }
            return UIImage(cgImage: cgImage)
        }
        filter.setValue(workingImage, forKey: kCIInputImageKey)
        filter.setValue(1.25, forKey: kCIInputContrastKey)    // 拉高對比，讓 LCD 數字邊緣更清楚
        filter.setValue(0.0, forKey: kCIInputSaturationKey)   // 去彩色雜訊，減少玻璃反光的顏色干擾
        filter.setValue(0.05, forKey: kCIInputBrightnessKey)
        
        guard let output = filter.outputImage else { return image }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: cgImage)
    }
    
    static func extractItems(_ observations: [VNRecognizedTextObservation]) -> [TextItem] {
        observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return TextItem(text: candidate.string, box: obs.boundingBox)
        }
    }
    
    static func nearestNumber(
        to center: CGPoint,
        in numberItems: [(value: Double, center: CGPoint, height: CGFloat)],
        excluding usedIndices: inout Set<Int>
    ) -> Double? {
        var bestIndex: Int? = nil
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (idx, num) in numberItems.enumerated() {
            if usedIndices.contains(idx) { continue }
            let dx = num.center.x - center.x
            let dy = num.center.y - center.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < bestDist {
                bestDist = dist
                bestIndex = idx
            }
        }
        if let idx = bestIndex {
            usedIndices.insert(idx)
            return numberItems[idx].value
        }
        return nil
    }
    
    // 備援：不靠文字標籤，直接找「上下疊放、字體大小相近且較大」的兩個數字方塊
    static func findStackedNumberPair(
        in numberItems: [(value: Double, center: CGPoint, height: CGFloat)]
    ) -> (top: Double, bottom: Double)? {
        guard numberItems.count >= 2 else { return nil }
        
        var bestPair: (i: Int, j: Int)? = nil
        var bestScore = CGFloat.greatestFiniteMagnitude
        
        for i in 0..<numberItems.count {
            for j in (i + 1)..<numberItems.count {
                let a = numberItems[i], b = numberItems[j]
                let dx = abs(a.center.x - b.center.x)
                let dy = abs(a.center.y - b.center.y)
                guard dy > 0.05, dx < 0.2 else { continue }
                
                let heightRatio = min(a.height, b.height) / max(a.height, b.height)
                guard heightRatio > 0.5 else { continue }
                
                let avgHeight = (a.height + b.height) / 2
                let score = dx - avgHeight
                if score < bestScore {
                    bestScore = score
                    bestPair = (i, j)
                }
            }
        }
        
        guard let pair = bestPair else { return nil }
        let a = numberItems[pair.i], b = numberItems[pair.j]
        return a.center.y > b.center.y ? (a.value, b.value) : (b.value, a.value)
    }
    
    // 從照片裡找「油種代號(92/95/98)」旁邊最近的單價數字，回傳 [代號: 單價]，
    // 用來跟直接讀到的公升數互相驗算，或在沒讀到公升數時，用「金額 ÷ 單價」反推。
    // 台灣油價每公升大約落在 15~60 之間，用這個範圍過濾掉總價、序號等不相關的數字，
    // 同時也順便排除了代號本身（92/95/98 都大於 60，不會被誤判成單價）。
    static func extractGradePrices(from items: [TextItem]) -> [String: Double] {
        let gradeLabels = ["92", "95", "98"]
        
        let priceCandidates: [(value: Double, center: CGPoint, height: CGFloat)] = items.compactMap { item in
            guard let v = extractNumber(from: item.text) else { return nil }
            guard v >= 15 && v <= 60 else { return nil }
            return (v, item.center, item.height)
        }
        
        var result: [String: Double] = [:]
        for label in gradeLabels {
            guard let labelItem = items.first(where: { $0.text.contains(label) }) else { continue }
            var usedIndices = Set<Int>()
            if let price = nearestNumber(to: labelItem.center, in: priceCandidates, excluding: &usedIndices) {
                result[label] = price
            }
        }
        return result
    }
    
    // MARK: 加油機面板 OCR：辨識「公升數」與「金額」，不涉及里程
    // 同步跑一次文字辨識，回傳偵測到的文字方塊（在背景執行緒呼叫，不要在主執行緒用）
    // level 可以帶 .accurate 或 .fast——兩種底層模型對小數點這類小符號的判斷標準不同，
    // 都試一次，任一種抓到都算數
    private static func recognizeTextItemsSync(
        from cgImage: CGImage,
        level: VNRequestTextRecognitionLevel = .accurate
    ) -> [TextItem] {
        var result: [TextItem] = []
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation]
            else { return }
            result = extractItems(observations)
        }
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        // 限定只猜「繁體中文」跟「英文/數字」，不要讓 Vision 把雜訊亂猜成其他語言的字母
        // （不設定的話，遇到反光、紋理這類雜訊，常常會亂猜出一堆看起來像別種語言的符號）
        request.recognitionLanguages = ["zh-Hant", "en-US"]
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return result
    }
    
    static func recognizePumpText(
        from image: UIImage,
        preferredFuelType: String,
        completion: @escaping (_ liters: Double?, _ amount: Double?, _ litersNote: String?, _ debugText: String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 原圖（.accurate）、放大+拉對比後的圖（.accurate 跟 .fast 各一次）都各辨識一次，
            // 抓到的文字通通合併起來再比對。小數點很小、容易讓 Vision 整段直接放棄辨識，
            // 多幾種版本、多幾種模型設定一起試，比單靠一種組合更保險。
            var items: [TextItem] = []
            if let originalCG = image.cgImage {
                items.append(contentsOf: recognizeTextItemsSync(from: originalCG, level: .accurate))
            }
            if let processedCG = preprocessForOCR(image).cgImage {
                items.append(contentsOf: recognizeTextItemsSync(from: processedCG, level: .accurate))
                items.append(contentsOf: recognizeTextItemsSync(from: processedCG, level: .fast))
            }
            
            guard !items.isEmpty else {
                completion(nil, nil, nil, "")
                return
            }
            
            // 只留下「看起來像數字」或「包含我們關心的中文字」的文字方塊，其餘當雜訊丟掉。
            // 加油機照片背景常有磚牆紋理、反光、貼紙、警示標語，Vision 偶爾會誤判成文字，
            // 猜出一堆不知道哪種語言的亂碼符號——這些對辨識金額/公升數毫無用處，先濾掉，
            // 除錯文字也會乾淨很多。
            let relevantKeywords = ["公升", "升", "元", "總價", "數量", "單價"]
            items = items.filter { item in
                let hasDigit = item.text.rangeOfCharacter(from: .decimalDigits) != nil
                let hasKeyword = relevantKeywords.contains { item.text.contains($0) }
                return hasDigit || hasKeyword
            }
            
            guard !items.isEmpty else {
                completion(nil, nil, nil, "")
                return
            }
            
            let numberItems: [(value: Double, center: CGPoint, height: CGFloat)] = items.compactMap { item in
                guard let v = extractNumber(from: item.text) else { return nil }
                return (v, item.center, item.height)
            }
            
            var usedIndices = Set<Int>()
            var foundLiters: Double? = nil
            var foundAmount: Double? = nil
            
            // 1. 先試著用「公升」「元」標籤文字比對——這是最準的規則，永遠優先試
            if let litersLabel = items.first(where: {
                ($0.text.contains("公升") || $0.text.contains("升")) && extractNumber(from: $0.text) == nil
            }) {
                foundLiters = nearestNumber(to: litersLabel.center, in: numberItems, excluding: &usedIndices)
            }
            if let amountLabel = items.first(where: {
                $0.text.contains("元") && !$0.text.contains("單價") && extractNumber(from: $0.text) == nil
            }) {
                foundAmount = nearestNumber(to: amountLabel.center, in: numberItems, excluding: &usedIndices)
            }
            
            // 2. 標籤配不到時，改用「上下疊放的大數字」抓（不靠中文字辨識）
            if foundLiters == nil || foundAmount == nil {
                if let pair = findStackedNumberPair(in: numberItems) {
                    if foundAmount == nil { foundAmount = pair.top }
                    if foundLiters == nil { foundLiters = pair.bottom }
                }
            }
            
            // 3. 還是配不到才用最後保底：有小數點→公升；無小數點的合理金額→總價
            if foundLiters == nil || foundAmount == nil {
                let tokens = items.map { $0.text }
                    .joined(separator: " ")
                    .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                    .map { $0.replacingOccurrences(of: ",", with: "") }
                
                if foundLiters == nil {
                    foundLiters = tokens.compactMap { $0.contains(".") ? Double($0) : nil }
                        .first { $0 > 0 && $0 < 100 }
                }
                if foundAmount == nil {
                    foundAmount = tokens.compactMap { !$0.contains(".") ? Double($0) : nil }
                        .first { $0 > 0 && $0 < 10000 }
                }
            }
            
            let debugText = items.map { $0.text }.joined(separator: " / ")
            
            // 用「畫面上這個油種的單價」反推公升數（金額 ÷ 單價），
            // 跟前面 OCR 直接讀到的公升數互相驗算；
            // 有讀到公升數 → 只驗算、不覆蓋；沒讀到 → 用反推的值頂上；兩邊都沒有 → 維持空白。
            var litersNote: String? = nil
            let targetGrade = preferredFuelType.filter { $0.isNumber } // "92無鉛" -> "92"
            if !targetGrade.isEmpty {
                let gradePrices = extractGradePrices(from: items)
                if let unitPrice = gradePrices[targetGrade], unitPrice > 0, let amount = foundAmount {
                    let derivedLiters = amount / unitPrice
                    if let ocrLiters = foundLiters {
                        let diffPercent = abs(ocrLiters - derivedLiters) / derivedLiters * 100
                        if diffPercent <= 8 {
                            litersNote = "✅ 與 \(targetGrade) 單價 \(String(format: "%.1f", unitPrice)) 元反推結果一致（約 \(String(format: "%.2f", derivedLiters))L）"
                        } else {
                            litersNote = "⚠️ 讀到的公升數跟單價反推結果差蠻多（反推約 \(String(format: "%.2f", derivedLiters))L），請確認"
                        }
                    } else {
                        foundLiters = derivedLiters
                        litersNote = "沒直接讀到公升數，由 \(targetGrade) 單價 \(String(format: "%.1f", unitPrice)) 元反推得出"
                    }
                }
            }
            
            completion(foundLiters, foundAmount, litersNote, debugText)
        }
    }
    
    // MARK: 儀表板/里程表 OCR：只辨識「當前里程」
    static func recognizeOdometerText(from image: UIImage, completion: @escaping (_ odometer: Double?) -> Void) {
        let processedImage = preprocessForOCR(image)
        guard let cgImage = processedImage.cgImage else {
            completion(nil)
            return
        }
        
        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                print("OCR 辨識失敗：\(error.localizedDescription)")
                completion(nil)
                return
            }
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion(nil)
                return
            }
            
            let recognizedText = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            
            // 里程通常是不帶小數點的整數，排除帶小數點的數字（多半是油量/單價等）
            var candidates = recognizedText
                .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "kmKM")))
                .filter { !$0.isEmpty && !$0.contains(".") }
                .compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
                .filter { $0 >= 10 && $0 < 999999 }
            
            // 排除「看起來像時速刻度」的數字：指針式儀表板外圈印的固定整十數字
            // （0,20,40...140 這種），車輛里程還很少（例如新車剛騎沒多久）時，
            // 數字可能比這些刻度還小，單純取最大值會誤抓到刻度上的「140」。
            let speedDialValues: Set<Double> = [
                0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100,
                110, 120, 130, 140, 150, 160, 180, 200, 220, 240, 260
            ]
            let filtered = candidates.filter { !speedDialValues.contains($0) }
            if !filtered.isEmpty {
                candidates = filtered
            }
            
            // 里程通常是 4 位數以上（很多車錶even低里程也會補零顯示），
            // 時速刻度一定只有 1~3 位數，位數多的優先；位數相同才比大小
            let best = candidates.max { a, b in
                let digitsA = String(Int(a)).count
                let digitsB = String(Int(b)).count
                if digitsA != digitsB { return digitsA < digitsB }
                return a < b
            }
            
            completion(best)
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hant", "en-US"]
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                print("OCR 執行失敗：\(error.localizedDescription)")
                completion(nil)
            }
        }
    }
}

// MARK: - 1. 資料模型 (Models)

/// 車款類別（用於切換建議保養里程基準）
enum ScooterType: String, CaseIterable, Identifiable, Codable {
    case standard = "一般白牌速可達"
    case heavy = "黃紅牌重機 / 檔車"
    
    var id: String { self.rawValue }
}

/// 車輛：可以新增多台，各自有名稱與車型，紀錄會各自歸屬到某台車
struct Vehicle: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var type: ScooterType
}

/// 加油紀錄模型
///
/// ⚠️ 這個 struct 自己寫 Codable（沒有用編譯器自動生成的版本），是刻意的：
/// Swift 自動生成的 Decodable，就算欄位有預設值，只要 JSON 裡缺少那個 key 還是會直接解碼失敗，
/// 導致「舊資料存檔」在下次改版新增欄位後整包讀不回來（等於資料全部消失）。
/// 這裡全部改用 decodeIfPresent + 預設值，未來不管再加什麼新欄位，
/// 舊存檔都保證讀得回來，不會因為升級就把資料清空。
struct FuelRecord: Identifiable, Codable {
    var id = UUID()
    var vehicleId: UUID
    var date: Date = Date()
    var odometer: Double            // 當前總里程 (km)
    var liters: Double              // 加油公升數 (L)
    var amount: Double              // 本次加油金額 ($)
    var fuelType: String = "92無鉛"   // 油品種類
    var isSkippedPrevious: Bool = false // 是否跳過上一期油耗計算
    var note: String = ""
    
    init(
        id: UUID = UUID(),
        vehicleId: UUID,
        date: Date = Date(),
        odometer: Double,
        liters: Double,
        amount: Double,
        fuelType: String = "92無鉛",
        isSkippedPrevious: Bool = false,
        note: String = ""
    ) {
        self.id = id
        self.vehicleId = vehicleId
        self.date = date
        self.odometer = odometer
        self.liters = liters
        self.amount = amount
        self.fuelType = fuelType
        self.isSkippedPrevious = isSkippedPrevious
        self.note = note
    }
    
    enum CodingKeys: String, CodingKey {
        case id, vehicleId, date, odometer, liters, amount, fuelType, isSkippedPrevious, note
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        vehicleId = try c.decode(UUID.self, forKey: .vehicleId)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        odometer = try c.decodeIfPresent(Double.self, forKey: .odometer) ?? 0
        liters = try c.decodeIfPresent(Double.self, forKey: .liters) ?? 0
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        fuelType = try c.decodeIfPresent(String.self, forKey: .fuelType) ?? "92無鉛"
        isSkippedPrevious = try c.decodeIfPresent(Bool.self, forKey: .isSkippedPrevious) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vehicleId, forKey: .vehicleId)
        try c.encode(date, forKey: .date)
        try c.encode(odometer, forKey: .odometer)
        try c.encode(liters, forKey: .liters)
        try c.encode(amount, forKey: .amount)
        try c.encode(fuelType, forKey: .fuelType)
        try c.encode(isSkippedPrevious, forKey: .isSkippedPrevious)
        try c.encode(note, forKey: .note)
    }
}

/// 保養紀錄模型（同樣自己寫 Codable，理由同上：確保之後不管再加什麼欄位，
/// 舊存檔都能安全讀回，不會整批解碼失敗、資料歸零）
struct MaintenanceRecord: Identifiable, Codable {
    var id = UUID()
    var vehicleId: UUID
    var date: Date = Date()
    var odometer: Double            // 保養時總里程 (km)
    var selectedItems: [String]     // 選取的保養項目清單
    var totalCost: Double           // 本次保養總金額 ($)
    var isFree: Bool = false        // 是否為免費/贈送保養 ($0)
    var note: String = ""           // 品名與店家備註
    var oilPhotoData: Data? = nil   // 壓縮後的機油照片數據 (約50KB內)
    var oilDarknessScore: Int? = nil // AI 分析出的黑度分數 (0~100，單張照片本身的絕對黑度)
    var oilBrand: String = ""       // 機油品牌/型號（選填，用於跨紀錄比較不同機油的表現）
    
    init(
        id: UUID = UUID(),
        vehicleId: UUID,
        date: Date = Date(),
        odometer: Double,
        selectedItems: [String],
        totalCost: Double,
        isFree: Bool = false,
        note: String = "",
        oilPhotoData: Data? = nil,
        oilDarknessScore: Int? = nil,
        oilBrand: String = ""
    ) {
        self.id = id
        self.vehicleId = vehicleId
        self.date = date
        self.odometer = odometer
        self.selectedItems = selectedItems
        self.totalCost = totalCost
        self.isFree = isFree
        self.note = note
        self.oilPhotoData = oilPhotoData
        self.oilDarknessScore = oilDarknessScore
        self.oilBrand = oilBrand
    }
    
    enum CodingKeys: String, CodingKey {
        case id, vehicleId, date, odometer, selectedItems, totalCost, isFree, note
        case oilPhotoData, oilDarknessScore, oilBrand
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        vehicleId = try c.decode(UUID.self, forKey: .vehicleId)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        odometer = try c.decodeIfPresent(Double.self, forKey: .odometer) ?? 0
        selectedItems = try c.decodeIfPresent([String].self, forKey: .selectedItems) ?? []
        totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
        isFree = try c.decodeIfPresent(Bool.self, forKey: .isFree) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        oilPhotoData = try c.decodeIfPresent(Data.self, forKey: .oilPhotoData)
        oilDarknessScore = try c.decodeIfPresent(Int.self, forKey: .oilDarknessScore)
        oilBrand = try c.decodeIfPresent(String.self, forKey: .oilBrand) ?? ""
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vehicleId, forKey: .vehicleId)
        try c.encode(date, forKey: .date)
        try c.encode(odometer, forKey: .odometer)
        try c.encode(selectedItems, forKey: .selectedItems)
        try c.encode(totalCost, forKey: .totalCost)
        try c.encode(isFree, forKey: .isFree)
        try c.encode(note, forKey: .note)
        try c.encodeIfPresent(oilPhotoData, forKey: .oilPhotoData)
        try c.encodeIfPresent(oilDarknessScore, forKey: .oilDarknessScore)
        try c.encode(oilBrand, forKey: .oilBrand)
    }
}

/// 單一月份的成本資料點（用於置頂與各分頁的年度折線圖）
struct MonthlyCostPoint: Identifiable {
    let id = UUID()
    let month: Int              // 1...12
    let fuelCost: Double
    let maintenanceCost: Double
    var totalCost: Double { fuelCost + maintenanceCost }
    var monthLabel: String { "\(month)月" }
}

// MARK: - 帳單對帳（匯入信用卡/銀行帳單 CSV，跟 App 內加油紀錄比對）

/// 從帳單 CSV 讀出的一筆候選交易（純比對用，不會直接存進紀錄）
struct BillCandidate: Identifiable {
    let id = UUID()
    let date: Date
    let merchant: String
    let amount: Double
}

/// 一筆帳單候選交易的比對結果
enum BillMatchStatus {
    case matched(FuelRecord)                  // 日期、金額完全吻合
    case pointDifference(FuelRecord, Double)  // 日期吻合、小額差異，疑似會員點數折抵
    case amountMismatch(FuelRecord)           // 同一天有紀錄，但差額不是合理的小額差異
    case missing                              // 完全找不到對應紀錄
}

struct BillReconciliationRow: Identifiable {
    let id = UUID()
    let candidate: BillCandidate
    let status: BillMatchStatus
}

/// 保養項目枚舉（包含預設建議保養週期）
enum MaintenanceItemCategory: String, CaseIterable, Identifiable, Codable {
    case engineOil = "機油"
    case gearOil = "齒輪油"
    case sparkPlug = "火星塞"
    case airFilter = "空濾 (空氣濾清器)"
    case transmission = "傳動小組"
    case belt = "傳動皮帶"
    case brake = "煞車皮 / 煞車油"
    case tires = "前後輪胎"
    case coolant = "水冷液 / 節氣門"
    case custom = "其他"
    
    var id: String { self.rawValue }
    
    /// 依車款取得預設建議保養里程 (km)
    func recommendedInterval(for type: ScooterType) -> Double {
        switch (type, self) {
        case (.standard, .engineOil): return 1000      // 速可達建議 1,000 km
        case (.heavy, .engineOil): return 3000         // 重機建議 3,000 km
        case (.standard, .gearOil): return 2000
        case (.heavy, .gearOil): return 5000
        case (_, .sparkPlug): return 10000
        case (_, .airFilter): return 5000
        case (_, .transmission), (_, .belt): return 15000
        case (_, .brake), (_, .tires): return 10000
        case (_, .coolant): return 15000
        case (_, .custom): return 5000
        }
    }
}

// MARK: - 1.5 CSV 匯出用的檔案文件

struct CSVFile: FileDocument {
    static var readableContentTypes: [UTType] = [.commaSeparatedText, .plainText]
    var text: String
    
    init(text: String) {
        self.text = text
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - 2. View Model (業務邏輯、多車輛管理、本機持久化、CSV 匯出入)

class VehicleViewModel: ObservableObject {
    @Published var vehicles: [Vehicle] = [] {
        didSet { saveVehicles() }
    }
    @Published var selectedVehicleID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedVehicleID?.uuidString, forKey: StorageKeys.selectedVehicleID)
        }
    }
    @Published var fuelRecords: [FuelRecord] = [] {
        didSet { saveFuelRecords() }
    }
    @Published var maintenanceRecords: [MaintenanceRecord] = [] {
        didSet { saveMaintenanceRecords() }
    }
    
    @Published var selectedSegment: Int = 0 // 0 = 加油紀錄, 1 = 保養紀錄
    @Published var selectedYear: Int = Calendar.current.component(.year, from: Date()) // 年度折線圖目前選定的年份
    
    private enum StorageKeys {
        static let vehicles = "vehicles.json"
        static let fuelRecords = "fuelRecords.json"
        static let maintenanceRecords = "maintenanceRecords.json"
        static let selectedVehicleID = "selectedVehicleID"
    }
    
    init() {
        loadAll()
        if vehicles.isEmpty {
            let defaultVehicle = Vehicle(name: "我的車輛", type: .standard)
            vehicles = [defaultVehicle]
            selectedVehicleID = defaultVehicle.id
        } else if selectedVehicleID == nil || !vehicles.contains(where: { $0.id == selectedVehicleID }) {
            selectedVehicleID = vehicles.first?.id
        }
    }
    
    // --- 目前選定車輛 ---
    
    var selectedVehicle: Vehicle? {
        vehicles.first { $0.id == selectedVehicleID }
    }
    
    var scooterType: ScooterType {
        selectedVehicle?.type ?? .standard
    }
    
    /// 目前選定車輛的加油紀錄
    var currentFuelRecords: [FuelRecord] {
        fuelRecords.filter { $0.vehicleId == selectedVehicleID }
    }
    /// 目前選定車輛的保養紀錄
    var currentMaintenanceRecords: [MaintenanceRecord] {
        maintenanceRecords.filter { $0.vehicleId == selectedVehicleID }
    }
    
    // --- 車輛管理 ---
    
    @discardableResult
    func addVehicle(name: String, type: ScooterType) -> Vehicle {
        let v = Vehicle(name: name, type: type)
        vehicles.append(v)
        selectedVehicleID = v.id
        return v
    }
    
    func updateVehicle(_ vehicle: Vehicle) {
        guard let idx = vehicles.firstIndex(where: { $0.id == vehicle.id }) else { return }
        vehicles[idx] = vehicle
    }
    
    func deleteVehicle(_ vehicle: Vehicle) {
        vehicles.removeAll { $0.id == vehicle.id }
        fuelRecords.removeAll { $0.vehicleId == vehicle.id }
        maintenanceRecords.removeAll { $0.vehicleId == vehicle.id }
        if selectedVehicleID == vehicle.id {
            selectedVehicleID = vehicles.first?.id
        }
    }
    
    // --- 統計數據計算屬性（皆依目前選定車輛計算） ---
    
    /// 總行駛里程 (km)
    /// 注意：里程 <= 0 代表「帳單補登、尚未手動填寫里程」的暫存紀錄，
    /// 一律排除在外，避免把 0 當成一個真實的最小里程，把總里程算得離譜地大。
    var totalDrivenKm: Double {
        let fuelOdos = currentFuelRecords.filter { $0.odometer > 0 }.map { $0.odometer }
        let maintOdos = currentMaintenanceRecords.filter { $0.odometer > 0 }.map { $0.odometer }
        let allOdos = (fuelOdos + maintOdos).sorted()
        guard let minOdo = allOdos.first, let maxOdo = allOdos.last, maxOdo > minOdo else {
            return 0.0
        }
        return maxOdo - minOdo
    }
    
    var totalLiters: Double { currentFuelRecords.reduce(0) { $0 + $1.liters } }
    var totalFuelCost: Double { currentFuelRecords.reduce(0) { $0 + $1.amount } }
    
    /// 總保養金額（免費的金額為 0，也會精準拉低平均成本）
    var totalMaintenanceCost: Double { currentMaintenanceRecords.reduce(0) { $0 + $1.totalCost } }
    
    /// 加油總金額 + 保養總金額的加總（置頂總覽用）
    var grandTotalCost: Double { totalFuelCost + totalMaintenanceCost }
    
    /// 目前選定車輛的紀錄中出現過的所有年份（供年度折線圖切換），至少包含今年
    var availableYears: [Int] {
        let calendar = Calendar.current
        var years = Set<Int>()
        for r in currentFuelRecords { years.insert(calendar.component(.year, from: r.date)) }
        for r in currentMaintenanceRecords { years.insert(calendar.component(.year, from: r.date)) }
        years.insert(calendar.component(.year, from: Date()))
        return years.sorted(by: >)
    }
    
    /// 計算指定年度、目前選定車輛的「每月油錢金額」與「每月保養金額」
    func monthlyCostBreakdown(year: Int) -> [MonthlyCostPoint] {
        let calendar = Calendar.current
        var fuelByMonth: [Int: Double] = [:]
        var maintByMonth: [Int: Double] = [:]
        
        for r in currentFuelRecords where calendar.component(.year, from: r.date) == year {
            let m = calendar.component(.month, from: r.date)
            fuelByMonth[m, default: 0] += r.amount
        }
        for r in currentMaintenanceRecords where calendar.component(.year, from: r.date) == year {
            let m = calendar.component(.month, from: r.date)
            maintByMonth[m, default: 0] += r.totalCost
        }
        
        return (1...12).map { m in
            MonthlyCostPoint(month: m, fuelCost: fuelByMonth[m] ?? 0, maintenanceCost: maintByMonth[m] ?? 0)
        }
    }
    
    /// 1. 油耗表現 (km/L)
    var averageKmPerLiter: Double {
        // 這裡要用「加油紀錄本身」相鄰兩筆的里程差（effectiveDrivenKm），
        // 不能用 totalDrivenKm——totalDrivenKm 會把保養紀錄的里程也算進去當基準點，
        // 跟這幾公升油實際加出來、騎了多遠完全無關，會把油耗算出離譜的數字
        // （例如只有一筆加油紀錄，卻因為保養紀錄裡有更早的里程，被拿去除出 200+ km/L）
        guard totalLiters > 0, effectiveDrivenKm > 0 else { return 0.0 }
        return effectiveDrivenKm / totalLiters
    }
    
    /// 2. 每公里油錢 (元/km)
    var fuelCostPerKm: Double {
        guard effectiveDrivenKm > 0 else { return 0.0 }
        return totalFuelCost / effectiveDrivenKm
    }
    
    /// 3. 每公里保養費 (元/km)
    var maintenanceCostPerKm: Double {
        guard totalDrivenKm > 0 else { return 0.0 }
        return totalMaintenanceCost / totalDrivenKm
    }
    
    /// 4. 每公里總車耗 (元/km)
    var totalVehicleCostPerKm: Double {
        return fuelCostPerKm + maintenanceCostPerKm
    }
    
    /// 最新一次紀錄的總里程數（同樣排除里程 <= 0 的「待補登」暫存紀錄）
    var latestOdometer: Double {
        let allOdos = (currentFuelRecords.filter { $0.odometer > 0 }.map { $0.odometer }
            + currentMaintenanceRecords.filter { $0.odometer > 0 }.map { $0.odometer }).sorted()
        return allOdos.last ?? 0.0
    }
    
    // --- 漏填與過期提醒檢測 ---
    
    /// 取得特定項目上次保養時的里程數
    func lastMaintenanceOdometer(for itemName: String) -> Double? {
        return currentMaintenanceRecords
            .filter { $0.selectedItems.contains(itemName) }
            .map { $0.odometer }
            .max()
    }
    
    /// 計算「剔除漏記斷層後」的有效總里程（同樣排除里程 <= 0 的「待補登」暫存紀錄，
    /// 否則 0 會被排序到最前面，把中間一大段里程差全部算進去，油耗會嚴重失真）
    var effectiveDrivenKm: Double {
        let sortedRecords = currentFuelRecords.filter { $0.odometer > 0 }.sorted { $0.odometer < $1.odometer }
        guard sortedRecords.count > 1 else { return 0.0 }
        
        var validKm: Double = 0.0
        for i in 1..<sortedRecords.count {
            let current = sortedRecords[i]
            let previous = sortedRecords[i-1]
            
            if !current.isSkippedPrevious {
                validKm += (current.odometer - previous.odometer)
            }
        }
        return validKm
    }
    
    /// 檢查某項目是否「已超期未紀錄」（可能漏填或未保養）
    func checkMaintenanceWarning(for item: MaintenanceItemCategory) -> (isOverdue: Bool, drivenSince: Double) {
        guard latestOdometer > 0 else { return (false, 0) }
        let lastOdo = lastMaintenanceOdometer(for: item.rawValue) ?? 0.0
        let driven = latestOdometer - lastOdo
        let limit = item.recommendedInterval(for: scooterType)
        return (driven >= limit, driven)
    }
    
    // MARK: - 機油黑度跨紀錄比較（不同品牌/不同罐機油的耐用度比較）
    //
    // 單張照片的「AI 黑度預估值」只反映這一張照片本身多黑，容易受拍照環境（光源、角度）影響，
    // 且沒有考慮「這罐油騎了多久」。真正該比較的是「每跑 1000km 黑幾分」的速率，
    // 這樣不同里程數拍的照片才有公平的比較基準。
    
    /// 依「機油相關」保養紀錄（且有拍照評分），計算歷史上每一次換油週期的「黑化速率」
    /// 黑化速率 = 該次拍照的黑度分數 ÷ (與上一次機油相關紀錄相隔的里程數 / 1000)
    private func oilBlackeningRates() -> [(brand: String, rate: Double)] {
        let oilRecords = currentMaintenanceRecords
            .filter {
                $0.selectedItems.contains(MaintenanceItemCategory.engineOil.rawValue)
                    && $0.oilDarknessScore != nil
            }
            .sorted { $0.odometer < $1.odometer }
        
        guard oilRecords.count >= 2 else { return [] }
        
        var rates: [(brand: String, rate: Double)] = []
        for i in 1..<oilRecords.count {
            let previous = oilRecords[i - 1]
            let current = oilRecords[i]
            let km = current.odometer - previous.odometer
            guard km > 0, let score = current.oilDarknessScore else { continue }
            
            let rate = Double(score) / (km / 1000.0)
            let trimmedBrand = current.oilBrand.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            rates.append((brand: trimmedBrand.isEmpty ? "未標示品牌" : trimmedBrand, rate: rate))
        }
        return rates
    }
    
    /// 新增一筆機油照片評分時，與過去的紀錄比較「黑化速率」，回傳一句中文建議。
    /// 沒有足夠歷史資料（例如這是第一次拍照、或還沒填上一次機油相關紀錄）時回傳 nil，
    /// 讓畫面只顯示單張照片的黑度分析，不勉強比較。
    func oilChangeComparisonText(newScore: Int, newOdometer: Double, brand: String) -> String? {
        // 找出上一筆「機油相關」的保養紀錄，用來算這次騎了多少公里
        let priorOilRecords = currentMaintenanceRecords
            .filter { $0.selectedItems.contains(MaintenanceItemCategory.engineOil.rawValue) }
            .filter { $0.odometer < newOdometer }
            .sorted { $0.odometer < $1.odometer }
        
        guard let lastOilRecord = priorOilRecords.last else { return nil }
        let km = newOdometer - lastOilRecord.odometer
        guard km > 0 else { return nil }
        
        let newRate = Double(newScore) / (km / 1000.0)
        
        let historicalRates = oilBlackeningRates()
        guard !historicalRates.isEmpty else { return nil }
        
        let trimmedBrand = brand.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let sameBrandRates = trimmedBrand.isEmpty
            ? []
            : historicalRates.filter { $0.brand == trimmedBrand }.map { $0.rate }
        
        // 優先跟「同品牌」的歷史紀錄比；沒有同品牌資料時，改跟所有品牌的平均比
        let compareRates = !sameBrandRates.isEmpty ? sameBrandRates : historicalRates.map { $0.rate }
        let compareAvg = compareRates.reduce(0, +) / Double(compareRates.count)
        guard compareAvg > 0 else { return nil }
        
        let diffPercent = ((newRate - compareAvg) / compareAvg) * 100
        let subjectLabel = !sameBrandRates.isEmpty ? "你過去使用「\(trimmedBrand)」的紀錄" : "你過去使用過的所有機油平均"
        
        if diffPercent <= -15 {
            return "與\(subjectLabel)相比，這次在相近里程下明顯較乾淨（黑化速率低 \(Int(abs(diffPercent)))%），可能可以延後更換。"
        } else if diffPercent >= 15 {
            return "與\(subjectLabel)相比，這次在相近里程下明顯較黑（黑化速率高 \(Int(diffPercent))%），建議提早更換或留意。"
        } else {
            return "與\(subjectLabel)相比，表現差不多。"
        }
    }
    
    // MARK: - 數據新增方法
    func addFuelRecord(_ record: FuelRecord) {
        fuelRecords.append(record)
        fuelRecords.sort { $0.date > $1.date }
    }
    
    /// 更新既有加油紀錄（用於編輯，或帳單補登後回來補填里程）
    func updateFuelRecord(_ record: FuelRecord) {
        guard let idx = fuelRecords.firstIndex(where: { $0.id == record.id }) else { return }
        fuelRecords[idx] = record
        fuelRecords.sort { $0.date > $1.date }
    }
    
    func deleteFuelRecord(_ record: FuelRecord) {
        fuelRecords.removeAll { $0.id == record.id }
    }
    
    func addMaintenanceRecord(_ record: MaintenanceRecord) {
        maintenanceRecords.append(record)
        maintenanceRecords.sort { $0.date > $1.date }
    }
    
    /// 更新既有保養紀錄（用於編輯）
    func updateMaintenanceRecord(_ record: MaintenanceRecord) {
        guard let idx = maintenanceRecords.firstIndex(where: { $0.id == record.id }) else { return }
        maintenanceRecords[idx] = record
        maintenanceRecords.sort { $0.date > $1.date }
    }
    
    func deleteMaintenanceRecord(_ record: MaintenanceRecord) {
        maintenanceRecords.removeAll { $0.id == record.id }
    }
    
    /// 清除「所有車輛」的全部紀錄（車輛設定保留）
    func clearAllRecords() {
        fuelRecords.removeAll()
        maintenanceRecords.removeAll()
    }
    
    // MARK: - 本機持久化 (JSON 存在 App 的 Documents 目錄)
    
    private func documentsURL(_ filename: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }
    
    private func save<T: Encodable>(_ value: T, to filename: String) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: documentsURL(filename), options: .atomic)
        } catch {
            print("儲存失敗 (\(filename))：\(error.localizedDescription)")
        }
    }
    
    private func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = documentsURL(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("讀取失敗 (\(filename))：\(error.localizedDescription)")
            return nil
        }
    }
    
    private func saveVehicles() { save(vehicles, to: StorageKeys.vehicles) }
    private func saveFuelRecords() { save(fuelRecords, to: StorageKeys.fuelRecords) }
    private func saveMaintenanceRecords() { save(maintenanceRecords, to: StorageKeys.maintenanceRecords) }
    
    private func loadAll() {
        vehicles = load([Vehicle].self, from: StorageKeys.vehicles) ?? []
        fuelRecords = load([FuelRecord].self, from: StorageKeys.fuelRecords) ?? []
        maintenanceRecords = load([MaintenanceRecord].self, from: StorageKeys.maintenanceRecords) ?? []
        if let idString = UserDefaults.standard.string(forKey: StorageKeys.selectedVehicleID) {
            selectedVehicleID = UUID(uuidString: idString)
        }
    }
    
    // MARK: - CSV 匯出 / 匯入
    //
    // CSV 內容包含：
    // 1. 車輛清單
    // 2. 每筆紀錄的原始 ID
    // 3. 保養照片 Base64
    // 4. 車輛名稱與車型
    //
    // 同一份 CSV 重複匯入時：
    // - 已存在的車輛不會重複建立
    // - 已存在的加油紀錄不會重複匯入
    // - 已存在的保養紀錄不會重複匯入

    private static let csvHeader =
        "RecordType,RecordID,VehicleID,VehicleName,VehicleType,Date,Odometer,Liters,Amount,FuelType,IsSkippedPrevious,Note,SelectedItems,TotalCost,IsFree,OilDarknessScore,OilPhotoBase64,OilBrand"

    // CSV 欄位轉義：
    // 如果文字內含逗號、雙引號或換行，就用雙引號包起來
    private func csvEscape(_ field: String) -> String {
        if field.contains(",") ||
            field.contains("\"") ||
            field.contains("\n") ||
            field.contains("\r") {

            let escaped = field.replacingOccurrences(
                of: "\"",
                with: "\"\""
            )

            return "\"\(escaped)\""
        }

        return field
    }

    // 根據車輛 ID 找車輛名稱
    private func vehicleName(for id: UUID) -> String {
        vehicles.first { $0.id == id }?.name ?? ""
    }

    // MARK: 匯出 CSV

    /// 匯出全部車輛、全部加油紀錄與全部保養紀錄
    func exportCSVString() -> String {
        var lines: [String] = [Self.csvHeader]

        let iso = ISO8601DateFormatter()

        // --------------------------------------------------
        // 1. 匯出車輛清單
        // --------------------------------------------------

        for vehicle in vehicles {
            let fields = [
                "Vehicle",                         // RecordType
                "",                                // RecordID
                vehicle.id.uuidString,             // VehicleID
                vehicle.name,                      // VehicleName
                vehicle.type.rawValue,             // VehicleType
                "",                                // Date
                "",                                // Odometer
                "",                                // Liters
                "",                                // Amount
                "",                                // FuelType
                "",                                // IsSkippedPrevious
                "",                                // Note
                "",                                // SelectedItems
                "",                                // TotalCost
                "",                                // IsFree
                "",                                // OilDarknessScore
                "",                                // OilPhotoBase64
                ""                                 // OilBrand
            ]

            lines.append(
                fields.map { csvEscape($0) }.joined(separator: ",")
            )
        }

        // --------------------------------------------------
        // 2. 匯出加油紀錄
        // --------------------------------------------------

        for record in fuelRecords.sorted(by: { $0.date < $1.date }) {
            let fields = [
                "Fuel",                            // RecordType
                record.id.uuidString,              // RecordID
                record.vehicleId.uuidString,       // VehicleID
                vehicleName(for: record.vehicleId),// VehicleName
                "",                                // VehicleType
                iso.string(from: record.date),     // Date
                String(record.odometer),           // Odometer
                String(record.liters),             // Liters
                String(record.amount),             // Amount
                record.fuelType,                   // FuelType
                record.isSkippedPrevious ? "1" : "0",
                record.note,                       // Note
                "",                                // SelectedItems
                "",                                // TotalCost
                "",                                // IsFree
                "",                                // OilDarknessScore
                "",                                // OilPhotoBase64
                ""                                 // OilBrand
            ]

            lines.append(
                fields.map { csvEscape($0) }.joined(separator: ",")
            )
        }

        // --------------------------------------------------
        // 3. 匯出保養紀錄
        // --------------------------------------------------

        for record in maintenanceRecords.sorted(by: { $0.date < $1.date }) {

            // 將機油照片 Data 轉成 Base64 字串
            let photoBase64: String

            if let photoData = record.oilPhotoData {
                photoBase64 = photoData.base64EncodedString()
            } else {
                photoBase64 = ""
            }

            let fields = [
                "Maintenance",                     // RecordType
                record.id.uuidString,              // RecordID
                record.vehicleId.uuidString,       // VehicleID
                vehicleName(for: record.vehicleId),// VehicleName
                "",                                // VehicleType
                iso.string(from: record.date),     // Date
                String(record.odometer),           // Odometer
                "",                                // Liters
                "",                                // Amount
                "",                                // FuelType
                "",                                // IsSkippedPrevious
                record.note,                       // Note
                record.selectedItems.joined(
                    separator: "|"
                ),                                 // SelectedItems
                String(record.totalCost),          // TotalCost
                record.isFree ? "1" : "0",         // IsFree
                record.oilDarknessScore.map {
                    String($0)
                } ?? "",                           // OilDarknessScore
                photoBase64,                        // OilPhotoBase64
                record.oilBrand                    // OilBrand
            ]

            lines.append(
                fields.map { csvEscape($0) }.joined(separator: ",")
            )
        }

        return lines.joined(separator: "\n")
    }

    // MARK: CSV 單行解析器

    /// 支援雙引號、逗號及雙引號跳脫的 CSV 單行解析器
    private func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var insideQuotes = false

        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\"" {
                if insideQuotes &&
                    index + 1 < characters.count &&
                    characters[index + 1] == "\"" {

                    // CSV 中的 "" 代表一個雙引號
                    current.append("\"")
                    index += 2
                } else {
                    // 進入或離開雙引號區域
                    insideQuotes.toggle()
                    index += 1
                }
            } else if character == "," && !insideQuotes {
                result.append(current)
                current = ""
                index += 1
            } else {
                current.append(character)
                index += 1
            }
        }

        result.append(current)

        return result
    }

    // MARK: CSV 匯入
    //
    // 匯入邏輯改為「依欄位名稱」讀取，而不是寫死欄位順序/數量。
    // 這樣不管是舊版本匯出的 CSV（欄位比較少、順序不同）、
    // 還是未來版本新增欄位之後匯出的 CSV，只要欄位名稱不變，
    // 都保證讀得回來——缺少的欄位就用空字串/預設值處理，不會整批匯入失敗。

    /// 依標題列建立「欄位名稱 -> 欄位索引」對照表
    private func csvColumnMap(from headerFields: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (idx, rawName) in headerFields.enumerated() {
            // 有些銀行/信用卡 CSV 第一個欄位會帶 UTF-8 BOM，
            // 或欄位名稱前後會多出空白；先統一處理。
            let name = rawName
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{FEFF}", with: "")
            map[name] = idx
        }
        return map
    }

    /// 依欄位名稱從一列資料中取值；找不到該欄位（例如舊版 CSV 沒有這欄）就回傳空字串
    private func csvField(_ name: String, in row: [String], columnMap: [String: Int]) -> String {
        guard let idx = columnMap[name], idx < row.count else { return "" }
        return row[idx].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// 用穩定的內容（日期、里程、金額等）算出一個「固定不變」的 UUID。
    /// 用於還原「沒有 RecordID 欄位」的舊版 CSV：同一份檔案重複匯入多次，
    /// 也會算出同一個 ID，不會每次都被當成新紀錄而重複新增。
    private func deterministicID(from parts: [String]) -> UUID {
        let raw = parts.joined(separator: "|")
        let digestBytes = Array(Insecure.MD5.hash(data: Data(raw.utf8)))
        let uuidTuple = uuid_t(
            digestBytes[0], digestBytes[1], digestBytes[2], digestBytes[3],
            digestBytes[4], digestBytes[5], digestBytes[6], digestBytes[7],
            digestBytes[8], digestBytes[9], digestBytes[10], digestBytes[11],
            digestBytes[12], digestBytes[13], digestBytes[14], digestBytes[15]
        )
        return UUID(uuid: uuidTuple)
    }

    // MARK: - 帳單對帳：解析帳單 CSV、跟 App 內加油紀錄比對
    //
    // 帳單 CSV 建議欄位（大小寫、中英文皆可，順序不拘）：
    //   Date（或「日期」）：建議用完整日期 yyyy-MM-dd；如果只有「月/日」（像信用卡帳單常見的 07/30），
    //                       會用下面傳入的 fallbackYear 補上年份。
    //   Merchant（或「商家」）：商家名稱，純顯示用，不影響比對。
    //   Amount（或「金額」）：交易金額。
    
    /// 解析「月/日」或「yyyy-MM-dd」等常見帳單日期格式；只有月/日時用 fallbackYear 補上年份
    private func parseBillDate(_ raw: String, fallbackYear: Int) -> Date? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        for format in ["yyyy-MM-dd", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        
        for format in ["MM/dd", "M/d"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: trimmed) {
                var comps = Calendar.current.dateComponents([.month, .day], from: parsed)
                comps.year = fallbackYear
                return Calendar.current.date(from: comps)
            }
        }
        
        return nil
    }
    
    /// 從欄位名稱清單中依序找第一個有值的欄位（同時支援中英文表頭）
    private func csvFieldAnyName(_ names: [String], in row: [String], columnMap: [String: Int]) -> String {
        for name in names {
            let value = csvField(name, in: row, columnMap: columnMap)
            if !value.isEmpty { return value }
        }
        return ""
    }
    
    /// 讀取帳單 CSV，解析出候選交易清單（純讀取，不會寫入任何紀錄）。
    /// fallbackYear：當某一列日期只有「月/日」沒有年份時，用這個年份補上。
    /// 檔案無法讀取，或標題列完全找不到日期/金額欄位時，回傳 nil。
    func parseBillCSV(from url: URL, fallbackYear: Int) -> [BillCandidate]? {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        // 不同銀行/信用卡可能輸出 UTF-8、UTF-8 BOM、UTF-16，
        // 台灣部分舊格式也可能是 Big5；依序嘗試，避免「檔案明明能開，App 卻讀不到」。
        let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .unicode)

        guard let content else {
            return nil
        }
        
        var lines = content
            .components(separatedBy: CharacterSet.newlines)
            .filter { !$0.isEmpty }
        
        guard !lines.isEmpty else { return nil }
        
        let headerLine = lines.removeFirst()
        let columnMap = csvColumnMap(from: parseCSVLine(headerLine))
        
        var candidates: [BillCandidate] = []
        for line in lines {
            let fields = parseCSVLine(line)
            
            let dateString = csvFieldAnyName([
                "Date", "日期", "簽帳日期", "消費日", "交易日"
            ], in: fields, columnMap: columnMap)
            let merchant = csvFieldAnyName([
                "Merchant", "商家", "交易說明", "消費明細", "消費說明", "交易明細"
            ], in: fields, columnMap: columnMap)
            let rawAmountString = csvFieldAnyName([
                "Amount", "金額", "新台幣金額", "金額 (元)", "金額(元)", "消費金額", "交易金額"
            ], in: fields, columnMap: columnMap)

            // 帳單金額可能是「1,234」、「$1,234」、「1,234 元」等格式，
            // 先清掉常見符號再轉成 Double。
            let amountString = rawAmountString
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "NT$", with: "")
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: "元", with: "")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            guard let date = parseBillDate(dateString, fallbackYear: fallbackYear),
                  let amount = Double(amountString)
            else { continue }
            
            candidates.append(BillCandidate(date: date, merchant: merchant, amount: amount))
        }
        
        return candidates
    }
    
    /// 把帳單候選交易同時跟「所有車輛」的加油紀錄比對。
    ///
    /// 比對優先順序：
    /// 1. 同一天 + 金額完全相同。
    /// 2. 若沒有完全相同，再找同一天的小額差異，提示「疑似會員點數差額」。
    /// 3. 同一筆 FuelRecord 只能被使用一次，避免多張帳單重複配到同一筆。
    /// 4. 完全找不到才建議補登。
    func reconcileBillCandidates(_ candidates: [BillCandidate]) -> [BillReconciliationRow] {
        let calendar = Calendar.current
        let pointDifferenceTolerance = 9.0
        let allRecords = fuelRecords
        var usedRecordIDs = Set<UUID>()
        var results = Array<BillReconciliationRow?>(repeating: nil, count: candidates.count)

        // 第一輪：先處理所有「日期 + 金額完全相同」的配對。
        // 先把 exact 配對完成，可以避免前面的帳單先吃掉後面真正完全相符的紀錄。
        for i in candidates.indices {
            let candidate = candidates[i]
            let exact = allRecords.first(where: { record in
                !usedRecordIDs.contains(record.id) &&
                calendar.isDate(record.date, inSameDayAs: candidate.date) &&
                abs(record.amount - candidate.amount) < 0.01
            })

            if let exact {
                usedRecordIDs.insert(exact.id)
                results[i] = BillReconciliationRow(candidate: candidate, status: .matched(exact))
            }
        }

        // 第二輪：處理尚未配對的帳單。
        for i in candidates.indices where results[i] == nil {
            let candidate = candidates[i]
            let sameDayUnused = allRecords.filter { record in
                !usedRecordIDs.contains(record.id) &&
                calendar.isDate(record.date, inSameDayAs: candidate.date)
            }

            // 同一天內找差額最小的紀錄；只有在小額範圍內才提示可能是會員點數差異。
            if let nearest = sameDayUnused
                .map({ (record: $0, difference: abs($0.amount - candidate.amount)) })
                .filter({ $0.difference > 0.01 && $0.difference <= pointDifferenceTolerance })
                .min(by: { $0.difference < $1.difference }) {
                usedRecordIDs.insert(nearest.record.id)
                results[i] = BillReconciliationRow(
                    candidate: candidate,
                    status: .pointDifference(nearest.record, nearest.difference)
                )
            } else if let mismatched = sameDayUnused.first {
                usedRecordIDs.insert(mismatched.id)
                results[i] = BillReconciliationRow(
                    candidate: candidate,
                    status: .amountMismatch(mismatched)
                )
            } else {
                results[i] = BillReconciliationRow(candidate: candidate, status: .missing)
            }
        }

        return results.compactMap { $0 }
    }

    /// 匯入 CSV：
    /// - 還原車輛清單
    /// - 還原加油紀錄
    /// - 還原保養紀錄與照片
    /// - 依照原始 ID（或內容算出的固定 ID）防止重複匯入
    ///
    /// 回傳成功匯入的紀錄數。
    /// 如果檔案無法讀取，回傳 nil。
    @discardableResult
    func importCSV(from url: URL) -> Int? {

        let didStartAccessing =
            url.startAccessingSecurityScopedResource()

        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        var lines = content
            .components(separatedBy: CharacterSet.newlines)
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return nil
        }

        // 第一列一定是標題列，用它來建立「欄位名稱 -> 索引」對照表，
        // 而不是假設欄位一定照著目前版本的順序與數量排列。
        let headerLine = lines.removeFirst()
        let columnMap = csvColumnMap(from: parseCSVLine(headerLine))

        let iso = ISO8601DateFormatter()

        // --------------------------------------------------
        // 先建立目前已存在的 ID 集合
        // --------------------------------------------------

        var existingVehicleIDs = Set(
            vehicles.map { $0.id }
        )

        var existingFuelRecordIDs = Set(
            fuelRecords.map { $0.id }
        )

        var existingMaintenanceRecordIDs = Set(
            maintenanceRecords.map { $0.id }
        )

        var importedCount = 0

        // --------------------------------------------------
        // 第一階段：先匯入車輛清單（僅在 CSV 有獨立 "Vehicle" 列時才會用到；
        // 沒有這種列也沒關係，第二階段會依每筆紀錄的 VehicleID 自動補建）
        // --------------------------------------------------

        for line in lines {
            let fields = parseCSVLine(line)
            let recordType = csvField("RecordType", in: fields, columnMap: columnMap)

            guard recordType == "Vehicle" else {
                continue
            }

            guard let vehicleID = UUID(uuidString: csvField("VehicleID", in: fields, columnMap: columnMap)) else {
                continue
            }

            // 車輛已存在就跳過
            if existingVehicleIDs.contains(vehicleID) {
                continue
            }

            let vehicleName = csvField("VehicleName", in: fields, columnMap: columnMap).isEmpty
                ? "匯入車輛"
                : csvField("VehicleName", in: fields, columnMap: columnMap)

            let vehicleType = ScooterType(
                rawValue: csvField("VehicleType", in: fields, columnMap: columnMap)
            ) ?? .standard

            var newVehicle = Vehicle(
                name: vehicleName,
                type: vehicleType
            )

            // 保留原始車輛 ID
            newVehicle.id = vehicleID

            vehicles.append(newVehicle)
            existingVehicleIDs.insert(vehicleID)
        }

        // --------------------------------------------------
        // 第二階段：匯入加油與保養紀錄
        // --------------------------------------------------

        for line in lines {
            let fields = parseCSVLine(line)
            let recordType = csvField("RecordType", in: fields, columnMap: columnMap)

            // 跳過車輛資料
            guard recordType == "Fuel" ||
                  recordType == "Maintenance"
            else {
                continue
            }

            let dateString = csvField("Date", in: fields, columnMap: columnMap)
            let odometerString = csvField("Odometer", in: fields, columnMap: columnMap)
            let vehicleIDString = csvField("VehicleID", in: fields, columnMap: columnMap)

            // 日期、里程、車輛 ID 是還原紀錄的必要資訊，缺了就無法還原這一列
            guard let vehicleID = UUID(uuidString: vehicleIDString),
                  let date = iso.date(from: dateString)
            else {
                continue
            }

            // RecordID 欄位是後來才加入的；沒有這欄（舊版 CSV）就用內容算出一個固定 ID，
            // 這樣同一份舊版 CSV 重複匯入也不會產生重複紀錄
            let rawRecordID = csvField("RecordID", in: fields, columnMap: columnMap)
            let recordID = UUID(uuidString: rawRecordID) ?? deterministicID(from: [
                recordType, vehicleIDString, dateString, odometerString,
                csvField("Amount", in: fields, columnMap: columnMap),
                csvField("TotalCost", in: fields, columnMap: columnMap),
                csvField("Note", in: fields, columnMap: columnMap)
            ])

            // 如果 CSV 中的車輛不存在，就建立車輛
            if !existingVehicleIDs.contains(vehicleID) {

                let importedVehicleName = csvField("VehicleName", in: fields, columnMap: columnMap).isEmpty
                    ? "匯入車輛"
                    : csvField("VehicleName", in: fields, columnMap: columnMap)

                let newVehicleType = ScooterType(
                    rawValue: csvField("VehicleType", in: fields, columnMap: columnMap)
                ) ?? .standard

                var newVehicle = Vehicle(
                    name: importedVehicleName,
                    type: newVehicleType
                )

                newVehicle.id = vehicleID

                vehicles.append(newVehicle)
                existingVehicleIDs.insert(vehicleID)
            }

            // --------------------------------------------------
            // 匯入加油紀錄
            // --------------------------------------------------

            if recordType == "Fuel" {

                // 已存在相同 ID 就跳過
                if existingFuelRecordIDs.contains(recordID) {
                    continue
                }

                let fuelTypeValue = csvField("FuelType", in: fields, columnMap: columnMap)

                let record = FuelRecord(
                    id: recordID,
                    vehicleId: vehicleID,
                    date: date,
                    odometer: Double(odometerString) ?? 0,
                    liters: Double(csvField("Liters", in: fields, columnMap: columnMap)) ?? 0,
                    amount: Double(csvField("Amount", in: fields, columnMap: columnMap)) ?? 0,
                    fuelType: fuelTypeValue.isEmpty ? "92無鉛" : fuelTypeValue,
                    isSkippedPrevious: csvField("IsSkippedPrevious", in: fields, columnMap: columnMap) == "1",
                    note: csvField("Note", in: fields, columnMap: columnMap)
                )

                fuelRecords.append(record)
                existingFuelRecordIDs.insert(recordID)
                importedCount += 1
            }

            // --------------------------------------------------
            // 匯入保養紀錄
            // --------------------------------------------------

            else if recordType == "Maintenance" {

                // 已存在相同 ID 就跳過
                if existingMaintenanceRecordIDs.contains(recordID) {
                    continue
                }

                let selectedItemsString = csvField("SelectedItems", in: fields, columnMap: columnMap)
                let selectedItems: [String] = selectedItemsString.isEmpty
                    ? []
                    : selectedItemsString.components(separatedBy: "|")

                // Base64 還原成照片 Data（舊版 CSV 沒有這欄就是 nil，不影響其他資料還原）
                let photoBase64String = csvField("OilPhotoBase64", in: fields, columnMap: columnMap)
                let photoData: Data? = photoBase64String.isEmpty
                    ? nil
                    : Data(base64Encoded: photoBase64String)

                let darknessScoreString = csvField("OilDarknessScore", in: fields, columnMap: columnMap)
                let darknessScore: Int? = darknessScoreString.isEmpty
                    ? nil
                    : Int(darknessScoreString)

                // OilBrand 為後續版本新增的欄位，舊版 CSV 沒有這一欄也能正常匯入（預設空字串）
                let oilBrand = csvField("OilBrand", in: fields, columnMap: columnMap)

                let record = MaintenanceRecord(
                    id: recordID,
                    vehicleId: vehicleID,
                    date: date,
                    odometer: Double(odometerString) ?? 0,
                    selectedItems: selectedItems,
                    totalCost: Double(csvField("TotalCost", in: fields, columnMap: columnMap)) ?? 0,
                    isFree: csvField("IsFree", in: fields, columnMap: columnMap) == "1",
                    note: csvField("Note", in: fields, columnMap: columnMap),
                    oilPhotoData: photoData,
                    oilDarknessScore: darknessScore,
                    oilBrand: oilBrand
                )

                maintenanceRecords.append(record)
                existingMaintenanceRecordIDs.insert(recordID)
                importedCount += 1
            }
        }

        // --------------------------------------------------
        // 整理排序並確保選定車輛有效
        // --------------------------------------------------

        fuelRecords.sort {
            $0.date > $1.date
        }

        maintenanceRecords.sort {
            $0.date > $1.date
        }

        if selectedVehicleID == nil ||
            !vehicles.contains(where: {
                $0.id == selectedVehicleID
            }) {

            selectedVehicleID = vehicles.first?.id
        }

        return importedCount
    }
}

// MARK: - 3. 主視圖 (VehicleMaintenanceView)

// MARK: - 2.5 年度月結折線圖（共用元件）
struct YearlyCostLineChart: View {
    enum SeriesKind {
        case totalOnly          // 只顯示「加總」金額（置頂總覽用）
        case fuelOnly            // 只顯示油錢（加油紀錄頁用）
        case maintenanceOnly     // 只顯示保養費（保養紀錄頁用）
    }
    
    let title: String
    let seriesKind: SeriesKind
    let data: [MonthlyCostPoint]
    @Binding var selectedYear: Int
    let availableYears: [Int]
    
    private var lineColor: Color {
        switch seriesKind {
        case .totalOnly: return .purple
        case .fuelOnly: return .orange
        case .maintenanceOnly: return .blue
        }
    }
    
    private func value(for point: MonthlyCostPoint) -> Double {
        switch seriesKind {
        case .totalOnly: return point.totalCost
        case .fuelOnly: return point.fuelCost
        case .maintenanceOnly: return point.maintenanceCost
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .bold()
                    .foregroundColor(.secondary)
                Spacer()
                yearSwitcher
            }
            
            Chart(data) { point in
                LineMark(
                    x: .value("月份", point.month),
                    y: .value("金額", value(for: point))
                )
                .foregroundStyle(lineColor)
                .interpolationMethod(.monotone)
                .symbol(.circle)
                
                AreaMark(
                    x: .value("月份", point.month),
                    y: .value("金額", value(for: point))
                )
                .foregroundStyle(lineColor.opacity(0.12))
                .interpolationMethod(.monotone)
            }
            .chartXScale(domain: 0.5...12.5)
            .chartXAxis {
                AxisMarks(values: Array(1...12)) { axisValue in
                    if let m = axisValue.as(Int.self) {
                        AxisValueLabel { Text("\(m)").font(.system(size: 8)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 130)
            .padding(.trailing, 4)
        }
    }
    
    private var yearSwitcher: some View {
        HStack(spacing: 10) {
            Button {
                selectedYear -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2)
            }
            Text("\(String(selectedYear))年")
                .font(.caption)
                .bold()
            Button {
                selectedYear += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
        }
        .foregroundColor(.secondary)
    }
}

struct VehicleMaintenanceView: View {
    @StateObject private var viewModel = VehicleViewModel()
    
    @State private var showAddFuelSheet = false
    @State private var showAddMaintenanceSheet = false
    @State private var showVehicleManagement = false
    
    // CSV 匯出 / 匯入
    @State private var showCSVExporter = false
    @State private var csvExportDocument: CSVFile = CSVFile(text: "")
    @State private var showClearAfterExportConfirm = false
    @State private var showCSVImporter = false
    @State private var importResultMessage: String? = nil
    @State private var showImportResultAlert = false
    
    // 清除所有紀錄
    @State private var showClearAllConfirm = false
    
    // 編輯既有加油紀錄（例如回來補上里程）
    @State private var editingFuelRecord: FuelRecord? = nil
    
    // 帳單對帳
    @State private var showBillReconciliation = false
    
    // 刪除確認（改用明確的垃圾桶按鈕，不再依賴左滑——這個畫面本身就在可左右滑動切換的分頁裡，
    // 左滑手勢常常會被外層分頁搶走，滑不出刪除鍵）
    @State private var fuelRecordPendingDelete: FuelRecord? = nil
    @State private var maintenanceRecordPendingDelete: MaintenanceRecord? = nil
    
    var body: some View {
        // 注意：這個畫面是被放在外層 ContentView 的 TabView(.page 樣式) 裡面swipe切換的分頁之一。
        // 這裡保留 NavigationView，是因為它會自動把內容往下推到狀態列安全區域之下；
        // 如果拿掉整個 NavigationView，畫面會直接貼齊螢幕最上緣，上面的按鈕會被狀態列蓋住一部分（只露出下緣的弧形）。
        // 但系統原生導覽列標題在「page 樣式 TabView」裡常會跑版、字體跟下面內容擠在一起，
        // 所以用 .navigationBarHidden(true) 把系統導覽列整個藏起來，改用自己手刻的 topBar 當標題列。
        NavigationView {
            VStack(spacing: 0) {
                topBar
                
                // 這裡改成「整個畫面就是一個 List」，而不是把卡片/圖表放在固定高度的 VStack 裡、
                // 下面再塞一個獨立的 List——後者會發生「上面卡片+圖表太高，List 分不到剩餘空間」
                // 的問題，導致紀錄列表整個被壓成看不到、也滑不動。
                // 全部放進同一個 List，卡片、圖表跟紀錄會一起自然捲動，滑動刪除也照樣可以用。
                List {
                    overviewSummaryCard
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    
                    maintenanceWarningBanner
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    
                    Picker("紀錄類別", selection: $viewModel.selectedSegment) {
                        Text("⛽ 加油紀錄").tag(0)
                        Text("🔧 保養紀錄").tag(1)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    
                    if viewModel.selectedSegment == 0 {
                        fuelChartCard
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        
                        if viewModel.currentFuelRecords.isEmpty {
                            emptyStateView(message: "尚無加油紀錄\n點擊右上角「+」新增第一筆紀錄")
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(viewModel.currentFuelRecords) { record in
                                fuelRecordRow(record)
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            viewModel.deleteFuelRecord(record)
                                        } label: {
                                            Label("刪除", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    } else {
                        maintenanceChartCard
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        
                        if viewModel.currentMaintenanceRecords.isEmpty {
                            emptyStateView(message: "尚無保養紀錄\n點擊右上角「+」紀錄機油與消耗品更換")
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(viewModel.currentMaintenanceRecords) { record in
                                maintenanceRecordRow(record)
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            viewModel.deleteMaintenanceRecord(record)
                                        } label: {
                                            Label("刪除", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
            }
            .navigationBarHidden(true)
            .confirmationDialog(
                "確定要刪除這筆加油紀錄嗎？此動作無法復原。",
                isPresented: Binding(
                    get: { fuelRecordPendingDelete != nil },
                    set: { if !$0 { fuelRecordPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("刪除", role: .destructive) {
                    if let record = fuelRecordPendingDelete {
                        viewModel.deleteFuelRecord(record)
                    }
                    fuelRecordPendingDelete = nil
                }
                Button("取消", role: .cancel) {
                    fuelRecordPendingDelete = nil
                }
            }
            .confirmationDialog(
                "確定要刪除這筆保養紀錄嗎？此動作無法復原。",
                isPresented: Binding(
                    get: { maintenanceRecordPendingDelete != nil },
                    set: { if !$0 { maintenanceRecordPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("刪除", role: .destructive) {
                    if let record = maintenanceRecordPendingDelete {
                        viewModel.deleteMaintenanceRecord(record)
                    }
                    maintenanceRecordPendingDelete = nil
                }
                Button("取消", role: .cancel) {
                    maintenanceRecordPendingDelete = nil
                }
            }
            .sheet(isPresented: $showAddFuelSheet) {
                AddFuelSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $showAddMaintenanceSheet) {
                AddMaintenanceSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $showVehicleManagement) {
                VehicleManagementSheet(viewModel: viewModel)
            }
            .sheet(item: $editingFuelRecord) { record in
                AddFuelSheet(viewModel: viewModel, editingRecord: record)
            }
            .sheet(isPresented: $showBillReconciliation) {
                BillReconciliationSheet(viewModel: viewModel)
            }
            .fileExporter(
                isPresented: $showCSVExporter,
                document: csvExportDocument,
                contentType: .commaSeparatedText,
                defaultFilename: "車輛紀錄"
            ) { result in
                switch result {
                case .success:
                    showClearAfterExportConfirm = true
                case .failure(let error):
                    print("匯出失敗：\(error.localizedDescription)")
                }
            }
            .fileImporter(
                isPresented: $showCSVImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText]
            ) { result in
                switch result {
                case .success(let url):
                    let count = viewModel.importCSV(from: url)
                    if let count = count {
                        importResultMessage = "已匯入 \(count) 筆紀錄"
                    } else {
                        importResultMessage = "匯入失敗，請確認 CSV 格式"
                    }
                    showImportResultAlert = true
                case .failure(let error):
                    importResultMessage = "匯入失敗：\(error.localizedDescription)"
                    showImportResultAlert = true
                }
            }
            .confirmationDialog(
                "已匯出完成，是否清除本機所有紀錄？",
                isPresented: $showClearAfterExportConfirm,
                titleVisibility: .visible
            ) {
                Button("清除本機所有紀錄", role: .destructive) {
                    viewModel.clearAllRecords()
                }
                Button("保留，不清除", role: .cancel) {}
            }
            .confirmationDialog(
                "確定要清除所有車輛的所有紀錄嗎？此動作無法復原。",
                isPresented: $showClearAllConfirm,
                titleVisibility: .visible
            ) {
                Button("清除所有紀錄", role: .destructive) {
                    viewModel.clearAllRecords()
                }
                Button("取消", role: .cancel) {}
            }
            .alert(importResultMessage ?? "", isPresented: $showImportResultAlert) {
                Button("好") {}
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    // MARK: - 手刻頂部標題列（取代 NavigationView 的導覽列，避免在 page 樣式 TabView 裡跑版）
    private var topBar: some View {
        HStack {
            Menu {
                Button {
                    showVehicleManagement = true
                } label: {
                    Label("管理車輛", systemImage: "car.2.fill")
                }
                Button {
                    csvExportDocument = CSVFile(text: viewModel.exportCSVString())
                    showCSVExporter = true
                } label: {
                    Label("匯出 CSV", systemImage: "square.and.arrow.up")
                }
                Button {
                    showCSVImporter = true
                } label: {
                    Label("匯入 CSV", systemImage: "square.and.arrow.down")
                }
                Button {
                    showBillReconciliation = true
                } label: {
                    Label("帳單對帳（匯入油費清單比對）", systemImage: "checklist")
                }
                Button(role: .destructive) {
                    showClearAllConfirm = true
                } label: {
                    Label("清除所有紀錄", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            
            Spacer()
            
            Text("車輛維護與油耗")
                .font(.headline)
                .bold()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            
            Spacer()
            
            Button(action: {
                if viewModel.selectedSegment == 0 {
                    showAddFuelSheet = true
                } else {
                    showAddMaintenanceSheet = true
                }
            }) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
        }
        .padding(.horizontal)
        .padding(.top, UIApplication.shared.keyWindowSafeAreaTopInset + 10)
        .padding(.bottom, 6)
    }
    
    // MARK: - 頂部數據總覽卡片
    private var overviewSummaryCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("📊 車輛營運成本總覽")
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.secondary)
                Spacer()
                
                if viewModel.vehicles.count > 1 {
                    Picker("車輛", selection: Binding(
                        get: { viewModel.selectedVehicleID },
                        set: { viewModel.selectedVehicleID = $0 }
                    )) {
                        ForEach(viewModel.vehicles) { vehicle in
                            Text(vehicle.name).tag(vehicle.id as UUID?)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .font(.caption)
                } else if let vehicle = viewModel.selectedVehicle {
                    Text(vehicle.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Button {
                    showVehicleManagement = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if let vehicle = viewModel.selectedVehicle {
                HStack {
                    Text("目前車型：\(vehicle.type.rawValue)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Spacer()
                }
            }
            
            Divider()
            
            HStack(spacing: 0) {
                statCell(
                    title: "油耗表現",
                    value: String(format: "%.1f", viewModel.averageKmPerLiter),
                    unit: "km/L",
                    color: .green
                )
                Divider().frame(height: 35)
                statCell(
                    title: "每公里油錢",
                    value: String(format: "%.2f", viewModel.fuelCostPerKm),
                    unit: "元/km",
                    color: .orange
                )
                Divider().frame(height: 35)
                statCell(
                    title: "每公里保養費",
                    value: String(format: "%.2f", viewModel.maintenanceCostPerKm),
                    unit: "元/km",
                    color: .blue
                )
            }
            
            HStack {
                Spacer()
                Text("💡 每公里總車耗（含免費保養均攤）：")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(String(format: "%.2f 元/km", viewModel.totalVehicleCostPerKm))
                    .font(.caption)
                    .bold()
                    .foregroundColor(.purple)
            }
            
            Divider()
            
            HStack(spacing: 0) {
                statCell(
                    title: "加油錢總金額",
                    value: "$\(Int(viewModel.totalFuelCost))",
                    unit: "",
                    color: .orange
                )
                Divider().frame(height: 35)
                statCell(
                    title: "保養總金額",
                    value: "$\(Int(viewModel.totalMaintenanceCost))",
                    unit: "",
                    color: .blue
                )
                Divider().frame(height: 35)
                statCell(
                    title: "加總",
                    value: "$\(Int(viewModel.grandTotalCost))",
                    unit: "",
                    color: .purple
                )
            }
            
            Divider()
            
            YearlyCostLineChart(
                title: "📈 總金額年度趨勢",
                seriesKind: .totalOnly,
                data: viewModel.monthlyCostBreakdown(year: viewModel.selectedYear),
                selectedYear: $viewModel.selectedYear,
                availableYears: viewModel.availableYears
            )
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    private func statCell(title: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.headline)
                    .bold()
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - 超期 / 漏填保養提醒橫幅
    private var maintenanceWarningBanner: some View {
        let warning = viewModel.checkMaintenanceWarning(for: .engineOil)
        return Group {
            if warning.isOverdue {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("提醒：機油已行駛 \(Int(warning.drivenSince)) km（建議 \(Int(MaintenanceItemCategory.engineOil.recommendedInterval(for: viewModel.scooterType))) km 更換），是否漏下記錄？")
                        .font(.caption)
                        .foregroundColor(.primary)
                    Spacer()
                    Button("去記錄") {
                        showAddMaintenanceSheet = true
                    }
                    .font(.caption)
                    .bold()
                }
                .padding(8)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(8)
                .padding(.horizontal)
            }
        }
    }
    
    // MARK: - 加油紀錄列表
    // MARK: - 加油紀錄圖表卡片
    private var fuelChartCard: some View {
        YearlyCostLineChart(
            title: "⛽ 每月油錢金額",
            seriesKind: .fuelOnly,
            data: viewModel.monthlyCostBreakdown(year: viewModel.selectedYear),
            selectedYear: $viewModel.selectedYear,
            availableYears: viewModel.availableYears
        )
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    // MARK: - 加油紀錄單筆列內容（swipe / tap 由呼叫端的 ForEach 附加）
    @ViewBuilder
    private func fuelRecordRow(_ record: FuelRecord) -> some View {
        HStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formatDate(record.date))
                        .font(.subheadline)
                        .bold()
                    if record.odometer > 0 {
                        Text("總里程：\(Int(record.odometer)) km | \(record.fuelType)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("⚠️ 里程待補登，點這筆補上 | \(record.fuelType)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if !record.note.isEmpty {
                        Text("備註: \(record.note)")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("$\(Int(record.amount))")
                        .font(.headline)
                        .foregroundColor(.orange)
                    Text(String(format: "%.2f L", record.liters))
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                editingFuelRecord = record
            }
            
            // 用明確的垃圾桶按鈕刪除，不依賴左滑——這個畫面本身在可左右滑動切換的分頁裡，
            // 左滑手勢常被外層分頁搶走，滑不出刪除鍵
            Button {
                fuelRecordPendingDelete = record
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.title3)
                    .foregroundColor(.red.opacity(0.75))
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
        }
    }
    
    // MARK: - 保養紀錄圖表卡片
    private var maintenanceChartCard: some View {
        YearlyCostLineChart(
            title: "🔧 每月保養金額",
            seriesKind: .maintenanceOnly,
            data: viewModel.monthlyCostBreakdown(year: viewModel.selectedYear),
            selectedYear: $viewModel.selectedYear,
            availableYears: viewModel.availableYears
        )
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    // MARK: - 保養紀錄單筆列內容（swipe 由呼叫端的 ForEach 附加）
    @ViewBuilder
    private func maintenanceRecordRow(_ record: MaintenanceRecord) -> some View {
        HStack(alignment: .top) {
            if let photoData = record.oilPhotoData, let uiImage = UIImage(data: photoData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .cornerRadius(6)
                    .clipped()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(formatDate(record.date))
                        .font(.subheadline)
                        .bold()
                    if record.isFree {
                        Text("免費/贈送")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                    Spacer()
                    Text("$\(Int(record.totalCost))")
                        .font(.headline)
                        .foregroundColor(record.isFree ? .green : .blue)
                }
                Text("保養里程：\(Int(record.odometer)) km")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("項目：\(record.selectedItems.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                if !record.oilBrand.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                    Text("機油品牌：\(record.oilBrand)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                if let score = record.oilDarknessScore {
                    Text("機油黑度評估：\(score) 分")
                        .font(.caption2)
                        .bold()
                        .foregroundColor(score > 70 ? .red : .green)
                }
            }
            
            Spacer(minLength: 4)
            
            // 用明確的垃圾桶按鈕刪除，不依賴左滑（原因同加油紀錄那邊）
            Button {
                maintenanceRecordPendingDelete = record
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.title3)
                    .foregroundColor(.red.opacity(0.75))
            }
            .buttonStyle(.plain)
        }
    }
    
    private func emptyStateView(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 40))
                .foregroundColor(.gray)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 3.5 車輛管理 Sheet

struct VehicleManagementSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: VehicleViewModel
    
    @State private var newVehicleName: String = ""
    @State private var newVehicleType: ScooterType = .standard
    @State private var vehiclePendingDelete: Vehicle? = nil
    @State private var showDeleteConfirm = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("我的車輛")) {
                    ForEach(viewModel.vehicles) { vehicle in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vehicle.name)
                                    .font(.subheadline)
                                Text(vehicle.type.rawValue)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            if vehicle.id == viewModel.selectedVehicleID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectedVehicleID = vehicle.id
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                vehiclePendingDelete = vehicle
                                showDeleteConfirm = true
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                        }
                    }
                }
                
                Section(header: Text("新增車輛")) {
                    TextField("車輛名稱（如：小綠、重機）", text: $newVehicleName)
                    Picker("車型", selection: $newVehicleType) {
                        ForEach(ScooterType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    Button("新增") {
                        let name = newVehicleName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        viewModel.addVehicle(name: name, type: newVehicleType)
                        newVehicleName = ""
                        newVehicleType = .standard
                    }
                    .disabled(newVehicleName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("管理車輛")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                "刪除「\(vehiclePendingDelete?.name ?? "")」會一併刪除這台車的所有加油與保養紀錄，確定嗎？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("刪除", role: .destructive) {
                    if let v = vehiclePendingDelete {
                        viewModel.deleteVehicle(v)
                    }
                    vehiclePendingDelete = nil
                }
                Button("取消", role: .cancel) {
                    vehiclePendingDelete = nil
                }
            }
        }
    }
}

// MARK: - 4. 新增加油 Sheet (AddFuelSheet)

struct AddFuelSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: VehicleViewModel
    
    /// 非 nil 代表這次是「編輯既有紀錄」；nil 代表新增
    private var editingRecordID: UUID? = nil
    /// 是否為帳單對帳的快速補登。快速補登時要讓使用者選擇白牌／黃牌。
    private var isBillQuickAdd: Bool = false
    
    @State private var selectedVehicleID: UUID?
    @State private var recordDate: Date = Date()
    @State private var odometerText: String = ""
    @State private var litersText: String = ""
    @State private var amountText: String = ""
    @State private var selectedFuelType: String = "92無鉛"
    @State private var isSkippedPrevious: Bool = false
    @State private var note: String = ""
    
    // 加油機面板照片（帶入公升數 + 金額）
    @State private var selectedPumpPhotoItem: PhotosPickerItem? = nil
    @State private var showPumpSourceDialog = false
    @State private var showPumpCamera = false
    @State private var showPumpLibraryPicker = false
    @State private var pumpOCRDebugText: String = "" // 顯示這次 OCR 實際讀到的文字，方便確認/除錯
    @State private var litersValidationNote: String? = nil // 用畫面上油種單價反推公升數，跟 OCR 讀到的互相驗算的結果
    // 儀表板/里程表照片（帶入里程）
    @State private var selectedOdometerPhotoItem: PhotosPickerItem? = nil
    @State private var showOdometerSourceDialog = false
    @State private var showOdometerCamera = false
    @State private var showOdometerLibraryPicker = false
    
    let fuelTypes = ["92無鉛", "95無鉛", "98無鉛"]
    
    /// 一般「新增」用
    init(viewModel: VehicleViewModel) {
        self.viewModel = viewModel
        self._selectedVehicleID = State(initialValue: viewModel.selectedVehicleID)
        self.isBillQuickAdd = false
    }
    
    /// 編輯既有紀錄用（例如帳單補登後，回來補上里程）
    init(viewModel: VehicleViewModel, editingRecord: FuelRecord) {
        self.viewModel = viewModel
        self.editingRecordID = editingRecord.id
        self._selectedVehicleID = State(initialValue: editingRecord.vehicleId)
        self.isBillQuickAdd = false
        _recordDate = State(initialValue: editingRecord.date)
        _odometerText = State(initialValue: editingRecord.odometer > 0 ? String(Int(editingRecord.odometer)) : "")
        _litersText = State(initialValue: editingRecord.liters > 0 ? String(format: "%.2f", editingRecord.liters) : "")
        _amountText = State(initialValue: editingRecord.amount > 0 ? String(Int(editingRecord.amount)) : "")
        _selectedFuelType = State(initialValue: editingRecord.fuelType)
        _isSkippedPrevious = State(initialValue: editingRecord.isSkippedPrevious)
        _note = State(initialValue: editingRecord.note)
    }
    
    /// 帳單對帳「快速補登」用：預填日期／金額／備註，里程與加油量先留白，之後可以再點這筆紀錄回來補上
    init(viewModel: VehicleViewModel, prefillDate: Date, prefillAmount: Double, prefillNote: String) {
        self.viewModel = viewModel
        self._selectedVehicleID = State(initialValue: viewModel.selectedVehicleID)
        self.isBillQuickAdd = true
        _recordDate = State(initialValue: prefillDate)
        _amountText = State(initialValue: String(Int(prefillAmount)))
        _note = State(initialValue: "帳單對帳補登：\(prefillNote)")
    }
    
    var body: some View {
        NavigationView {
            Form {
                if isBillQuickAdd {
                    Section(header: Text("補登車輛")) {
                        Picker("車輛", selection: $selectedVehicleID) {
                            Text("請選擇車輛").tag(UUID?.none)
                            ForEach(viewModel.vehicles) { vehicle in
                                Text(vehicle.name).tag(Optional(vehicle.id))
                            }
                        }
                        Text("請確認這筆帳單是白牌還是黃牌，再儲存。")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                
                Section(header: Text("基本資訊與 OCR 辨識")) {
                    Button {
                        showPumpSourceDialog = true
                    } label: {
                        HStack {
                            Image(systemName: "fuelpump.fill")
                                .foregroundColor(.blue)
                            Text("拍加油機面板 → 帶入公升數與金額")
                                .foregroundColor(.blue)
                        }
                    }
                    .confirmationDialog("選擇照片來源", isPresented: $showPumpSourceDialog, titleVisibility: .visible) {
                        Button("拍照") { showPumpCamera = true }
                        Button("從相簿選擇") { showPumpLibraryPicker = true }
                        Button("取消", role: .cancel) {}
                    }
                    .photosPicker(isPresented: $showPumpLibraryPicker, selection: $selectedPumpPhotoItem, matching: .images)
                    .fullScreenCover(isPresented: $showPumpCamera) {
                        CameraPicker { image in
                            handlePumpImage(image)
                        }
                        .ignoresSafeArea()
                    }
                    .onChange(of: selectedPumpPhotoItem) { _, newItem in
                        guard let newItem = newItem else { return }
                        Task {
                            do {
                                guard let data = try await newItem.loadTransferable(type: Data.self),
                                      let image = UIImage(data: data) else {
                                    return
                                }
                                handlePumpImage(image)
                            } catch {
                                print("讀取照片失敗：\(error.localizedDescription)")
                            }
                        }
                    }
                    
                    if !pumpOCRDebugText.isEmpty {
                        Text("辨識到的文字：\(pumpOCRDebugText)")
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .lineLimit(3)
                    }
                    
                    Button {
                        showOdometerSourceDialog = true
                    } label: {
                        HStack {
                            Image(systemName: "gauge.with.needle.fill")
                                .foregroundColor(.purple)
                            Text("拍儀表板/里程表 → 帶入當前里程")
                                .foregroundColor(.purple)
                        }
                    }
                    .confirmationDialog("選擇照片來源", isPresented: $showOdometerSourceDialog, titleVisibility: .visible) {
                        Button("拍照") { showOdometerCamera = true }
                        Button("從相簿選擇") { showOdometerLibraryPicker = true }
                        Button("取消", role: .cancel) {}
                    }
                    .photosPicker(isPresented: $showOdometerLibraryPicker, selection: $selectedOdometerPhotoItem, matching: .images)
                    .fullScreenCover(isPresented: $showOdometerCamera) {
                        CameraPicker { image in
                            handleOdometerImage(image)
                        }
                        .ignoresSafeArea()
                    }
                    .onChange(of: selectedOdometerPhotoItem) { _, newItem in
                        guard let newItem = newItem else { return }
                        Task {
                            do {
                                guard let data = try await newItem.loadTransferable(type: Data.self),
                                      let image = UIImage(data: data) else {
                                    return
                                }
                                handleOdometerImage(image)
                            } catch {
                                print("讀取照片失敗：\(error.localizedDescription)")
                            }
                        }
                    }
                    
                    DatePicker("日期與時間", selection: $recordDate, displayedComponents: [.date, .hourAndMinute])
                }
                
                Section(header: Text("加油數據")) {
                    HStack {
                        Text("當前里程")
                        Spacer()
                        TextField("例如 12500", text: $odometerText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("km")
                    }
                    if viewModel.latestOdometer > 0 {
                        Text("（上次紀錄里程：\(Int(viewModel.latestOdometer)) km）")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    if odometerText.isEmpty {
                        Text("💡 里程可以先留白，之後在加油紀錄列表點這一筆再回來補上")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    
                    HStack {
                        Text("加油量")
                        Spacer()
                        TextField("例如 4.5", text: $litersText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("L")
                    }
                    if let note = litersValidationNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundColor(note.hasPrefix("⚠️") ? .orange : .secondary)
                    }
                    
                    HStack {
                        Text("總金額")
                        Spacer()
                        TextField("例如 140", text: $amountText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                        Text("$")
                    }
                    
                    Picker("油品種類", selection: $selectedFuelType) {
                        ForEach(fuelTypes, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                }
                
                Section(header: Text("備註")) {
                    Toggle("漏記/跳過上一期油耗計算", isOn: $isSkippedPrevious)
                    TextField("備註 (加油站名稱/優惠折抵)", text: $note)
                }
            }
            .navigationTitle(editingRecordID == nil ? "新增加油紀錄" : "編輯加油紀錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { saveRecord() }
                        .disabled(amountText.isEmpty || selectedVehicleID == nil)
                }
            }
        }
    }
    
    private func handlePumpImage(_ image: UIImage) {
        OCRHelper.recognizePumpText(from: image, preferredFuelType: selectedFuelType) { liters, amount, litersNote, debugText in
            DispatchQueue.main.async {
                if let liters = liters {
                    self.litersText = String(format: "%.2f", liters)
                }
                if let amount = amount {
                    self.amountText = String(Int(amount))
                }
                self.pumpOCRDebugText = debugText
                self.litersValidationNote = litersNote
                // 注意：刻意不在此帶入里程，里程一律來自儀表板照片或手動輸入
            }
        }
    }
    
    private func handleOdometerImage(_ image: UIImage) {
        OCRHelper.recognizeOdometerText(from: image) { odometer in
            DispatchQueue.main.async {
                if let odometer = odometer {
                    self.odometerText = String(Int(odometer))
                }
            }
        }
    }
    
    private func saveRecord() {
        guard let vehicleId = selectedVehicleID,
              let amount = Double(amountText) else { return }
        
        // 里程、加油量可以先留白（帳單補登常見情況），存成 0 代表「待補登」，
        // 統計計算那邊已經會自動排除這種 <= 0 的暫存紀錄，不會拉低油耗/總里程準確度
        let odo = Double(odometerText) ?? 0
        let liters = Double(litersText) ?? 0
        
        let record = FuelRecord(
            id: editingRecordID ?? UUID(),
            vehicleId: vehicleId,
            date: recordDate,
            odometer: odo,
            liters: liters,
            amount: amount,
            fuelType: selectedFuelType,
            isSkippedPrevious: isSkippedPrevious,
            note: note
        )
        
        if editingRecordID != nil {
            viewModel.updateFuelRecord(record)
        } else {
            viewModel.addFuelRecord(record)
        }
        dismiss()
    }
}

// MARK: - 4.5 帳單對帳 Sheet

struct BillReconciliationSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: VehicleViewModel
    
    @State private var showImporter = false
    @State private var fallbackYear: Int = Calendar.current.component(.year, from: Date())
    @State private var rows: [BillReconciliationRow] = []
    @State private var hasImportedOnce = false
    @State private var importErrorMessage: String? = nil
    @State private var showImportError = false
    @State private var quickAddCandidate: BillCandidate? = nil
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("帳單日期只有「月/日」（沒有年份）時，用這裡補上年份：")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Stepper("帳單年份：\(String(fallbackYear))", value: $fallbackYear, in: 2000...2100)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                Button {
                    showImporter = true
                } label: {
                    Label("選擇帳單 CSV 檔案", systemImage: "doc.badge.plus")
                }
                .padding(.vertical, 8)
                
                if !hasImportedOnce {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("匯入帳單 CSV 後，會同時比對所有車輛的加油紀錄，\n依日期、金額配對；小額差異會提示可能是會員點數折抵")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                        Text("CSV 欄位支援：日期／消費日、商家／消費明細、金額／金額 (元)")
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    Spacer()
                } else if rows.isEmpty {
                    Spacer()
                    Text("這份 CSV 沒有解析出任何一筆交易，\n請確認欄位名稱與日期格式")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                } else {
                    List(rows) { row in
                        rowView(row)
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle("帳單對帳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText]
            ) { result in
                switch result {
                case .success(let url):
                    if let candidates = viewModel.parseBillCSV(from: url, fallbackYear: fallbackYear) {
                        rows = viewModel.reconcileBillCandidates(candidates)
                        hasImportedOnce = true
                    } else {
                        importErrorMessage = "無法解析帳單 CSV，請確認有日期、消費明細、金額欄位，且日期格式為 yyyy-MM-dd 或 MM/dd"
                        showImportError = true
                    }
                case .failure(let error):
                    importErrorMessage = "匯入失敗：\(error.localizedDescription)"
                    showImportError = true
                }
            }
            .alert(importErrorMessage ?? "", isPresented: $showImportError) {
                Button("好") {}
            }
            .sheet(item: $quickAddCandidate) { candidate in
                AddFuelSheet(
                    viewModel: viewModel,
                    prefillDate: candidate.date,
                    prefillAmount: candidate.amount,
                    prefillNote: candidate.merchant
                )
            }
        }
    }
    
    @ViewBuilder
    private func rowView(_ row: BillReconciliationRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(formatDate(row.candidate.date))
                    .font(.subheadline)
                    .bold()
                Text(row.candidate.merchant)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("$\(Int(row.candidate.amount))")
                    .font(.subheadline)
                statusLabel(row.status)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case .missing = row.status {
                quickAddCandidate = row.candidate
            }
        }
    }
    
    @ViewBuilder
    private func statusLabel(_ status: BillMatchStatus) -> some View {
        switch status {
        case .matched(let record):
            Label("已有紀錄 · \(vehicleName(for: record))", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.green)

        case .pointDifference(let record, let difference):
            Label(
                "疑似會員點數差額 $\(Int(difference)) · \(vehicleName(for: record))",
                systemImage: "checkmark.circle.badge.questionmark"
            )
            .font(.caption2)
            .foregroundColor(.orange)

        case .amountMismatch(let record):
            Label(
                "金額不符（App $\(Int(record.amount)) · \(vehicleName(for: record))）",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption2)
            .foregroundColor(.yellow)

        case .missing:
            Label("建議補登，點我快速新增", systemImage: "plus.circle.fill")
                .font(.caption2)
                .foregroundColor(.orange)
        }
    }
    
    private func vehicleName(for record: FuelRecord) -> String {
        viewModel.vehicles.first(where: { $0.id == record.vehicleId })?.name ?? "未知車輛"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}

// MARK: - 5. 新增保養 Sheet (AddMaintenanceSheet)

struct AddMaintenanceSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: VehicleViewModel
    
    @State private var recordDate: Date = Date()
    @State private var odometerText: String = ""
    @State private var totalCostText: String = ""
    @State private var isFree: Bool = false // 是否為免費保養
    @State private var note: String = ""
    @State private var customItemText: String = ""
    
    @State private var selectedCategories: Set<MaintenanceItemCategory> = [.engineOil]
    
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var showOilSourceDialog = false
    @State private var showOilCamera = false
    @State private var showOilLibraryPicker = false
    @State private var compressedPhotoData: Data? = nil
    @State private var previewImage: UIImage? = nil
    @State private var estimatedDarknessScore: Int? = nil
    @State private var oilBrand: String = "" // 機油品牌/型號（選填，用於跨紀錄比較不同機油的黑化速率）
    
    // 儀表板/里程表照片（帶入保養時里程）
    @State private var selectedOdometerPhotoItem: PhotosPickerItem? = nil
    @State private var showOdometerSourceDialog = false
    @State private var showOdometerCamera = false
    @State private var showOdometerLibraryPicker = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("保養時間與里程")) {
                    DatePicker("保養日期時間", selection: $recordDate, displayedComponents: [.date, .hourAndMinute])
                    
                    Button {
                        showOdometerSourceDialog = true
                    } label: {
                        HStack {
                            Image(systemName: "gauge.with.needle.fill")
                                .foregroundColor(.purple)
                            Text("拍儀表板/里程表 → 帶入保養時里程")
                                .foregroundColor(.purple)
                        }
                    }
                    .confirmationDialog("選擇照片來源", isPresented: $showOdometerSourceDialog, titleVisibility: .visible) {
                        Button("拍照") { showOdometerCamera = true }
                        Button("從相簿選擇") { showOdometerLibraryPicker = true }
                        Button("取消", role: .cancel) {}
                    }
                    .photosPicker(isPresented: $showOdometerLibraryPicker, selection: $selectedOdometerPhotoItem, matching: .images)
                    .fullScreenCover(isPresented: $showOdometerCamera) {
                        CameraPicker { image in
                            handleOdometerImage(image)
                        }
                        .ignoresSafeArea()
                    }
                    .onChange(of: selectedOdometerPhotoItem) { _, newItem in
                        guard let newItem = newItem else { return }
                        Task {
                            do {
                                guard let data = try await newItem.loadTransferable(type: Data.self),
                                      let image = UIImage(data: data) else {
                                    return
                                }
                                handleOdometerImage(image)
                            } catch {
                                print("讀取照片失敗：\(error.localizedDescription)")
                            }
                        }
                    }
                    
                    HStack {
                        Text("保養時里程")
                        Spacer()
                        TextField("例如 12500", text: $odometerText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("km")
                    }
                }
                
                Section(header: Text("勾選保養項目 (可多選)")) {
                    ForEach(MaintenanceItemCategory.allCases) { category in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.rawValue)
                                Text("建議每 \(Int(category.recommendedInterval(for: viewModel.scooterType))) km")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            if selectedCategories.contains(category) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.gray)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedCategories.contains(category) {
                                selectedCategories.remove(category)
                            } else {
                                selectedCategories.insert(category)
                            }
                        }
                    }
                    
                    if selectedCategories.contains(.custom) {
                        TextField("請輸入其他項目名稱", text: $customItemText)
                    }
                }
                
                // 拍攝機油照片區塊
                if selectedCategories.contains(.engineOil) {
                    Section(header: Text("機油狀態照片 (50KB壓縮與評估)")) {
                        TextField("機油品牌/型號（選填，方便比較不同機油表現）", text: $oilBrand)
                        
                        HStack {
                            Button {
                                showOilSourceDialog = true
                            } label: {
                                HStack {
                                    Image(systemName: "photo.badge.plus")
                                    Text(previewImage == nil ? "拍攝或選擇廢油照片" : "重新選擇照片")
                                }
                            }
                            .confirmationDialog("選擇照片來源", isPresented: $showOilSourceDialog, titleVisibility: .visible) {
                                Button("拍照") { showOilCamera = true }
                                Button("從相簿選擇") { showOilLibraryPicker = true }
                                Button("取消", role: .cancel) {}
                            }
                            .photosPicker(isPresented: $showOilLibraryPicker, selection: $selectedPhotoItem, matching: .images)
                            .fullScreenCover(isPresented: $showOilCamera) {
                                CameraPicker { image in
                                    processOilImage(image)
                                }
                                .ignoresSafeArea()
                            }
                            Spacer()
                            if let img = previewImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 40, height: 40)
                                    .cornerRadius(6)
                                    .clipped()
                            }
                        }
                        .onChange(of: selectedPhotoItem) { _, newItem in
                            Task {
                                if let data = try? await newItem?.loadTransferable(type: Data.self),
                                   let rawImage = UIImage(data: data) {
                                    processOilImage(rawImage)
                                }
                            }
                        }
                        
                        if let score = estimatedDarknessScore {
                            HStack {
                                Text("AI 黑度預估值：")
                                    .font(.caption)
                                Text("\(score) / 100")
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(score > 70 ? .red : .green)
                                Spacer()
                                Text(score > 70 ? "（建議更換）" : "（狀況良好）")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            
                            if let comparison = oilComparisonText {
                                Text("📊 \(comparison)")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            } else {
                                Text("目前僅為單張照片的黑度分析；累積至少兩筆機油紀錄（含里程與照片）後，這裡會顯示跟過去紀錄的比較建議。")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
                
                Section(header: Text("保養費用與優惠")) {
                    Toggle("原廠免費 / 贈送保養 ($0)", isOn: $isFree)
                        .onChange(of: isFree) { _, newValue in                            if newValue { totalCostText = "0" }
                        }
                    
                    HStack {
                        Text("本次總金額")
                        Spacer()
                        TextField("例如 350", text: $totalCostText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .disabled(isFree)
                        Text("$")
                    }
                    
                    TextField("備註 (如: 前5次免費機油、店家名稱等)", text: $note)
                }
            }
            .navigationTitle("新增保養紀錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { saveRecord() }
                        .disabled(odometerText.isEmpty || (totalCostText.isEmpty && !isFree) || selectedCategories.isEmpty || viewModel.selectedVehicleID == nil)
                }
            }
        }
    }
    
    /// 依目前拍照分析出的黑度分數、輸入的里程與品牌，跟歷史機油紀錄比較黑化速率
    private var oilComparisonText: String? {
        guard let score = estimatedDarknessScore,
              let odo = Double(odometerText) else { return nil }
        return viewModel.oilChangeComparisonText(newScore: score, newOdometer: odo, brand: oilBrand)
    }
    
    private func handleOdometerImage(_ image: UIImage) {
        OCRHelper.recognizeOdometerText(from: image) { odometer in
            DispatchQueue.main.async {
                if let odometer = odometer {
                    self.odometerText = String(Int(odometer))
                }
            }
        }
    }
    
    // 相機拍照與相簿選擇共用的照片處理邏輯
    private func processOilImage(_ rawImage: UIImage) {
        self.compressedPhotoData = compressToThumbnail(image: rawImage, maxKb: 50)
        self.previewImage = rawImage
        self.estimatedDarknessScore = evaluateOilDarkness(image: rawImage)
    }
    
    // 照片壓縮算法（控制在 50KB 內）
    private func compressToThumbnail(image: UIImage, maxKb: Int) -> Data? {
        let maxBytes = maxKb * 1024
        let targetSize = CGSize(width: 500, height: 500)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        var compression: CGFloat = 0.6
        var data = resizedImage.jpegData(compressionQuality: compression)
        while let d = data, d.count > maxBytes, compression > 0.1 {
            compression -= 0.1
            data = resizedImage.jpegData(compressionQuality: compression)
        }
        return data
    }
    
    private func evaluateOilDarkness(image: UIImage) -> Int {
        let targetSize = CGSize(width: 100, height: 100)
        UIGraphicsBeginImageContext(targetSize)
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        guard let cgImage = resizedImage?.cgImage,
              let pixelData = cgImage.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else {
            return 50
        }
        
        let bytesPerPixel = 4
        let width = cgImage.width
        let height = cgImage.height
        
        // 取中央 50% 區域 (ROI)
        let minX = Int(Double(width) * 0.25)
        let maxX = Int(Double(width) * 0.75)
        let minY = Int(Double(height) * 0.25)
        let maxY = Int(Double(height) * 0.75)
        
        var totalDarknessScore: Double = 0.0
        var pixelCount: Int = 0
        
        for y in minY..<maxY {
            for x in minX..<maxX {
                let pixelIndex = (y * width + x) * bytesPerPixel
                
                let r = CGFloat(data[pixelIndex]) / 255.0
                let g = CGFloat(data[pixelIndex + 1]) / 255.0
                let b = CGFloat(data[pixelIndex + 2]) / 255.0
                
                // 轉換為 HSV 色彩空間
                var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                UIColor(red: r, green: g, blue: b, alpha: 1.0).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
                
                // --- 綜合評估指標 ---
                // 1. 明亮度扣分 (0~1)：越暗 (v越小) 分數越高
                let brightnessDarkness = 1.0 - v
                
                // 2. 飽和度喪失扣分 (0~1)：無論原本何種顏色，劣化變灰黑時飽和度(s)會大幅下降
                let saturationLoss = 1.0 - s
                
                // 3. 複合加權：明亮度佔 60%，飽和度喪失（變灰程度）佔 40%
                let pixelScore = (brightnessDarkness * 0.6) + (saturationLoss * 0.4)
                
                totalDarknessScore += Double(pixelScore)
                pixelCount += 1
            }
        }
        
        guard pixelCount > 0 else { return 50 }
        
        let avgScore = (totalDarknessScore / Double(pixelCount)) * 100.0
        return min(max(Int(avgScore), 0), 100)
    }
    
    private func saveRecord() {
        guard let vehicleId = viewModel.selectedVehicleID,
              let odo = Double(odometerText) else { return }
        let cost = isFree ? 0.0 : (Double(totalCostText) ?? 0.0)
        
        var items = selectedCategories.map { $0.rawValue }
        if selectedCategories.contains(.custom) && !customItemText.isEmpty {
            items.append(customItemText)
        }
        
        let record = MaintenanceRecord(
            vehicleId: vehicleId,
            date: recordDate,
            odometer: odo,
            selectedItems: items,
            totalCost: cost,
            isFree: isFree,
            note: note,
            oilPhotoData: compressedPhotoData,
            oilDarknessScore: estimatedDarknessScore,
            oilBrand: oilBrand
        )
        viewModel.addMaintenanceRecord(record)
        dismiss()
    }
}
