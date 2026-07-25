package me.osholt.ride_relay

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import androidx.car.app.CarAppService
import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.model.Action
import androidx.car.app.model.Header
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.Template
import androidx.car.app.validation.HostValidator
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.CopyOnWriteArraySet

internal data class ProjectedRider(
    val label: String,
    val role: String,
    val needsAttention: Boolean,
)

internal data class ProjectedAlert(
    val message: String,
    val severity: String,
)

internal data class ProjectedRideSnapshot(
    val routeName: String?,
    val rideState: String,
    val guidanceTitle: String?,
    val guidanceDetail: String?,
    val groupStatus: String,
    val markerStatus: String?,
    val riders: List<ProjectedRider>,
    val alert: ProjectedAlert?,
    val updatedAtMillis: Long,
) {
    companion object {
        fun from(raw: Map<String, Any?>): ProjectedRideSnapshot {
            val riders = (raw["riders"] as? List<*>)
                .orEmpty()
                .mapNotNull { item ->
                    val rider = item as? Map<*, *> ?: return@mapNotNull null
                    ProjectedRider(
                        label = rider.string("label", "Rider"),
                        role = rider.string("role", "Rider"),
                        needsAttention = rider["needsAttention"] == true,
                    )
                }
                .take(24)
            val rawAlert = raw["alert"] as? Map<*, *>
            val alert = rawAlert?.let {
                ProjectedAlert(
                    message = it.string("message", "Ride alert"),
                    severity = it.string("severity", "alert"),
                )
            }
            return ProjectedRideSnapshot(
                routeName = raw.boundedString("routeName"),
                rideState = raw.boundedString("rideState") ?: "Open the phone app",
                guidanceTitle = raw.boundedString("guidanceTitle"),
                guidanceDetail = raw.boundedString("guidanceDetail"),
                groupStatus = raw.boundedString("groupStatus") ?: "${riders.size} riders visible",
                markerStatus = raw.boundedString("markerStatus"),
                riders = riders,
                alert = alert,
                updatedAtMillis = (raw["updatedAtMillis"] as? Number)?.toLong()
                    ?: System.currentTimeMillis(),
            )
        }
    }
}

private fun Map<*, *>.string(key: String, fallback: String): String =
    (this[key] as? String)?.trim()?.take(120)?.takeIf(String::isNotEmpty) ?: fallback

private fun Map<String, Any?>.boundedString(key: String): String? =
    (this[key] as? String)?.trim()?.take(120)?.takeIf(String::isNotEmpty)

internal object AndroidAutoSnapshotStore {
    fun interface Listener {
        fun onSnapshotChanged()
    }

    @Volatile
    var latest: ProjectedRideSnapshot? = null
        private set

    private val listeners = CopyOnWriteArraySet<Listener>()

    fun update(raw: Map<String, Any?>) {
        latest = ProjectedRideSnapshot.from(raw)
        listeners.forEach(Listener::onSnapshotChanged)
    }

    fun addListener(listener: Listener) {
        listeners.add(listener)
    }

    fun removeListener(listener: Listener) {
        listeners.remove(listener)
    }

    internal fun clearForTesting() {
        latest = null
        listeners.clear()
    }
}

class TailEndCharlieCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator =
        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        } else {
            HostValidator.Builder(applicationContext)
                .addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample)
                .build()
        }

    override fun onCreateSession(): Session = TailEndCharlieCarSession()
}

private class TailEndCharlieCarSession : Session() {
    override fun onCreateScreen(intent: Intent): Screen =
        TailEndCharlieStatusScreen(carContext)
}

private class TailEndCharlieStatusScreen(carContext: CarContext) : Screen(carContext) {
    private val listener = AndroidAutoSnapshotStore.Listener { invalidate() }
    private val handler = Handler(Looper.getMainLooper())
    private val refreshFreshness = object : Runnable {
        override fun run() {
            invalidate()
            handler.postDelayed(this, 15_000)
        }
    }

    init {
        lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) {
                    AndroidAutoSnapshotStore.addListener(listener)
                    handler.post(refreshFreshness)
                }

                override fun onStop(owner: LifecycleOwner) {
                    AndroidAutoSnapshotStore.removeListener(listener)
                    handler.removeCallbacks(refreshFreshness)
                }
            },
        )
    }

    override fun onGetTemplate(): Template {
        val snapshot = AndroidAutoSnapshotStore.latest
        val rows = ItemList.Builder()
        if (snapshot == null) {
            rows.addItem(
                Row.Builder()
                    .setTitle("Waiting for ride status")
                    .addText("Open Tail End Charlie on the phone")
                    .build(),
            )
        } else {
            rows.addItem(
                Row.Builder()
                    .setTitle(snapshot.routeName ?: "No route selected")
                    .addText(snapshot.rideState)
                    .build(),
            )
            snapshot.guidanceTitle?.let { guidance ->
                rows.addItem(
                    Row.Builder()
                        .setTitle(guidance)
                        .apply {
                            snapshot.guidanceDetail?.let(::addText)
                        }
                        .build(),
                )
            }
            snapshot.alert?.let { alert ->
                rows.addItem(
                    Row.Builder()
                        .setTitle(alert.message)
                        .addText("Priority ${alert.severity}")
                        .build(),
                )
            }
            snapshot.markerStatus?.let { marker ->
                rows.addItem(
                    Row.Builder()
                        .setTitle(marker)
                        .addText("Marker status")
                        .build(),
                )
            }
            rows.addItem(
                Row.Builder()
                    .setTitle(snapshot.groupStatus)
                    .addText(freshness(snapshot.updatedAtMillis))
                    .build(),
            )
            snapshot.riders
                .asSequence()
                .filter(ProjectedRider::needsAttention)
                .take(1)
                .forEach { rider ->
                    rows.addItem(
                        Row.Builder()
                            .setTitle("${rider.label} needs attention")
                            .addText(rider.role)
                            .build(),
                    )
                }
        }
        val template = ListTemplate.Builder().setSingleList(rows.build())
        if (carContext.carAppApiLevel >= 7) {
            template.setHeader(
                Header.Builder()
                    .setTitle("Tail End Charlie")
                    .setStartHeaderAction(Action.APP_ICON)
                    .build(),
            )
        } else {
            applyLegacyHeader(template)
        }
        return template.build()
    }

    private fun freshness(updatedAtMillis: Long): String {
        val seconds = ((System.currentTimeMillis() - updatedAtMillis).coerceAtLeast(0) / 1000)
        return when {
            seconds < 15 -> "Live from phone"
            seconds < 120 -> "Updated ${seconds}s ago"
            else -> "Phone status is stale"
        }
    }

    @Suppress("DEPRECATION")
    private fun applyLegacyHeader(template: ListTemplate.Builder) {
        template
            .setTitle("Tail End Charlie")
            .setHeaderAction(Action.APP_ICON)
    }
}
