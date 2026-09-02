package me.osholt.ride_relay

import android.graphics.Bitmap
import android.graphics.Canvas
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import kotlin.math.sin

/**
 * The car surface, drawn at head-unit sizes on real `android.graphics`.
 *
 * The head unit itself is hard to reach: the Desktop Head Unit needs a real
 * Android Auto host, and the emulator system image ships only
 * `AndroidAutoStubPrebuilt` — a stub with no launchable activity. But what
 * Android Auto hands over is a `Surface` and a size, and both of those can be
 * supplied here. So this is the real renderer producing the real pixels, and it
 * runs in CI rather than on a bench (#602).
 *
 * Set `CAR_SURFACE_OUT` to a directory to keep the PNGs and look at them.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(manifest = Config.NONE, sdk = [34])
class ProjectedMapRendererTest {
    private val renderer = ProjectedMapRenderer()

    @Test
    fun `draws the ride at head unit sizes`() {
        for ((label, size) in SIZES) {
            for ((state, snapshot) in states()) {
                val bitmap = Bitmap.createBitmap(size.first, size.second, Bitmap.Config.ARGB_8888)
                val drew = renderer.draw(
                    canvas = Canvas(bitmap),
                    snapshot = snapshot,
                    widthPx = size.first.toFloat(),
                    heightPx = size.second.toFloat(),
                    hostDarkMode = true,
                )
                write(bitmap, "$state-$label")
                assertEquals("$state drew when it should not have", snapshot != null, drew)
                if (snapshot != null) {
                    // Something other than flat ground. A renderer that drew
                    // nothing at all would still have returned true.
                    assertNotEquals(
                        "$state drew nothing but the background",
                        bitmap.getPixel(1, 1),
                        centreOfMass(bitmap),
                    )
                }
            }
        }
    }

    @Test
    fun `nothing to draw remains a map-only surface`() {
        val bitmap = Bitmap.createBitmap(800, 480, Bitmap.Config.ARGB_8888)

        assertFalse(renderer.draw(Canvas(bitmap), null, 800f, 480f, hostDarkMode = true))
        assertUniform(bitmap)
        // Loading and ride state belong to host templates, never map pixels.
        val bare = ProjectedRideSnapshot.from(mapOf("rideState" to "Waiting to start"))
        assertFalse(renderer.draw(Canvas(bitmap), bare, 800f, 480f, hostDarkMode = true))
        assertUniform(bitmap)
    }

    @Test
    fun `car host selects day and night independently of phone theme`() {
        val phoneLight = ProjectedRideSnapshot.from(
            ride(followRider = false) + ("basemap" to mapOf("dark" to false)),
        )
        val phoneDark = ProjectedRideSnapshot.from(
            ride(followRider = false) + ("basemap" to mapOf("dark" to true)),
        )
        val night = Bitmap.createBitmap(800, 480, Bitmap.Config.ARGB_8888)
        val day = Bitmap.createBitmap(800, 480, Bitmap.Config.ARGB_8888)

        renderer.draw(Canvas(night), phoneLight, 800f, 480f, hostDarkMode = true)
        renderer.draw(Canvas(day), phoneDark, 800f, 480f, hostDarkMode = false)

        assertEquals(ProjectedMapPalette.night.groundArgb, night.getPixel(0, 0))
        assertEquals(ProjectedMapPalette.day.groundArgb, day.getPixel(0, 0))
        assertNotEquals(night.getPixel(0, 0), day.getPixel(0, 0))
    }

    @Test
    fun `host palettes keep marker outlines legible on their ground`() {
        assertNotEquals(
            ProjectedMapPalette.night.groundArgb,
            ProjectedMapPalette.night.markerHaloArgb,
        )
        assertNotEquals(
            ProjectedMapPalette.day.groundArgb,
            ProjectedMapPalette.day.markerHaloArgb,
        )
    }

    @Test
    fun `route pixels remain inside obstructed stable area`() {
        val sizes = listOf(800 to 480, 1280 to 720, 1920 to 720)
        for ((width, height) in sizes) {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val stable = ProjectedMapBounds(
                left = width * 0.28f,
                top = height * 0.12f,
                right = width * 0.96f,
                bottom = height * 0.92f,
            )
            val snapshot = ProjectedRideSnapshot.from(ride(followRider = false))

            assertTrue(
                renderer.draw(
                    canvas = Canvas(bitmap),
                    snapshot = snapshot,
                    widthPx = width.toFloat(),
                    heightPx = height.toFloat(),
                    visibleArea = ProjectedMapBounds(0f, 0f, width.toFloat(), height.toFloat()),
                    stableArea = stable,
                    hostDarkMode = true,
                ),
            )

            assertBackgroundOutside(bitmap, stable)
            assertNotEquals(bitmap.getPixel(1, 1), centreOfMass(bitmap, stable))
        }
    }

    @Test
    fun `a route with no progress split is still drawn`() {
        // Before a ride starts there is no ridden/remaining split, only the
        // route. Drawing nothing here would leave a leader reviewing a blank
        // screen.
        val snapshot = ProjectedRideSnapshot.from(
            mapOf("routePoints" to bristolToBath(), "rideState" to "Waiting to start"),
        )
        val bitmap = Bitmap.createBitmap(800, 480, Bitmap.Config.ARGB_8888)

        assertTrue(renderer.draw(Canvas(bitmap), snapshot, 800f, 480f, hostDarkMode = true))
        assertNotEquals(bitmap.getPixel(1, 1), centreOfMass(bitmap))
    }

    @Test
    fun `the bike's heading is drawn, and points where the bike points`() {
        // North-up map: without a heading a rider cannot tell whether the line
        // ahead of the dot is in front of them or behind. The field has always
        // been on the wire and used to be parsed and dropped.
        //
        // Sampled just outside the marker's white halo (radius 17) and inside
        // the arrow, so the two cannot be confused — both are white.
        val east = renderer.render(heading = 90.0)
        val north = renderer.render(heading = 0.0)
        val stationary = renderer.render(heading = null)
        write(east, "04-heading-east-800x480")

        // East: to the right of the rider, and nothing above.
        assertTrue("no arrow to the east", isWhite(east, RIDER_X + 20, RIDER_Y))
        assertFalse("an arrow to the north too", isWhite(east, RIDER_X, RIDER_Y - 20))
        // North: above the rider, and nothing to the right. A flipped rotation
        // sign draws south instead and looks just as plausible.
        assertTrue("no arrow to the north", isWhite(north, RIDER_X, RIDER_Y - 20))
        assertFalse("an arrow to the east too", isWhite(north, RIDER_X + 20, RIDER_Y))
        // No heading is a stationary bike or a fix with no course. An arrow
        // there is a claim about a direction nobody is travelling in.
        assertFalse("an arrow for a bike with no heading", isWhite(stationary, RIDER_X + 20, RIDER_Y))
        assertFalse(isWhite(stationary, RIDER_X, RIDER_Y - 20))
    }

    private fun isWhite(bitmap: Bitmap, x: Int, y: Int): Boolean =
        bitmap.getPixel(x, y) == -1

    private fun ProjectedMapRenderer.render(heading: Double?): Bitmap {
        val bitmap = Bitmap.createBitmap(800, 480, Bitmap.Config.ARGB_8888)
        val position = mutableMapOf<String, Any?>(
            "latitude" to 51.4295,
            "longitude" to -2.5079,
        )
        if (heading != null) position["headingDegrees"] = heading
        draw(
            canvas = Canvas(bitmap),
            snapshot = ProjectedRideSnapshot.from(
                mapOf(
                    "followRider" to true,
                    "routePoints" to bristolToBath(),
                    "localPosition" to position,
                    "basemap" to mapOf("dark" to true),
                ),
            ),
            widthPx = 800f,
            heightPx = 480f,
            hostDarkMode = true,
        )
        return bitmap
    }

    /** The most-used colour away from the edges, as a crude "something is here". */
    private fun centreOfMass(
        bitmap: Bitmap,
        bounds: ProjectedMapBounds = ProjectedMapBounds(
            0f,
            0f,
            bitmap.width.toFloat(),
            bitmap.height.toFloat(),
        ),
    ): Int {
        val counts = mutableMapOf<Int, Int>()
        var x = bounds.left.toInt().coerceAtLeast(0)
        while (x < bounds.right.toInt().coerceAtMost(bitmap.width)) {
            var y = bounds.top.toInt().coerceAtLeast(0)
            while (y < bounds.bottom.toInt().coerceAtMost(bitmap.height)) {
                val pixel = bitmap.getPixel(x, y)
                if (pixel != bitmap.getPixel(1, 1)) counts[pixel] = (counts[pixel] ?: 0) + 1
                y += 2
            }
            x += 2
        }
        return counts.maxByOrNull { it.value }?.key ?: bitmap.getPixel(1, 1)
    }

    private fun assertUniform(bitmap: Bitmap) {
        val expected = bitmap.getPixel(0, 0)
        for (x in 0 until bitmap.width step 16) {
            for (y in 0 until bitmap.height step 16) {
                assertEquals("non-map pixel at $x,$y", expected, bitmap.getPixel(x, y))
            }
        }
    }

    private fun assertBackgroundOutside(bitmap: Bitmap, bounds: ProjectedMapBounds) {
        val expected = bitmap.getPixel(0, 0)
        for (x in 0 until bitmap.width step 4) {
            for (y in 0 until bitmap.height step 4) {
                val inside = x >= bounds.left && x <= bounds.right &&
                    y >= bounds.top && y <= bounds.bottom
                if (!inside) {
                    assertEquals("content escaped safe area at $x,$y", expected, bitmap.getPixel(x, y))
                }
            }
        }
    }

    private fun states(): List<Pair<String, ProjectedRideSnapshot?>> = listOf(
        "01-waiting" to null,
        "02-route-overview" to ProjectedRideSnapshot.from(ride(followRider = false)),
        "03-following" to ProjectedRideSnapshot.from(ride(followRider = true)),
    )

    private fun bristolToBath(): List<Map<String, Double>> = (0..40).map { step ->
        val t = step / 40.0
        mapOf(
            "latitude" to 51.4545 - 0.0734 * t,
            "longitude" to -2.5879 + 0.2289 * t + 0.004 * sin(t * 9),
        )
    }

    /**
     * A leader out front, a rider mid-group, and a Tail End Charlie who has
     * dropped back and needs looking at.
     */
    private fun ride(followRider: Boolean): Map<String, Any?> {
        val route = bristolToBath()
        return mapOf(
            "routeName" to "Bristol to Bath",
            "rideState" to "Riding",
            "followRider" to followRider,
            "routePoints" to route,
            "riddenRoutePoints" to route.take(14),
            "remainingRoutePoints" to route.drop(13),
            "localPosition" to mapOf(
                "latitude" to 51.4295,
                "longitude" to -2.5079,
                "headingDegrees" to 118.0,
            ),
            "basemap" to mapOf("dark" to true),
            "riders" to listOf(
                mapOf(
                    "label" to "Oliver", "role" to "Ride leader", "riderColor" to "cyan",
                    "latitude" to 51.4210, "longitude" to -2.4790,
                ),
                mapOf(
                    "label" to "Simmo", "role" to "Rider", "riderColor" to "green",
                    "latitude" to 51.4330, "longitude" to -2.5210,
                ),
                mapOf(
                    "label" to "Keith", "role" to "Tail End Charlie",
                    "riderColor" to "amber", "isTec" to true, "needsAttention" to true,
                    "latitude" to 51.4460, "longitude" to -2.5660,
                ),
            ),
        )
    }

    private fun write(bitmap: Bitmap, name: String) {
        val directory = System.getenv("CAR_SURFACE_OUT") ?: return
        File(directory).mkdirs()
        File(directory, "$name.png").outputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
    }

    private companion object {
        /** The 800x480 floor most head units still report, and a widescreen one. */
        val SIZES = listOf("800x480" to (800 to 480), "1920x720" to (1920 to 720))

        /** Where `following` puts the rider on an 800x480 surface. */
        const val RIDER_X = 400
        const val RIDER_Y = 374
    }
}
