package me.osholt.ride_relay

import android.graphics.Rect
import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.SurfaceCallback
import androidx.car.app.SurfaceContainer
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.Distance
import androidx.car.app.model.Template
import androidx.car.app.navigation.model.Maneuver
import androidx.car.app.navigation.model.NavigationTemplate
import androidx.car.app.navigation.model.RoutingInfo
import androidx.car.app.navigation.model.Step
import androidx.car.app.navigation.model.TravelEstimate
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.math.roundToLong

/**
 * The head unit's ride screen: a map, a turn card, and an arrival estimate.
 *
 * Replaces the `ListTemplate` of text rows that stood here since #94. That list
 * was also a category error — the manifest declares this app under
 * `androidx.car.app.category.NAVIGATION` and requests `NAVIGATION_TEMPLATES`,
 * and then never drew a navigation template, which is a car-app-quality failure
 * as well as a disappointing screen (#602).
 *
 * The layout is `NavigationTemplate`'s, not ours: the host places the map
 * surface, the routing card and the estimate strip to suit the car it is running
 * on. All this decides is what goes in them.
 */
internal class AndroidAutoNavigationScreen(
    carContext: CarContext,
    private val renderer: ProjectedMapRenderer = ProjectedMapRenderer(),
    private val now: () -> Long = System::currentTimeMillis,
) : Screen(carContext) {

    private var surface: SurfaceContainer? = null

    private val snapshotListener = AndroidAutoSnapshotStore.Listener {
        // Both, and for different reasons: the card is host-drawn and only
        // changes when the template is rebuilt, while the map is ours and only
        // changes when we draw it.
        invalidate()
        drawMap()
    }

    private val surfaceCallback = object : SurfaceCallback {
        override fun onSurfaceAvailable(surfaceContainer: SurfaceContainer) {
            surface = surfaceContainer
            drawMap()
        }

        override fun onSurfaceDestroyed(surfaceContainer: SurfaceContainer) {
            surface = null
        }

        override fun onVisibleAreaChanged(visibleArea: Rect) {
            // The host has moved its own controls over the surface. Redraw at
            // the new size; insetting the drawing to the safe rectangle needs a
            // head unit to judge and is not guessed at here.
            drawMap()
        }
    }

    init {
        lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onCreate(owner: LifecycleOwner) {
                    carContext.getCarService(androidx.car.app.AppManager::class.java)
                        .setSurfaceCallback(surfaceCallback)
                }

                override fun onStart(owner: LifecycleOwner) {
                    AndroidAutoSnapshotStore.addListener(snapshotListener)
                    drawMap()
                }

                override fun onStop(owner: LifecycleOwner) {
                    AndroidAutoSnapshotStore.removeListener(snapshotListener)
                }
            },
        )
    }

    override fun onGetTemplate(): Template {
        val snapshot = AndroidAutoSnapshotStore.latest
        val builder = NavigationTemplate.Builder()
            .setActionStrip(actionStrip(snapshot))
        val routing = routingInfo(snapshot)
        if (routing != null) {
            builder.setNavigationInfo(routing)
        }
        travelEstimate(snapshot)?.let(builder::setDestinationTravelEstimate)
        return builder.build()
    }

    /**
     * The turn card.
     *
     * Absent rather than empty when there is no guidance: a routing card that
     * says nothing still occupies the top third of a head unit, and free roam
     * with no route is a first-class mode here as it is on the phone (#124).
     */
    private fun routingInfo(snapshot: ProjectedRideSnapshot?): RoutingInfo? {
        if (snapshot == null) {
            return RoutingInfo.Builder()
                .setLoading(true)
                .build()
        }
        val typed = snapshot.androidAutoNavigation?.currentManeuver
        if (typed != null) {
            return RoutingInfo.Builder()
                .setCurrentStep(
                    AndroidAutoManeuverFactory.step(typed),
                    distance(typed.distanceMeters),
                )
                .apply {
                    snapshot.androidAutoNavigation.followingManeuver?.let {
                        setNextStep(AndroidAutoManeuverFactory.step(it))
                    }
                }
                .build()
        }
        val guidance = snapshot.guidance ?: return null
        val step = Step.Builder()
            .setCue(guidance.title)
            .setManeuver(
                // A V1 phone has text but no classified turn. Unknown is honest;
                // claiming straight here used to contradict the spoken instruction.
                Maneuver.Builder(Maneuver.TYPE_UNKNOWN).build(),
            )
            .apply { guidance.roadName?.let { setRoad(it) } }
            .build()
        val builder = RoutingInfo.Builder().setCurrentStep(step, distance(guidance))
        return builder.build()
    }

    private fun distance(guidance: ProjectedGuidance): Distance =
        distance(guidance.distanceMeters)

    private fun distance(distanceMeters: Double?): Distance {
        val metres = distanceMeters ?: 0.0
        return Distance.create(metres.coerceAtLeast(0.0), Distance.UNIT_METERS)
    }

    /**
     * The arrival strip.
     *
     * Built from the phone's own estimate rather than recomputed here, so the
     * head unit and the phone never disagree about when the ride gets there.
     */
    private fun travelEstimate(snapshot: ProjectedRideSnapshot?): TravelEstimate? {
        val journey = snapshot?.journey ?: return null
        val arrivalMillis = journey.arrivalAtMillis ?: return null
        val remainingMetres = journey.remainingMeters ?: return null
        val arrival = ZonedDateTime.ofInstant(
            Instant.ofEpochMilli(arrivalMillis),
            ZoneId.systemDefault(),
        )
        val builder = TravelEstimate.Builder(
            Distance.create(remainingMetres.coerceAtLeast(0.0), Distance.UNIT_METERS),
            arrival,
        )
        journey.remainingSeconds?.let { seconds ->
            builder.setRemainingTimeSeconds(seconds.roundToLong().coerceAtLeast(0))
        }
        return builder.build()
    }

    /**
     * What the rider can press.
     *
     * Deliberately thin. A head unit is not the place to administer a ride, and
     * the safety case for a motorcycle is worse than for a car: these are things
     * a rider might reasonably do at a standstill and nothing that needs
     * attention while moving.
     */
    private fun actionStrip(snapshot: ProjectedRideSnapshot?): ActionStrip {
        val builder = ActionStrip.Builder()
        // Where to? first, because going somewhere is what a rider reaches for.
        if (snapshot?.canPlanRoute == true) {
            builder.addAction(
                Action.Builder()
                    .setTitle("Where to?")
                    .setOnClickListener {
                        screenManager.push(AndroidAutoDestinationScreen(carContext))
                    }
                    .build(),
            )
        }
        // Starting the prepared ride, only while the phone says it may be
        // started, and carrying the phone's own refusal when it may not.
        val rideStart = snapshot?.rideStart
        if (rideStart != null) {
            builder.addAction(
                Action.Builder()
                    .setTitle("Start ride")
                    .setOnClickListener {
                        val refusal = rideStart.unavailableReason
                        if (!rideStart.enabled && refusal != null) {
                            CarToast.makeText(carContext, refusal, CarToast.LENGTH_LONG).show()
                        } else {
                            ProjectedRideChannel.startPreparedRide {}
                        }
                    }
                    .build(),
            )
        } else if (snapshot?.canFreeRoam == true) {
            // No ride to start, so the way onto the map is free roam. Offered
            // only when the phone says it is available — location has to be
            // granted on the handset first and the phone knows whether it was.
            builder.addAction(
                Action.Builder()
                    .setTitle("Ride")
                    .setOnClickListener {
                        ProjectedRideChannel.startFreeRoam { error ->
                            if (error != null) {
                                CarToast.makeText(
                                    carContext,
                                    error,
                                    CarToast.LENGTH_LONG,
                                ).show()
                            }
                        }
                    }
                    .build(),
            )
        }
        builder.addAction(
            Action.Builder()
                .setTitle(groupSummary(snapshot))
                .setOnClickListener { screenManager.push(AndroidAutoGroupScreen(carContext)) }
                .build(),
        )
        return builder.build()
    }

    private fun groupSummary(snapshot: ProjectedRideSnapshot?): String {
        if (snapshot == null) return "Group"
        val attention = snapshot.riders.count(ProjectedRider::needsAttention)
        return if (attention > 0) "Group ($attention)" else "Group"
    }

    private fun drawMap() {
        val container = surface ?: return
        val canvas = container.surface?.lockCanvas(null) ?: return
        try {
            renderer.draw(
                canvas = canvas,
                snapshot = AndroidAutoSnapshotStore.latest?.takeIf { it.isFresh(now()) },
                widthPx = container.width.toFloat(),
                heightPx = container.height.toFloat(),
            )
        } finally {
            container.surface?.unlockCanvasAndPost(canvas)
        }
    }
}

