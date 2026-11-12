package com.example.omni_drop

import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private var startupPermissionResult: MethodChannel.Result? = null
    private var pendingStoragePickerResult: MethodChannel.Result? = null
    private val storagePickerRequest = 9215
    private var wifiP2pManager: WifiP2pManager? = null
    private var wifiP2pChannel: WifiP2pManager.Channel? = null

    override fun onPause() {
        if (!isChangingConfigurations &&
            getSharedPreferences("omnidrop_runtime", MODE_PRIVATE).getBoolean("visible", true)) {
            val intent = Intent(this, OmniDropBackgroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
            else startService(intent)
        }
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        stopService(Intent(this, OmniDropBackgroundService::class.java))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.omnidrop/direct_radio")
            .setMethodCallHandler { call, result ->
                if (call.method == "requestStartupPermissions") {
                    requestStartupPermissions(result)
                    return@setMethodCallHandler
                }
                if (call.method == "setVisibility") {
                    val visible = call.argument<Boolean>("visible") ?: true
                    getSharedPreferences("omnidrop_runtime", MODE_PRIVATE)
                        .edit().putBoolean("visible", visible).apply()
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (call.method == "updateTransferNotification") {
                    val active = call.argument<Boolean>("active") ?: true
                    val title = call.argument<String>("title") ?: "OmniDrop transfer"
                    val text = call.argument<String>("text") ?: "Transferring files"
                    val progress = call.argument<Int>("progress") ?: -1
                    getSharedPreferences("omnidrop_runtime", MODE_PRIVATE).edit()
                        .putBoolean("transfer_notification_active", active)
                        .putString("transfer_notification_title", title)
                        .putString("transfer_notification_text", text)
                        .putInt("transfer_notification_progress", progress)
                        .apply()
                    val intent = Intent(this, OmniDropBackgroundService::class.java)
                        .putExtra(OmniDropBackgroundService.EXTRA_ACTIVE, active)
                        .putExtra(OmniDropBackgroundService.EXTRA_TITLE, title)
                        .putExtra(OmniDropBackgroundService.EXTRA_TEXT, text)
                        .putExtra(OmniDropBackgroundService.EXTRA_PROGRESS, progress)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                    else startService(intent)
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (call.method == "pickStorageDirectory") {
                    if (pendingStoragePickerResult != null) {
                        result.error("PICKER_BUSY", "A storage picker is already open.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        pendingStoragePickerResult = result
                        val picker = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        }
                        startActivityForResult(picker, storagePickerRequest)
                    } catch (error: Exception) {
                        pendingStoragePickerResult = null
                        result.error("PICKER_FAILED", error.message ?: "Could not open storage picker.", null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "listStorageDirectory") {
                    try {
                        val treeUri = android.net.Uri.parse(call.argument<String>("treeUri")
                            ?: throw IllegalArgumentException("Storage folder is missing."))
                        val documentId = call.argument<String>("documentId")
                            ?: android.provider.DocumentsContract.getTreeDocumentId(treeUri)
                        val childrenUri = android.provider.DocumentsContract
                            .buildChildDocumentsUriUsingTree(treeUri, documentId)
                        val columns = arrayOf(
                            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                            android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE,
                            android.provider.DocumentsContract.Document.COLUMN_SIZE,
                            android.provider.DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                        )
                        val entries = mutableListOf<Map<String, Any?>>()
                        contentResolver.query(childrenUri, columns, null, null, null)?.use { cursor ->
                            while (cursor.moveToNext()) {
                                val id = cursor.getString(0) ?: continue
                                val uri = android.provider.DocumentsContract
                                    .buildDocumentUriUsingTree(treeUri, id)
                                entries.add(mapOf(
                                    "id" to id,
                                    "uri" to uri.toString(),
                                    "name" to (cursor.getString(1) ?: "Unnamed"),
                                    "isDirectory" to (cursor.getString(2) == android.provider.DocumentsContract.Document.MIME_TYPE_DIR),
                                    "size" to if (cursor.isNull(3)) 0L else cursor.getLong(3),
                                    "modified" to if (cursor.isNull(4)) 0L else cursor.getLong(4),
                                ))
                            }
                        }
                        result.success(entries)
                    } catch (error: Exception) {
                        result.error("STORAGE_LIST_FAILED", error.message ?: "Could not read this folder.", null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "deleteStorageDocument") {
                    try {
                        val uri = android.net.Uri.parse(call.argument<String>("uri")
                            ?: throw IllegalArgumentException("File is missing."))
                        result.success(android.provider.DocumentsContract.deleteDocument(contentResolver, uri))
                    } catch (error: Exception) {
                        result.error("STORAGE_DELETE_FAILED", error.message ?: "Could not delete this item.", null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "openStorageDocument") {
                    try {
                        val uri = android.net.Uri.parse(call.argument<String>("uri")
                            ?: throw IllegalArgumentException("File is missing."))
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, contentResolver.getType(uri) ?: "*/*")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(intent)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("STORAGE_OPEN_FAILED", error.message ?: "No app can open this file.", null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "startDirectGroup") {
                    startDirectGroup(result)
                    return@setMethodCallHandler
                }
                if (call.method == "stopDirectGroup") {
                    stopDirectGroup(result)
                    return@setMethodCallHandler
                }
                if (call.method == "getDefaultDownloadFolder") {
                    val folder = java.io.File(
                        android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS),
                        "OmniDrop",
                    )
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        val marker = android.content.ContentValues().apply {
                            put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, ".omnidrop-folder-init")
                            put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
                            put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, "Download/OmniDrop")
                            put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
                        }
                        val uri = contentResolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, marker)
                            ?: throw java.io.IOException("Android could not prepare Downloads/OmniDrop.")
                        contentResolver.delete(uri, null, null)
                    } else if (!folder.exists() && !folder.mkdirs()) {
                        throw java.io.IOException("Could not create Downloads/OmniDrop.")
                    }
                    result.success(folder.absolutePath)
                    return@setMethodCallHandler
                }
                if (call.method == "publishReceivedFile") {
                    try {
                        val sourcePath = call.argument<String>("sourcePath")
                            ?: throw IllegalArgumentException("Missing source file")
                        val requestedName = call.argument<String>("fileName")
                            ?: throw IllegalArgumentException("Missing file name")
                        result.success(publishReceivedFile(sourcePath, requestedName))
                    } catch (error: Exception) {
                        result.error("DOWNLOAD_SAVE_FAILED", error.message ?: "Could not save received file.", null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "publishedFileExists") {
                    try {
                        val uri = android.net.Uri.parse(call.argument<String>("uri") ?: "")
                        result.success(contentResolver.query(uri, arrayOf("_id"), null, null, null)?.use { it.moveToFirst() } ?: false)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "getNetworkBand") {
                    result.success(getNetworkBand())
                    return@setMethodCallHandler
                }
                if (call.method != "getCapabilities") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                result.success(getDirectRadioCapabilities())
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.omnidrop/secure_store")
            .setMethodCallHandler { call, result ->
                try {
                    val key = call.argument<String>("key")
                    if (key.isNullOrBlank() || !key.matches(Regex("[a-zA-Z0-9_-]{1,128}"))) {
                        result.error("INVALID_KEY", "Invalid secure storage key.", null)
                        return@setMethodCallHandler
                    }
                    val preferences = getSharedPreferences("omnidrop_secure_values", MODE_PRIVATE)
                    when (call.method) {
                        "write" -> {
                            val value = call.argument<String>("value") ?: throw IllegalArgumentException("Missing value")
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateStoreKey())
                            val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
                            val iv = cipher.iv
                            val envelope = ByteArray(iv.size + ciphertext.size)
                            System.arraycopy(iv, 0, envelope, 0, iv.size)
                            System.arraycopy(ciphertext, 0, envelope, iv.size, ciphertext.size)
                            preferences.edit().putString(key, Base64.encodeToString(envelope, Base64.NO_WRAP)).apply()
                            result.success(null)
                        }
                        "read" -> {
                            val stored = preferences.getString(key, null)
                            if (stored == null) {
                                result.success(null)
                            } else {
                                val envelope = Base64.decode(stored, Base64.NO_WRAP)
                                require(envelope.size > 12) { "Encrypted value is malformed." }
                                val iv = envelope.copyOfRange(0, 12)
                                val ciphertext = envelope.copyOfRange(12, envelope.size)
                                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                                cipher.init(Cipher.DECRYPT_MODE, getOrCreateStoreKey(), GCMParameterSpec(128, iv))
                                result.success(String(cipher.doFinal(ciphertext), Charsets.UTF_8))
                            }
                        }
                        "delete" -> {
                            preferences.edit().remove(key).apply()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("SECURE_STORE_FAILED", error.message ?: "Secure storage failed.", null)
                }
            }
    }

    @Deprecated("Retained for the Android document tree picker callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != storagePickerRequest) return
        val callback = pendingStoragePickerResult ?: return
        pendingStoragePickerResult = null
        val uri = if (resultCode == RESULT_OK) data?.data else null
        if (uri == null) {
            callback.success(null)
            return
        }
        try {
            val read = data?.flags?.and(Intent.FLAG_GRANT_READ_URI_PERMISSION) ?: 0
            val write = data?.flags?.and(Intent.FLAG_GRANT_WRITE_URI_PERMISSION) ?: 0
            contentResolver.takePersistableUriPermission(uri, read or write)
            callback.success(uri.toString())
        } catch (error: Exception) {
            callback.error("STORAGE_PERMISSION_FAILED", error.message ?: "Could not keep access to this folder.", null)
        }
    }

    @Suppress("DEPRECATION")
    private fun startDirectGroup(result: MethodChannel.Result) {
        try {
            startDirectGroupInternal(result)
        } catch (error: Exception) {
            result.success(mapOf(
                "ok" to false,
                "reason" to (error.message ?: "Android could not start Wi-Fi Direct."),
            ))
        }
    }

    @Suppress("DEPRECATION")
    private fun startDirectGroupInternal(result: MethodChannel.Result) {
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)) {
            result.success(mapOf("ok" to false, "reason" to "This device does not support Wi-Fi Direct."))
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            checkSelfPermission(android.Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED) {
            result.success(mapOf("ok" to false, "reason" to "Allow Nearby devices permission before starting a direct session."))
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            Build.VERSION.SDK_INT <= Build.VERSION_CODES.S_V2 &&
            checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            result.success(mapOf("ok" to false, "reason" to "Allow location permission for Android Wi-Fi Direct discovery."))
            return
        }
        val manager = getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        if (manager == null) {
            result.success(mapOf("ok" to false, "reason" to "Android Wi-Fi Direct service is unavailable."))
            return
        }
        wifiP2pManager = manager
        wifiP2pChannel = manager.initialize(this, mainLooper, null)
        val channel = wifiP2pChannel ?: run {
            result.success(mapOf("ok" to false, "reason" to "Could not initialize Wi-Fi Direct."))
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            manager.createGroup(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    result.success(mapOf("ok" to true, "band" to "Automatic", "message" to "This Android version cannot request a Wi-Fi Direct band. Started a group using the system-selected band."))
                }
                override fun onFailure(reason: Int) {
                    result.success(mapOf("ok" to false, "reason" to "Could not start Wi-Fi Direct (code $reason). Check Wi-Fi and try again."))
                }
            })
            return
        }
        val random = SecureRandom()
        val groupCode = CharArray(2) { "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"[random.nextInt(32)] }.concatToString()
        val passphrase = CharArray(20) { "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"[random.nextInt(57)] }.concatToString()
        val config = WifiP2pConfig.Builder()
            .setNetworkName("DIRECT-$groupCode-OmniDrop")
            .setPassphrase(passphrase)
            .setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_5GHZ)
            .build()
        manager.createGroup(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                result.success(mapOf("ok" to true, "band" to "5 GHz", "message" to "5 GHz Wi-Fi Direct group started. Open Direct connections on the PC and connect to this phone."))
            }
            override fun onFailure(reason: Int) {
                createAutomaticDirectGroup(manager, channel, result, reason)
            }
        })
    }

    @Suppress("DEPRECATION")
    private fun createAutomaticDirectGroup(manager: WifiP2pManager, channel: WifiP2pManager.Channel,
                                          result: MethodChannel.Result, fiveGhzFailure: Int) {
        manager.createGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                result.success(mapOf("ok" to true, "band" to "Automatic", "message" to "This phone could not start a 5 GHz Wi-Fi Direct group (code $fiveGhzFailure). Started an automatic-band group instead."))
            }
            override fun onFailure(reason: Int) {
                result.success(mapOf("ok" to false, "reason" to "Could not start Wi-Fi Direct (code $reason). Check Wi-Fi and try again."))
            }
        })
    }

    @Suppress("DEPRECATION")
    private fun stopDirectGroup(result: MethodChannel.Result) {
        val manager = wifiP2pManager
        val channel = wifiP2pChannel
        if (manager == null || channel == null) {
            result.success(true)
            return
        }
        manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { result.success(true) }
            override fun onFailure(reason: Int) {
                result.error("DIRECT_STOP_FAILED", "Could not stop Wi-Fi Direct (code $reason).", null)
            }
        })
    }

    private fun publishReceivedFile(sourcePath: String, requestedName: String): String {
        val source = java.io.File(sourcePath)
        require(source.isFile) { "Received file is missing." }
        val safeName = requestedName.substringAfterLast('/').substringAfterLast('\\')
            .replace(Regex("[\\u0000-\\u001f<>:\"|?*]"), "_")
            .takeLast(240).ifBlank { "received-file" }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
                put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, "Download/OmniDrop")
                put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw java.io.IOException("Android could not create the Downloads file.")
            try {
                val output = contentResolver.openOutputStream(uri, "w")
                    ?: throw java.io.IOException("Android could not open the Downloads file.")
                output.use { sink -> source.inputStream().buffered().use { input -> input.copyTo(sink, 1024 * 1024) } }
                values.clear()
                values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                return uri.toString()
            } catch (error: Exception) {
                contentResolver.delete(uri, null, null)
                throw error
            }
        }
        val folder = java.io.File(android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS), "OmniDrop")
        if (!folder.exists() && !folder.mkdirs()) throw java.io.IOException("Could not create Downloads/OmniDrop.")
        var target = java.io.File(folder, safeName)
        var index = 1
        while (target.exists()) {
            val dot = safeName.lastIndexOf('.')
            val stem = if (dot > 0) safeName.substring(0, dot) else safeName
            val extension = if (dot > 0) safeName.substring(dot) else ""
            target = java.io.File(folder, "$stem ($index)$extension")
            index++
        }
        source.inputStream().buffered().use { input -> target.outputStream().buffered().use { input.copyTo(it, 1024 * 1024) } }
        return target.absolutePath
    }

    @Suppress("DEPRECATION")
    private fun requestStartupPermissions(result: MethodChannel.Result) {
        val candidates = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(android.Manifest.permission.NEARBY_WIFI_DEVICES)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
        } else {
            emptyArray()
        }
        val permissions = candidates.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }.toMutableList()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            permissions.add(android.Manifest.permission.POST_NOTIFICATIONS)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
            checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            permissions.add(android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }
        if (permissions.isEmpty()) {
            result.success(true)
        } else {
            startupPermissionResult = result
            requestPermissions(permissions.toTypedArray(), 7401)
        }
    }

    @Deprecated("Deprecated in Android API")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 7401) return
        val granted = permissions.indices
            .filter { permissions[it] != android.Manifest.permission.POST_NOTIFICATIONS }
            .all { grantResults.getOrNull(it) == PackageManager.PERMISSION_GRANTED }
        startupPermissionResult?.success(granted)
        startupPermissionResult = null
    }

    @Suppress("DEPRECATION")
    private fun getNetworkBand(): String {
        return try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return "unknown"
            val frequency = wifi.connectionInfo.frequency
            when (frequency) {
                in 2400..2500 -> "2.4 GHz"
                in 4900..5895 -> "5 GHz"
                in 5925..7125 -> "6 GHz"
                else -> "unknown"
            }
        } catch (_: SecurityException) {
            "unknown"
        } catch (_: Exception) {
            "unknown"
        }
    }

    private fun getOrCreateStoreKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "omnidrop_pairing_aes_key"
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun capability(name: String, supported: Boolean, available: Boolean, details: String): Map<String, String> {
        val support = when {
            !supported -> "unsupported"
            !available -> "unavailable"
            else -> "supported"
        }
        return mapOf("name" to name, "support" to support, "message" to details)
    }

    private fun getDirectRadioCapabilities(): List<Map<String, String>> {
        val packageManager = packageManager
        val p2pSupported = packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
        val p2pManager = getSystemService(Context.WIFI_P2P_SERVICE)
        val p2pAvailable = p2pSupported && p2pManager != null

        val awareSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)
        val awareManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
        } else null
        val awareAvailable = awareSupported && awareManager?.isAvailable == true

        val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
        val bleSupported = bluetoothAdapter != null
        val bluetoothPermissionGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        val bleAvailable = bleSupported && bluetoothPermissionGranted && bluetoothAdapter?.isEnabled == true

        return listOf(
            capability(
                "Wi-Fi Direct",
                p2pSupported,
                p2pAvailable,
                when {
                    !p2pSupported -> "This device's Wi-Fi hardware does not expose Wi-Fi Direct."
                    !p2pAvailable -> "Wi-Fi Direct is supported but unavailable right now. Check Wi-Fi and system settings."
                    else -> "Supported by this device. Direct discovery and connection require runtime nearby-device permission."
                },
            ),
            capability(
                "Wi-Fi Aware (NAN)",
                awareSupported,
                awareAvailable,
                when {
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O -> "Requires Android 8.0 or newer."
                    !awareSupported -> "This device does not advertise Wi-Fi Aware hardware support."
                    !awareAvailable -> "Wi-Fi Aware is supported but unavailable. Wi-Fi, location services, or another Wi-Fi mode may be blocking it."
                    else -> "Supported and currently available for router-free discovery."
                },
            ),
            capability(
                "Bluetooth Low Energy",
                bleSupported,
                bleAvailable,
                when {
                    !bleSupported -> "This device has no Bluetooth adapter."
                    !bluetoothPermissionGranted -> "Android has not granted nearby-device permission yet. OmniDrop will request it when direct discovery is enabled."
                    !bleAvailable -> "Bluetooth is off. Turn it on to enable nearby discovery."
                    else -> "Bluetooth is available for low-power nearby discovery."
                },
            ),
        )
    }
}
