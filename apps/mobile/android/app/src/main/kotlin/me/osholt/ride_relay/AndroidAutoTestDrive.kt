package me.osholt.ride_relay

import android.os.Handler
import android.os.Looper
import android.os.SystemClock

internal interface AndroidAutoNavigationTestDrive {
    val enabled: Boolean

    fun enable()

    fun accept(projection: AndroidAutoNavigationProjectionV2)

    fun clearRoute()

    fun close()
}

internal object DisabledAndroidAutoTestDrive : AndroidAutoNavigationTestDrive {
    override val enabled = false
    override fun enable() = Unit
    override fun accept(projection: AndroidAutoNavigationProjectionV2) = Unit
    override fun clearRoute() = Unit
    override fun close() = Unit
}

/**
 * The deterministic trip driver requested by the Android Auto review harness.
 *
 * It changes only host-facing trip metadata. It never invents GPS samples, writes to the ride
 * journal, or contributes to the heat map. A real ride therefore cannot be contaminated by a
 * reviewer enabling AUTO_DRIVE through `dumpsys`.
 */
internal class AndroidAutoDeterministicTestDrive(
    private val publish: (AndroidAutoNavigationProjectionV2) -> Unit,
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val elapsedRealtime: () -> Long = SystemClock::elapsedRealtime,
) : AndroidAutoNavigationTestDrive {
    override var enabled: Boolean = false
        private set

    private var base: AndroidAutoNavigationProjectionV2? = null
    private var startedAtMillis = 0L

    private val tick = object : Runnable {
        override fun run() {
            val projection = base ?: return
            val elapsedSeconds = ((elapsedRealtime() - startedAtMillis).coerceAtLeast(0)) / 1_000.0
            publish(simulate(projection, elapsedSeconds))
            handler.postDelayed(this, UPDATE_INTERVAL_MILLIS)
        }
    }

    override fun enable() {
        enabled = true
    }

    override fun accept(projection: AndroidAutoNavigationProjectionV2) {
        if (!enabled) return
        if (base?.route?.navigationSessionId == projection.route?.navigationSessionId) return
        handler.removeCallbacks(tick)
        base = projection
        startedAtMillis = elapsedRealtime()
        publish(simulate(projection, 0.0))
        handler.postDelayed(tick, UPDATE_INTERVAL_MILLIS)
    }

    override fun clearRoute() {
        handler.removeCallbacks(tick)
        base = null
    }

    override fun close() {
        enabled = false
        clearRoute()
    }

    companion object {
        private const val SIMULATED_SPEED_METERS_PER_SECOND = 15.0
        private const val UPDATE_INTERVAL_MILLIS = 1_000L

        fun simulate(
            projection: AndroidAutoNavigationProjectionV2,
            elapsedSeconds: Double,
        ): AndroidAutoNavigationProjectionV2 {
            val travelled = elapsedSeconds.coerceAtLeast(0.0) *
                SIMULATED_SPEED_METERS_PER_SECOND
            val originalCurrent = projection.currentManeuver
            val originalFollowing = projection.followingManeuver
            val currentDistance = originalCurrent?.distanceMeters ?: 0.0
            val (current, following) = when {
                originalCurrent == null -> null to originalFollowing
                travelled < currentDistance || originalFollowing == null ->
                    originalCurrent.copy(distanceMeters = (currentDistance - travelled).coerceAtLeast(0.0)) to
                        originalFollowing
                else -> {
                    val followingDistance = originalFollowing.distanceMeters ?: 0.0
                    originalFollowing.copy(
                        distanceMeters = (followingDistance - (travelled - currentDistance))
                            .coerceAtLeast(0.0),
                    ) to null
                }
            }
            val journey = projection.journey?.let { original ->
                original.copy(
                    remainingDistanceMeters = original.remainingDistanceMeters
                        ?.minus(travelled)?.coerceAtLeast(0.0),
                    remainingSeconds = original.remainingSeconds
                        ?.minus(elapsedSeconds.toLong())?.coerceAtLeast(0),
                )
            }
            return projection.copy(
                currentManeuver = current,
                followingManeuver = following,
                journey = journey,
            )
        }
    }
}
