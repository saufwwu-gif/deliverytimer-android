package com.example.UberDeliveryTracker.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** 一條線：名字、顏色、每個日期的數值（沒資料就放 null，線會在那裡斷開） */
data class ChartSeries(
    val name: String,
    val color: Color,
    val values: List<Double?>
)

/** 一條橫的參考虛線（例如旺季門檻 1.4） */
data class ChartRule(
    val value: Double,
    val color: Color
)

/**
 * 自己畫的折線圖（Android 沒有現成的）。
 * labels 是底下的日期文字，每條線的 values 數量要跟 labels 一樣多。
 * startAtZero = true 時，縱軸從 0 開始（金額用）；疊單率之後可以設 false。
 */
@Composable
fun SimpleLineChart(
    labels: List<String>,
    series: List<ChartSeries>,
    modifier: Modifier = Modifier,
    chartHeight: Dp = 220.dp,
    startAtZero: Boolean = true,
    rules: List<ChartRule> = emptyList(),
    valueFormat: (Double) -> String = { "%.0f".format(it) }
) {
    val allValues = series.flatMap { it.values.filterNotNull() } + rules.map { it.value }

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        if (labels.isEmpty() || allValues.isEmpty()) {
            Text("目前沒有資料可畫圖", fontSize = 12.sp, color = Color.Gray)
            return@Column
        }

        val rawMin = allValues.minOrNull() ?: 0.0
        val rawMax = allValues.maxOrNull() ?: 1.0
        val span0 = rawMax - rawMin
        val yMin = if (startAtZero) minOf(0.0, rawMin)
        else rawMin - (if (span0 > 0) span0 * 0.1 else 1.0)
        val yMax = if (rawMax > yMin) rawMax + (rawMax - yMin) * 0.1 else yMin + 1.0

        Canvas(
            modifier = Modifier
                .fillMaxWidth()
                .height(chartHeight)
        ) {
            val leftPad = 46.dp.toPx()
            val rightPad = 10.dp.toPx()
            val topPad = 8.dp.toPx()
            val bottomPad = 22.dp.toPx()
            val w = size.width - leftPad - rightPad
            val h = size.height - topPad - bottomPad
            val n = labels.size

            fun xAt(i: Int): Float =
                if (n == 1) leftPad + w / 2f else leftPad + w * i / (n - 1)

            fun yAt(v: Double): Float =
                topPad + h - ((v - yMin) / (yMax - yMin)).toFloat() * h

            val axisPaint = android.graphics.Paint().apply {
                isAntiAlias = true
                textSize = 10.sp.toPx()
                color = android.graphics.Color.GRAY
                textAlign = android.graphics.Paint.Align.RIGHT
            }
            val labelPaint = android.graphics.Paint().apply {
                isAntiAlias = true
                textSize = 10.sp.toPx()
                color = android.graphics.Color.GRAY
                textAlign = android.graphics.Paint.Align.CENTER
            }

            // 橫的格線與左邊數字
            for (k in 0..4) {
                val v = yMin + (yMax - yMin) * k / 4.0
                val y = yAt(v)
                drawLine(
                    color = Color.LightGray.copy(alpha = 0.5f),
                    start = Offset(leftPad, y),
                    end = Offset(size.width - rightPad, y),
                    strokeWidth = 1.dp.toPx()
                )
                drawIntoCanvas {
                    it.nativeCanvas.drawText(valueFormat(v), leftPad - 4.dp.toPx(), y + 4.dp.toPx(), axisPaint)
                }
            }

            // 底下的日期文字（太擠就隔幾個顯示一個）
            val stepN = Math.ceil(n / 7.0).toInt().coerceAtLeast(1)
            for (i in 0 until n step stepN) {
                drawIntoCanvas {
                    it.nativeCanvas.drawText(labels[i], xAt(i), size.height - 4.dp.toPx(), labelPaint)
                }
            }

            // 參考虛線
            rules.forEach { r ->
                val y = yAt(r.value)
                drawLine(
                    color = r.color,
                    start = Offset(leftPad, y),
                    end = Offset(size.width - rightPad, y),
                    strokeWidth = 1.dp.toPx(),
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 8f))
                )
            }

            // 每條線
            series.forEach { s ->
                val path = Path()
                var penDown = false
                s.values.forEachIndexed { i, v ->
                    if (v == null) {
                        penDown = false
                    } else {
                        val x = xAt(i)
                        val y = yAt(v)
                        if (!penDown) {
                            path.moveTo(x, y)
                            penDown = true
                        } else {
                            path.lineTo(x, y)
                        }
                    }
                }
                drawPath(path = path, color = s.color, style = Stroke(width = 2.5.dp.toPx()))
                s.values.forEachIndexed { i, v ->
                    if (v != null) {
                        drawCircle(color = s.color, radius = 3.5.dp.toPx(), center = Offset(xAt(i), yAt(v)))
                    }
                }
            }
        }

        // 圖例
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            series.forEach { s ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    androidx.compose.foundation.layout.Box(
                        modifier = Modifier
                            .size(8.dp)
                            .background(s.color, CircleShape)
                    )
                    androidx.compose.foundation.layout.Spacer(modifier = Modifier.size(4.dp))
                    Text(s.name, fontSize = 11.sp, color = s.color)
                }
            }
        }
    }
}
