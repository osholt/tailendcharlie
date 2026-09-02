package me.osholt.ride_relay

import androidx.car.app.navigation.model.Maneuver
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(ParameterizedRobolectricTestRunner::class)
@Config(sdk = [35])
class AndroidAutoManeuverMappingTest(
    private val kind: String,
    private val direction: String,
    private val trafficSide: String,
    private val expected: Int,
) {
    @Test
    fun `maps the shared manoeuvre to the Android host type`() {
        assertEquals(expected, mapped(kind, direction, trafficSide).type)
    }

    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0} {1} {2} -> {3}")
        fun cases(): List<Array<Any>> = listOf(
            arrayOf("turn", "sharpLeft", "right", Maneuver.TYPE_TURN_SHARP_LEFT),
            arrayOf("turn", "left", "right", Maneuver.TYPE_TURN_NORMAL_LEFT),
            arrayOf("turn", "slightLeft", "right", Maneuver.TYPE_TURN_SLIGHT_LEFT),
            arrayOf("turn", "straight", "right", Maneuver.TYPE_STRAIGHT),
            arrayOf("turn", "slightRight", "right", Maneuver.TYPE_TURN_SLIGHT_RIGHT),
            arrayOf("turn", "right", "right", Maneuver.TYPE_TURN_NORMAL_RIGHT),
            arrayOf("turn", "sharpRight", "right", Maneuver.TYPE_TURN_SHARP_RIGHT),
            arrayOf("turn", "uTurn", "right", Maneuver.TYPE_U_TURN_LEFT),
            arrayOf("turn", "uTurn", "left", Maneuver.TYPE_U_TURN_RIGHT),
            arrayOf("turn", "unstated", "right", Maneuver.TYPE_UNKNOWN),
            arrayOf("fork", "left", "right", Maneuver.TYPE_FORK_LEFT),
            arrayOf("fork", "right", "right", Maneuver.TYPE_FORK_RIGHT),
            arrayOf("merge", "left", "right", Maneuver.TYPE_MERGE_LEFT),
            arrayOf("merge", "right", "right", Maneuver.TYPE_MERGE_RIGHT),
            arrayOf("merge", "unstated", "right", Maneuver.TYPE_MERGE_SIDE_UNSPECIFIED),
            arrayOf("onRamp", "slightLeft", "right", Maneuver.TYPE_ON_RAMP_SLIGHT_LEFT),
            arrayOf("onRamp", "sharpRight", "right", Maneuver.TYPE_ON_RAMP_SHARP_RIGHT),
            arrayOf("onRamp", "uTurn", "left", Maneuver.TYPE_ON_RAMP_U_TURN_RIGHT),
            arrayOf("offRamp", "left", "right", Maneuver.TYPE_OFF_RAMP_NORMAL_LEFT),
            arrayOf("offRamp", "slightRight", "right", Maneuver.TYPE_OFF_RAMP_SLIGHT_RIGHT),
            arrayOf("useLane", "left", "right", Maneuver.TYPE_KEEP_LEFT),
            arrayOf("useLane", "right", "right", Maneuver.TYPE_KEEP_RIGHT),
            arrayOf("depart", "unstated", "right", Maneuver.TYPE_DEPART),
            arrayOf("arrive", "left", "right", Maneuver.TYPE_DESTINATION_LEFT),
            arrayOf("arrive", "right", "right", Maneuver.TYPE_DESTINATION_RIGHT),
            arrayOf("arrive", "unstated", "right", Maneuver.TYPE_DESTINATION),
            arrayOf("continueAhead", "unstated", "right", Maneuver.TYPE_STRAIGHT),
        )
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AndroidAutoManeuverFactoryTest {
    @Test
    fun `roundabouts follow traffic side and retain exit number`() {
        val france = mapped("roundabout", "right", "right", exitNumber = 3)
        val britain = mapped("roundabout", "left", "left", exitNumber = 2)

        assertEquals(Maneuver.TYPE_ROUNDABOUT_ENTER_AND_EXIT_CCW, france.type)
        assertEquals(3, france.roundaboutExitNumber)
        assertEquals(Maneuver.TYPE_ROUNDABOUT_ENTER_AND_EXIT_CW, britain.type)
        assertEquals(2, britain.roundaboutExitNumber)
    }

    @Test
    fun `step cue road and icon come from one typed manoeuvre`() {
        val value = value(kind = "fork", direction = "right")
        val step = AndroidAutoManeuverFactory.step(value)

        assertEquals("Keep right", step.cue!!.toCharSequence().toString())
        assertEquals("D 680", step.road!!.toCharSequence().toString())
        assertEquals(Maneuver.TYPE_FORK_RIGHT, step.maneuver!!.type)
    }
}

private fun mapped(
    kind: String,
    direction: String,
    trafficSide: String = "right",
    exitNumber: Int? = null,
): Maneuver = AndroidAutoManeuverFactory.maneuver(
    value(kind, direction, trafficSide, exitNumber),
)

private fun value(
    kind: String,
    direction: String,
    trafficSide: String = "right",
    exitNumber: Int? = null,
) = AndroidAutoNavigationProjectionV2.Maneuver(
    id = "$kind-$direction",
    kind = kind,
    direction = direction,
    engineType = kind,
    engineModifier = direction,
    instructionVariants = listOf("Keep right"),
    roadNameVariants = listOf("D 680"),
    position = AndroidAutoNavigationProjectionV2.Position(45.052, 2.711),
    exitNumber = exitNumber,
    trafficSide = trafficSide,
    distanceMeters = 400.0,
    secondsRemaining = 20.0,
    bearingBeforeDegrees = null,
    bearingAfterDegrees = null,
    departureBearingDegrees = null,
    stepCount = 1,
    lanes = emptyList(),
)
