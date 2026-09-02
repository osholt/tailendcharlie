package me.osholt.ride_relay

import android.app.Notification
import android.app.NotificationManager
import androidx.car.app.notification.CarAppExtender
import androidx.core.app.NotificationCompat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AndroidAutoNavigationCoordinatorTest {
    @Test
    fun `starts once updates every accepted trip and ends once`() {
        val host = FakeHost()
        val notification = FakeNotification()
        val events = mutableListOf<ProjectedRideChannel.NavigationHostEvent>()
        val coordinator = AndroidAutoNavigationCoordinator(host, notification) { event, _, _ ->
            events += event
        }
        val navigating = projection()

        coordinator.accept(navigating)
        coordinator.accept(navigating.copy(sequence = 2))
        coordinator.accept(navigating.copy(sequence = 3, navigationPhase = "ended", shouldOwnNavigation = false))
        coordinator.accept(null)

        assertEquals(1, host.started)
        assertEquals(2, host.trips.size)
        assertEquals(1, host.ended)
        assertEquals(2, notification.published)
        assertEquals(1, notification.cancelled)
        assertEquals(listOf(ProjectedRideChannel.NavigationHostEvent.STARTED), events)
    }

    @Test
    fun `host preemption stops once and blocks stale ownership replay`() {
        val host = FakeHost()
        val notification = FakeNotification()
        val events = mutableListOf<Triple<ProjectedRideChannel.NavigationHostEvent, String?, String?>>()
        val coordinator = AndroidAutoNavigationCoordinator(host, notification) { event, state, reason ->
            events += Triple(event, state.route?.id, reason)
        }
        val navigating = projection()
        coordinator.accept(navigating)

        coordinator.hostStoppedNavigation()
        coordinator.hostStoppedNavigation()
        coordinator.accept(navigating.copy(sequence = 2))

        assertEquals(1, host.started)
        assertEquals(1, host.ended)
        assertEquals(1, host.trips.size)
        assertEquals(1, notification.cancelled)
        assertEquals(ProjectedRideChannel.NavigationHostEvent.STOPPED, events.last().first)
        assertEquals("route-1", events.last().second)
        assertTrue(events.last().third!!.contains("another app"))

        coordinator.accept(
            navigating.copy(sequence = 3, navigationPhase = "ended", shouldOwnNavigation = false),
        )
        coordinator.accept(navigating.copy(sequence = 4))
        assertEquals(2, host.started)
    }

    @Test
    fun `route replacement and close balance host ownership`() {
        val host = FakeHost()
        val notification = FakeNotification()
        val coordinator = AndroidAutoNavigationCoordinator(host, notification) { _, _, _ -> }
        coordinator.accept(projection())
        coordinator.accept(
            projection(
                routeId = "route-2",
                sessionId = "session-2",
            ),
        )
        coordinator.close()
        coordinator.close()
        coordinator.accept(projection(routeId = "route-3", sessionId = "session-3"))

        assertEquals(2, host.started)
        assertEquals(2, host.ended)
        assertEquals(1, host.closed)
        assertEquals(2, notification.cancelled)
    }

    @Test
    fun `trip contains current following and destination metadata`() {
        val trip = AndroidAutoTripFactory.build(projection(), 1_788_344_100_000L)

        assertFalse(trip.isLoading)
        assertEquals(2, trip.steps.size)
        assertEquals("Turn right", trip.steps[0].cue!!.toCharSequence().toString())
        assertEquals("Then keep left", trip.steps[1].cue!!.toCharSequence().toString())
        assertEquals("D 680", trip.currentRoad!!.toCharSequence().toString())
        assertEquals(1, trip.destinations.size)
        assertEquals("Puy Mary", trip.destinations.single().name!!.toCharSequence().toString())
        assertEquals(
            13_700.0,
            trip.destinationTravelEstimates.single().remainingDistance!!.displayDistance,
            0.0,
        )
    }

    @Test
    fun `missing current maneuver publishes loading trip instead of ending navigation`() {
        val trip = AndroidAutoTripFactory.build(
            projection().copy(currentManeuver = null, followingManeuver = null),
            1_788_344_100_000L,
        )

        assertTrue(trip.isLoading)
        assertTrue(trip.steps.isEmpty())
    }

    @Test
    fun `active turn notification is ongoing navigation and extended for the car`() {
        val context = RuntimeEnvironment.getApplication()
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.cancelAll()
        val notifier = AndroidAutoNavigationNotifier(context)

        notifier.publish(projection())

        val posted = manager.activeNotifications.single().notification
        assertEquals(NotificationCompat.CATEGORY_NAVIGATION, posted.category)
        assertTrue(posted.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertTrue(CarAppExtender.isExtended(posted))
        assertEquals(
            "Turn right",
            CarAppExtender(posted).contentTitle.toString(),
        )

        notifier.cancel()
        assertTrue(manager.activeNotifications.isEmpty())
    }

    private class FakeHost : AndroidAutoNavigationHost {
        var started = 0
        var ended = 0
        var closed = 0
        val trips = mutableListOf<AndroidAutoNavigationProjectionV2>()

        override fun navigationStarted() {
            started += 1
        }

        override fun updateTrip(projection: AndroidAutoNavigationProjectionV2) {
            trips += projection
        }

        override fun navigationEnded() {
            ended += 1
        }

        override fun close() {
            closed += 1
        }
    }

    private class FakeNotification : AndroidAutoNavigationNotification {
        var published = 0
        var cancelled = 0

        override fun publish(projection: AndroidAutoNavigationProjectionV2) {
            published += 1
        }

        override fun cancel() {
            cancelled += 1
        }
    }

    private fun projection(
        routeId: String = "route-1",
        sessionId: String = "session-1",
    ): AndroidAutoNavigationProjectionV2 {
        fun maneuver(id: String, cue: String, road: String, distance: Double) =
            AndroidAutoNavigationProjectionV2.Maneuver(
                id = id,
                kind = "turn",
                direction = "right",
                engineType = "turn",
                engineModifier = "right",
                instructionVariants = listOf(cue),
                roadNameVariants = listOf(road),
                position = AndroidAutoNavigationProjectionV2.Position(45.052, 2.711),
                exitNumber = null,
                trafficSide = "right",
                distanceMeters = distance,
                secondsRemaining = 20.0,
                bearingBeforeDegrees = null,
                bearingAfterDegrees = null,
                departureBearingDegrees = null,
                stepCount = 1,
                lanes = emptyList(),
            )
        return AndroidAutoNavigationProjectionV2(
            sourceId = "source",
            sequence = 1,
            generatedAtMillis = 1_788_344_100_000L,
            ridePhase = "activeRide",
            navigationPhase = "navigating",
            shouldOwnNavigation = true,
            route = AndroidAutoNavigationProjectionV2.Route(
                id = routeId,
                navigationSessionId = sessionId,
                restorationId = routeId,
                name = "To Puy Mary",
                trafficSide = "right",
            ),
            currentManeuver = maneuver("turn-1", "Turn right", "D 680", 400.0),
            followingManeuver = maneuver("turn-2", "Then keep left", "D 680", 120.0),
            journey = AndroidAutoNavigationProjectionV2.Journey(
                remainingDistanceMeters = 13_700.0,
                remainingSeconds = 1_644,
                arrivalTimeMillis = 1_788_345_744_000L,
                nextWaypointName = "Puy Mary",
                nextWaypointDistanceMeters = 13_700.0,
                nextWaypointArrivalTimeMillis = 1_788_345_744_000L,
            ),
            progress = AndroidAutoNavigationProjectionV2.Progress(1_200.0, 14_900.0),
            units = AndroidAutoNavigationProjectionV2.Units("kilometres", "kilometresPerHour"),
            localeIdentifier = "fr-FR",
            followRider = true,
            actions = AndroidAutoNavigationProjectionV2.Actions(
                canPlanRoute = false,
                canFreeRoam = false,
                canStartPreparedRide = false,
                canCancelNavigation = true,
                canLeaveRide = true,
            ),
            alert = null,
        )
    }
}
