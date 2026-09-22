package com.khushi.conduit.link

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.ParcelUuid
import android.util.Log
import com.khushi.conduit.core.link.HotspotRequest
import java.io.ByteArrayOutputStream
import java.util.UUID

/**
 * Lets a paired Mac ask for this phone's hotspot over Bluetooth LE when it
 * has no network to reach the phone any other way — Shared/Protocol/README.md
 * §8a.
 *
 * The advert carries only Conduit's service UUID: no name, no device ID. The
 * characteristic takes writes and nothing else; what arrives is handed on as
 * bytes, and [HotspotRequestGate][com.khushi.conduit.core.link.HotspotRequestGate]
 * decides whether it is a real request from a paired Mac.
 */
class HotspotBeacon(private val context: Context, private val onRequest: (ByteArray) -> Unit) {

    private val manager = context.getSystemService(BluetoothManager::class.java)
    private var server: BluetoothGattServer? = null
    private var advertising = false
    /** A request longer than one write arrives as prepared writes, per device. */
    private val prepared = HashMap<String, ByteArrayOutputStream>()

    val canRun: Boolean
        get() = NEEDED.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } &&
            manager?.adapter?.isEnabled == true

    @Synchronized
    fun start() {
        if (advertising || !canRun) return
        try {
            server = manager.openGattServer(context, callback)?.also { gatt ->
                gatt.addService(
                    BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY).apply {
                        addCharacteristic(
                            BluetoothGattCharacteristic(
                                CHARACTERISTIC,
                                BluetoothGattCharacteristic.PROPERTY_WRITE,
                                BluetoothGattCharacteristic.PERMISSION_WRITE,
                            ),
                        )
                    },
                )
            }
            manager.adapter.bluetoothLeAdvertiser?.startAdvertising(
                AdvertiseSettings.Builder()
                    .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
                    .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                    .setConnectable(true)
                    .build(),
                AdvertiseData.Builder()
                    .setIncludeDeviceName(false)
                    .addServiceUuid(ParcelUuid(SERVICE))
                    .build(),
                advertiseCallback,
            )
            advertising = true
            Log.i(TAG, "a paired Mac can ask for the hotspot")
        } catch (error: SecurityException) {
            Log.w(TAG, "Bluetooth permission missing", error)
            stop()
        }
    }

    @Synchronized
    fun stop() {
        try {
            if (advertising) manager?.adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
            server?.close()
        } catch (_: SecurityException) {
        }
        server = null
        advertising = false
        prepared.clear()
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            Log.w(TAG, "could not advertise for hotspot requests: $errorCode")
            synchronized(this@HotspotBeacon) { advertising = false }
        }
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            val bytes = value ?: ByteArray(0)
            val accepted = characteristic.uuid == CHARACTERISTIC && bytes.size <= MAX_REQUEST
            if (accepted && preparedWrite) {
                val buffer = synchronized(prepared) { prepared.getOrPut(device.address) { ByteArrayOutputStream() } }
                if (buffer.size() == offset && buffer.size() + bytes.size <= MAX_REQUEST) buffer.write(bytes)
            } else if (accepted && offset == 0) {
                onRequest(bytes)
            }
            respond(device, requestId, responseNeeded, offset, bytes)
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            val buffer = synchronized(prepared) { prepared.remove(device.address) }
            if (execute && buffer != null) onRequest(buffer.toByteArray())
            respond(device, requestId, true, 0, null)
        }
    }

    private fun respond(device: BluetoothDevice, requestId: Int, needed: Boolean, offset: Int, value: ByteArray?) {
        if (!needed) return
        try {
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
        } catch (_: SecurityException) {
        }
    }

    companion object {
        private const val TAG = "ConduitHotspot"
        private val SERVICE: UUID = UUID.fromString(HotspotRequest.SERVICE_UUID)
        private val CHARACTERISTIC: UUID = UUID.fromString(HotspotRequest.CHARACTERISTIC_UUID)
        /** A request is 127 bytes; anything much larger is not one. */
        private const val MAX_REQUEST = 512

        /** Android's "Nearby devices" permissions. */
        val NEEDED = arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
    }
}
