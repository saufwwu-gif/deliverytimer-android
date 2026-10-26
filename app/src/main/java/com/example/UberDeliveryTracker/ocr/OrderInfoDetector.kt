package com.example.UberDeliveryTracker.ocr

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.regex.Pattern
import kotlin.coroutines.resume

data class DetectedInfo(
    var name: String? = null,
    var orderCode: String? = null,
    var fullOrderNumber: String? = null,
    // ── 新來單（還沒按「接受」的那張卡片）──
    var isNewOffer: Boolean = false,
    var offerPlatform: String? = null,   // "Uber" 或 "熊貓"
    var offerPrice: Double? = null,
    var offerMinutes: Int? = null,
    var offerKm: Double? = null,
    var isCash: Boolean = false,
    var cashAmount: Double? = null   // 收取費用畫面上要收的金額
) {
    val hasAnything: Boolean get() = isNewOffer || orderCode != null || name != null || cashAmount != null

    val combinedText: String?
        get() {
            if (isNewOffer) return null
            if (fullOrderNumber != null) {
                return listOfNotNull(orderCode, fullOrderNumber, name).joinToString("\n")
            }
            return when {
                orderCode != null && name != null -> "$orderCode\n$name"
                orderCode != null -> orderCode
                name != null -> name
                else -> null
            }
        }

    /** 例如：Uber・$115・32 分鐘・9.7 公里 */
    val offerSummary: String
        get() {
            val parts = mutableListOf<String>()
            offerPlatform?.let { parts.add(it) }
            offerPrice?.let {
                parts.add("\$" + (if (it % 1.0 == 0.0) it.toInt().toString() else "%.2f".format(it)))
            }
            offerMinutes?.let { if (it > 0) parts.add("$it 分鐘") }
            offerKm?.let { parts.add("$it 公里") }
            return parts.joinToString("・")
        }
}

object OrderInfoDetector {

    private val uiKeywords = setOf(
        "關閉", "截圖", "辨識", "單號", "換一張", "提示", "套用",
        "確認", "訂單", "商家", "說明", "支援", "行程", "客服", "領取",
        "背面輕點", "拷貝", "送達", "接受", "配對", "總計", "現金"
    )

    // Uber 單號：4~7 個大寫英文/數字 (例 DAE30, 92DB7)
    private val uberOrderCodePattern = Pattern.compile("[A-Z0-9]{4,7}")

    // 熊貓取餐畫面那一行：
    //  iPhone 版「d9eb-2642-v7je - #8534 - 逸娟 陳」
    //  安卓版  「a-rsq6-wc6exe - 484683 - 張OO」（沒有 #，單號 6 位數）
    private val foodpandaLinePattern = Pattern.compile(
        "([a-z0-9]+-[a-z0-9]+-[a-z0-9]+)\\s*[-–—]\\s*#?\\s*([0-9]{3,8})\\s*[-–—]\\s*(.+)$",
        Pattern.CASE_INSENSITIVE
    )

    // 熊貓畫面上那個大方框「#8534」
    private val pandaBoxPattern = Pattern.compile("^#([0-9]{3,8})$")

    // Uber 新來單：「總計 32 分鐘 (9.7 公里)」「總計 1 小時 10 分鐘 (12.7 公里)」
    private val totalTimeKmPattern = Pattern.compile(
        "總計\\s*(?:([0-9]+)\\s*小時)?\\s*(?:([0-9]+)\\s*分鐘?)?\\s*[（(]\\s*([0-9]+(?:\\.[0-9]+)?)\\s*公里"
    )
    // Uber 新來單的大金額：「$115」
    private val uberPricePattern = Pattern.compile("^[\\$＄]\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)$")
    // 熊貓新來單的金額：「93.92 $」
    private val pandaPricePattern = Pattern.compile("([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*[\\$＄]")
    private val minutesPattern = Pattern.compile("([0-9]+)\\s*分鐘")
    private val kmPattern = Pattern.compile("([0-9]+(?:\\.[0-9]+)?)\\s*公里")

