package me.osholt.ride_relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectedBasemapProviderTest {
    private val camera = ProjectedMapCamera.following(
        rider = ProjectedPoint(51.4545, -2.5879),
        viewport = ProjectedMapBounds(240f, 80f, 1_200f, 640f),
        metresAcross = 900.0,
    )!!

    @Test
    fun `host appearance selects its own style and matching phone style json`() {
        val basemap = ProjectedBasemap(
            lightStyleUrl = "https://tiles.example.test/day",
            darkStyleUrl = "https://tiles.example.test/night",
            selectedStyleUrl = "https://tiles.example.test/night",
            selectedDark = true,
            selectedStyleJson = "{\"version\":8}",
        )

        val day = ProjectedBasemapPlan.create(basemap, camera, 2f, false)!!
        val night = ProjectedBasemapPlan.create(basemap, camera, 2f, true)!!

        assertEquals("https://tiles.example.test/day", day.styleUrl)
        assertNull(day.styleJson)
        assertEquals("https://tiles.example.test/night", night.styleUrl)
        assertEquals("{\"version\":8}", night.styleJson)
    }

    @Test
    fun `snapshot plans stay inside the bitmap budget on every host shape`() {
        val basemap = ProjectedBasemap(
            lightStyleUrl = "https://tiles.example.test/day",
            darkStyleUrl = "https://tiles.example.test/night",
            selectedStyleUrl = null,
            selectedDark = false,
            selectedStyleJson = null,
        )
        val surfaces = listOf(
            ProjectedMapBounds(188f, 72f, 760f, 456f),
            ProjectedMapBounds(240f, 80f, 1_200f, 640f),
            ProjectedMapBounds(420f, 56f, 3_780f, 1_024f),
        )

        for (surface in surfaces) {
            val hostCamera = ProjectedMapCamera.following(
                rider = ProjectedPoint(51.4545, -2.5879),
                viewport = surface,
                metresAcross = 900.0,
            )!!
            val plan = ProjectedBasemapPlan.create(basemap, hostCamera, 3.5f, true)!!
            val outputPixels = plan.widthPx.toDouble() * plan.heightPx *
                plan.pixelRatio * plan.pixelRatio
            assertTrue(outputPixels <= ProjectedBasemapPlan.MAX_BITMAP_PIXELS + 1)
            assertEquals(
                surface.width / surface.height,
                plan.widthPx.toFloat() / plan.heightPx,
                0.01f,
            )
            assertEquals(hostCamera.region(), plan.region)
        }
    }

    @Test
    fun `no style or camera produces no native map work`() {
        assertNull(ProjectedBasemapPlan.create(null, camera, 2f, true))
        assertNull(
            ProjectedBasemapPlan.create(
                ProjectedBasemap(
                    lightStyleUrl = "https://tiles.example.test/day",
                    darkStyleUrl = "https://tiles.example.test/night",
                    selectedStyleUrl = null,
                    selectedDark = false,
                    selectedStyleJson = null,
                ),
                null,
                2f,
                true,
            ),
        )
    }
}
