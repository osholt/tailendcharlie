package me.osholt.ride_relay

import kotlin.math.abs
import kotlin.math.cos
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
    val widthPx: Float,
    val heightPx: Float,
) {
    fun x(point: ProjectedPoint): Float = ((mercatorX(point.longitude) - westX) * scale).toFloat()

    fun y(point: ProjectedPoint): Float = ((mercatorY(point.latitude) - northY) * scale).toFloat()

    /** True when the point is inside the drawn area, with a little margin. */
    fun contains(point: ProjectedPoint): Boolean {
        val px = x(point)
        val py = y(point)
        return px >= -MARGIN_PX && px <= widthPx + MARGIN_PX &&
            py >= -MARGIN_PX && py <= heightPx + MARGIN_PX
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
        ): ProjectedMapCamera? {
            if (points.isEmpty() || widthPx <= 0f || heightPx <= 0f) return null
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
            val usableWidth = max(1.0, (widthPx - paddingPx * 2).toDouble())
            val usableHeight = max(1.0, (heightPx - paddingPx * 2).toDouble())
            val spanX = mercatorX(east) - mercatorX(west)
            val spanY = mercatorY(south) - mercatorY(north)
            // The smaller scale of the two, so the longer axis fits rather than
            // running off the side.
            val scale = minOf(usableWidth / spanX, usableHeight / spanY)
            val centredX = mercatorX(west) - (widthPx - spanX * scale) / 2 / scale
            val centredY = mercatorY(north) - (heightPx - spanY * scale) / 2 / scale
            return ProjectedMapCamera(centredX, centredY, scale, widthPx, heightPx)
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
        ): ProjectedMapCamera? {
            if (widthPx <= 0f || heightPx <= 0f || metresAcross <= 0.0) return null
            val metresPerMercator = metresPerMercatorUnit(rider.latitude)
            val spanMercator = metresAcross / metresPerMercator
            val scale = widthPx / spanMercator
            val westX = mercatorX(rider.longitude) - (widthPx / 2) / scale
            val northY = mercatorY(rider.latitude) -
                (heightPx * (0.5f + forwardBias)) / scale
            return ProjectedMapCamera(westX, northY, scale, widthPx, heightPx)
        }

        fun mercatorX(longitude: Double): Double = longitude / 360.0 + 0.5

        fun mercatorY(latitude: Double): Double {
            val clamped = latitude.coerceIn(-MAX_LATITUDE, MAX_LATITUDE)
            val radians = Math.toRadians(clamped)
            return 0.5 - ln(tan(radians) + 1 / cos(radians)) / (2 * Math.PI)
        }

        /** Metres per unit of the normalised Mercator square, at this latitude. */
        private fun metresPerMercatorUnit(latitude: Double): Double {
            val equatorial = 40_075_016.686
            return equatorial * abs(cos(Math.toRadians(latitude.coerceIn(-89.0, 89.0))))
        }
    }
}