    fun detect(lines: List<String>): DetectedInfo {
        val cleanedLines = lines.map { it.trim() }.filter { it.isNotEmpty() }

        // 0. 新來單（還沒按接受的那張卡片）最優先判斷
        detectNewOffer(cleanedLines)?.let { return it }

        // 0.5 收取費用畫面（現金單要收多少）
        detectCashCollect(cleanedLines)?.let { return it }

        val info = DetectedInfo()

        // 1. 熊貓取餐畫面：完整單號 - 短單號 - 姓名
        for (line in cleanedLines) {
            val matcher = foodpandaLinePattern.matcher(line)
            if (matcher.find()) {
                info.fullOrderNumber = matcher.group(1)?.lowercase()
                info.orderCode = "#" + matcher.group(2)
                info.name = matcher.group(3)?.trim()
                return info
            }
        }

        // 2. 「聯絡」畫面：按鈕下方為 姓名、單號
        val contactIdx = cleanedLines.indexOfFirst { it == "聯絡" }
        if (contactIdx != -1) {
            var nameCandidate: String? = null
            val sub = cleanedLines.drop(contactIdx + 1).take(4)
            for (line in sub) {
                val compact = line.replace(" ", "")
                if (isStandaloneOrderCode(compact)) {
                    info.orderCode = compact
                    info.name = nameCandidate
                    return info
                }
                if (nameCandidate == null && isLikelyName(line)) {
                    nameCandidate = line
                }
            }
        }

        // 3. 「領取」畫面：以「預估抵達」或「確認訂單」為基準點，往上找單號與姓名
        //    （熊貓寫的是「預計…抵達店家」，不要拿來當基準）
        val estimateIndex = cleanedLines.indexOfFirst {
            !it.contains("預計") &&
                    (it.contains("預估") || it.contains("抵達") || it.contains("確認訂單"))
        }
        if (estimateIndex != -1) {
            for (offset in 1..2) {
                val checkIdx = estimateIndex - offset
                if (checkIdx < 0) continue
                val line = cleanedLines[checkIdx]

                val targetStr = line.split(Regex("[・•·]")).firstOrNull() ?: line
                val matcher = uberOrderCodePattern.matcher(targetStr)
                if (matcher.find()) {
                    val extracted = matcher.group()
                    if (extracted.any { it in 'A'..'Z' } || extracted.length <= 5) {
                        info.orderCode = extracted
                        val nameIdx = checkIdx - 1
                        if (nameIdx >= 0) {
                            val potentialName = cleanedLines[nameIdx]
                            if (isLikelyName(potentialName)) {
                                info.name = potentialName
                            }
                        }
                        return info
                    }
                }
            }
        }

        // 4. 備用規則（跟 iOS 一樣）：只看含「項」的那一行，例如「DAE30 · 1 項」
        for ((index, line) in cleanedLines.withIndex()) {
            if (uiKeywords.any { line.contains(it) }) continue
            if (line.contains("項")) {
                val targetStr = line.split(Regex("[・•·]")).firstOrNull() ?: line
                val matcher = uberOrderCodePattern.matcher(targetStr)
                if (matcher.find()) {
                    info.orderCode = matcher.group()
                    if (index - 1 >= 0 && isLikelyName(cleanedLines[index - 1])) {
                        info.name = cleanedLines[index - 1]
                    }
                    break
                }
            }
        }

        // 5. 熊貓備用：只讀到那個大方框「#8534」
        if (info.orderCode == null) {
            for (line in cleanedLines) {
                val m = pandaBoxPattern.matcher(line.replace(" ", ""))
                if (m.matches()) {
                    info.orderCode = "#" + m.group(1)
                    break
                }
            }
        }

        return info
    }

    // 金額：「$505.00」或「505.00」（一定要有 $ 或兩位小數，避免把電量、時間當成金額）
    private val collectMoneyPattern = Pattern.compile(
        "^(?:[\\$＄]\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)|([0-9][0-9,]*\\.[0-9]{2})|([0-9][0-9,]*(?:\\.[0-9]+)?)[\\$＄])$"
    )

