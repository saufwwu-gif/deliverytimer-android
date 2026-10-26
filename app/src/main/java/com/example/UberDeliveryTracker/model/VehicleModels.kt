package com.example.UberDeliveryTracker.model

import kotlinx.serialization.Serializable
import java.util.Date
import java.util.UUID

@Serializable
enum class ScooterType(val label: String) {
    STANDARD("一般白牌速可達"),
    HEAVY("黃紅牌重機 / 檔車")
}

@Serializable
data class Vehicle(
    val id: String = UUID.randomUUID().toString(),
    var name: String,
    var type: ScooterType = ScooterType.STANDARD
)

@Serializable
enum class MaintenanceItemCategory(val label: String) {
    ENGINE_OIL("機油"),
    GEAR_OIL("齒輪油"),
    AIR_FILTER("空濾 (空氣濾清器)"),
    SPARK_PLUG("火星塞"),
    TRANSMISSION("傳動小組"),
    BELT("傳動皮帶"),
    BRAKE("煞車皮 / 煞車油"),
    TIRES("前後輪胎"),
    COOLANT("水冷液 / 節氣門"),
    CUSTOM("其他");

    fun recommendedInterval(type: ScooterType): Double {
        return when (this) {
            ENGINE_OIL -> if (type == ScooterType.STANDARD) 1000.0 else 3000.0
            GEAR_OIL -> if (type == ScooterType.STANDARD) 2000.0 else 5000.0
            AIR_FILTER -> 5000.0
            SPARK_PLUG -> 10000.0
            TRANSMISSION, BELT -> 15000.0
            BRAKE, TIRES -> 10000.0
            COOLANT -> 15000.0
            CUSTOM -> 5000.0
        }
    }
}

@Serializable
data class MaintenanceRecord(
    val id: String = UUID.randomUUID().toString(),
    val vehicleId: String,
    val timestampMillis: Long = System.currentTimeMillis(),
    var odometer: Double,
    var selectedItems: List<String>,
    var totalCost: Double,
    var isFree: Boolean = false,
    var note: String = "",
    var oilBrand: String = ""
) {
    val date: Date get() = Date(timestampMillis)
}

@Serializable
data class FuelRecord(
    val id: String = UUID.randomUUID().toString(),
    val vehicleId: String,
    val timestampMillis: Long = System.currentTimeMillis(),
    var odometer: Double,
    var liters: Double,
    var amount: Double,
    var fuelType: String = "92無鉛",
    var note: String = ""
) {
    val date: Date get() = Date(timestampMillis)
}

data class ConsumableStatus(
    val category: MaintenanceItemCategory,
    val recommendedInterval: Double,
    val lastServiceOdometer: Double,
    val drivenDistance: Double,
    val remainingDistance: Double,
    val isDue: Boolean,
    val progress: Float // 0.0 ~ 1.0 (超過1.0表示超期)
)
