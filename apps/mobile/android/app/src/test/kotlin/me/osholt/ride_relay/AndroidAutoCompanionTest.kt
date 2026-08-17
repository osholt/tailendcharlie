package me.osholt.ride_relay

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidAutoCompanionTest {
    @After
    fun cleanUp() {
        AndroidAutoSnapshotStore.clearForTesting()
    }

    @Test
    fun `snapshot parser bounds untrusted phone data`() {
        val snapshot = ProjectedRideSnapshot.from(
            mapOf(
                "routeName" to "  Friday to the Ferry  ",
                "rideState" to "Riding",
                "guidanceTitle" to "At the roundabout take exit 3",
                "markerStatus" to "Marker at the next junction",
                "updatedAtMillis" to 123L,
                "riders" to listOf(
                    mapOf(
                        "label" to "Keith",
                        "role" to "Tail End Charlie",
                        "needsAttention" to true,
                        "latitude" to 51.45,
                        "longitude" to -2.58,
                    ),
                    // Not a map, and a map that is not a rider. Neither should
                    // reach the head unit as a row.
                    "not a rider",
                    mapOf("label" to "x".repeat(400)),
                ),
                "alert" to mapOf("message" to "Rider off route", "severity" to "urgent"),
            ),
        )

        assertEquals("Friday to the Ferry", snapshot.routeName)
        assertEquals("At the roundabout take exit 3", snapshot.guidance?.title)
        assertEquals("Marker at the next junction", snapshot.markerStatus)
        assertEquals(2, snapshot.riders.size)
        assertTrue(snapshot.riders.first().needsAttention)
        assertEquals("Rider off route", snapshot.alert?.message)
        assertEquals(123L, snapshot.updatedAtMillis)
        // A display name is whatever somebody typed on their phone.
        assertEquals(120, snapshot.riders.last().label.length)
    }

    @Test
    fun `snapshot parser supplies safe empty state`() {
        val snapshot = ProjectedRideSnapshot.from(emptyMap())

        assertNull(snapshot.routeName)
        assertEquals("Open the phone app", snapshot.rideState)
        assertEquals("0 riders visible", snapshot.groupStatus)
        assertTrue(snapshot.riders.isEmpty())
        assertNull(snapshot.alert)
        assertNull(snapshot.guidance)
        assertNull(snapshot.journey)
        assertTrue(snapshot.routePoints.isEmpty())
    }

    @Test
    fun `route geometry and the progress split reach the head unit`() {
        // The whole of #602 in one assertion: every one of these fields arrived
        // on every tick and was dropped, which is why the car could only ever
        // show text.
        val snapshot = ProjectedRideSnapshot.from(
            mapOf(
                "routePoints" to listOf(
                    mapOf("latitude" to 51.45, "longitude" to -2.59),
                    mapOf("latitude" to 51.46, "longitude" to -2.58),
                ),
                "riddenRoutePoints" to listOf(
                    mapOf("latitude" to 51.45, "longitude" to -2.59),
                ),
                "remainingRoutePoints" to listOf(
                    mapOf("latitude" to 51.455, "longitude" to -2.585),
                    mapOf("latitude" to 51.46, "longitude" to -2.58),
                ),
                "localPosition" to mapOf(
                    "latitude" to 51.452,
                    "longitude" to -2.587,
                    "headingDegrees" to 47.5,
                ),
                "followRider" to true,
                "distanceUnit" to "miles",
            ),
        )

        assertEquals(2, snapshot.routePoints.size)
        assertEquals(1, snapshot.riddenPoints.size)
        assertEquals(2, snapshot.remainingPoints.size)
        assertEquals(51.452, snapshot.localPoint?.latitude!!, 1e-9)
        assertEquals(47.5, snapshot.localHeadingDegrees!!, 1e-9)
        assertTrue(snapshot.followRider)
        assertFalse(snapshot.metric)
    }

    @Test
    fun `journey estimate reads the key the phone actually sends`() {
        // `remainingDistanceMeters`, not `remainingMeters`. Getting this wrong
        // is silent: the strip simply never appears.
        val snapshot = ProjectedRideSnapshot.from(
            mapOf(
                "journeyProgress" to mapOf(
                    "remainingDistanceMeters" to 18400.0,
                    "remainingSeconds" to 1620,
                    "arrivalTimeMillis" to 1_776_000_000_000L,
                ),
            ),
        )

        val journey = snapshot.journey!!
        assertEquals(18400.0, journey.remainingMeters!!, 1e-9)
        assertEquals(1620.0, journey.remainingSeconds!!, 1e-9)
        assertEquals(1_776_000_000_000L, journey.arrivalAtMillis)
    }

    @Test
    fun `a dropped fix is not a position off the coast of Africa`() {
        val snapshot = ProjectedRideSnapshot.from(
            mapOf(
                "localPosition" to mapOf("latitude" to 0.0, "longitude" to 0.0),
                "riders" to listOf(
                    mapOf("label" to "Zeroed", "latitude" to 0.0, "longitude" to 0.0),
                    mapOf("label" to "Impossible", "latitude" to 991.0, "longitude" to 4.0),
                    mapOf("label" to "Real", "latitude" to 51.45, "longitude" to -2.58),
                ),
            ),
        )

        assertNull(snapshot.localPoint)
        // The riders are still listed — they are in the group — but only one of
        // them can be drawn, and a camera that framed the other two would put
        // the whole ride in the Atlantic.
        assertEquals(3, snapshot.riders.size)
        assertNull(snapshot.riders[0].point)
        assertNull(snapshot.riders[1].point)
        assertNotNull(snapshot.riders[2].point)
    }

    @Test
    fun `staleness is judged against the phone's own clock`() {
        val snapshot = ProjectedRideSnapshot.from(mapOf("updatedAtMillis" to 1_000_000L))

        assertTrue(snapshot.isFresh(1_000_000L))
        assertTrue(snapshot.isFresh(1_119_000L))
        assertFalse(snapshot.isFresh(1_121_000L))
    }

    @Test
    fun `snapshot store updates listeners and retains latest in process`() {
        var notified = 0
        val listener = AndroidAutoSnapshotStore.Listener { notified++ }
        AndroidAutoSnapshotStore.addListener(listener)

        AndroidAutoSnapshotStore.update(mapOf("rideState" to "Riding"))

        assertEquals(1, notified)
        assertEquals("Riding", AndroidAutoSnapshotStore.latest?.rideState)

        AndroidAutoSnapshotStore.removeListener(listener)
        AndroidAutoSnapshotStore.update(mapOf("rideState" to "Ended"))

        assertEquals(1, notified)
        assertEquals("Ended", AndroidAutoSnapshotStore.latest?.rideState)
    }
}
