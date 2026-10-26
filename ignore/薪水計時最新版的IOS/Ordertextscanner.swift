import SwiftUI
import Vision
import VisionKit
import PhotosUI
import Photos
import UIKit

// MARK: - 文字辨識 (OCR)
enum OrderTextRecognizer {
    static func recognizeLines(in image: UIImage, completion: @escaping ([String]) -> Void) {
        guard let cgImage = image.cgImage else {
            completion([])
            return
        }
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            DispatchQueue.main.async { completion(lines) }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hant", "en-US"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                // 辨識失敗也要回報，不然畫面會一直卡在「辨識中…」
                DispatchQueue.main.async { completion([]) }
            }
        }
    }

    /// async 版本：給捷徑 / 背景流程用，不用寫 callback
    static func recognizeLines(in image: UIImage) async -> [String] {
        await withCheckedContinuation { continuation in
            recognizeLines(in: image) { lines in
                continuation.resume(returning: lines)
            }
        }
    }
}

// MARK: - 一站式「圖片 → 單號/姓名」小工具（畫面與捷徑共用，辨識只寫這一份）
extension OrderInfoDetector.DetectedInfo {
    var hasAnything: Bool { orderCode != nil || name != nil }

    /// 要填進「平台單號」欄位的文字：單號 + 姓名（跟原本「全部套用」格式一樣）
    var combinedText: String? {
        // 熊貓：#四位數 / 完整單號 / 客人姓名，分三行
        if let full = fullOrderNumber {
            return [orderCode, full, name].compactMap { $0 }.joined(separator: "\n")
        }
        switch (orderCode, name) {
        case let (code?, name?): return "\(code)\n\(name)"
        case let (code?, nil): return code
        case let (nil, name?): return name
        default: return nil
        }
    }
}

enum OrderScreenshotReader {
    /// 丟一張截圖進來，回傳偵測到的單號與姓名
    static func read(image: UIImage) async -> OrderInfoDetector.DetectedInfo {
        let lines = await OrderTextRecognizer.recognizeLines(in: image)
        return OrderInfoDetector.detect(from: lines)
    }
}

// MARK: - 自動比對規則
enum OrderInfoDetector {
    struct DetectedInfo {
        var name: String?
        var orderCode: String?
        /// 熊貓完整單號（例：d9eb-2642-v7je）。有值時，orderCode 是「#8534」這種4位數短單號
        var fullOrderNumber: String?
    }

    // 排除介面常見關鍵字
    private static let uiKeywords = [
        "關閉", "截圖", "辨識", "單號", "換一張", "提示", "套用",
        "確認", "訂單", "商家", "說明", "支援", "行程", "客服", "領取",
        "背面輕點", "拷貝", "送達"
    ]

    // 單號匹配：2~5 個大寫英文 + 1~5 個數字 (如 DAE30, 92DB7)
    private static let uberOrderCodeRegex = try! NSRegularExpression(pattern: "[A-Z0-9]{4,7}")
    private static let foodpandaOrderCodeRegex = try! NSRegularExpression(pattern: "[a-z0-9]{2,10}-[a-z0-9]{2,10}\\s*\\(#[0-9]+\\)")
    // 熊貓畫面那一行：「d9eb-2642-v7je - #8534 - 逸娟 陳」→ 完整單號 / 4位數 / 姓名
    private static let foodpandaLineRegex = try! NSRegularExpression(
        pattern: "([a-z0-9]{3,6}-[a-z0-9]{3,6}-[a-z0-9]{3,6})\\s*[-–—]\\s*#\\s*([0-9]{3,5})\\s*[-–—]\\s*(.+)$",
        options: [.caseInsensitive]
    )

