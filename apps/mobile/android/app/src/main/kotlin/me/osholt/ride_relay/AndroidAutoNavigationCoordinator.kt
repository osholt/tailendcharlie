package me.osholt.ride_relay

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.car.app.CarContext
import androidx.car.app.navigation.NavigationManager
import androidx.car.app.navigation.NavigationManagerCallback
import androidx.car.app.navigation.model.Destination
import androidx.car.app.navigation.model.Maneuver
import androidx.car.app.navigation.model.Step
import androidx.car.app.navigation.model.TravelEstimate
import androidx.car.app.navigation.model.Trip
import androidx.car.app.notification.CarAppExtender
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.math.roundToLong

/** Host operations kept behind a small seam so lifecycle arbitration is testable. */
internal interface AndroidAutoNavigationHost {
    fun navigationStarted()

    fun updateTrip(projection: AndroidAutoNavigationProjectionV2)

    fun navigationEnded()

    fun close()
}

/** The one active turn-by-turn notification required by Android Auto. */
internal interface AndroidAutoNavigationNotification {
    fun publish(projection: AndroidAutoNavigationProjectionV2)

    fun cancel()
}

/**
 * Owns the Android Auto navigation lifecycle independently from the ride.
 *
 * A host can take navigation ownership away while the group ride and its location journal
 * continue. This coordinator therefore ends only guidance, trip metadata and its notification;
 * the stop event asks Dart to suppress navigation without leaving the ride.
 */
internal class AndroidAutoNavigationCoordinator(
    private val host: AndroidAutoNavigationHost,
    private val notification: AndroidAutoNavigationNotification,
    private val testDrive: AndroidAutoNavigationTestDrive = DisabledAndroidAutoTestDrive,
    private val sendHostEvent: (
        ProjectedRideChannel.NavigationHostEvent,
        AndroidAutoNavigationProjectionV2,
        String?,
    ) -> Unit,
) {
    private data class ActiveNavigation(
        val sessionId: String,
        val routeId: String,
        val projection: AndroidAutoNavigationProjectionV2,
    )

    private var active: ActiveNavigation? = null
    private var hostRejectedSessionId: String? = null
    private var autoDriveEventSessionId: String? = null
    private var closed = false

    @Synchronized
    fun accept(projection: AndroidAutoNavigationProjectionV2?) {
        if (closed) return
        val route = projection?.route
        if (projection == null || !projection.shouldOwnNavigation || route == null) {
            endActiveNavigation()
            if (route?.navigationSessionId == hostRejectedSessionId) {
                hostRejectedSessionId = null
            }
            return
        }
        if (route.navigationSessionId == hostRejectedSessionId) return

        val current = active
        if (current?.sessionId != route.navigationSessionId) {
            endActiveNavigation()
            host.navigationStarted()
            active = ActiveNavigation(
                sessionId = route.navigationSessionId,
                routeId = route.id,
                projection = projection,
            )
            sendHostEvent(ProjectedRideChannel.NavigationHostEvent.STARTED, projection, null)
        } else {
            active = current.copy(projection = projection)
        }

        if (testDrive.enabled) {
            publishAutoDriveEvent(projection)
            testDrive.accept(projection)
        } else {
            host.updateTrip(projection)
            notification.publish(projection)
        }
    }

    /** Called only by [NavigationManagerCallback.onStopNavigation]. */
    @Synchronized
    fun hostStoppedNavigation() {
        if (closed) return
        val stopped = active ?: return
        // Clear first: a duplicate callback, or a projection published while Dart handles the
        // event, cannot produce a duplicate navigationEnded call.
        active = null
        hostRejectedSessionId = stopped.sessionId
        testDrive.clearRoute()
        host.navigationEnded()
        notification.cancel()
        sendHostEvent(
            ProjectedRideChannel.NavigationHostEvent.STOPPED,
            stopped.projection,
            "navigation ownership moved to another app",
        )
    }

    @Synchronized
    fun hostEnabledAutoDrive() {
        if (closed) return
        testDrive.enable()
        active?.projection?.let { projection ->
            publishAutoDriveEvent(projection)
            testDrive.accept(projection)
        }
    }

    @Synchronized
    fun close() {
        if (closed) return
        endActiveNavigation()
        closed = true
        testDrive.close()
        host.close()
    }

    private fun endActiveNavigation() {
        if (active == null) return
        active = null
        testDrive.clearRoute()
        host.navigationEnded()
        notification.cancel()
    }

    private fun publishAutoDriveEvent(projection: AndroidAutoNavigationProjectionV2) {
        val sessionId = projection.route?.navigationSessionId ?: return
        if (sessionId == autoDriveEventSessionId) return
        autoDriveEventSessionId = sessionId
        sendHostEvent(
            ProjectedRideChannel.NavigationHostEvent.AUTO_DRIVE_ENABLED,
            projection,
            "Android Auto test drive",
        )
    }
}

/** Real Car App Library adapter. The callback is registered before any navigation can start. */
internal class AndroidAutoNavigationManagerHost(
    carContext: CarContext,
    onStopNavigation: () -> Unit,
    onAutoDriveEnabled: () -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
) : AndroidAutoNavigationHost {
    private val navigationManager = carContext.getCarService(NavigationManager::class.java)

    init {
        navigationManager.setNavigationManagerCallback(
            ContextCompat.getMainExecutor(carContext),
            object : NavigationManagerCallback {
                override fun onStopNavigation() = onStopNavigation()

                override fun onAutoDriveEnabled() = onAutoDriveEnabled()
            },
        )
    }

    override fun navigationStarted() = navigationManager.navigationStarted()

    override fun updateTrip(projection: AndroidAutoNavigationProjectionV2) {
        navigationManager.updateTrip(AndroidAutoTripFactory.build(projection, now()))
    }

    override fun navigationEnded() = navigationManager.navigationEnded()

    override fun close() = navigationManager.clearNavigationManagerCallback()
}

