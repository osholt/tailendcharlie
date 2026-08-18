package me.osholt.ride_relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The half of the projection bridge that has no compiler.
 *
 * Android Auto talks back to the phone over a platform channel, so a wrong
 * method name is a silent `notImplemented` at runtime and a wrong reply key is
 * an empty list. Both are invisible on a bench and expensive on a head unit,
 * which has no cheap visual loop (#602).
 *
 * That class of mistake has already cost one round on this branch: the journey
 * estimate read `remainingMeters` when the phone sends
 * `remainingDistanceMeters`, and the ETA strip simply never appeared.
 */
class AndroidAutoChannelContractTest {
    @Test
    fun `every method the car sends is one the phone handles`() {
        val bridge = dartBridgeSource()
        for (method in METHODS_SENT) {
            assertTrue(
                "carplay_bridge.dart has no `case '$method'` — the car would " +
                    "get notImplemented at runtime",
                bridge.contains("case '$method':"),
            )
        }
    }

    @Test
    fun `search results are read with the keys the phone writes`() {
        val results = ProjectedRideChannel.parseDestinations(
            mapOf(
                "results" to listOf(
                    mapOf("label" to "  Bath  ", "latitude" to 51.38, "longitude" to -2.36),
                    // Each of these is missing something. A destination with no
                    // coordinates would route to whatever the geocoder returned
                    // first, which is what carrying coordinates prevents.
                    mapOf("label" to "No coordinates"),
                    mapOf("latitude" to 51.0, "longitude" to -2.0),
                    mapOf("label" to "", "latitude" to 51.0, "longitude" to -2.0),
                    "not a result",
                ),
                "error" to null,
            ),
        )

        assertEquals(1, results.size)
        assertEquals("Bath", results.single().label)
        assertEquals(51.38, results.single().latitude, 1e-9)
        assertEquals(-2.36, results.single().longitude, 1e-9)
    }

    @Test
    fun `an unparseable reply is empty rather than wrong`() {
        assertTrue(ProjectedRideChannel.parseDestinations(null).isEmpty())
        assertTrue(ProjectedRideChannel.parseDestinations("nonsense").isEmpty())
        assertTrue(ProjectedRideChannel.parseDestinations(mapOf("results" to 7)).isEmpty())
    }

    @Test
    fun `a refusal keeps the phone's own wording`() {
        assertNull(ProjectedRideChannel.okError(mapOf("ok" to true, "error" to null)))
        assertEquals(
            "Free roam is unavailable on this screen.",
            ProjectedRideChannel.okError(
                mapOf("ok" to false, "error" to "Free roam is unavailable on this screen."),
            ),
        )
        // A refusal with no message still has to say something a rider can act
        // on, rather than failing silently.
        assertEquals(
            "That did not work. Try the phone.",
            ProjectedRideChannel.okError(mapOf("ok" to false)),
        )
    }

    /**
     * Read from disk rather than duplicated here, so this cannot pass against a
     * stale copy of the contract.
     */
    private fun dartBridgeSource(): String {
        // The gradle module is apps/mobile/android/app.
        val bridge = File("../../lib/services/carplay_bridge.dart")
        assertTrue(
            "cannot find carplay_bridge.dart at ${bridge.absolutePath}",
            bridge.isFile,
        )
        return bridge.readText()
    }

    private companion object {
        val METHODS_SENT = listOf(
            ProjectedRideChannel.METHOD_FREE_ROAM,
            ProjectedRideChannel.METHOD_PREPARED_RIDE,
            ProjectedRideChannel.METHOD_SEARCH,
            ProjectedRideChannel.METHOD_PLAN,
        )
    }
}
