package me.osholt.ride_relay

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path

/**
 * Draws the ride onto whatever surface the head unit hands over.
 *
 * ## Why the app draws this itself
 *
 * CarPlay hands an app a `UIWindow`, so the phone's MapLibre view can simply be
 * put in it. Android Auto hands over a bare `Surface` and expects the app to
 * render onto it, so there is no equivalent of "show the map view over there".
 * What is drawn here is the ride — the route, the ridden/remaining split, the
 * group, the rider — on a plain ground rather than on basemap tiles.
 *
 * That is deliberate for a first pass, and it is the honest half of the parity
 * gap with CarPlay: no roads, no place names. It is also the half that carries
 * the information this app exists for, and unlike a GL basemap it is
 * deterministic, testable without a car, and cannot fail to a black screen at
 * 60mph. Tiles are tracked separately.
 */
internal class ProjectedMapRenderer {
    private val ridden = strokePaint(0xFF56606C.toInt(), 10f)
    private val remaining = strokePaint(0xFFFF7A1A.toInt(), 10f)
    private val routeOutline = strokePaint(0xFF10151C.toInt(), 16f)
    private val marker = Paint(Paint.ANTI_ALIAS_FLAG)
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textAlign = Paint.Align.CENTER
    }

    /**
     * @param widthPx/[heightPx] the surface size, which differs per head unit.
     * @return false when there was nothing to draw, so the caller can say why.
     */
    fun draw(
        canvas: Canvas,
        snapshot: ProjectedRideSnapshot?,
        widthPx: Float,
        heightPx: Float,
    ): Boolean {
        canvas.drawColor(if (snapshot?.darkMap != false) GROUND_DARK else GROUND_LIGHT)
        if (snapshot == null) {
            drawCentredMessage(canvas, "Waiting for the phone", widthPx, heightPx)
            return false
        }
        val camera = camera(snapshot, widthPx, heightPx)
        if (camera == null) {
            drawCentredMessage(canvas, snapshot.rideState, widthPx, heightPx)
            return false
        }
        // Ridden first, so the part still to come is drawn over the part behind
        // where they meet.
        drawPath(canvas, camera, snapshot.riddenPoints, ridden)
        drawPath(canvas, camera, snapshot.remainingPoints, remaining)
        // Only when the split is absent — drawing both puts the full-strength
        // route line over the greyed-out ridden section.
        if (snapshot.riddenPoints.isEmpty() && snapshot.remainingPoints.isEmpty()) {
            drawPath(canvas, camera, snapshot.routePoints, remaining)
        }
        for (rider in snapshot.riders) {
            val point = rider.point ?: continue
            if (rider.isLocal) continue
            if (!camera.contains(point)) continue
            drawRider(canvas, camera.x(point), camera.y(point), rider)
        }
        // The local rider last and on top: on a crowded start line it is the one
        // marker that must not be underneath somebody else.
        snapshot.localPoint?.let { point ->
            if (camera.contains(point)) {
                drawLocalRider(
                    canvas,
                    camera.x(point),
                    camera.y(point),
                    snapshot.localHeadingDegrees,
                )
            }
        }
        return true
    }

    private fun camera(
        snapshot: ProjectedRideSnapshot,
        widthPx: Float,
        heightPx: Float,
    ): ProjectedMapCamera? {
        val local = snapshot.localPoint
        if (snapshot.followRider && local != null) {
            return ProjectedMapCamera.following(
                rider = local,
                widthPx = widthPx,
                heightPx = heightPx,
                metresAcross = FOLLOW_METRES_ACROSS,
            )
        }
        // Everything worth keeping in frame, which is the route plus wherever
        // the group actually is — a rider who has gone the wrong way is exactly
        // who the leader is looking for.
        val framed = buildList {
            addAll(snapshot.routePoints)
            addAll(snapshot.remainingPoints)
            addAll(snapshot.riddenPoints)
            snapshot.riders.forEach { rider -> rider.point?.let(::add) }
            local?.let(::add)
        }
        return ProjectedMapCamera.fitting(framed, widthPx, heightPx, FIT_PADDING_PX)
    }

    private fun drawPath(
        canvas: Canvas,
        camera: ProjectedMapCamera,
        points: List<ProjectedPoint>,
        paint: Paint,
    ) {
        if (points.size < 2) return
        val path = Path()
        points.forEachIndexed { index, point ->
            val x = camera.x(point)
            val y = camera.y(point)
            if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        canvas.drawPath(path, routeOutline)
        canvas.drawPath(path, paint)
    }

    private fun drawRider(canvas: Canvas, x: Float, y: Float, rider: ProjectedRider) {
        marker.style = Paint.Style.FILL
        marker.color = rider.colourArgb
        canvas.drawCircle(x, y, RIDER_RADIUS_PX, marker)
        marker.style = Paint.Style.STROKE
        marker.strokeWidth = 3f
        marker.color = if (rider.needsAttention) ATTENTION else Color.rgb(16, 21, 28)
        canvas.drawCircle(x, y, RIDER_RADIUS_PX + 3f, marker)
        if (rider.isTec) {
            // The back of the group is the one role a leader scans for.
            marker.style = Paint.Style.STROKE
            marker.strokeWidth = 2f
            marker.color = Color.WHITE
            canvas.drawCircle(x, y, RIDER_RADIUS_PX + 8f, marker)
        }
    }

    /**
     * The rider, and which way the bike is pointing.
     *
     * The heading is drawn because the map is north-up: without it a rider has
     * no way to tell whether the line ahead of the dot is in front of them or
     * behind. The phone and CarPlay both show it and the phone has always sent
     * it — this used to parse the field and then draw a plain circle (#602).
     *
     * A null heading is a stationary bike or a fix with no course, which is
     * honest as a plain dot: an arrow pointing at the last known heading is a
     * claim about a direction nobody is travelling in.
     */
    private fun drawLocalRider(
        canvas: Canvas,
        x: Float,
        y: Float,
        headingDegrees: Double?,
    ) {
        if (headingDegrees != null) {
            canvas.save()
            // Screen degrees, not compass: the canvas rotates clockwise from
            // the positive x axis and a heading is clockwise from north.
            canvas.rotate(headingDegrees.toFloat() - 90f, x, y)
            val nose = Path().apply {
                moveTo(x + LOCAL_RADIUS_PX + 14f, y)
                lineTo(x + LOCAL_RADIUS_PX - 1f, y - 9f)
                lineTo(x + LOCAL_RADIUS_PX - 1f, y + 9f)
                close()
            }
            marker.style = Paint.Style.FILL
            marker.color = Color.WHITE
            canvas.drawPath(nose, marker)
            canvas.restore()
        }
        marker.style = Paint.Style.FILL
        marker.color = Color.WHITE
        canvas.drawCircle(x, y, LOCAL_RADIUS_PX + 4f, marker)
        marker.color = 0xFF2F80ED.toInt()
        canvas.drawCircle(x, y, LOCAL_RADIUS_PX, marker)
    }

    private fun drawCentredMessage(
        canvas: Canvas,
        message: String,
        widthPx: Float,
        heightPx: Float,
    ) {
        text.textSize = 34f
        canvas.drawText(message, widthPx / 2f, heightPx / 2f, text)
    }

    private fun strokePaint(colour: Int, width: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = colour
        style = Paint.Style.STROKE
        strokeWidth = width
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    private companion object {
        const val GROUND_DARK = 0xFF10151C.toInt()
        const val GROUND_LIGHT = 0xFFE8E4DD.toInt()
        const val ATTENTION = 0xFFFF715B.toInt()
        const val RIDER_RADIUS_PX = 11f
        const val LOCAL_RADIUS_PX = 13f
        const val FIT_PADDING_PX = 40f

        /**
         * How much road is in frame while following.
         *
         * A fixed span rather than one derived from the group, so the zoom does
         * not lurch every time the rider at the back drops out of radio range
         * and reappears.
         */
        const val FOLLOW_METRES_ACROSS = 900.0
    }
}
