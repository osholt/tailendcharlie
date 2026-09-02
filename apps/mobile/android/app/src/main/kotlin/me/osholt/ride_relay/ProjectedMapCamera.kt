package me.osholt.ride_relay

import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.tan

/**
 * Where the head unit's map is looking, and how a coordinate lands on it.
 *
 * Separated from the drawing so it can be tested without a `Canvas`. Everything
 * that can be wrong about a map — the wrong things in frame, a rider off the
 * edge, north-up when it should be heading-up — is arithmetic, and arithmetic
 * belongs in a plain JVM test rather than on a head unit in traffic (#602).
 *
 * Web Mercator, because the route geometry comes from a Mercator basemap and
 * anything else would put the line beside the road it describes rather than on
 * it. Latitude is clamped to the projection's usable range.
 */
internal class ProjectedMapCamera private constructor(
    private val westX: Double,
    private val northY: Double,
    private val scale: Double,
    val viewport: ProjectedMapBounds,
) {
    fun x(point: ProjectedPoint): Float = ((mercatorX(point.longitude) - westX) * scale).toFloat()

    fun y(point: ProjectedPoint): Float = ((mercatorY(point.latitude) - northY) * scale).toFloat()

    /** Geographic edges represented by this camera's unobstructed viewport. */
    fun region(): ProjectedMapRegion = ProjectedMapRegion(
        north = inverseMercatorY(northY + viewport.top / scale),
        east = inverseMercatorX(westX + viewport.right / scale),
        south = inverseMercatorY(northY + viewport.bottom / scale),
        west = inverseMercatorX(westX + viewport.left / scale),
    )

    /** True when the point is inside the drawn area, with a little margin. */
    fun contains(point: ProjectedPoint): Boolean {
        val px = x(point)
        val py = y(point)
        return px >= viewport.left - MARGIN_PX && px <= viewport.right + MARGIN_PX &&
            py >= viewport.top - MARGIN_PX && py <= viewport.bottom + MARGIN_PX
    }

    companion object {
        private const val MARGIN_PX = 48f
        private const val MIN_SPAN_DEGREES = 0.0015
        private const val MAX_LATITUDE = 85.05112878

        /**
         * Frames the whole route, the way the phone does before a ride starts.
         *
         * Returns null when there is nothing to frame, so the caller can say so
         * rather than draw an empty map centred on the Atlantic.
         */
        fun fitting(
            points: List<ProjectedPoint>,
            widthPx: Float,
            heightPx: Float,
            paddingPx: Float,
        ): ProjectedMapCamera? = fitting(
            points = points,
            viewport = ProjectedMapBounds.full(widthPx, heightPx),
            paddingPx = paddingPx,
        )

        fun fitting(
            points: List<ProjectedPoint>,
            viewport: ProjectedMapBounds?,
            paddingPx: Float,
        ): ProjectedMapCamera? {
            if (points.isEmpty() || viewport == null) return null
            var west = points.minOf { it.longitude }
            var east = points.maxOf { it.longitude }
            var south = points.minOf { it.latitude }
            var north = points.maxOf { it.latitude }
            // A single point, or a group all stopped at the same set of lights,
            // has no extent. Give it one rather than dividing by zero.
            if (east - west < MIN_SPAN_DEGREES) {
                val centre = (east + west) / 2
                west = centre - MIN_SPAN_DEGREES / 2
                east = centre + MIN_SPAN_DEGREES / 2
            }
            if (north - south < MIN_SPAN_DEGREES) {
                val centre = (north + south) / 2
                south = centre - MIN_SPAN_DEGREES / 2
                north = centre + MIN_SPAN_DEGREES / 2
            }
            val usableWidth = max(1.0, (viewport.width - paddingPx * 2).toDouble())
            val usableHeight = max(1.0, (viewport.height - paddingPx * 2).toDouble())
            val spanX = mercatorX(east) - mercatorX(west)
            val spanY = mercatorY(south) - mercatorY(north)
            // The smaller scale of the two, so the longer axis fits rather than
            // running off the side.
            val scale = minOf(usableWidth / spanX, usableHeight / spanY)
            val leftPx = viewport.left + (viewport.width - spanX * scale) / 2
            val topPx = viewport.top + (viewport.height - spanY * scale) / 2
            val centredX = mercatorX(west) - leftPx / scale
            val centredY = mercatorY(north) - topPx / scale
            return ProjectedMapCamera(centredX, centredY, scale, viewport)
        }

        /**
         * Frames the rider, the way the phone does once under way.
         *
         * The rider sits below centre rather than in the middle, because what is
         * ahead matters and what is behind does not. `metresAcross` sets the
         * zoom directly instead of deriving it from the group, so the map does
         * not lurch every time a rider at the back drops out of range.
         */
        fun following(
            rider: ProjectedPoint,
            widthPx: Float,
            heightPx: Float,
            metresAcross: Double,
            forwardBias: Float = 0.28f,
        ): ProjectedMapCamera? = following(
            rider = rider,
            viewport = ProjectedMapBounds.full(widthPx, heightPx),
            metresAcross = metresAcross,
            forwardBias = forwardBias,
        )

        fun following(
            rider: ProjectedPoint,
            viewport: ProjectedMapBounds?,
            metresAcross: Double,
            forwardBias: Float = 0.28f,
        ): ProjectedMapCamera? {
            if (viewport == null || metresAcross <= 0.0) return null
            val metresPerMercator = metresPerMercatorUnit(rider.latitude)
            val spanMercator = metresAcross / metresPerMercator
            val scale = viewport.width / spanMercator
            val riderX = viewport.left + viewport.width / 2
            val riderY = viewport.top + viewport.height * (0.5f + forwardBias)
            val westX = mercatorX(rider.longitude) - riderX / scale
            val northY = mercatorY(rider.latitude) -
                riderY / scale
            return ProjectedMapCamera(westX, northY, scale, viewport)
        }

        fun mercatorX(longitude: Double): Double = longitude / 360.0 + 0.5

        fun mercatorY(latitude: Double): Double {
            val clamped = latitude.coerceIn(-MAX_LATITUDE, MAX_LATITUDE)
            val radians = Math.toRadians(clamped)
            return 0.5 - ln(tan(radians) + 1 / cos(radians)) / (2 * Math.PI)
        }

        private fun inverseMercatorX(value: Double): Double = (value - 0.5) * 360.0

        private fun inverseMercatorY(value: Double): Double {
            val radians = 2.0 * atan(exp((0.5 - value) * 2.0 * Math.PI)) - Math.PI / 2.0
            return Math.toDegrees(radians).coerceIn(-MAX_LATITUDE, MAX_LATITUDE)
        }

        /** Metres per unit of the normalised Mercator square, at this latitude. */
        private fun metresPerMercatorUnit(latitude: Double): Double {
            val equatorial = 40_075_016.686
            return equatorial * abs(cos(Math.toRadians(latitude.coerceIn(-89.0, 89.0))))
        }
    }
}

