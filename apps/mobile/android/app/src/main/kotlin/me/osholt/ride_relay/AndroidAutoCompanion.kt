package me.osholt.ride_relay

import java.util.concurrent.CopyOnWriteArraySet

/**
 * What the phone tells the head unit about the ride.
 *
 * The wire format is `lib/services/carplay_bridge.dart`, shared with CarPlay and
 * platform-neutral despite the name. This used to read eight of its fields into
 * a list of text rows; the rest — the route geometry, the ridden/remaining
 * split, every rider's position and colour, the distance to the next turn, the
 * journey estimate — arrived on every tick and was dropped on the floor (#602).
 *
 * Every string is trimmed and bounded. This is data from another process and
 * some of it is rider-authored: a display name is whatever somebody typed.
 */
internal data class ProjectedPoint(val latitude: Double, val longitude: Double)

internal data class ProjectedRider(
    val label: String,
    val role: String,
    val needsAttention: Boolean,
    val isLocal: Boolean,
    val isTec: Boolean,
    val colourArgb: Int,
    val point: ProjectedPoint?,
    val headingDegrees: Double?,
)

internal data class ProjectedAlert(
    val message: String,
    val severity: String,
)

internal data class ProjectedGuidance(
    val title: String,
    val detail: String?,
    val roadName: String?,
    val distanceMeters: Double?,
    val secondsRemaining: Double?,
)

internal data class ProjectedJourney(
    val remainingMeters: Double?,
    val remainingSeconds: Double?,
    /**
     * When the phone thinks the rider arrives.
     *
     * `TravelEstimate` is built around an arrival *time*, not a duration, so
     * without this the ETA strip cannot be drawn at all.
     */
    val arrivalAtMillis: Long?,
)

