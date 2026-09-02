package me.osholt.ride_relay

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import org.maplibre.android.MapLibre
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.snapshotter.MapSnapshotter
import kotlin.math.roundToInt

internal data class ProjectedBasemapFrame(
    val bitmap: Bitmap,
    val region: ProjectedMapRegion,
    val dark: Boolean,
)

internal data class ProjectedBasemapPlan(
    val widthPx: Int,
    val heightPx: Int,
    val pixelRatio: Float,
    val region: ProjectedMapRegion,
    val styleUrl: String,
    val styleJson: String?,
    val dark: Boolean,
) {
    companion object {
        internal const val MAX_BITMAP_PIXELS = 1920 * 1080

        fun create(
            basemap: ProjectedBasemap?,
            camera: ProjectedMapCamera?,
            density: Float,
            hostDarkMode: Boolean,
        ): ProjectedBasemapPlan? {
            if (basemap == null || camera == null) return null
            val viewport = camera.viewport
            var width = viewport.width.roundToInt().coerceAtLeast(1)
            var height = viewport.height.roundToInt().coerceAtLeast(1)
            val pixels = width.toLong() * height
            if (pixels > MAX_BITMAP_PIXELS) {
                val scale = kotlin.math.sqrt(MAX_BITMAP_PIXELS.toDouble() / pixels)
                width = (width * scale).roundToInt().coerceAtLeast(1)
                height = (height * scale).roundToInt().coerceAtLeast(1)
            }
            val pixelRatioBudget = kotlin.math.sqrt(
                MAX_BITMAP_PIXELS.toDouble() / (width.toLong() * height).coerceAtLeast(1L),
            ).toFloat()
            return ProjectedBasemapPlan(
                widthPx = width,
                heightPx = height,
                pixelRatio = density.coerceIn(1f, 3f).coerceAtMost(pixelRatioBudget),
                region = camera.region(),
                styleUrl = basemap.styleUrl(hostDarkMode),
                styleJson = basemap.styleJson(hostDarkMode),
                dark = hostDarkMode,
            )
        }
    }
}

internal interface ProjectedBasemapProvider {
    fun frame(
        snapshot: ProjectedRideSnapshot?,
        camera: ProjectedMapCamera?,
        density: Float,
        hostDarkMode: Boolean,
        onChanged: () -> Unit,
    ): ProjectedBasemapFrame?

    fun cancel()
    fun close()
}

/**
 * Off-screen MapLibre compositor for Android Auto's bare Surface.
 *
 * MapSnapshotter uses the same process-wide MapLibre FileSource as the Flutter
 * map plugin, so style resources and vector tiles already viewed/downloaded on
 * the phone remain available here without a second cache implementation.
 */
internal class MapLibreProjectedBasemapProvider(
    context: Context,
    private val now: () -> Long = System::currentTimeMillis,
) : ProjectedBasemapProvider {
    private val applicationContext = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private var active: MapSnapshotter? = null
    private var activePlan: ProjectedBasemapPlan? = null
    private var latestPlan: ProjectedBasemapPlan? = null
    private var latestFrame: ProjectedBasemapFrame? = null
    private var lastStartedAt = 0L
    private var lastFailureAt = 0L
    private var wakeScheduled = false
    private var closed = false

    override fun frame(
        snapshot: ProjectedRideSnapshot?,
        camera: ProjectedMapCamera?,
        density: Float,
        hostDarkMode: Boolean,
        onChanged: () -> Unit,
    ): ProjectedBasemapFrame? {
        if (closed) return null
        val plan = ProjectedBasemapPlan.create(
            snapshot?.basemap,
            camera,
            density,
            hostDarkMode,
        ) ?: return null
        val compatible = latestFrame?.takeIf {
            latestPlan?.styleUrl == plan.styleUrl &&
                latestPlan?.styleJson == plan.styleJson &&
                it.dark == hostDarkMode
        }
        if (activePlan != plan && latestPlan != plan) {
            startWhenAllowed(plan, onChanged)
        }
        return compatible
    }

    private fun startWhenAllowed(plan: ProjectedBasemapPlan, onChanged: () -> Unit) {
        if (active != null || closed) return
        val elapsed = now() - maxOf(lastStartedAt, lastFailureAt)
        val delay = if (lastFailureAt >= lastStartedAt) FAILURE_RETRY_MS else MIN_REFRESH_MS
        if (elapsed < delay) {
            if (!wakeScheduled) {
                wakeScheduled = true
                handler.postDelayed(
                    {
                        wakeScheduled = false
                        onChanged()
                    },
                    delay - elapsed,
                )
            }
            return
        }
        lastStartedAt = now()
        activePlan = plan
        try {
            MapLibre.getInstance(applicationContext)
            val bounds = LatLngBounds.Builder()
                .include(LatLng(plan.region.north, plan.region.west))
                .include(LatLng(plan.region.south, plan.region.east))
                .build()
            val options = MapSnapshotter.Options(plan.widthPx, plan.heightPx)
                .withRegion(bounds)
                .withPixelRatio(plan.pixelRatio)
                .withLogo(false)
                .withAttribution(true)
            if (plan.styleJson != null) {
                options.withStyleJson(plan.styleJson)
            } else {
                options.withStyle(plan.styleUrl)
            }
            val request = MapSnapshotter(applicationContext, options)
            active = request
            request.start(
                { snapshot ->
                    if (closed || active !== request) return@start
                    active = null
                    activePlan = null
                    val old = latestFrame
                    latestPlan = plan
                    latestFrame = ProjectedBasemapFrame(
                        bitmap = snapshot.bitmap,
                        region = plan.region,
                        dark = plan.dark,
                    )
                    if (old?.bitmap !== snapshot.bitmap) old?.bitmap?.recycle()
                    onChanged()
                },
                {
                    if (active === request) {
                        active = null
                        activePlan = null
                        lastFailureAt = now()
                        onChanged()
                    }
                },
            )
        } catch (_: Throwable) {
            active = null
            activePlan = null
            lastFailureAt = now()
            onChanged()
        }
    }

    override fun cancel() {
        handler.removeCallbacksAndMessages(null)
        wakeScheduled = false
        active?.cancel()
        active = null
        activePlan = null
    }

    override fun close() {
        closed = true
        cancel()
        latestFrame?.bitmap?.recycle()
        latestFrame = null
        latestPlan = null
        handler.removeCallbacksAndMessages(null)
    }

    private companion object {
        const val MIN_REFRESH_MS = 1_000L
        const val FAILURE_RETRY_MS = 15_000L
    }
}
