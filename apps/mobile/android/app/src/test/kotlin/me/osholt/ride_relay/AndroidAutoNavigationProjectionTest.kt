package me.osholt.ride_relay

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AndroidAutoNavigationProjectionTest {
    @Test
    fun `decodes the shared French V2 fixture without inferring display strings`() {
        val projection = AndroidAutoNavigationProjectionV2.fromSnapshot(fixtureSnapshot())

        assertNotNull(projection)
        projection!!
        assertEquals("android-fixture-source", projection.sourceId)
        assertEquals(7, projection.sequence)
        assertEquals("activeRide", projection.ridePhase)
        assertEquals("navigating", projection.navigationPhase)
        assertTrue(projection.shouldOwnNavigation)
        assertEquals("france-route:android-navigation", projection.route?.navigationSessionId)
        assertEquals("france-route", projection.route?.restorationId)
        assertEquals("right", projection.route?.trafficSide)
        assertEquals("roundabout", projection.currentManeuver?.kind)
        assertEquals("right", projection.currentManeuver?.direction)
        assertEquals(3, projection.currentManeuver?.exitNumber)
        assertEquals(listOf("right"), projection.currentManeuver?.lanes?.single()?.indications)
        assertEquals("slightRight", projection.followingManeuver?.direction)
        assertEquals("kilometres", projection.units.distance)
        assertEquals("fr-FR", projection.localeIdentifier)
        assertTrue(projection.followRider)
        assertTrue(projection.actions.canCancelNavigation)
        assertTrue(projection.actions.canLeaveRide)
        assertEquals("Gravel: high", projection.alert?.message)
    }

    @Test
    fun `V1 snapshots remain valid while migration is in progress`() {
        val snapshot = ProjectedRideSnapshot.from(
            mapOf(
                "routeName" to "Legacy route",
                "guidanceTitle" to "Turn right",
                "guidanceDistanceMeters" to 250.0,
            ),
        )

        assertEquals("Legacy route", snapshot.routeName)
        assertEquals("Turn right", snapshot.guidance?.title)
        assertNull(snapshot.androidAutoNavigation)
    }

    @Test
    fun `malformed typed projection is rejected rather than guessed`() {
        val missingRoute = fixtureSnapshot()
        missingRoute.projection()["route"] = null
        assertNull(AndroidAutoNavigationProjectionV2.fromSnapshot(missingRoute))

        val badCoordinate = fixtureSnapshot()
        badCoordinate.projection().map("currentManeuver").map("position")["latitude"] = 95.0
        assertNull(AndroidAutoNavigationProjectionV2.fromSnapshot(badCoordinate))

        val contradictoryOwnership = fixtureSnapshot()
        contradictoryOwnership.projection().map("navigationLifecycle")["shouldOwnNavigation"] = false
        assertNull(AndroidAutoNavigationProjectionV2.fromSnapshot(contradictoryOwnership))

        val mismatchedUnits = fixtureSnapshot()
        mismatchedUnits.projection().map("units")["speed"] = "milesPerHour"
        assertNull(AndroidAutoNavigationProjectionV2.fromSnapshot(mismatchedUnits))
    }

    @Test
    fun `store rejects replay out of order and stale source commands`() {
        val store = AndroidAutoNavigationProjectionStore()
        assertTrue(store.accept(fixtureSnapshot()))
        assertFalse(store.accept(fixtureSnapshot()))

        val outOfOrder = fixtureSnapshot()
        outOfOrder.projection()["sequence"] = 6
        assertFalse(store.accept(outOfOrder))

        val ended = endedSnapshot()
        assertTrue(store.accept(ended))
        assertEquals("ended", store.latest?.navigationPhase)

        val staleSource = fixtureSnapshot()
        staleSource.projection().apply {
            this["sourceId"] = "retired-source"
            this["sequence"] = 99
            this["generatedAtMillis"] = 1_788_344_099_999L
        }
        assertFalse(store.accept(staleSource))
        assertEquals("ended", store.latest?.navigationPhase)

        val newSource = fixtureSnapshot()
        newSource.projection().apply {
            this["sourceId"] = "replacement-source"
            this["sequence"] = 1
            this["generatedAtMillis"] = 1_788_344_200_000L
        }
        assertTrue(store.accept(newSource))
        assertEquals("replacement-source", store.latest?.sourceId)
    }

    @Test
    fun `snapshot store does not revive guidance from a rejected command`() {
        AndroidAutoSnapshotStore.clearForTesting()
        assertTrue(AndroidAutoSnapshotStore.update(fixtureSnapshot()))
        assertTrue(AndroidAutoSnapshotStore.update(endedSnapshot()))

        assertFalse(AndroidAutoSnapshotStore.update(fixtureSnapshot()))
        assertEquals("ended", AndroidAutoSnapshotStore.latest?.androidAutoNavigation?.navigationPhase)
        AndroidAutoSnapshotStore.clearForTesting()
    }

    private fun endedSnapshot(): MutableMap<String, Any?> = fixtureSnapshot().apply {
        projection()["sequence"] = 8
        projection().map("navigationLifecycle").apply {
            this["phase"] = "ended"
            this["shouldOwnNavigation"] = false
        }
        projection().map("actions")["canCancelNavigation"] = false
    }

    private fun fixtureSnapshot(): MutableMap<String, Any?> = mutableMapOf(
        "androidAutoNavigation" to jsonObjectToMap(
            JSONObject(
                javaClass.classLoader!!.getResourceAsStream("android_auto_navigation_v2.json")!!
                    .bufferedReader()
                    .use { it.readText() },
            ),
        ),
    )

    private fun jsonObjectToMap(value: JSONObject): MutableMap<String, Any?> = buildMap {
        value.keys().forEach { key -> put(key, jsonValue(value.get(key))) }
    }.toMutableMap()

    private fun jsonArrayToList(value: JSONArray): List<Any?> =
        (0 until value.length()).map { index -> jsonValue(value.get(index)) }

    private fun jsonValue(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> jsonObjectToMap(value)
        is JSONArray -> jsonArrayToList(value)
        else -> value
    }

    @Suppress("UNCHECKED_CAST")
    private fun MutableMap<String, Any?>.projection(): MutableMap<String, Any?> =
        getValue("androidAutoNavigation") as MutableMap<String, Any?>

    @Suppress("UNCHECKED_CAST")
    private fun MutableMap<String, Any?>.map(key: String): MutableMap<String, Any?> =
        getValue(key) as MutableMap<String, Any?>
}
