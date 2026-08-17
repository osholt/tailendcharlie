package me.osholt.ride_relay

import android.content.Context
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

    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
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
}
