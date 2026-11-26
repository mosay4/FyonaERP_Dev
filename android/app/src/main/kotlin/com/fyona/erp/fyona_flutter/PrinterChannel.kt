package com.fyona.erp.fyona_flutter

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * FYONA Print Center — native transports (channel `com.fyona.erp/printer`):
 * Bluetooth classic (SPP), Bluetooth Low Energy (GATT write) and USB host
 * (bulk). Methods: scan / connect / write / read / disconnect, each with a
 * `transport` of "bt" | "ble" | "usb". Everything runs on one worker
 * thread (ordered, never on the UI thread); replies come back on the main
 * thread. No new permission is needed: Bluetooth uses the existing
 * BLUETOOTH_SCAN / BLUETOOTH_CONNECT grants, USB asks the user per device.
 */
@SuppressLint("MissingPermission")
class PrinterChannel(private val context: Context) {

    companion object {
        const val NAME = "com.fyona.erp/printer"
        private val SPP: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

        /** GATT services receipt printers expose for data. */
        private val BLE_PRINT_SERVICES = listOf(
            "000018f0-0000-1000-8000-00805f9b34fb",
            "e7810a71-73ae-499d-8c15-faa9aef0c3f2",
            "49535343-fe7d-4ae5-8fa9-9fafd205e455",
            "0000ff00-0000-1000-8000-00805f9b34fb",
            "0000ffe0-0000-1000-8000-00805f9b34fb",
            "0000fee7-0000-1000-8000-00805f9b34fb",
        ).map { UUID.fromString(it) }

        private const val USB_PERMISSION = "com.fyona.erp.USB_PRINTER_PERMISSION"

        fun register(context: Context, messenger: BinaryMessenger): PrinterChannel {
            val channel = PrinterChannel(context.applicationContext)
            MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
                channel.handle(call.method, call.arguments as? Map<*, *> ?: emptyMap<String, Any>(), result)
            }
            return channel
        }
    }

    private val worker = Executors.newSingleThreadExecutor()

    /** Scans run apart from the I/O worker: a 6-8 s search never delays a
     *  job, and Bluetooth classic / BLE / USB scans run side by side. */
    private val scanner = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    private fun ok(result: MethodChannel.Result, value: Any?) = main.post { result.success(value) }
    private fun fail(result: MethodChannel.Result, code: String, message: String) =
        main.post { result.error(code, message, null) }

    fun handle(method: String, args: Map<*, *>, result: MethodChannel.Result) {
        val transport = args["transport"] as? String ?: "bt"
        (if (method == "scan") scanner else worker).execute {
            try {
                when (method) {
                    "scan" -> ok(result, scan(transport, (args["timeoutMs"] as? Number)?.toLong() ?: 6000L))
                    "connect" -> ok(result, connect(transport, args["address"] as? String ?: ""))
                    "write" -> {
                        write(transport, args["bytes"] as? ByteArray ?: ByteArray(0))
                        ok(result, true)
                    }
                    "read" -> ok(result, read(transport, (args["timeoutMs"] as? Number)?.toLong() ?: 600L))
                    "disconnect" -> {
                        disconnect(transport)
                        ok(result, true)
                    }
                    else -> main.post { result.notImplemented() }
                }
            } catch (e: SecurityException) {
                fail(result, "permission", e.message ?: "permission")
            } catch (e: PrinterError) {
                fail(result, e.code, e.message ?: e.code)
            } catch (e: Exception) {
                fail(result, if (method == "write") "write" else "connect", e.message ?: method)
            }
        }
    }

    class PrinterError(val code: String, message: String) : Exception(message)

    private fun adapter(): BluetoothAdapter? = try {
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    } catch (_: Exception) { null }

    // ── Scan ──
    private fun scan(transport: String, timeoutMs: Long): List<Map<String, Any?>> = when (transport) {
        "bt" -> scanClassic(timeoutMs)
        "ble" -> scanBle(timeoutMs)
        "usb" -> scanUsb()
        else -> emptyList()
    }

    private fun scanClassic(timeoutMs: Long): List<Map<String, Any?>> {
        val a = adapter() ?: return emptyList()
        if (!a.isEnabled) return emptyList()
        val found = LinkedHashMap<String, Map<String, Any?>>()
        for (d in a.bondedDevices ?: emptySet()) {
            found[d.address] = mapOf("name" to d.name, "address" to d.address, "paired" to true)
        }
        // Nearby, not yet paired: imaging-class devices (printers).
        val done = CountDownLatch(1)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                when (intent?.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        val d: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33)
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                        else @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        if (d != null && !found.containsKey(d.address)) {
                            val major = d.bluetoothClass?.majorDeviceClass
                            if (major == BluetoothClass.Device.Major.IMAGING ||
                                major == BluetoothClass.Device.Major.UNCATEGORIZED) {
                                found[d.address] = mapOf("name" to d.name, "address" to d.address, "paired" to false)
                            }
                        }
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> done.countDown()
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                context.registerReceiver(receiver, filter)
            }
            if (a.startDiscovery()) done.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: Exception) {
        } finally {
            try { a.cancelDiscovery() } catch (_: Exception) {}
            try { context.unregisterReceiver(receiver) } catch (_: Exception) {}
        }
        return found.values.toList()
    }

    private fun scanBle(timeoutMs: Long): List<Map<String, Any?>> {
        val a = adapter() ?: return emptyList()
        if (!a.isEnabled) return emptyList()
        val scanner = a.bluetoothLeScanner ?: return emptyList()
        val found = LinkedHashMap<String, Map<String, Any?>>()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, r: ScanResult) {
                val name = r.scanRecord?.deviceName ?: r.device.name
                val uuids = r.scanRecord?.serviceUuids?.map { it.uuid } ?: emptyList()
                val printer = uuids.any { it in BLE_PRINT_SERVICES } ||
                    (name != null && Regex("(?i)print|pos|mpt|ptp|rpp|xp-|mtp|thermal|receipt").containsMatchIn(name))
                if (printer) found[r.device.address] = mapOf("name" to name, "address" to r.device.address)
            }
        }
        try {
            val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
            scanner.startScan(null, settings, cb)
            Thread.sleep(timeoutMs.coerceAtMost(8000L))
        } catch (_: Exception) {
        } finally {
            try { scanner.stopScan(cb) } catch (_: Exception) {}
        }
        return found.values.toList()
    }

    private fun usbManager() = context.getSystemService(Context.USB_SERVICE) as? UsbManager

    /** A printer-class interface, or a vendor one with a bulk OUT endpoint. */
    private fun printerInterface(d: UsbDevice): Triple<UsbInterface, UsbEndpoint, UsbEndpoint?>? {
        for (i in 0 until d.interfaceCount) {
            val itf = d.getInterface(i)
            if (itf.interfaceClass != UsbConstants.USB_CLASS_PRINTER &&
                itf.interfaceClass != UsbConstants.USB_CLASS_VENDOR_SPEC) continue
            var out: UsbEndpoint? = null
            var inp: UsbEndpoint? = null
            for (e in 0 until itf.endpointCount) {
                val ep = itf.getEndpoint(e)
                if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                if (ep.direction == UsbConstants.USB_DIR_OUT) out = ep else inp = ep
            }
            if (out != null) return Triple(itf, out, inp)
        }
        return null
    }

    private fun scanUsb(): List<Map<String, Any?>> {
        val m = usbManager() ?: return emptyList()
        return m.deviceList.values.filter { printerInterface(it) != null }.map { d ->
            mapOf(
                "name" to (d.productName ?: d.manufacturerName ?: "USB printer"),
                "address" to d.deviceName,
            )
        }
    }

    // ── Connect / write / read ──
    private var btSocket: BluetoothSocket? = null
    private var btOut: OutputStream? = null
    private var btIn: InputStream? = null
    private var gatt: BluetoothGatt? = null
    private var gattWrite: BluetoothGattCharacteristic? = null
    @Volatile private var gattWriteDone: CountDownLatch? = null
    @Volatile private var mtu = 23
    private var usbConn: UsbDeviceConnection? = null
    private var usbOut: UsbEndpoint? = null
    private var usbIn: UsbEndpoint? = null
    private var usbItf: UsbInterface? = null

    private fun connect(transport: String, address: String): Boolean {
        if (address.isEmpty()) throw PrinterError("connect", "address")
        return when (transport) {
            "bt" -> connectClassic(address)
            "ble" -> connectBle(address)
            "usb" -> connectUsb(address)
            else -> false
        }
    }

    private fun connectClassic(address: String): Boolean {
        val a = adapter() ?: throw PrinterError("unsupported", "bluetooth")
        if (!a.isEnabled) throw PrinterError("connect", "bluetooth off")
        disconnect("bt")
        try { a.cancelDiscovery() } catch (_: Exception) {}
        val d = a.getRemoteDevice(address)
        val socket = try {
            d.createRfcommSocketToServiceRecord(SPP).also { it.connect() }
        } catch (first: Exception) {
            // Some cheap printers only answer the insecure channel.
            d.createInsecureRfcommSocketToServiceRecord(SPP).also { it.connect() }
        }
        btSocket = socket
        btOut = socket.outputStream
        btIn = socket.inputStream
        return true
    }

    private val gattCallback = object : BluetoothGattCallback() {
        var connected: CountDownLatch? = null
        var discovered: CountDownLatch? = null
        var mtuSet: CountDownLatch? = null

        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) connected?.countDown()
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                gattWrite = null
                gattWriteDone?.countDown()
            }
        }
        override fun onMtuChanged(g: BluetoothGatt, value: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) mtu = value
            mtuSet?.countDown()
        }
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) { discovered?.countDown() }
        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            gattWriteDone?.countDown()
        }
    }

    private fun connectBle(address: String): Boolean {
        val a = adapter() ?: throw PrinterError("unsupported", "bluetooth")
        disconnect("ble")
        val d = a.getRemoteDevice(address)
        gattCallback.connected = CountDownLatch(1)
        val g = d.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            ?: throw PrinterError("connect", "gatt")
        gatt = g
        if (!gattCallback.connected!!.await(10, TimeUnit.SECONDS)) {
            disconnect("ble"); throw PrinterError("connect", "timeout")
        }
        gattCallback.mtuSet = CountDownLatch(1)
        if (g.requestMtu(247)) gattCallback.mtuSet!!.await(3, TimeUnit.SECONDS)
        gattCallback.discovered = CountDownLatch(1)
        g.discoverServices()
        if (!gattCallback.discovered!!.await(10, TimeUnit.SECONDS)) {
            disconnect("ble"); throw PrinterError("connect", "services")
        }
        val writable = { c: BluetoothGattCharacteristic ->
            (c.properties and (BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE)) != 0
        }
        val known = g.services.filter { it.uuid in BLE_PRINT_SERVICES }
        val c = (known + g.services).asSequence().flatMap { it.characteristics.asSequence() }
            .firstOrNull(writable)
        if (c == null) { disconnect("ble"); throw PrinterError("unsupported", "no writable characteristic") }
        gattWrite = c
        return true
    }

    private fun connectUsb(name: String): Boolean {
        val m = usbManager() ?: throw PrinterError("unsupported", "usb")
        val d = m.deviceList[name] ?: throw PrinterError("connect", "not attached")
        if (!m.hasPermission(d)) {
            val granted = CountDownLatch(1)
            var ok = false
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, i: Intent?) {
                    ok = i?.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) == true
                    granted.countDown()
                }
            }
            val filter = IntentFilter(USB_PERMISSION)
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(receiver, filter)
            }
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            val pi = PendingIntent.getBroadcast(context, 0,
                Intent(USB_PERMISSION).setPackage(context.packageName), flags)
            m.requestPermission(d, pi)
            granted.await(60, TimeUnit.SECONDS)
            try { context.unregisterReceiver(receiver) } catch (_: Exception) {}
            if (!ok) throw PrinterError("permission", "usb permission denied")
        }
        disconnect("usb")
        val (itf, out, inp) = printerInterface(d) ?: throw PrinterError("unsupported", "no printer interface")
        val conn = m.openDevice(d) ?: throw PrinterError("connect", "open")
        if (!conn.claimInterface(itf, true)) { conn.close(); throw PrinterError("connect", "claim") }
        usbConn = conn; usbOut = out; usbIn = inp; usbItf = itf
        return true
    }

    private fun write(transport: String, bytes: ByteArray) {
        when (transport) {
            "bt" -> {
                val out = btOut ?: throw PrinterError("lost", "not connected")
                out.write(bytes); out.flush()
            }
            "ble" -> writeBle(bytes)
            "usb" -> {
                val c = usbConn ?: throw PrinterError("lost", "not connected")
                val ep = usbOut ?: throw PrinterError("lost", "not connected")
                var off = 0
                while (off < bytes.size) {
                    val n = minOf(16384, bytes.size - off)
                    val w = c.bulkTransfer(ep, bytes, off, n, 8000)
                    if (w <= 0) throw PrinterError("write", "usb transfer failed")
                    off += w
                }
            }
        }
    }

    private fun writeBle(bytes: ByteArray) {
        val g = gatt ?: throw PrinterError("lost", "not connected")
        val c = gattWrite ?: throw PrinterError("lost", "not connected")
        val noResponse = (c.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
        val type = if (noResponse) BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                   else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        val size = (mtu - 3).coerceIn(20, 512)
        var off = 0
        while (off < bytes.size) {
            val part = bytes.copyOfRange(off, minOf(off + size, bytes.size))
            val done = CountDownLatch(1)
            gattWriteDone = done
            val started = if (Build.VERSION.SDK_INT >= 33) {
                g.writeCharacteristic(c, part, type) == BluetoothGatt.GATT_SUCCESS
            } else {
                @Suppress("DEPRECATION")
                c.writeType = type
                @Suppress("DEPRECATION")
                c.value = part
                @Suppress("DEPRECATION")
                g.writeCharacteristic(c)
            }
            if (!started) {
                // The stack is busy: wait a moment and retry the same slice.
                Thread.sleep(15)
                continue
            }
            // Callback = the stack took the slice (also for no-response).
            if (!done.await(5, TimeUnit.SECONDS)) throw PrinterError("write", "ble timeout")
            if (gattWrite == null) throw PrinterError("lost", "ble disconnected")
            off += part.size
        }
    }

    private fun read(transport: String, timeoutMs: Long): ByteArray? {
        val deadline = System.currentTimeMillis() + timeoutMs
        when (transport) {
            "bt" -> {
                val inp = btIn ?: return null
                while (System.currentTimeMillis() < deadline) {
                    val n = try { inp.available() } catch (_: Exception) { 0 }
                    if (n > 0) {
                        Thread.sleep(30)
                        val buf = ByteArray(inp.available().coerceAtLeast(n))
                        val r = inp.read(buf)
                        return if (r > 0) buf.copyOf(r) else null
                    }
                    Thread.sleep(20)
                }
                return null
            }
            "usb" -> {
                val c = usbConn ?: return null
                val ep = usbIn ?: return null
                val buf = ByteArray(64)
                val r = c.bulkTransfer(ep, buf, buf.size, timeoutMs.toInt().coerceAtLeast(1))
                return if (r > 0) buf.copyOf(r) else null
            }
        }
        return null
    }

    private fun disconnect(transport: String) {
        when (transport) {
            "bt" -> {
                try { btOut?.close() } catch (_: Exception) {}
                try { btIn?.close() } catch (_: Exception) {}
                try { btSocket?.close() } catch (_: Exception) {}
                btOut = null; btIn = null; btSocket = null
            }
            "ble" -> {
                try { gatt?.disconnect() } catch (_: Exception) {}
                try { gatt?.close() } catch (_: Exception) {}
                gatt = null; gattWrite = null; mtu = 23
            }
            "usb" -> {
                try { usbItf?.let { usbConn?.releaseInterface(it) } } catch (_: Exception) {}
                try { usbConn?.close() } catch (_: Exception) {}
                usbConn = null; usbOut = null; usbIn = null; usbItf = null
            }
        }
    }
}