    static func detect(from lines: [String]) -> DetectedInfo {
        var info = DetectedInfo()
        
        // 清理空白列
        let cleanedLines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        
        // 00. 熊貓畫面：找「完整單號 - #四位數 - 客人姓名」那一行
        for line in cleanedLines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let m = foodpandaLineRegex.firstMatch(in: line, range: range),
               let r1 = Range(m.range(at: 1), in: line),
               let r2 = Range(m.range(at: 2), in: line),
               let r3 = Range(m.range(at: 3), in: line) {
                info.fullOrderNumber = String(line[r1]).lowercased()
                info.orderCode = "#" + String(line[r2])
                info.name = String(line[r3]).trimmingCharacters(in: .whitespacesAndNewlines)
                return info
            }
        }

        // 0. 新規則：「聯絡」畫面——「聯絡」按鈕下方依序是 姓名、單號（例：趙 映. / D9536）
        if let contactIdx = cleanedLines.firstIndex(where: { $0 == "聯絡" }) {
            var nameCandidate: String? = nil
            for line in cleanedLines[(contactIdx + 1)...].prefix(4) {
                let compact = line.replacingOccurrences(of: " ", with: "")
                if isStandaloneOrderCode(compact) {
                    info.orderCode = compact
                    info.name = nameCandidate
                    return info
                }
                if nameCandidate == nil && isLikelyName(line) {
                    nameCandidate = line
                }
            }
        }

        var estimateIndex: Int? = nil

        // 1. 尋找「預估抵達」或「確認訂單」作為核心定位基準點
        for (index, line) in cleanedLines.enumerated() {
            if line.contains("預估") || line.contains("抵達") || line.contains("確認訂單") {
                estimateIndex = index
                break
            }
        }

        // 2. 如果找到預估抵達點，往上提取單號與姓名
        if let anchorIdx = estimateIndex {
            // 單號在「預估抵達」上方 1~2 行
            for offset in 1...2 {
                let checkIdx = anchorIdx - offset
                guard checkIdx >= 0 else { continue }
                let line = cleanedLines[checkIdx]
                
                // 從這行抓單號 (處理 "DAE30 · 1 項")
                let targetStr = line.components(separatedBy: CharacterSet(charactersIn: "・•·")).first ?? line
                let range = NSRange(targetStr.startIndex..<targetStr.endIndex, in: targetStr)
                
                if let match = uberOrderCodeRegex.firstMatch(in: targetStr, range: range),
                   let r = Range(match.range, in: targetStr) {
                    let extracted = String(targetStr[r])
                    // 排除純數字（如郵遞區號），Uber 單號通常包含英文
                    if extracted.rangeOfCharacter(from: .letters) != nil || extracted.count <= 5 {
                        info.orderCode = extracted
                        
                        // 單號再上一行就是姓名
                        if checkIdx - 1 >= 0 {
                            let nameLine = cleanedLines[checkIdx - 1]
                            if isLikelyName(nameLine) {
                                info.name = nameLine
                            }
                        }
                        break
                    }
                }
            }
        }

        // 3. 備用機制：若無「預估」關鍵字，用舊規則全行搜尋
        if info.orderCode == nil {
            for (index, line) in cleanedLines.enumerated() {
                if uiKeywords.contains(where: { line.contains($0) }) { continue }
                
                if line.contains("項") {
                    let targetStr = line.components(separatedBy: CharacterSet(charactersIn: "・•·")).first ?? line
                    let range = NSRange(targetStr.startIndex..<targetStr.endIndex, in: targetStr)
                    if let match = uberOrderCodeRegex.firstMatch(in: targetStr, range: range),
                       let r = Range(match.range, in: targetStr) {
                        info.orderCode = String(targetStr[r])
                        if index - 1 >= 0 && isLikelyName(cleanedLines[index - 1]) {
                            info.name = cleanedLines[index - 1]
                        }
                        break
                    }
                }
            }
        }

        return info
    }

    /// 整行就是單號（4~7 個大寫英文或數字，如 D9536、DAE30、92DB7）
    private static func isStandaloneOrderCode(_ text: String) -> Bool {
        text.range(of: "^[A-Z0-9]{4,7}$", options: .regularExpression) != nil
    }

    private static func isLikelyName(_ text: String) -> Bool {
        for keyword in uiKeywords {
            if text.contains(keyword) { return false }
        }
        return text.count >= 2 && text.count <= 10
    }
}

