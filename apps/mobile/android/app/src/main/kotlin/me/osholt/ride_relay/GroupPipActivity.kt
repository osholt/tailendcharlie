package me.osholt.ride_relay

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.os.Bundle
import android.util.AttributeSet
import android.util.Rational
import android.view.View
import java.lang.ref.WeakReference
import java.util.concurrent.CopyOnWriteArraySet
import kotlin.math.max
import kotlin.math.min

data class GroupPipPoint(
    val latitude: Double,
    val longitude: Double,
)

data class GroupPipMarker(
    val point: GroupPipPoint,
    val label: String,
    val colourArgb: Int,
    val kind: String,
    val isLocal: Boolean,
)

data class GroupPipSnapshot(
    val routePaths: List<List<GroupPipPoint>> = emptyList(),
    val markers: List<GroupPipMarker> = emptyList(),
    val status: String? = null,
    val alert: Boolean = false,
)

object GroupPipSnapshotStore {
    private val listeners = CopyOnWriteArraySet<(GroupPipSnapshot) -> Unit>()

    @Volatile
    var latest = GroupPipSnapshot()
        private set

    fun update(arguments: Any?): GroupPipSnapshot {
        val payload = arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
        val routePaths = (payload["routePaths"] as? List<*>)
            .orEmpty()
            .take(50)
            .mapNotNull { rawPath ->
                val points = (rawPath as? List<*>)
                    .orEmpty()
                    .take(500)
                    .mapNotNull(::pointFrom)
                points.takeIf { it.size >= 2 }
            }
        val markers = (payload["markers"] as? List<*>)
            .orEmpty()
            .take(100)
            .mapNotNull(::markerFrom)
        val status = (payload["status"] as? String)
            ?.trim()
            ?.take(80)
            ?.takeIf(String::isNotEmpty)
        latest = GroupPipSnapshot(
            routePaths = routePaths,
            markers = markers,
            status = status,
            alert = payload["alert"] as? Boolean ?: false,
        )
        listeners.forEach { it(latest) }
        return latest
    }

    fun addListener(listener: (GroupPipSnapshot) -> Unit) {
        listeners.add(listener)
        listener(latest)
    }

    fun removeListener(listener: (GroupPipSnapshot) -> Unit) {
        listeners.remove(listener)
    }

    private fun pointFrom(raw: Any?): GroupPipPoint? {
        val value = raw as? Map<*, *> ?: return null
        val latitude = (value["latitude"] as? Number)?.toDouble() ?: return null
        val longitude = (value["longitude"] as? Number)?.toDouble() ?: return null
        if (!latitude.isFinite() || latitude !in -90.0..90.0) return null
        if (!longitude.isFinite() || longitude !in -180.0..180.0) return null
        return GroupPipPoint(latitude, longitude)
    }

    private fun markerFrom(raw: Any?): GroupPipMarker? {
        val value = raw as? Map<*, *> ?: return null
        val point = pointFrom(value) ?: return null
        val label = (value["label"] as? String)?.trim()?.take(40).orEmpty()
        val colourArgb = (value["colourArgb"] as? Number)?.toInt() ?: Color.CYAN
        val kind = (value["kind"] as? String)
            ?.takeIf { it == "rider" || it == "hazard" }
            ?: "hazard"
        return GroupPipMarker(
            point = point,
            label = label,
            colourArgb = colourArgb,
            kind = kind,
            isLocal = value["isLocal"] as? Boolean ?: false,
        )
    }
}

class GroupPipActivity : Activity() {
    companion object {
        private var current = WeakReference<GroupPipActivity>(null)

        fun closeCurrent() {
            current.get()?.finishAndRemoveTask()
        }

        fun isRunning(): Boolean {
            val activity = current.get() ?: return false
            return !activity.isFinishing && !activity.isDestroyed
        }
    }

    private lateinit var mapView: GroupPipView
    private var requestedPictureInPicture = false
    private val pictureInPictureParams = PictureInPictureParams.Builder()
        .setAspectRatio(Rational(16, 9))
        .build()
    private val snapshotListener: (GroupPipSnapshot) -> Unit = { snapshot ->
        runOnUiThread { mapView.snapshot = snapshot }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = WeakReference(this)
        mapView = GroupPipView(this)
        setContentView(mapView)
        GroupPipSnapshotStore.addListener(snapshotListener)
        setPictureInPictureParams(pictureInPictureParams)
    }

