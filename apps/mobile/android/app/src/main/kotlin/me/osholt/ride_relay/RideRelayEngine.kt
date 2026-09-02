package me.osholt.ride_relay

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * One Dart engine for the whole process, outliving any single activity.
 *
 * ## Why this exists
 *
 * [MainActivity] used to own the only engine. `FlutterActivity` creates one on
 * attach and destroys it on detach, so Dart — the ride journal, the relay, the
 * projection bridge — stopped the moment Android reclaimed the activity. On the
 * phone that is invisible: nothing is on screen to go stale. On a head unit it
 * is the whole bug (#602): a rider with the phone in a pocket saw "Phone status
 * is stale" a couple of minutes into every ride, and a rider who opened Android
 * Auto without opening the phone app first saw "Waiting for ride status", because
 * no engine had ever run.
 *
 * The ride keeps a foreground location service alive, so the *process* survives
 * the activity. Only the engine did not. Now it does.
 *
 * ## What did not change
 *
 * Everything activity-scoped stays in [MainActivity.configureFlutterEngine]:
 * permission prompts, the Nearby client, file imports. Flutter still calls that
 * on every attach, cached engine or not. Only [ProjectedRideChannel] moved out,
 * because it is the one channel whose whole purpose is to keep publishing when
 * nobody is looking at the phone.
 *
 * Created lazily rather than in `Application.onCreate`. A cold start that is not
 * going to a car should not pay for an engine before it knows it needs one.
 */
object RideRelayEngine {
    const val ENGINE_ID = "ride_relay_main"

    /**
     * The process-wide engine, started if this is the first caller.
     *
     * Safe to call from the car service or the activity, in either order —
     * whichever arrives first starts Dart and the other attaches to it.
     */
    @Synchronized
    fun ensure(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val engine = FlutterEngine(context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        // Registered here, on the engine rather than on an activity, so the car
        // keeps receiving ride state with no phone screen involved.
        ProjectedRideChannel.attach(engine)
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    /** True when Dart is already running, without starting it. */
    fun isRunning(): Boolean = FlutterEngineCache.getInstance().get(ENGINE_ID) != null
}

/**
 * The phone-to-projection bridge, one half of `lib/services/carplay_bridge.dart`.
 *
 * Named for CarPlay because that is what asked for it first; the channel and its
 * payload are platform-neutral and Android Auto reads the same fields.
 */
object ProjectedRideChannel {
    private const val CHANNEL = "me.osholt.ride_relay/carplay"

    /**
     * Every method this side sends, named once.
     *
     * There is no compiler across a platform channel: a typo here is a silent
     * `notImplemented` at runtime. `AndroidAutoChannelContractTest` checks each
     * of these against the `case` labels in `carplay_bridge.dart`.
     */
    internal const val METHOD_FREE_ROAM = "startFreeRoam"
    internal const val METHOD_PREPARED_RIDE = "startPreparedRide"
    internal const val METHOD_SEARCH = "searchDestinations"
    internal const val METHOD_PLAN = "planDestination"
    internal const val METHOD_NAVIGATION_EVENT = "androidAutoNavigationEvent"

    internal enum class NavigationHostEvent(val wireValue: String) {
        STARTED("started"),
        STOPPED("stopped"),
        EXTERNAL_DESTINATION("externalDestination"),
        AUTO_DRIVE_ENABLED("autoDriveEnabled"),
        REROUTE_REQUESTED("rerouteRequested"),
        ARRIVED("arrived"),
        RESTORATION_ACKNOWLEDGED("restorationAcknowledged"),
    }

    /**
     * Kept so the car can talk back, not only listen.
     *
     * Dart has handled `startFreeRoam`, `searchDestinations`, `planDestination`
     * and `startPreparedRide` since CarPlay needed them. Android Auto has never
     * called one, which is why the head unit could only ever watch a ride the
     * phone had already started (#602).
     */
    @Volatile
    private var channel: MethodChannel? = null

    /** A place the rider can be sent to, as the bridge serialises it. */
    data class Destination(val label: String, val latitude: Double, val longitude: Double)

    fun attach(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel!!
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateSnapshot" -> {
                        @Suppress("UNCHECKED_CAST")
                        val snapshot = call.arguments as? Map<String, Any?>
                        if (snapshot == null) {
                            result.error("invalid_arguments", "Snapshot must be a map", null)
                        } else {
                            AndroidAutoSnapshotStore.update(snapshot)
                            result.success(null)
                        }
                    }
                    // The car draws from the snapshot's own camera fields, so
                    // these carry nothing Android needs. Accepted rather than
                    // refused so the shared bridge can publish at its normal
                    // cadence without logging a platform error every tick.
                    "updateViewport", "updateMapStyle" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Asks the phone to start free roam.
     *
     * [onDone] receives null on success or a rider-facing message. Dart already
     * words those messages for CarPlay, so they are passed through rather than
     * reworded here — two surfaces explaining the same refusal differently is
     * how they drift.
     */
    fun startFreeRoam(onDone: (String?) -> Unit) =
        invoke(METHOD_FREE_ROAM, null) { reply -> onDone(okError(reply)) }

    fun startPreparedRide(onDone: (String?) -> Unit) =
        invoke(METHOD_PREPARED_RIDE, null) { onDone(null) }

    fun searchDestinations(
        query: String,
        onDone: (List<Destination>, String?) -> Unit,
    ) = invoke(METHOD_SEARCH, mapOf("query" to query)) { reply ->
        onDone(parseDestinations(reply), (reply as? Map<*, *>)?.get("error") as? String)
    }

    /**
     * `{results: [{label, latitude, longitude}], error}` as the bridge sends it.
     *
     * A result missing any of the three is dropped rather than guessed at: a
     * destination with no coordinates would route to whatever the geocoder
     * returned first, which is the mistake `CarPlayDestination` carries
     * coordinates to prevent.
     */
    internal fun parseDestinations(reply: Any?): List<Destination> =
        ((reply as? Map<*, *>)?.get("results") as? List<*>).orEmpty().mapNotNull { raw ->
            val item = raw as? Map<*, *> ?: return@mapNotNull null
            val label = (item["label"] as? String)?.trim()?.take(120)
            val latitude = (item["latitude"] as? Number)?.toDouble()
            val longitude = (item["longitude"] as? Number)?.toDouble()
            if (label.isNullOrEmpty() || latitude == null || longitude == null) {
                null
            } else {
                Destination(label, latitude, longitude)
            }
        }

    /**
     * @param groupRide null leaves the choice to the phone's own default, which
     * is what free roam does now (#600). Passed explicitly only when the rider
     * asked for a group.
     */
    fun planDestination(
        destination: Destination,
        groupRide: Boolean?,
        onDone: (String?) -> Unit,
    ) = invoke(
        METHOD_PLAN,
        buildMap {
            put("label", destination.label)
            put("latitude", destination.latitude)
            put("longitude", destination.longitude)
            if (groupRide != null) put("groupRide", groupRide)
        },
    ) { reply -> onDone(okError(reply)) }

    /** Sends a typed host event without changing ride membership or recording. */
    internal fun navigationEvent(
        type: NavigationHostEvent,
        navigationSessionId: String? = null,
        routeId: String? = null,
        destination: Destination? = null,
        reason: String? = null,
        projectionSequence: Long? = null,
        onDone: (String?) -> Unit,
    ) = invoke(
        METHOD_NAVIGATION_EVENT,
        buildMap {
            put("type", type.wireValue)
            navigationSessionId?.let { put("navigationSessionId", it) }
            routeId?.let { put("routeId", it) }
            destination?.let {
                put(
                    "destination",
                    mapOf("latitude" to it.latitude, "longitude" to it.longitude),
                )
            }
            reason?.let { put("reason", it) }
            projectionSequence?.let { put("projectionSequence", it) }
        },
    ) { reply -> onDone(okError(reply)) }

    /** Null when the phone said yes; otherwise the phone's own wording. */
    internal fun okError(reply: Any?): String? {
        val map = reply as? Map<*, *> ?: return null
        if (map["ok"] == true) return null
        return (map["error"] as? String) ?: "That did not work. Try the phone."
    }

    /**
     * Every call goes to the platform thread, because a `MethodChannel` may only
     * be used from there and a car screen's callbacks do not promise to be on
     * it. A missing engine answers rather than hanging: a car screen waiting
     * forever on a reply that cannot come is worse than being told.
     */
    private fun invoke(method: String, arguments: Any?, onReply: (Any?) -> Unit) {
        val target = channel
        Handler(Looper.getMainLooper()).post {
            if (target == null) {
                onReply(mapOf("ok" to false, "error" to "Open Tail End Charlie on the phone."))
                return@post
            }
            target.invokeMethod(
                method,
                arguments,
                object : MethodChannel.Result {
                    override fun success(result: Any?) = onReply(result)

                    override fun error(code: String, message: String?, details: Any?) =
                        onReply(mapOf("ok" to false, "error" to (message ?: code)))

                    override fun notImplemented() = onReply(
                        mapOf("ok" to false, "error" to "The phone app is too old for this."),
                    )
                },
            )
        }
    }
}