internal data class ProjectedMapRegion(
    val north: Double,
    val east: Double,
    val south: Double,
    val west: Double,
)

/** Host-owned surface rectangle in absolute surface pixels. */
internal data class ProjectedMapBounds(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
) {
    val width: Float get() = right - left
    val height: Float get() = bottom - top

    private fun intersect(other: ProjectedMapBounds): ProjectedMapBounds? = bounded(
        left = maxOf(left, other.left),
        top = maxOf(top, other.top),
        right = minOf(right, other.right),
        bottom = minOf(bottom, other.bottom),
    )

    companion object {
        fun full(widthPx: Float, heightPx: Float): ProjectedMapBounds? = bounded(
            left = 0f,
            top = 0f,
            right = widthPx,
            bottom = heightPx,
        )

        /**
         * Uses the live visible area and the always-visible stable area together.
         * A malformed or temporarily stale callback cannot move content outside
         * the surface; if two valid callbacks do not overlap, the live area wins.
         */
        fun resolve(
            widthPx: Float,
            heightPx: Float,
            visible: ProjectedMapBounds?,
            stable: ProjectedMapBounds?,
        ): ProjectedMapBounds? {
            val surface = full(widthPx, heightPx) ?: return null
            val visibleOnSurface = visible?.intersect(surface)
            val stableOnSurface = stable?.intersect(surface)
            return when {
                visibleOnSurface != null && stableOnSurface != null ->
                    visibleOnSurface.intersect(stableOnSurface) ?: visibleOnSurface
                stableOnSurface != null -> stableOnSurface
                visibleOnSurface != null -> visibleOnSurface
                else -> surface
            }
        }

        private fun bounded(
            left: Float,
            top: Float,
            right: Float,
            bottom: Float,
        ): ProjectedMapBounds? = if (
            left.isFinite() && top.isFinite() && right.isFinite() && bottom.isFinite() &&
            right - left >= 1f && bottom - top >= 1f
        ) {
            ProjectedMapBounds(left, top, right, bottom)
        } else {
            null
        }
    }
}