// MARK: - Live Text 手動選字
@available(iOS 16.0, *)
private struct LiveTextImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true

        let interaction = ImageAnalysisInteraction()
        imageView.addInteraction(interaction)
        context.coordinator.interaction = interaction
        context.coordinator.analyze(image: image)
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if uiView.image !== image {
            uiView.image = image
            context.coordinator.analyze(image: image)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        guard let img = uiView.image, img.size.width > 0, img.size.height > 0 else {
            return proposal.replacingUnspecifiedDimensions()
        }
        // 放大縮圖：將高度限制放寬至 520pt，寬度盡量佔滿螢幕
        let maxWidth = proposal.width ?? (UIScreen.main.bounds.width - 24)
        let maxHeight = proposal.height ?? 520
        let imageAspect = img.size.width / img.size.height
        var width = maxWidth
        var height = width / imageAspect
        if height > maxHeight {
            height = maxHeight
            width = height * imageAspect
        }
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var interaction: ImageAnalysisInteraction?
        private let analyzer = ImageAnalyzer()

        func analyze(image: UIImage) {
            guard let interaction else { return }
            Task {
                do {
                    let configuration = ImageAnalyzer.Configuration([.text])
                    let analysis = try await analyzer.analyze(image, configuration: configuration)
                    await MainActor.run {
                        interaction.analysis = analysis
                        interaction.preferredInteractionTypes = .textSelection
                    }
                } catch {}
            }
        }
    }
}

// MARK: - 掃描截圖的彈出視窗
@available(iOS 16.0, *)
struct OrderTextScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pickedImage: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var detected = OrderInfoDetector.DetectedInfo()
    @State private var isRecognizing = false
    @State private var isFromPhotoPicker = false // 改用明確 Flag 判斷是否為相簿選取
    @State private var showDeleteConfirm = false

    var onApply: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let image = pickedImage {
                        LiveTextImageView(image: image)
                            .frame(maxHeight: 520)
                            .background(Color.black.opacity(0.05))
                            .cornerRadius(12)
                            .padding(.horizontal, 12)

                        Text("提示：也可以直接長按或用手指滑過圖片上的文字選取，選完系統會跳出「拷貝」。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        if isRecognizing {
                            ProgressView("辨識中…")
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                if let code = detected.orderCode {
                                    HStack {
                                        Text("偵測到單號：\(code)").font(.subheadline)
                                        Spacer()
                                        Button("套用單號") { handleApply(code) }
                                            .buttonStyle(.bordered)
                                    }
                                }
                                if let name = detected.name {
                                    HStack {
                                        Text("偵測到姓名：\(name)").font(.subheadline)
                                        Spacer()
                                        Button("套用姓名") { handleApply(name) }
                                            .buttonStyle(.bordered)
                                    }
                                }

                                if detected.orderCode != nil && detected.name != nil {
                                    Button(action: {
                                        if let combined = detected.combinedText {
                                            handleApply(combined)
                                        }
                                    }) {
                                        Label("全部套用 (單號 + 姓名)", systemImage: "checkmark.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .padding(.top, 4)
                                }

                                if detected.orderCode == nil && detected.name == nil {
                                    Text("沒有自動偵測到符合格式的單號或姓名，長按或用手指滑過圖片上想要的文字直接選取，選完系統會跳出「拷貝」，拷貝後回上一頁貼上即可。")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal)
                        }
                    } else {
                        VStack(spacing: 16) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Label("從相簿選截圖", systemImage: "photo.on.rectangle")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue.opacity(0.12))
                                    .cornerRadius(10)
                            }
                            Button {
                                if let image = UIPasteboard.general.image {
                                    isFromPhotoPicker = false
                                    pickedImage = image
                                    recognize(image)
                                }
                            } label: {
                                Label("貼上剪貼簿截圖", systemImage: "doc.on.clipboard")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.green.opacity(0.12))
                                    .cornerRadius(10)
                            }
                            Text("先在系統截圖的分享清單裡點「拷貝」，再回來這裡按上面這顆按鈕貼上。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    }
                    Spacer(minLength: 20)
                }
                .padding(.top)
            }
            .navigationTitle("截圖辨識單號")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
                if pickedImage != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("換一張") {
                            pickedImage = nil
                            photoItem = nil
                            isFromPhotoPicker = false
                            detected = .init()
                        }
                    }
                }
            }
            .onChange(of: photoItem) { oldValue, newItem in
                guard let newItem else { return }
                isFromPhotoPicker = true
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        pickedImage = image
                        recognize(image)
                    }
                }
            }
            .confirmationDialog("已完成套用，要刪除這張截圖嗎？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("刪除截圖", role: .destructive) {
                    deleteLastPhoto()
                    dismiss()
                }
                Button("保留截圖", role: .cancel) {
                    dismiss()
                }
            } message: {
                Text("確定不會再用到的話可以順手刪掉，保留的話會留在你的相簿裡。")
            }
        }
    }

    private func handleApply(_ text: String) {
        // 先確定回傳字串給父視圖
        onApply(text)
        
        // 判斷是否彈出刪除相片的提示
        if isFromPhotoPicker {
            showDeleteConfirm = true
        } else {
            dismiss()
        }
    }

    // 取得最新一張相片並請求刪除 (解決 photoItem.itemIdentifier 可能取得空值的狀況)
    private func deleteLastPhoto() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 1
        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        
        guard let asset = fetchResult.firstObject else { return }
        
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }) { success, error in
            if !success {
                print("刪除截圖失敗：\(error?.localizedDescription ?? "未知錯誤")")
            }
        }
    }

    private func recognize(_ image: UIImage) {
        isRecognizing = true
        Task {
            let result = await OrderScreenshotReader.read(image: image)
            await MainActor.run {
                detected = result
                isRecognizing = false
            }
        }
    }
}