/**
 * The group, in words, behind one press.
 *
 * The map shows where everyone is; this says who they are and who needs
 * looking at. Kept off the navigation screen because #133 settled that the
 * riding surface stays quiet.
 */
internal class AndroidAutoGroupScreen(carContext: CarContext) : Screen(carContext) {
    private val listener = AndroidAutoSnapshotStore.Listener { invalidate() }

    init {
        lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) {
                    AndroidAutoSnapshotStore.addListener(listener)
                }

                override fun onStop(owner: LifecycleOwner) {
                    AndroidAutoSnapshotStore.removeListener(listener)
                }
            },
        )
    }

    override fun onGetTemplate(): Template {
        val snapshot = AndroidAutoSnapshotStore.latest
        val rows = androidx.car.app.model.ItemList.Builder()
        if (snapshot == null || snapshot.riders.isEmpty()) {
            rows.addItem(
                androidx.car.app.model.Row.Builder()
                    .setTitle(snapshot?.groupStatus ?: "Waiting for the phone")
                    .build(),
            )
        } else {
            snapshot.alert?.let { alert ->
                rows.addItem(
                    androidx.car.app.model.Row.Builder()
                        .setTitle(alert.message)
                        .addText(alert.severity)
                        .build(),
                )
            }
            // Whoever needs attention first: on a head unit the rider scans the
            // top of the list and stops.
            snapshot.riders
                .sortedByDescending(ProjectedRider::needsAttention)
                .take(MAX_ROWS)
                .forEach { rider ->
                    rows.addItem(
                        androidx.car.app.model.Row.Builder()
                            .setTitle(rider.label)
                            .addText(
                                if (rider.needsAttention) {
                                    "${rider.role} · needs attention"
                                } else {
                                    rider.role
                                },
                            )
                            .build(),
                    )
                }
        }
        return androidx.car.app.model.ListTemplate.Builder()
            .setSingleList(rows.build())
            .setHeader(
                androidx.car.app.model.Header.Builder()
                    .setTitle("Group")
                    .setStartHeaderAction(Action.BACK)
                    .build(),
            )
            .build()
    }

    private companion object {
        /** The host refuses a longer list, and refuses it by throwing. */
        const val MAX_ROWS = 6
    }
}