    override fun onResume() {
        super.onResume()
        if (!requestedPictureInPicture) {
            requestedPictureInPicture = true
            mapView.post {
                if (
                    !isFinishing &&
                    !enterPictureInPictureMode(pictureInPictureParams)
                ) {
                    finish()
                }
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        mapView.compact = isInPictureInPictureMode
    }

    override fun onDestroy() {
        GroupPipSnapshotStore.removeListener(snapshotListener)
        if (current.get() === this) current.clear()
        super.onDestroy()
    }
}

class GroupPipView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val routePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(255, 122, 26)
        style = Paint.Style.STROKE
        strokeWidth = 5f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val routeBorderPaint = Paint(routePaint).apply {
        color = Color.rgb(16, 21, 28)
        strokeWidth = 9f
    }

    var snapshot: GroupPipSnapshot = GroupPipSnapshot()
        set(value) {
            field = value
            invalidate()
        }

    var compact: Boolean = false
        set(value) {
            field = value
            invalidate()
        }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawColor(Color.rgb(21, 30, 40))
        val allPoints = buildList {
            snapshot.routePaths.forEach(::addAll)
            snapshot.markers.forEach { add(it.point) }
        }
        if (allPoints.isEmpty()) {
            drawWaiting(canvas)
            return
        }

        var west = allPoints.minOf { it.longitude }
        var east = allPoints.maxOf { it.longitude }
        var south = allPoints.minOf { it.latitude }
        var north = allPoints.maxOf { it.latitude }
        if (east - west < 0.0005) {
            west -= 0.00025
            east += 0.00025
        }
        if (north - south < 0.0005) {
            south -= 0.00025
            north += 0.00025
        }
        val topInset = if (snapshot.status == null && !snapshot.alert) 8f else 30f
        val left = 10f
        val right = width - 10f
        val top = topInset
        val bottom = height - 10f

        fun project(point: GroupPipPoint): Pair<Float, Float> {
            val x = left + ((point.longitude - west) / (east - west)).toFloat() * (right - left)
            val y = bottom - ((point.latitude - south) / (north - south)).toFloat() * (bottom - top)
            return x to y
        }

        for (routePath in snapshot.routePaths) {
            val path = Path()
            routePath.forEachIndexed { index, point ->
                val (x, y) = project(point)
                if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            canvas.drawPath(path, routeBorderPaint)
            canvas.drawPath(path, routePaint)
        }
        for (marker in snapshot.markers) {
            val (x, y) = project(marker.point)
            val radius = if (marker.kind == "rider") 8f else 7f
            paint.style = Paint.Style.FILL
            paint.color = marker.colourArgb
            canvas.drawCircle(x, y, radius, paint)
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = if (marker.isLocal) 4f else 2f
            paint.color = if (marker.isLocal) Color.WHITE else Color.rgb(16, 21, 28)
            canvas.drawCircle(x, y, radius + 2f, paint)
        }
        drawStatus(canvas)
    }

    private fun drawWaiting(canvas: Canvas) {
        paint.style = Paint.Style.FILL
        paint.color = Color.WHITE
        paint.textAlign = Paint.Align.CENTER
        paint.textSize = if (compact) 18f else 22f
        canvas.drawText("Waiting for group positions", width / 2f, height / 2f, paint)
    }

    private fun drawStatus(canvas: Canvas) {
        val status = snapshot.status
        if (status != null) {
            paint.style = Paint.Style.FILL
            paint.color = Color.WHITE
            paint.textAlign = Paint.Align.LEFT
            paint.textSize = if (compact) 16f else 19f
            canvas.drawText(status, 10f, 21f, paint)
        }
        if (snapshot.alert) {
            val centerX = width - 18f
            paint.style = Paint.Style.FILL
            paint.color = Color.rgb(255, 113, 91)
            canvas.drawCircle(centerX, 16f, 11f, paint)
            paint.color = Color.WHITE
            paint.textAlign = Paint.Align.CENTER
            paint.textSize = 16f
            paint.isFakeBoldText = true
            canvas.drawText("!", centerX, 22f, paint)
            paint.isFakeBoldText = false
        }
    }
}