// MARK: - 會隨內容自動長高且支援收起鍵盤的輸入框
struct DeferringTextEditor: View {
    let placeholder: String
    @Binding var externalValue: String
    var font: UIFont = .preferredFont(forTextStyle: .body)

    var body: some View {
        AutoGrowingTextViewRepresentable(placeholder: placeholder, text: $externalValue, font: font)
    }
}

private struct AutoGrowingTextViewRepresentable: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var font: UIFont

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = font
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 6
        textView.delegate = context.coordinator

        // 新增：鍵盤上方加入「完成」按鈕列 (InputAccessoryView)
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let flexibleSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let doneButton = UIBarButtonItem(title: "完成", style: .done, target: context.coordinator, action: #selector(Coordinator.dismissKeyboard))
        toolbar.setItems([flexibleSpace, doneButton], animated: false)
        textView.inputAccessoryView = toolbar

        applyDisplayText(text, placeholder: placeholder, to: textView)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        guard !uiView.isFirstResponder else { return }
        applyDisplayText(text, placeholder: placeholder, to: uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(36, fitted.height))
    }

    private func applyDisplayText(_ value: String, placeholder: String, to textView: UITextView) {
        let display = value.isEmpty ? placeholder : value
        if textView.text != display {
            textView.text = display
        }
        textView.textColor = value.isEmpty ? .placeholderText : .label
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AutoGrowingTextViewRepresentable
        init(_ parent: AutoGrowingTextViewRepresentable) { self.parent = parent }

        @objc func dismissKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if parent.text.isEmpty {
                textView.text = ""
                textView.textColor = .label
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            let newValue = textView.text ?? ""
            if parent.text != newValue {
                parent.text = newValue
            }
            if newValue.isEmpty {
                textView.text = parent.placeholder
                textView.textColor = .placeholderText
            }
        }
    }
}
