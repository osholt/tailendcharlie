package me.osholt.ride_relay

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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
        private const val PERMISSION_REQUEST = 7102
        private const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
    }

    private val connectionsClient: ConnectionsClient by lazy {
        Nearby.getConnectionsClient(this)
    }
    private val connectedPeers = linkedSetOf<String>()
    private val pendingPeers = mutableSetOf<String>()
    private var eventSink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null
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
        }
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
        stopNearby()
        super.onDestroy()
    }
}
