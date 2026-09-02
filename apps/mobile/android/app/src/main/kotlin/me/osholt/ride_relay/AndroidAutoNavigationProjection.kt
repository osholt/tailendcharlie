package me.osholt.ride_relay

/** Strict decoder for the versioned Android Auto navigation projection. */
internal data class AndroidAutoNavigationProjectionV2(
    val sourceId: String,
    val sequence: Long,
    val generatedAtMillis: Long,
    val ridePhase: String,
    val navigationPhase: String,
    val shouldOwnNavigation: Boolean,
    val route: Route?,
    val currentManeuver: Maneuver?,
    val followingManeuver: Maneuver?,
    val journey: Journey?,
    val progress: Progress,
    val units: Units,
    val localeIdentifier: String?,
    val followRider: Boolean,
    val actions: Actions,
    val alert: Alert?,
) {
    internal data class Route(
        val id: String,
        val navigationSessionId: String,
        val restorationId: String,
        val name: String,
        val trafficSide: String,
    )

    internal data class Position(val latitude: Double, val longitude: Double)

    internal data class Lane(val indications: List<String>, val valid: Boolean)

    internal data class Maneuver(
        val id: String,
        val kind: String,
        val direction: String,
        val engineType: String,
        val engineModifier: String?,
        val instructionVariants: List<String>,
        val roadNameVariants: List<String>,
        val position: Position,
        val exitNumber: Int?,
        val trafficSide: String,
        val distanceMeters: Double?,
        val secondsRemaining: Double?,
        val bearingBeforeDegrees: Double?,
        val bearingAfterDegrees: Double?,
        val departureBearingDegrees: Double?,
        val stepCount: Int,
        val lanes: List<Lane>,
    )

    internal data class Journey(
        val remainingDistanceMeters: Double?,
        val remainingSeconds: Long?,
        val arrivalTimeMillis: Long?,
        val nextWaypointName: String?,
        val nextWaypointDistanceMeters: Double?,
        val nextWaypointArrivalTimeMillis: Long?,
    )

    internal data class Progress(val travelledMeters: Double?, val totalMeters: Double?)

    internal data class Units(val distance: String?, val speed: String?)

    internal data class Actions(
        val canPlanRoute: Boolean,
        val canFreeRoam: Boolean,
        val canStartPreparedRide: Boolean,
        val canCancelNavigation: Boolean,
        val canLeaveRide: Boolean,
    )

    internal data class Alert(val message: String, val severity: String)

    companion object {
        private val ridePhases = setOf("home", "preRide", "activeRide", "endedRide")
        private val navigationPhases = setOf("inactive", "routeReady", "navigating", "ended")
        private val maneuverKinds = setOf(
            "depart",
            "arrive",
            "roundabout",
            "turn",
            "endOfRoad",
            "merge",
            "fork",
            "onRamp",
            "offRamp",
            "useLane",
            "continueAhead",
        )
        private val maneuverDirections = setOf(
            "sharpLeft",
            "left",
            "slightLeft",
            "straight",
            "slightRight",
            "right",
            "sharpRight",
            "uTurn",
            "unstated",
        )
        private val trafficSides = setOf("left", "right", "unknown")

        fun fromSnapshot(snapshot: Map<String, Any?>): AndroidAutoNavigationProjectionV2? {
            val raw = snapshot["androidAutoNavigation"] as? Map<*, *> ?: return null
            if (raw.integer("schemaVersion") != 2) return null
            val sourceId = raw.boundedString("sourceId", 96) ?: return null
            val sequence = raw.long("sequence")?.takeIf { it > 0 } ?: return null
            val generatedAtMillis = raw.long("generatedAtMillis")?.takeIf { it >= 0 } ?: return null
            val rideLifecycle = raw["rideLifecycle"] as? Map<*, *> ?: return null
            val ridePhase = rideLifecycle.boundedString("phase", 32)
                ?.takeIf(ridePhases::contains) ?: return null
            val navigationLifecycle = raw["navigationLifecycle"] as? Map<*, *> ?: return null
            val navigationPhase = navigationLifecycle.boundedString("phase", 32)
                ?.takeIf(navigationPhases::contains) ?: return null
            val shouldOwnNavigation = navigationLifecycle.boolean("shouldOwnNavigation")
                ?: return null
            if (shouldOwnNavigation != (navigationPhase == "navigating")) return null

            val route = when (val rawRoute = raw["route"]) {
                null -> null
                is Map<*, *> -> route(rawRoute) ?: return null
                else -> return null
            }
            if (navigationPhase != "inactive" && route == null) return null
            if (navigationPhase == "inactive" && route != null) return null

            val current = optionalMap(raw, "currentManeuver", ::maneuver) ?: return null
            val following = optionalMap(raw, "followingManeuver", ::maneuver) ?: return null
            val journey = optionalMap(raw, "journey", ::journey) ?: return null
            val progress = (raw["progress"] as? Map<*, *>)?.let(::progress) ?: return null
            val units = (raw["units"] as? Map<*, *>)?.let(::units) ?: return null
            val locale = raw.optionalBoundedString("localeIdentifier", 48) ?: return null
            val camera = raw["camera"] as? Map<*, *> ?: return null
            val followRider = camera.boolean("followRider") ?: return null
            val actions = (raw["actions"] as? Map<*, *>)?.let(::actions) ?: return null
            if (actions.canCancelNavigation != shouldOwnNavigation) return null
            val alert = optionalMap(raw, "alert", ::alert) ?: return null

            return AndroidAutoNavigationProjectionV2(
                sourceId = sourceId,
                sequence = sequence,
                generatedAtMillis = generatedAtMillis,
                ridePhase = ridePhase,
                navigationPhase = navigationPhase,
                shouldOwnNavigation = shouldOwnNavigation,
                route = route,
                currentManeuver = current.value,
                followingManeuver = following.value,
                journey = journey.value,
                progress = progress,
                units = units,
                localeIdentifier = locale.value,
                followRider = followRider,
                actions = actions,
                alert = alert.value,
            )
        }

        private fun route(raw: Map<*, *>): Route? {
            val trafficSide = raw.boundedString("trafficSide", 12)
                ?.takeIf(trafficSides::contains) ?: return null
            return Route(
                id = raw.boundedString("id", 160) ?: return null,
                navigationSessionId = raw.boundedString("navigationSessionId", 200) ?: return null,
                restorationId = raw.boundedString("restorationId", 200) ?: return null,
                name = raw.boundedString("name", 160) ?: return null,
                trafficSide = trafficSide,
            )
        }

        private fun maneuver(raw: Map<*, *>): Maneuver? {
            val kind = raw.boundedString("kind", 32)?.takeIf(maneuverKinds::contains)
                ?: return null
            val direction = raw.boundedString("direction", 32)
                ?.takeIf(maneuverDirections::contains) ?: return null
            val instructions = raw.stringList("instructionVariants", 4, 180)
                ?.takeIf(List<String>::isNotEmpty) ?: return null
            val roadNames = raw.stringList("roadNameVariants", 4, 160) ?: return null
            val position = (raw["position"] as? Map<*, *>)?.let(::position) ?: return null
            val trafficSide = raw.boundedString("trafficSide", 12)
                ?.takeIf(trafficSides::contains) ?: return null
            val exitNumber = raw.optionalInteger("exitNumber", 1..99) ?: return null
            val distance = raw.optionalNonNegativeDouble("distanceMeters") ?: return null
            val seconds = raw.optionalNonNegativeDouble("secondsRemaining") ?: return null
            val before = raw.optionalBearing("bearingBeforeDegrees") ?: return null
            val after = raw.optionalBearing("bearingAfterDegrees") ?: return null
            val departure = raw.optionalBearing("departureBearingDegrees") ?: return null
            val stepCount = raw.integer("stepCount")?.takeIf { it in 1..32 } ?: return null
            val lanes = lanes(raw["lanes"]) ?: return null
            val engineModifier = raw.optionalBoundedString("engineModifier", 80) ?: return null
            return Maneuver(
                id = raw.boundedString("id", 220) ?: return null,
                kind = kind,
                direction = direction,
                engineType = raw.boundedString("engineType", 80) ?: return null,
                engineModifier = engineModifier.value,
                instructionVariants = instructions,
                roadNameVariants = roadNames,
                position = position,
                exitNumber = exitNumber.value,
                trafficSide = trafficSide,
                distanceMeters = distance.value,
                secondsRemaining = seconds.value,
                bearingBeforeDegrees = before.value,
                bearingAfterDegrees = after.value,
                departureBearingDegrees = departure.value,
                stepCount = stepCount,
                lanes = lanes,
            )
        }

        private fun lanes(raw: Any?): List<Lane>? {
            val values = raw as? List<*> ?: return null
            if (values.size > 8) return null
            return values.map { value ->
                val lane = value as? Map<*, *> ?: return null
                Lane(
                    indications = lane.stringList("indications", 4, 32) ?: return null,
                    valid = lane.boolean("valid") ?: return null,
                )
            }
        }

        private fun position(raw: Map<*, *>): Position? {
            val latitude = raw.finiteDouble("latitude")?.takeIf { it in -90.0..90.0 }
                ?: return null
            val longitude = raw.finiteDouble("longitude")?.takeIf { it in -180.0..180.0 }
                ?: return null
            return Position(latitude, longitude)
        }

        private fun journey(raw: Map<*, *>): Journey? {
            val remainingDistance = raw.optionalNonNegativeDouble("remainingDistanceMeters")
                ?: return null
            val remainingSeconds = raw.optionalNonNegativeLong("remainingSeconds") ?: return null
            val arrival = raw.optionalNonNegativeLong("arrivalTimeMillis") ?: return null
            val waypointName = raw.optionalBoundedString("nextWaypointName", 160) ?: return null
            val waypointDistance = raw.optionalNonNegativeDouble("nextWaypointDistanceMeters")
                ?: return null
            val waypointArrival = raw.optionalNonNegativeLong("nextWaypointArrivalTimeMillis")
                ?: return null
            return Journey(
                remainingDistanceMeters = remainingDistance.value,
                remainingSeconds = remainingSeconds.value,
                arrivalTimeMillis = arrival.value,
                nextWaypointName = waypointName.value,
                nextWaypointDistanceMeters = waypointDistance.value,
                nextWaypointArrivalTimeMillis = waypointArrival.value,
            )
        }

        private fun progress(raw: Map<*, *>): Progress? {
            val travelled = raw.optionalNonNegativeDouble("travelledMeters") ?: return null
            val total = raw.optionalNonNegativeDouble("totalMeters") ?: return null
            if (travelled.value != null && total.value != null && travelled.value > total.value) {
                return null
            }
            return Progress(travelled.value, total.value)
        }

        private fun units(raw: Map<*, *>): Units? {
            val distance = raw.optionalBoundedString("distance", 24) ?: return null
            val speed = raw.optionalBoundedString("speed", 32) ?: return null
            if (distance.value !in setOf(null, "miles", "kilometres")) return null
            if (speed.value !in setOf(null, "milesPerHour", "kilometresPerHour")) return null
            if ((distance.value == "miles") != (speed.value == "milesPerHour")) return null
            if ((distance.value == "kilometres") != (speed.value == "kilometresPerHour")) return null
            return Units(distance.value, speed.value)
        }

        private fun actions(raw: Map<*, *>): Actions? = Actions(
            canPlanRoute = raw.boolean("canPlanRoute") ?: return null,
            canFreeRoam = raw.boolean("canFreeRoam") ?: return null,
            canStartPreparedRide = raw.boolean("canStartPreparedRide") ?: return null,
            canCancelNavigation = raw.boolean("canCancelNavigation") ?: return null,
            canLeaveRide = raw.boolean("canLeaveRide") ?: return null,
        )

        private fun alert(raw: Map<*, *>): Alert? = Alert(
            message = raw.boundedString("message", 180) ?: return null,
            severity = raw.boundedString("severity", 32) ?: return null,
        )

        /**
         * Distinguishes a valid explicit null from a malformed value. Platform
         * channels preserve nulls, and every optional field must be intentional.
         */
        private data class Optional<out T>(val value: T?)

        private fun <T> optionalMap(
            raw: Map<*, *>,
            key: String,
            decode: (Map<*, *>) -> T?,
        ): Optional<T>? = when (val value = raw[key]) {
            null -> Optional(null)
            is Map<*, *> -> decode(value)?.let(::Optional)
            else -> null
        }

        private fun Map<*, *>.optionalBoundedString(key: String, max: Int): Optional<String>? {
            val value = this[key] ?: return Optional(null)
            return (value as? String)?.trim()?.takeIf(String::isNotEmpty)
                ?.take(max)?.let(::Optional)
        }

        private fun Map<*, *>.optionalInteger(key: String, range: IntRange): Optional<Int>? {
            val value = this[key] ?: return Optional(null)
            return (value as? Number)?.toInt()?.takeIf(range::contains)?.let(::Optional)
        }

        private fun Map<*, *>.optionalNonNegativeDouble(key: String): Optional<Double>? {
            val value = this[key] ?: return Optional(null)
            return (value as? Number)?.toDouble()?.takeIf { it.isFinite() && it >= 0 }
                ?.let(::Optional)
        }

        private fun Map<*, *>.optionalNonNegativeLong(key: String): Optional<Long>? {
            val value = this[key] ?: return Optional(null)
            return (value as? Number)?.toLong()?.takeIf { it >= 0 }?.let(::Optional)
        }

        private fun Map<*, *>.optionalBearing(key: String): Optional<Double>? {
            val value = this[key] ?: return Optional(null)
            return (value as? Number)?.toDouble()?.takeIf { it.isFinite() && it in 0.0..360.0 }
                ?.let(::Optional)
        }

        private fun Map<*, *>.boundedString(key: String, max: Int): String? =
            (this[key] as? String)?.trim()?.takeIf(String::isNotEmpty)?.take(max)

        private fun Map<*, *>.stringList(
            key: String,
            maxCount: Int,
            maxLength: Int,
        ): List<String>? {
            val values = this[key] as? List<*> ?: return null
            if (values.size > maxCount) return null
            val result = mutableListOf<String>()
            values.forEach { value ->
                val text = (value as? String)?.trim()?.takeIf(String::isNotEmpty)
                    ?.take(maxLength) ?: return null
                if (text !in result) result += text
            }
            return result
        }

        private fun Map<*, *>.integer(key: String): Int? = (this[key] as? Number)?.toInt()

        private fun Map<*, *>.long(key: String): Long? = (this[key] as? Number)?.toLong()

        private fun Map<*, *>.boolean(key: String): Boolean? = this[key] as? Boolean

        private fun Map<*, *>.finiteDouble(key: String): Double? =
            (this[key] as? Number)?.toDouble()?.takeIf(Double::isFinite)
    }
}

/**
 * Orders projections independently from ride state.
 *
 * A new Flutter bridge restarts its sequence at one, so a newer source may take
 * ownership by generation time. Replayed commands from the current source and
 * older commands from a retired source are rejected before they can revive
 * ended guidance or duplicate a native navigation session.
 */
internal class AndroidAutoNavigationProjectionStore {
    var latest: AndroidAutoNavigationProjectionV2? = null
        private set

    fun accept(snapshot: Map<String, Any?>): Boolean {
        val candidate = AndroidAutoNavigationProjectionV2.fromSnapshot(snapshot) ?: return false
        latest?.let { current ->
            if (candidate.sourceId == current.sourceId) {
                if (candidate.sequence <= current.sequence) return false
            } else if (candidate.generatedAtMillis < current.generatedAtMillis) {
                return false
            }
        }
        latest = candidate
        return true
    }

    fun clear() {
        latest = null
    }
}
