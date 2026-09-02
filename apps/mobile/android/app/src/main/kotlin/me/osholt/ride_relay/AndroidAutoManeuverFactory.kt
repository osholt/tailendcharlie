package me.osholt.ride_relay

import androidx.car.app.navigation.model.Maneuver
import androidx.car.app.navigation.model.Step

/** One typed manoeuvre mapping shared by the host turn card, cluster and notification data. */
internal object AndroidAutoManeuverFactory {
    fun step(value: AndroidAutoNavigationProjectionV2.Maneuver): Step =
        Step.Builder()
            .setCue(value.instructionVariants.first())
            .setManeuver(maneuver(value))
            .apply { value.roadNameVariants.firstOrNull()?.let { setRoad(it) } }
            .build()

    fun maneuver(value: AndroidAutoNavigationProjectionV2.Maneuver): Maneuver {
        val type = type(value)
        return Maneuver.Builder(type).apply {
            if (
                value.kind == "roundabout" &&
                value.exitNumber != null &&
                type in ROUNDABOUT_WITH_EXIT_TYPES
            ) {
                setRoundaboutExitNumber(value.exitNumber)
            }
        }.build()
    }

    private fun type(value: AndroidAutoNavigationProjectionV2.Maneuver): Int = when (value.kind) {
        "depart" -> Maneuver.TYPE_DEPART
        "arrive" -> when (value.direction) {
            "left", "sharpLeft", "slightLeft" -> Maneuver.TYPE_DESTINATION_LEFT
            "right", "sharpRight", "slightRight" -> Maneuver.TYPE_DESTINATION_RIGHT
            "straight" -> Maneuver.TYPE_DESTINATION_STRAIGHT
            else -> Maneuver.TYPE_DESTINATION
        }
        "roundabout" -> roundabout(value)
        "fork" -> when (value.direction) {
            "left", "sharpLeft", "slightLeft" -> Maneuver.TYPE_FORK_LEFT
            "right", "sharpRight", "slightRight" -> Maneuver.TYPE_FORK_RIGHT
            else -> Maneuver.TYPE_UNKNOWN
        }
        "merge" -> when (value.direction) {
            "left", "sharpLeft", "slightLeft" -> Maneuver.TYPE_MERGE_LEFT
            "right", "sharpRight", "slightRight" -> Maneuver.TYPE_MERGE_RIGHT
            else -> Maneuver.TYPE_MERGE_SIDE_UNSPECIFIED
        }
        "onRamp" -> ramp(value.direction, value.trafficSide, onRamp = true)
        "offRamp" -> ramp(value.direction, value.trafficSide, onRamp = false)
        "continueAhead" -> Maneuver.TYPE_STRAIGHT
        "useLane" -> keep(value.direction)
        "turn", "endOfRoad" -> turn(value.direction, value.trafficSide)
        else -> Maneuver.TYPE_UNKNOWN
    }

    private fun roundabout(value: AndroidAutoNavigationProjectionV2.Maneuver): Int {
        val clockwise = value.trafficSide == "left"
        return when {
            value.exitNumber != null && clockwise -> Maneuver.TYPE_ROUNDABOUT_ENTER_AND_EXIT_CW
            value.exitNumber != null -> Maneuver.TYPE_ROUNDABOUT_ENTER_AND_EXIT_CCW
            clockwise -> Maneuver.TYPE_ROUNDABOUT_ENTER_CW
            else -> Maneuver.TYPE_ROUNDABOUT_ENTER_CCW
        }
    }

    private fun turn(direction: String, trafficSide: String): Int = when (direction) {
        "sharpLeft" -> Maneuver.TYPE_TURN_SHARP_LEFT
        "left" -> Maneuver.TYPE_TURN_NORMAL_LEFT
        "slightLeft" -> Maneuver.TYPE_TURN_SLIGHT_LEFT
        "straight" -> Maneuver.TYPE_STRAIGHT
        "slightRight" -> Maneuver.TYPE_TURN_SLIGHT_RIGHT
        "right" -> Maneuver.TYPE_TURN_NORMAL_RIGHT
        "sharpRight" -> Maneuver.TYPE_TURN_SHARP_RIGHT
        "uTurn" -> if (trafficSide == "left") {
            Maneuver.TYPE_U_TURN_RIGHT
        } else {
            Maneuver.TYPE_U_TURN_LEFT
        }
        else -> Maneuver.TYPE_UNKNOWN
    }

    private fun keep(direction: String): Int = when (direction) {
        "sharpLeft", "left", "slightLeft" -> Maneuver.TYPE_KEEP_LEFT
        "sharpRight", "right", "slightRight" -> Maneuver.TYPE_KEEP_RIGHT
        "straight" -> Maneuver.TYPE_STRAIGHT
        else -> Maneuver.TYPE_UNKNOWN
    }

    private fun ramp(direction: String, trafficSide: String, onRamp: Boolean): Int = when (direction) {
        "sharpLeft" -> if (onRamp) {
            Maneuver.TYPE_ON_RAMP_SHARP_LEFT
        } else {
            Maneuver.TYPE_OFF_RAMP_NORMAL_LEFT
        }
        "left" -> if (onRamp) {
            Maneuver.TYPE_ON_RAMP_NORMAL_LEFT
        } else {
            Maneuver.TYPE_OFF_RAMP_NORMAL_LEFT
        }
        "slightLeft" -> if (onRamp) {
            Maneuver.TYPE_ON_RAMP_SLIGHT_LEFT
        } else {
            Maneuver.TYPE_OFF_RAMP_SLIGHT_LEFT
        }
        "slightRight" -> if (onRamp) {
            Maneuver.TYPE_ON_RAMP_SLIGHT_RIGHT
        } else {
            Maneuver.TYPE_OFF_RAMP_SLIGHT_RIGHT
        }
        "right" -> if (onRamp) {
            Maneuver.TYPE_ON_RAMP_NORMAL_RIGHT
        } else {
            Maneuver.TYPE_OFF_RAMP_NORMAL_RIGHT
        }
        "sharpRight" -> if (onRamp) {
            Maneuver.TYPE_ON_RAMP_SHARP_RIGHT
        } else {
            Maneuver.TYPE_OFF_RAMP_NORMAL_RIGHT
        }
        "uTurn" -> when {
            !onRamp -> Maneuver.TYPE_UNKNOWN
            trafficSide == "left" -> Maneuver.TYPE_ON_RAMP_U_TURN_RIGHT
            else -> Maneuver.TYPE_ON_RAMP_U_TURN_LEFT
        }
        else -> Maneuver.TYPE_UNKNOWN
    }

    private val ROUNDABOUT_WITH_EXIT_TYPES = setOf(
        Maneuver.TYPE_ROUNDABOUT_ENTER_AND_EXIT_CW,
        Maneuver.TYPE_ROUNDABOUT_ENTER_AND_EXIT_CCW,
    )
}