internal data class ProjectedRideSnapshot(
    val routeName: String?,
    val rideState: String,
    val guidance: ProjectedGuidance?,
    val journey: ProjectedJourney?,
    val groupStatus: String,
    val markerStatus: String?,
    val riders: List<ProjectedRider>,
    val alert: ProjectedAlert?,
    val routePoints: List<ProjectedPoint>,
    val riddenPoints: List<ProjectedPoint>,
    val remainingPoints: List<ProjectedPoint>,
    val localPoint: ProjectedPoint?,
    val localHeadingDegrees: Double?,
    /**
     * Whether the phone is framing the rider or the whole route.
     *
     * Sent explicitly because the presence of a fix cannot distinguish the two:
     * before a ride starts the phone frames the complete route so the group can
     * review it, and both states have a position.
     */
    val followRider: Boolean,
    val metric: Boolean,
    val darkMap: Boolean,
    val updatedAtMillis: Long,
) {
    /** True while the phone is publishing often enough to be believed. */
    fun isFresh(nowMillis: Long): Boolean = nowMillis - updatedAtMillis < 120_000

    companion object {
        private const val DEFAULT_RIDER_ARGB = 0xFF2F80ED.toInt()

        fun from(raw: Map<String, Any?>): ProjectedRideSnapshot {
            val riders = (raw["riders"] as? List<*>)
                .orEmpty()
                .mapNotNull { item -> (item as? Map<*, *>)?.let(::rider) }
                .take(24)
            val rawAlert = raw["alert"] as? Map<*, *>
            val localPosition = raw["localPosition"] as? Map<*, *>
            return ProjectedRideSnapshot(
                routeName = raw.boundedString("routeName"),
                rideState = raw.boundedString("rideState") ?: "Open the phone app",
                guidance = guidance(raw),
                journey = journey(raw["journeyProgress"] as? Map<*, *>),
                groupStatus = raw.boundedString("groupStatus")
                    ?: "${riders.size} riders visible",
                markerStatus = raw.boundedString("markerStatus"),
                riders = riders,
                alert = rawAlert?.let {
                    ProjectedAlert(
                        message = it.string("message", "Ride alert"),
                        severity = it.string("severity", "alert"),
                    )
                },
                routePoints = points(raw["routePoints"]),
                riddenPoints = points(raw["riddenRoutePoints"]),
                remainingPoints = points(raw["remainingRoutePoints"]),
                localPoint = localPosition?.let(::point),
                localHeadingDegrees = (localPosition?.get("headingDegrees") as? Number)
                    ?.toDouble(),
                followRider = raw["followRider"] == true,
                // Anything that is not explicitly imperial is metric, which is
                // the app's own default and the safer way round: a rider who
                // has not chosen sees kilometres rather than a wrong unit.
                metric = raw.boundedString("distanceUnit") != "miles",
                darkMap = (raw["basemap"] as? Map<*, *>)?.get("dark") == true,
                updatedAtMillis = (raw["updatedAtMillis"] as? Number)?.toLong()
                    ?: System.currentTimeMillis(),
            )
        }

        private fun guidance(raw: Map<String, Any?>): ProjectedGuidance? {
            val title = raw.boundedString("guidanceTitle") ?: return null
            return ProjectedGuidance(
                title = title,
                detail = raw.boundedString("guidanceDetail"),
                roadName = raw.boundedString("guidanceRoadName"),
                distanceMeters = (raw["guidanceDistanceMeters"] as? Number)?.toDouble(),
                secondsRemaining = (raw["guidanceSecondsRemaining"] as? Number)
                    ?.toDouble(),
            )
        }

        private fun journey(raw: Map<*, *>?): ProjectedJourney? {
            if (raw == null) return null
            // `remainingDistanceMeters`, not `remainingMeters`: the key is
            // spelled out in `lib/services/route_journey_progress.dart` and
            // guessing it silently produces a journey with no distance.
            val meters = (raw["remainingDistanceMeters"] as? Number)?.toDouble()
            val seconds = (raw["remainingSeconds"] as? Number)?.toDouble()
            val arrival = (raw["arrivalTimeMillis"] as? Number)?.toLong()
            if (meters == null && seconds == null && arrival == null) return null
            return ProjectedJourney(
                remainingMeters = meters,
                remainingSeconds = seconds,
                arrivalAtMillis = arrival,
            )
        }

        private fun rider(raw: Map<*, *>): ProjectedRider = ProjectedRider(
            label = raw.string("label", "Rider"),
            role = raw.string("role", "Rider"),
            needsAttention = raw["needsAttention"] == true,
            isLocal = raw["isLocal"] == true,
            isTec = raw["isTec"] == true,
            colourArgb = riderColour(raw["riderColor"] as? String),
            point = point(raw),
            headingDegrees = (raw["headingDegrees"] as? Number)?.toDouble(),
        )

        private fun point(raw: Map<*, *>): ProjectedPoint? {
            val latitude = (raw["latitude"] as? Number)?.toDouble() ?: return null
            val longitude = (raw["longitude"] as? Number)?.toDouble() ?: return null
            // A pair of zeroes is the shape a dropped fix takes, and drawing it
            // puts a rider in the Gulf of Guinea and the camera with them.
            if (latitude == 0.0 && longitude == 0.0) return null
            if (latitude !in -90.0..90.0 || longitude !in -180.0..180.0) return null
            return ProjectedPoint(latitude, longitude)
        }

        /**
         * A flat list of `{latitude, longitude}`.
         *
         * The phone reduces a multi-thousand-point GPX to its longest path and
         * caps it at 600 points before sending, so this never has to thin or
         * choose between paths — `_projectRoute` in the bridge already did.
         */
        private fun points(raw: Any?): List<ProjectedPoint> =
            (raw as? List<*>).orEmpty().mapNotNull { (it as? Map<*, *>)?.let(::point) }

        /**
         * The rider palette, matching `lib/domain/rider_color.dart`.
         *
         * Duplicated rather than plumbed as an ARGB int on the wire, because the
         * wire carries the *name* the rider chose and every other surface — the
         * phone map, the group PiP, CarPlay — resolves that name itself.
         */
        private fun riderColour(name: String?): Int = when (name) {
            "blue" -> 0xFF2F80ED.toInt()
            "cyan" -> 0xFF31C5D8.toInt()
            "green" -> 0xFF41B871.toInt()
            "amber" -> 0xFFF2A93B.toInt()
            "orange" -> 0xFFFF7A1A.toInt()
            "red" -> 0xFFE4574C.toInt()
            "pink" -> 0xFFE86AA6.toInt()
            "purple" -> 0xFF9B6BE8.toInt()
            else -> DEFAULT_RIDER_ARGB
        }
    }
}

private fun Map<*, *>.string(key: String, fallback: String): String =
    (this[key] as? String)?.trim()?.take(120)?.takeIf(String::isNotEmpty) ?: fallback

private fun Map<*, *>.boundedString(key: String): String? =
    (this[key] as? String)?.trim()?.take(120)?.takeIf(String::isNotEmpty)

internal object AndroidAutoSnapshotStore {
    fun interface Listener {
        fun onSnapshotChanged()
    }

    @Volatile
    var latest: ProjectedRideSnapshot? = null
        private set

    private val listeners = CopyOnWriteArraySet<Listener>()

    fun update(raw: Map<String, Any?>) {
        latest = ProjectedRideSnapshot.from(raw)
        listeners.forEach(Listener::onSnapshotChanged)
    }

    fun addListener(listener: Listener) {
        listeners.add(listener)
    }

    fun removeListener(listener: Listener) {
        listeners.remove(listener)
    }

    internal fun clearForTesting() {
        latest = null
        listeners.clear()
    }
}
