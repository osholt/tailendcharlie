package me.osholt.ride_relay

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import com.google.android.gms.tasks.Tasks
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "me.osholt.ride_relay/nearby"
        private const val EVENT_CHANNEL = "me.osholt.ride_relay/nearby_events"
        private const val GPX_METHOD_CHANNEL = "me.osholt.ride_relay/gpx_import"
        private const val PLANNER_LINK_METHOD_CHANNEL = "me.osholt.ride_relay/planner_link"
        private const val PUSH_METHOD_CHANNEL = "me.osholt.ride_relay/push"
        private const val PERMISSION_REQUEST = 7102
        private const val PUSH_PERMISSION_REQUEST = 7103
        private const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
    }

    private var pendingGpxImport: Pair<ByteArray, String>? = null
    private var pendingPlannerLink: String? = null

    private val connectionsClient: ConnectionsClient by lazy {
        Nearby.getConnectionsClient(this)
    }
    private val connectedPeers = linkedSetOf<String>()
    private val pendingPeers = mutableSetOf<String>()
    private var eventSink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null
    private var pushPermissionResult: MethodChannel.Result? = null
    private var endpointName = "Tail End Charlie"
    private var serviceId = "me.osholt.ride_relay.relay.v1"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    emitStatus(if (connectedPeers.isEmpty()) "stopped" else "connected")
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCapabilities" -> result.success(
                    mapOf(
                        "platform" to "android",
                        "nativeBridgeReady" to true,
                        "nearbyApiLinked" to true,
                        "status" to "hardwareValidationRequired",
                    ),
                )
                "requestPermissions" -> requestNearbyPermissions(result)
                "start" -> {
                    endpointName = call.argument<String>("endpointName")?.take(32) ?: "Tail End Charlie"
                    serviceId = call.argument<String>("serviceId") ?: serviceId
                    startNearby(result)
                }
                "send" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val peerIds = call.argument<List<String>>("peerIds")
                    if (bytes == null || peerIds.isNullOrEmpty()) {
                        result.error("invalid_arguments", "Bytes and peer IDs are required", null)
                    } else {
                        connectionsClient.sendPayload(peerIds, Payload.fromBytes(bytes))
                            .addOnSuccessListener { result.success(null) }
                            .addOnFailureListener { error ->
                                result.error("send_failed", error.message, null)
                            }
                    }
                }
                "stop" -> {
                    stopNearby()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            GPX_METHOD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "consumePendingGpxImport") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val pending = pendingGpxImport
            if (pending == null) {
                result.success(null)
            } else {
                pendingGpxImport = null
                result.success(mapOf("bytes" to pending.first, "fileName" to pending.second))
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PLANNER_LINK_METHOD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "consumePendingPlannerLink") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val pending = pendingPlannerLink
            pendingPlannerLink = null
            result.success(pending)
        }
        val pushChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PUSH_METHOD_CHANNEL,
        )
        NativePushBridge.channel = pushChannel
        pushChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "configureAndRequest" -> configurePush(call, result, requestPermission = true)
                "currentStatus" -> configurePush(call, result, requestPermission = false)
                "consumeInitialNotification" -> {
                    val pending = NativePushBridge.pendingOpenedNotification
                    NativePushBridge.pendingOpenedNotification = null
                    result.success(pending)
                }
                else -> result.notImplemented()
            }
        }
    }

    // Dart pulls this on its own schedule via consumePendingGpxImport rather
    // than being pushed to live, since a cold launch's intent arrives before
    // the Flutter engine - and therefore any method call handler - exists.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
        captureGpxIntent(intent)
        capturePlannerLinkIntent(intent)
        capturePushIntent(intent)
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannels(
            listOf(
                NotificationChannel(
                    "ride_safety_alerts",
                    "Urgent ride alerts",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Safety and assistance alerts for the active ride"
                },
                NotificationChannel(
                    "ride_updates",
                    "Ride updates",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "Marker, status and administrative ride updates"
                },
            ),
        )
    }

    // launchMode="singleTop" routes a new VIEW/SEND intent here instead of a
    // fresh onCreate while this activity is already on screen.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        captureGpxIntent(intent)
        capturePlannerLinkIntent(intent)
        capturePushIntent(intent)
    }

    private fun captureGpxIntent(intent: Intent?) {
        val uri = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> extraStreamUri(intent)
            else -> null
        } ?: return
        if (uri.scheme != "content" && uri.scheme != "file") return
        val bytes = try {
            contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (error: Exception) {
            null
        } ?: return
        pendingGpxImport = bytes to (queryDisplayName(uri) ?: uri.lastPathSegment ?: "shared.gpx")
    }

    private fun capturePlannerLinkIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        if (
            uri.scheme != "https" ||
            !uri.host.equals("tailendcharlie.app", ignoreCase = true) ||
            uri.path != "/planner.html" ||
            uri.toString().length > 2048
        ) {
            return
        }
        pendingPlannerLink = uri.toString()
    }

    @Suppress("DEPRECATION")
    private fun extraStreamUri(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme != "content") return null
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
        } catch (error: Exception) {
            null
        }
    }

    private fun requestNearbyPermissions(result: MethodChannel.Result) {
        val missing = requiredPermissions().filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        if (permissionResult != null) {
            result.error("permission_pending", "A permission request is already active", null)
            return
        }
        permissionResult = result
        ActivityCompat.requestPermissions(this, missing.toTypedArray(), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST) {
            val granted = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            permissionResult?.success(granted)
            permissionResult = null
        } else if (requestCode == PUSH_PERMISSION_REQUEST) {
            val result = pushPermissionResult
            pushPermissionResult = null
            if (result != null) currentPushStatus(result)
        }
    }

    private fun configurePush(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
        requestPermission: Boolean,
    ) {
        if (!ensureFirebaseConfigured(call)) {
            result.success(pushStatus("unavailable"))
            return
        }
        val needsRuntimePermission =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) != PackageManager.PERMISSION_GRANTED
        if (requestPermission && needsRuntimePermission) {
            if (pushPermissionResult != null) {
                result.error(
                    "push_permission_pending",
                    "Notification permission is already being requested",
                    null,
                )
                return
            }
            pushPermissionResult = result
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                PUSH_PERMISSION_REQUEST,
            )
            return
        }
        currentPushStatus(result)
    }

    private fun ensureFirebaseConfigured(call: io.flutter.plugin.common.MethodCall): Boolean {
        if (FirebaseApp.getApps(this).isNotEmpty()) return true
        val apiKey = call.argument<String>("apiKey")
        val projectId = call.argument<String>("projectId")
        val senderId = call.argument<String>("messagingSenderId")
        val appId = call.argument<String>("appId")
        if (apiKey.isNullOrEmpty() ||
            projectId.isNullOrEmpty() ||
            senderId.isNullOrEmpty() ||
            appId.isNullOrEmpty()
        ) {
            return false
        }
        val options = FirebaseOptions.Builder()
            .setApiKey(apiKey)
            .setProjectId(projectId)
            .setGcmSenderId(senderId)
            .setApplicationId(appId)
            .build()
        return FirebaseApp.initializeApp(this, options) != null
    }

    private fun currentPushStatus(result: MethodChannel.Result) {
        val runtimeGranted =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == PackageManager.PERMISSION_GRANTED
        if (!runtimeGranted || !NotificationManagerCompat.from(this).areNotificationsEnabled()) {
            result.success(pushStatus("denied"))
            return
        }
        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { token ->
                result.success(pushStatus("granted", token))
            }
            .addOnFailureListener {
                result.success(pushStatus("granted"))
            }
    }

    private fun pushStatus(permission: String, token: String? = null): Map<String, String> =
        buildMap {
            put("permission", permission)
            put("platform", "android")
            put("provider", "fcm")
            if (!token.isNullOrEmpty()) put("token", token)
        }

    private fun capturePushIntent(intent: Intent?) {
        val rideId = intent?.getStringExtra("rideId") ?: return
        val eventId = intent.getStringExtra("eventId") ?: return
        val category = intent.getStringExtra("category") ?: return
        NativePushBridge.notificationOpened(
            mapOf(
                "rideId" to rideId,
                "eventId" to eventId,
                "category" to category,
            ),
        )
        intent.removeExtra("rideId")
        intent.removeExtra("eventId")
        intent.removeExtra("category")
    }

    private fun requiredPermissions(): List<String> = buildList {
        when {
            Build.VERSION.SDK_INT >= 37 -> {
                add(LOCAL_NETWORK_PERMISSION)
                add(Manifest.permission.NEARBY_WIFI_DEVICES)
                add(Manifest.permission.BLUETOOTH_ADVERTISE)
                add(Manifest.permission.BLUETOOTH_CONNECT)
                add(Manifest.permission.BLUETOOTH_SCAN)
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                add(Manifest.permission.NEARBY_WIFI_DEVICES)
                add(Manifest.permission.BLUETOOTH_ADVERTISE)
                add(Manifest.permission.BLUETOOTH_CONNECT)
                add(Manifest.permission.BLUETOOTH_SCAN)
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
                add(Manifest.permission.BLUETOOTH_ADVERTISE)
                add(Manifest.permission.BLUETOOTH_CONNECT)
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> add(Manifest.permission.ACCESS_FINE_LOCATION)
            else -> add(Manifest.permission.ACCESS_COARSE_LOCATION)
        }
    }

    private fun startNearby(result: MethodChannel.Result) {
        if (requiredPermissions().any {
                ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
            }
        ) {
            result.error("permission_required", "Nearby permissions are not granted", null)
            return
        }
        emitStatus("starting")
        val advertising = connectionsClient.startAdvertising(
            endpointName,
            serviceId,
            lifecycleCallback,
            AdvertisingOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build(),
        )
        val discovery = connectionsClient.startDiscovery(
            serviceId,
            discoveryCallback,
            DiscoveryOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build(),
        )
        Tasks.whenAll(advertising, discovery)
            .addOnSuccessListener {
                emitStatus(if (connectedPeers.isEmpty()) "searching" else "connected")
                result.success(null)
            }
            .addOnFailureListener { error ->
                stopNearby()
                emitStatus("failed", error.message)
                result.error("start_failed", error.message, null)
            }
    }

    private val discoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            if (endpointId in connectedPeers || !pendingPeers.add(endpointId)) return
            connectionsClient.requestConnection(endpointName, endpointId, lifecycleCallback)
                .addOnFailureListener { error ->
                    pendingPeers.remove(endpointId)
                    emitStatus("searching", "Connection request failed: ${error.message}")
                }
        }

        override fun onEndpointLost(endpointId: String) {
            pendingPeers.remove(endpointId)
        }
    }

    private val lifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            // Development alpha: transport pairing is automatic. Every accepted
            // byte frame is still authenticated with the shared ride secret.
            connectionsClient.acceptConnection(endpointId, payloadCallback)
        }

        override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) {
            pendingPeers.remove(endpointId)
            if (resolution.status.isSuccess) {
                connectedPeers.add(endpointId)
                emitStatus("connected")
            } else {
                emitStatus("searching", "Connection rejected: ${resolution.status.statusCode}")
            }
        }

        override fun onDisconnected(endpointId: String) {
            connectedPeers.remove(endpointId)
            emitStatus(if (connectedPeers.isEmpty()) "searching" else "connected")
        }
    }

    private val payloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            payload.asBytes()?.let { bytes ->
                eventSink?.success(
                    mapOf("kind" to "packet", "peerId" to endpointId, "bytes" to bytes),
                )
            }
        }

        override fun onPayloadTransferUpdate(
            endpointId: String,
            update: PayloadTransferUpdate,
        ) = Unit
    }

    private fun emitStatus(state: String, message: String? = null) {
        eventSink?.success(
            mapOf(
                "kind" to "status",
                "state" to state,
                "peerIds" to connectedPeers.toList(),
                "message" to message,
            ),
        )
    }

    private fun stopNearby() {
        connectionsClient.stopAdvertising()
        connectionsClient.stopDiscovery()
        connectionsClient.stopAllEndpoints()
        connectedPeers.clear()
        pendingPeers.clear()
        emitStatus("stopped")
    }

    override fun onDestroy() {
        NativePushBridge.channel = null
        stopNearby()
        super.onDestroy()
    }
}