    /** 「收取費用」畫面：許須支付下面那個大金額，就是要跟客人收的錢 */
    private fun detectCashCollect(lines: List<String>): DetectedInfo? {
        val isPandaCash = lines.any { it.contains("向消費者收取現金") } ||
                (lines.any { it.contains("付款方式") } && lines.any { it.contains("收取現金") })
        val isCollectScreen = isPandaCash ||
                lines.any { it.contains("收取費用") || it.contains("完成付款") }
        if (!isCollectScreen) return null

        val labelIdx = lines.indexOfFirst { it.contains("支付") || it.contains("須付") || it.contains("應付") }
        val start = if (labelIdx >= 0) labelIdx else 0
        // 熊貓畫面的金額離標題比較遠，整個畫面都找
        val scanLines = if (isPandaCash) lines else lines.drop(start).take(5)
        for (line in scanLines) {
            val m = collectMoneyPattern.matcher(line.replace(" ", ""))
            if (m.matches()) {
                val value = (m.group(1) ?: m.group(2) ?: m.group(3))?.replace(",", "")?.toDoubleOrNull()
                if (value != null && value > 0) {
                    return DetectedInfo(isCash = true, cashAmount = value)
                }
            }
        }
        return null
    }
    /** 判斷是不是「新來單」卡片；是的話回傳金額、時間、里程、是否現金 */
    private fun detectNewOffer(lines: List<String>): DetectedInfo? {
        val joined = lines.joinToString(" ")
        val hasButton = lines.any { it.contains("接受") || it.contains("配對") }
        val cash = joined.contains("現金")

        // ── Uber（一般單、採買、優物流、雷達單）──
        val totalMatcher = totalTimeKmPattern.matcher(joined)
        if (totalMatcher.find()) {
            var price: Double? = null
            for (line in lines) {
                val m = uberPricePattern.matcher(line)
                if (m.find()) {
                    price = m.group(1)?.replace(",", "")?.toDoubleOrNull()
                    break
                }
            }
            if (hasButton || price != null) {
                val hours = totalMatcher.group(1)?.toIntOrNull() ?: 0
                val mins = totalMatcher.group(2)?.toIntOrNull() ?: 0
                return DetectedInfo(
                    isNewOffer = true,
                    offerPlatform = if (lines.any { it.contains("雷達") }) "Uber雷達" else "Uber",
                    offerPrice = price,
                    offerMinutes = hours * 60 + mins,
                    offerKm = totalMatcher.group(3)?.toDoubleOrNull(),
                    isCash = cash
                )
            }
        } else if (joined.contains("總計") && joined.contains("公里") && hasButton) {
            // 數字沒讀乾淨，但看得出是來單卡片，還是要當成接單
            return DetectedInfo(isNewOffer = true, offerPlatform = "Uber", isCash = cash)
        }

        // ── 熊貓：「每單收入 93.92 $ (13.8 公里) 23 分鐘」＋「接受訂單」──
        val isPanda = joined.contains("每單收入") || lines.any { it.contains("接受訂單") }
        if (isPanda) {
            var price: Double? = null
            for (line in lines) {
                val m = pandaPricePattern.matcher(line)
                if (m.find()) {
                    price = m.group(1)?.replace(",", "")?.toDoubleOrNull()
                    break
                }
            }
            val kmMatcher = kmPattern.matcher(joined)
            val km = if (kmMatcher.find()) kmMatcher.group(1)?.toDoubleOrNull() else null
            val minMatcher = minutesPattern.matcher(joined)
            val minutes = if (minMatcher.find()) minMatcher.group(1)?.toIntOrNull() else null
            return DetectedInfo(
                isNewOffer = true,
                offerPlatform = "熊貓",
                offerPrice = price,
                offerMinutes = minutes,
                offerKm = km,
                isCash = cash
            )
        }
        return null
    }

    private fun isStandaloneOrderCode(str: String): Boolean {
        if (str.length !in 4..7) return false
        val containsLetter = str.any { it in 'A'..'Z' }
        val containsDigit = str.any { it.isDigit() }
        val allUpperOrDigit = str.all { (it in 'A'..'Z') || it.isDigit() }
        return allUpperOrDigit && (containsLetter || containsDigit) && !uiKeywords.contains(str)
    }

    private fun isLikelyName(str: String): Boolean {
        if (str.length !in 2..10) return false
        if (uiKeywords.any { str.contains(it) }) return false
        return true
    }
}

object OrderImageRecognizer {
    private val recognizer by lazy {
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }

    suspend fun recognize(bitmap: Bitmap): DetectedInfo = suspendCancellableCoroutine { cont ->
        val image = InputImage.fromBitmap(bitmap, 0)
        recognizer.process(image)
            .addOnSuccessListener { visionText ->
                val lines = visionText.textBlocks.flatMap { block -> block.lines.map { it.text } }
                val detected = OrderInfoDetector.detect(lines)
                cont.resume(detected)
            }
            .addOnFailureListener {
                cont.resume(DetectedInfo())
            }
    }
}