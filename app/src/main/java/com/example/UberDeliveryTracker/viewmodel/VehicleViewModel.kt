package com.example.UberDeliveryTracker.viewmodel

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import androidx.lifecycle.AndroidViewModel
import com.example.UberDeliveryTracker.model.ConsumableStatus
import com.example.UberDeliveryTracker.model.FuelRecord
import com.example.UberDeliveryTracker.model.MaintenanceItemCategory
import com.example.UberDeliveryTracker.model.MaintenanceRecord
import com.example.UberDeliveryTracker.model.ScooterType
import com.example.UberDeliveryTracker.model.Vehicle
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class VehicleViewModel(application: Application) : AndroidViewModel(application) {

    private val prefs: SharedPreferences =
        application.getSharedPreferences("vehicle_maintenance_prefs", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    private val KEY_VEHICLES = "SavedVehicles"
    private val KEY_SELECTED_VEHICLE_ID = "SavedSelectedVehicleId"
    private val KEY_MAINTENANCE_RECORDS = "SavedMaintenanceRecords"
    private val KEY_FUEL_RECORDS = "SavedFuelRecords"

    private val _vehicles = MutableStateFlow<List<Vehicle>>(emptyList())
    val vehicles: StateFlow<List<Vehicle>> = _vehicles.asStateFlow()

    private val _selectedVehicle = MutableStateFlow<Vehicle?>(null)
    val selectedVehicle: StateFlow<Vehicle?> = _selectedVehicle.asStateFlow()

    private val _maintenanceRecords = MutableStateFlow<List<MaintenanceRecord>>(emptyList())
    val maintenanceRecords: StateFlow<List<MaintenanceRecord>> = _maintenanceRecords.asStateFlow()

    private val _fuelRecords = MutableStateFlow<List<FuelRecord>>(emptyList())
    val fuelRecords: StateFlow<List<FuelRecord>> = _fuelRecords.asStateFlow()

    init {
        loadData()
    }

    private fun loadData() {
        val vehiclesJson = prefs.getString(KEY_VEHICLES, null)
        val list = if (!vehiclesJson.isNullOrEmpty()) {
            try {
                json.decodeFromString<List<Vehicle>>(vehiclesJson)
            } catch (e: Exception) {
                listOf(Vehicle(name = "我的外送機車", type = ScooterType.STANDARD))
            }
        } else {
            listOf(Vehicle(name = "我的外送機車", type = ScooterType.STANDARD))
        }
        _vehicles.value = list

        val savedId = prefs.getString(KEY_SELECTED_VEHICLE_ID, null)
        _selectedVehicle.value = list.firstOrNull { it.id == savedId } ?: list.firstOrNull()

        val mJson = prefs.getString(KEY_MAINTENANCE_RECORDS, null)
        if (!mJson.isNullOrEmpty()) {
            try {
                _maintenanceRecords.value = json.decodeFromString(mJson)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        val fJson = prefs.getString(KEY_FUEL_RECORDS, null)
        if (!fJson.isNullOrEmpty()) {
            try {
                _fuelRecords.value = json.decodeFromString(fJson)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    private fun saveData() {
        try {
            prefs.edit()
                .putString(KEY_VEHICLES, json.encodeToString(_vehicles.value))
                .putString(KEY_SELECTED_VEHICLE_ID, _selectedVehicle.value?.id)
                .putString(KEY_MAINTENANCE_RECORDS, json.encodeToString(_maintenanceRecords.value))
                .putString(KEY_FUEL_RECORDS, json.encodeToString(_fuelRecords.value))
                .apply()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    fun selectVehicle(vehicle: Vehicle) {
        _selectedVehicle.value = vehicle
        saveData()
    }

    fun addVehicle(name: String, type: ScooterType) {
        val newV = Vehicle(name = name, type = type)
        _vehicles.value = _vehicles.value + newV
        _selectedVehicle.value = newV
        saveData()
    }

    fun addMaintenanceRecord(
        odometer: Double,
        items: List<String>,
        cost: Double,
        isFree: Boolean,
        note: String,
        oilBrand: String
    ) {
        val vehicleId = _selectedVehicle.value?.id ?: return
        val record = MaintenanceRecord(
            vehicleId = vehicleId,
            odometer = odometer,
            selectedItems = items,
            totalCost = if (isFree) 0.0 else cost,
            isFree = isFree,
            note = note,
            oilBrand = oilBrand
        )
        _maintenanceRecords.value = listOf(record) + _maintenanceRecords.value
        saveData()
    }

    fun deleteMaintenanceRecord(id: String) {
        _maintenanceRecords.value = _maintenanceRecords.value.filter { it.id != id }
        saveData()
    }

    fun addFuelRecord(odometer: Double, liters: Double, amount: Double, fuelType: String, note: String) {
        val vehicleId = _selectedVehicle.value?.id ?: return
        val record = FuelRecord(
            vehicleId = vehicleId,
            odometer = odometer,
            liters = liters,
            amount = amount,
            fuelType = fuelType,
            note = note
        )
        _fuelRecords.value = listOf(record) + _fuelRecords.value
        saveData()
    }

    fun deleteFuelRecord(id: String) {
        _fuelRecords.value = _fuelRecords.value.filter { it.id != id }
        saveData()
    }

    /**
     * 當前最新總里程
     */
    fun getCurrentOdometer(): Double {
        val vehicleId = _selectedVehicle.value?.id ?: return 0.0
        val maxM = _maintenanceRecords.value.filter { it.vehicleId == vehicleId }.maxOfOrNull { it.odometer } ?: 0.0
        val maxF = _fuelRecords.value.filter { it.vehicleId == vehicleId }.maxOfOrNull { it.odometer } ?: 0.0
        return maxOf(maxM, maxF)
    }

    /**
     * 計算所有耗材的健康度與里程
     */
    fun getConsumableStatuses(): List<ConsumableStatus> {
        val currentOdo = getCurrentOdometer()
        val vehicle = _selectedVehicle.value ?: return emptyList()
        val records = _maintenanceRecords.value.filter { it.vehicleId == vehicle.id }

        return MaintenanceItemCategory.values().map { cat ->
            val interval = cat.recommendedInterval(vehicle.type)
            val lastRecord = records
                .filter { it.selectedItems.contains(cat.label) }
                .maxByOrNull { it.odometer }

            val lastOdo = lastRecord?.odometer ?: 0.0
            val driven = if (lastRecord != null) maxOf(0.0, currentOdo - lastOdo) else currentOdo
            val remaining = interval - driven
            val progress = (driven / interval).toFloat().coerceIn(0f, 1.5f)

            ConsumableStatus(
                category = cat,
                recommendedInterval = interval,
                lastServiceOdometer = lastOdo,
                drivenDistance = driven,
                remainingDistance = remaining,
                isDue = remaining <= 0,
                progress = progress
            )
        }
    }

    fun formatDate(millis: Long): String {
        val sdf = SimpleDateFormat("yyyy/MM/dd", Locale.getDefault())
        return sdf.format(Date(millis))
    }
}
