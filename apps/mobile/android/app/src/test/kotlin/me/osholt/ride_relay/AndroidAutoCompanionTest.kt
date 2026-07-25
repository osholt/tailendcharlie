package me.osholt.ride_relay

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
                "routeName" to " Friday to the Ferry ",
                "rideState" to "Ride in progress",
                "guidanceTitle" to "At the roundabout take exit 3",
                "guidanceDetail" to "400 m",
                "groupStatus" to "5 riders visible",
                "markerStatus" to "Marker at the next junction",
                "riders" to listOf(
                    mapOf(
                        "label" to "TEC",
                        "role" to "Tail End Charlie",
                        "needsAttention" to true,
                    ),
                ),
                "alert" to mapOf("message" to "Rider off route", "severity" to "urgent"),
                "updatedAtMillis" to 123L,
            ),
        )

        assertEquals("Friday to the Ferry", snapshot.routeName)
        assertEquals("At the roundabout take exit 3", snapshot.guidanceTitle)
        assertEquals("Marker at the next junction", snapshot.markerStatus)
        assertEquals(1, snapshot.riders.size)
        assertTrue(snapshot.riders.single().needsAttention)
        assertEquals("Rider off route", snapshot.alert?.message)
        assertEquals(123L, snapshot.updatedAtMillis)
    }

    @Test
    fun `snapshot parser supplies safe empty state`() {
        val snapshot = ProjectedRideSnapshot.from(emptyMap())

        assertNull(snapshot.routeName)
        assertEquals("Open the phone app", snapshot.rideState)
        assertEquals("0 riders visible", snapshot.groupStatus)
        assertTrue(snapshot.riders.isEmpty())
        assertNull(snapshot.alert)
    }

    @Test
    fun `snapshot store updates listeners and retains latest in process`() {
        var notified = false
        val listener = AndroidAutoSnapshotStore.Listener { notified = true }
        AndroidAutoSnapshotStore.addListener(listener)

        AndroidAutoSnapshotStore.update(mapOf("rideState" to "Ride paused"))

        assertTrue(notified)
        assertEquals("Ride paused", AndroidAutoSnapshotStore.latest?.rideState)
        AndroidAutoSnapshotStore.removeListener(listener)
        notified = false
        AndroidAutoSnapshotStore.update(mapOf("rideState" to "Ride ended"))
        assertFalse(notified)
    }
}
