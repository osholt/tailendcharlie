package me.osholt.ride_relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The map on a head unit is arithmetic, and arithmetic can be checked here
 * rather than in traffic.
 *
 * There is no phone-free Android Auto emulator — the Desktop Head Unit needs a
 * real handset over `adb forward` — so unlike CarPlay there is no cheap visual
 * loop for this. These tests are the substitute, and they are the reason the
 * camera is a separate class from the drawing (#602).
 */
class ProjectedMapCameraTest {
    private val bristol = ProjectedPoint(51.4545, -2.5879)
    private val bath = ProjectedPoint(51.3811, -2.3590)

    @Test
    fun `fitting frames every point inside the surface`() {
        val camera = ProjectedMapCamera.fitting(
            points = listOf(bristol, bath),
            widthPx = 800f,
            heightPx = 480f,
            paddingPx = 40f,
        )!!

        for (point in listOf(bristol, bath)) {
            val x = camera.x(point)
            val y = camera.y(point)
            assertTrue("x=$x is off the surface", x in 0f..800f)
            assertTrue("y=$y is off the surface", y in 0f..480f)
            assertTrue(camera.contains(point))
        }
    }

    @Test
    fun `host safe areas frame content with margin on every supported shape`() {
        val cases = listOf(
            "compact" to ProjectedMapBounds(188f, 72f, 760f, 456f),
            "standard" to ProjectedMapBounds(240f, 80f, 1200f, 640f),
            "ultrawide" to ProjectedMapBounds(420f, 56f, 1880f, 664f),
        )

        for ((label, viewport) in cases) {
            val camera = ProjectedMapCamera.fitting(
                points = listOf(bristol, bath),
                viewport = viewport,
                paddingPx = 40f,
            )!!
            for (point in listOf(bristol, bath)) {
                val x = camera.x(point)
                val y = camera.y(point)
                assertTrue("$label x=$x", x in viewport.left + 39f..viewport.right - 39f)
                assertTrue("$label y=$y", y in viewport.top + 39f..viewport.bottom - 39f)
            }
        }
    }

    @Test
    fun `following places the local rider inside the obstructed safe area`() {
        val viewport = ProjectedMapBounds(260f, 64f, 800f, 440f)
        val camera = ProjectedMapCamera.following(
            rider = bristol,
            viewport = viewport,
            metresAcross = 900.0,
        )!!

        assertEquals((viewport.left + viewport.right) / 2f, camera.x(bristol), 1f)
        assertTrue(camera.y(bristol) in viewport.top..viewport.bottom)
    }

    @Test
    fun `visible and stable areas are intersected and clamped to the surface`() {
        val resolved = ProjectedMapBounds.resolve(
            widthPx = 800f,
            heightPx = 480f,
            visible = ProjectedMapBounds(-20f, 40f, 780f, 500f),
            stable = ProjectedMapBounds(180f, 0f, 820f, 440f),
        )

        assertEquals(ProjectedMapBounds(180f, 40f, 780f, 440f), resolved)
    }

    @Test
    fun `fitting centres what it frames`() {
        val camera = ProjectedMapCamera.fitting(
            points = listOf(bristol, bath),
            widthPx = 800f,
            heightPx = 480f,
            paddingPx = 40f,
        )!!

        // The midpoint of the two corners lands in the middle of the surface,
        // give or take the Mercator stretch between the two latitudes.
        val midX = (camera.x(bristol) + camera.x(bath)) / 2
        val midY = (camera.y(bristol) + camera.y(bath)) / 2
        assertTrue("midX=$midX", abs(midX - 400f) < 1f)
        assertTrue("midY=$midY", abs(midY - 240f) < 1f)
    }

    @Test
    fun `north is up and east is right`() {
        val camera = ProjectedMapCamera.fitting(
            points = listOf(bristol, bath),
            widthPx = 800f,
            heightPx = 480f,
            paddingPx = 40f,
        )!!

        // Bath is south-east of Bristol. A sign error here draws the route as a
        // mirror image of the road, which looks plausible and is wrong.
        assertTrue("Bath should be right of Bristol", camera.x(bath) > camera.x(bristol))
        assertTrue("Bath should be below Bristol", camera.y(bath) > camera.y(bristol))
    }

    @Test
    fun `a long flat route fits the axis that needs it`() {
        // Bristol to Bath is almost exactly the aspect of a head unit, so it
        // cannot tell "fit the longer axis" from "fit the shorter one" — the
        // two answers differ by 8%. A route far wider than it is tall can: fit
        // the wrong axis and it runs off both sides.
        val west = ProjectedPoint(51.45, -3.2)
        val east = ProjectedPoint(51.45, -1.0)

        val camera = ProjectedMapCamera.fitting(
            points = listOf(west, east),
            widthPx = 800f,
            heightPx = 480f,
            paddingPx = 40f,
        )!!

        for (point in listOf(west, east)) {
            val x = camera.x(point)
            assertTrue("x=$x is off the surface", x in 0f..800f)
            assertTrue(camera.contains(point))
        }
        // And it genuinely used the width, rather than shrinking to nothing.
        assertTrue(camera.x(east) - camera.x(west) > 600f)
    }

    @Test
    fun `a group stopped at the same lights still has a map`() {
        // Every rider on one point: both spans are zero and a naive fit divides
        // by them. The camera should widen rather than produce infinities.
        //
        // Both axes matter together. Widening only one still yields a finite
        // scale, because the fit takes the smaller of the two and the sane axis
        // masks the broken one — so a guard on one axis alone looks tested and
        // is not.
        val camera = ProjectedMapCamera.fitting(
            points = listOf(bristol, bristol, bristol),
            widthPx = 800f,
            heightPx = 480f,
            paddingPx = 40f,
        )!!

        val x = camera.x(bristol)
        val y = camera.y(bristol)
        assertTrue(x.isFinite() && y.isFinite())
        assertTrue(abs(x - 400f) < 1f)
        assertTrue(abs(y - 240f) < 1f)
    }

    @Test
    fun `nothing to frame is nothing to draw`() {
        assertNull(ProjectedMapCamera.fitting(emptyList(), 800f, 480f, 40f))
        // A surface with no size arrives briefly on some hosts while the
        // template settles.
        assertNull(ProjectedMapCamera.fitting(listOf(bristol), 0f, 480f, 40f))
    }

    @Test
    fun `following puts the rider below centre, looking ahead`() {
        val camera = ProjectedMapCamera.following(
            rider = bristol,
            widthPx = 800f,
            heightPx = 480f,
            metresAcross = 900.0,
        )!!

        val x = camera.x(bristol)
        val y = camera.y(bristol)
        assertTrue("x=$x should be centred", abs(x - 400f) < 1f)
        // Below the middle, so most of the surface is the road ahead. Not so far
        // down that the rider falls off the bottom.
        assertTrue("y=$y should be below centre", y > 240f)
        assertTrue("y=$y should still be on the surface", y < 480f)
    }

    @Test
    fun `following holds the requested span, whatever the latitude`() {
        // A degree of longitude is 70km in Bristol and 111km at the equator. If
        // the zoom ignored that, the same ride would frame very different
        // amounts of road depending where it happened.
        for (latitude in listOf(0.0, 51.45, 68.0)) {
            val here = ProjectedPoint(latitude, 0.0)
            val camera = ProjectedMapCamera.following(here, 800f, 480f, 900.0)!!
            // 450m east of the rider is a quarter-surface to the right.
            val metresPerDegree = 111_320.0 * kotlin.math.cos(Math.toRadians(latitude))
            val eastward = ProjectedPoint(latitude, 450.0 / metresPerDegree)
            val x = camera.x(eastward)
            assertTrue("at $latitude the span was wrong: x=$x", abs(x - 800f) < 12f)
        }
    }

    @Test
    fun `contains keeps a small margin so markers do not pop`() {
        val camera = ProjectedMapCamera.following(bristol, 800f, 480f, 900.0)!!
        val farAway = ProjectedPoint(52.5, -1.0)

        assertTrue(camera.contains(bristol))
        assertFalse(camera.contains(farAway))
    }

    @Test
    fun `mercator matches the projection the route geometry came from`() {
        // Spot values against the standard Web Mercator normalisation, because
        // a route drawn in the wrong projection sits beside the road rather
        // than on it.
        assertEquals(0.5, ProjectedMapCamera.mercatorX(0.0), 1e-12)
        assertEquals(1.0, ProjectedMapCamera.mercatorX(180.0), 1e-12)
        assertEquals(0.5, ProjectedMapCamera.mercatorY(0.0), 1e-12)
        // 85.05112878° is the top of the square.
        assertEquals(0.0, ProjectedMapCamera.mercatorY(85.05112878), 1e-9)
        // Beyond it, clamped rather than infinite.
        assertNotNull(ProjectedMapCamera.mercatorY(90.0))
        assertTrue(ProjectedMapCamera.mercatorY(90.0).isFinite())
    }

    @Test
    fun `region is the geographic inverse of the obstructed viewport`() {
        val viewport = ProjectedMapBounds(240f, 80f, 1200f, 640f)
        val camera = ProjectedMapCamera.fitting(
            points = listOf(bristol, bath),
            viewport = viewport,
            paddingPx = 40f,
        )!!

        val region = camera.region()
        val northWest = ProjectedPoint(region.north, region.west)
        val southEast = ProjectedPoint(region.south, region.east)
        assertEquals(viewport.left, camera.x(northWest), 0.01f)
        assertEquals(viewport.top, camera.y(northWest), 0.01f)
        assertEquals(viewport.right, camera.x(southEast), 0.01f)
        assertEquals(viewport.bottom, camera.y(southEast), 0.01f)
        assertTrue(region.north > region.south)
        assertTrue(region.east > region.west)
    }
}