/** Builds the same bounded typed manoeuvre data the host uses for its cluster and HUD. */
internal object AndroidAutoTripFactory {
    fun build(projection: AndroidAutoNavigationProjectionV2, nowMillis: Long): Trip {
        val current = projection.currentManeuver
            ?: return Trip.Builder().setLoading(true).build()
        val builder = Trip.Builder()
        builder.addStep(
            step(current),
            estimate(
                distanceMeters = current.distanceMeters,
                secondsRemaining = current.secondsRemaining,
                nowMillis = nowMillis,
            ),
        )
        projection.followingManeuver?.let { following ->
            builder.addStep(
                step(following),
                estimate(
                    distanceMeters = (current.distanceMeters ?: 0.0) +
                        (following.distanceMeters ?: 0.0),
                    secondsRemaining = if (
                        current.secondsRemaining != null && following.secondsRemaining != null
                    ) {
                        current.secondsRemaining + following.secondsRemaining
                    } else {
                        null
                    },
                    nowMillis = nowMillis,
                ),
            )
        }
        current.roadNameVariants.firstOrNull()?.let(builder::setCurrentRoad)

        val journey = projection.journey
        val route = projection.route
        if (
            journey?.remainingDistanceMeters != null &&
            journey.arrivalTimeMillis != null &&
            route != null
        ) {
            val destination = Destination.Builder()
                .setName(journey.nextWaypointName ?: route.name)
                .build()
            builder.addDestination(
                destination,
                estimate(
                    distanceMeters = journey.remainingDistanceMeters,
                    secondsRemaining = journey.remainingSeconds?.toDouble(),
                    arrivalMillis = journey.arrivalTimeMillis,
                    nowMillis = nowMillis,
                ),
            )
        }
        return builder.build()
    }

    private fun step(maneuver: AndroidAutoNavigationProjectionV2.Maneuver): Step =
        Step.Builder()
            .setCue(maneuver.instructionVariants.first())
            // #687 maps the complete typed enum. Until then, the cluster gets honest text with
            // the established neutral icon rather than no next-turn metadata at all.
            .setManeuver(Maneuver.Builder(Maneuver.TYPE_STRAIGHT).build())
            .apply { maneuver.roadNameVariants.firstOrNull()?.let { setRoad(it) } }
            .build()

    private fun estimate(
        distanceMeters: Double?,
        secondsRemaining: Double?,
        nowMillis: Long,
        arrivalMillis: Long? = null,
    ): TravelEstimate {
        val seconds = secondsRemaining?.roundToLong()?.coerceAtLeast(0)
        val arrival = ZonedDateTime.ofInstant(
            Instant.ofEpochMilli(arrivalMillis ?: (nowMillis + (seconds ?: 0) * 1_000)),
            ZoneId.systemDefault(),
        )
        return TravelEstimate.Builder(
            androidx.car.app.model.Distance.create(
                distanceMeters?.coerceAtLeast(0.0) ?: 0.0,
                androidx.car.app.model.Distance.UNIT_METERS,
            ),
            arrival,
        ).apply {
            setRemainingTimeSeconds(seconds ?: TravelEstimate.REMAINING_TIME_UNKNOWN)
        }.build()
    }
}

/** Android notification adapter for the rail widget and background turn card. */
internal class AndroidAutoNavigationNotifier(
    private val context: Context,
) : AndroidAutoNavigationNotification {
    private val manager = NotificationManagerCompat.from(context)
    private var lastKey: String? = null

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Turn-by-turn directions",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Current motorcycle navigation instruction"
                },
            )
        }
    }

    override fun publish(projection: AndroidAutoNavigationProjectionV2) {
        val maneuver = projection.currentManeuver ?: run {
            cancel()
            return
        }
        val title = maneuver.instructionVariants.first()
        val detail = maneuver.roadNameVariants.firstOrNull()
            ?: projection.route?.name
            ?: "Directions active"
        val key = "${projection.route?.navigationSessionId}|${maneuver.id}|" +
            "${maneuver.distanceMeters?.roundToLong()}|$title|$detail"
        if (key == lastKey) return

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                context,
                NOTIFICATION_ID,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val carExtension = CarAppExtender.Builder()
            .setContentTitle(title)
            .setContentText(detail)
            .setSmallIcon(R.drawable.ic_navigation_notification)
            .setImportance(NotificationManagerCompat.IMPORTANCE_HIGH)
            .apply { contentIntent?.let(::setContentIntent) }
            .build()
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_navigation_notification)
            .setContentTitle(title)
            .setContentText(detail)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_NAVIGATION)
            .apply { contentIntent?.let(::setContentIntent) }
            .extend(carExtension)
            .build()
        try {
            manager.notify(NOTIFICATION_ID, notification)
            lastKey = key
        } catch (_: SecurityException) {
            // Android 13+ can deny notification permission. Do not take down navigation or its
            // cluster metadata; the phone's permission surface remains responsible for recovery.
        }
    }

    override fun cancel() {
        lastKey = null
        manager.cancel(NOTIFICATION_ID)
    }

    private companion object {
        const val CHANNEL_ID = "turn_by_turn_navigation"
        const val NOTIFICATION_ID = 68_401
    }
}
