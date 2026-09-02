package me.osholt.ride_relay

import android.content.Intent
import android.content.pm.ApplicationInfo
import androidx.car.app.CarAppService
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/**
 * The app, as Android Auto sees it.
 *
 * Starting the session also starts Dart if nothing else has (#602). Opening the
 * app from the car used to show "Waiting for ride status — open Tail End Charlie
 * on the phone", because the only engine belonged to the phone activity and
 * nobody had opened it. A rider putting a helmet on should not have to unlock a
 * phone first.
 */
class TailEndCharlieCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator =
        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            // Debug builds only, so the Desktop Head Unit can connect. A release
            // build validates the host, which is what stops another app on the
            // phone impersonating a car and reading the group's positions.
            HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        } else {
            // `hosts_allowlist_sample` is the only allowlist the library
            // ships, despite the name — it holds the Google-signed hosts
            // (Android Auto, Automotive OS, the Desktop Head Unit). Checked
            // against the 1.7.0 AAR: there is no non-sample array to prefer.
            HostValidator.Builder(applicationContext)
                .addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample)
                .build()
        }

    override fun onCreateSession(): Session = TailEndCharlieCarSession()
}

private class TailEndCharlieCarSession : Session() {
    private var navigationCoordinator: AndroidAutoNavigationCoordinator? = null
    private var snapshotListener: AndroidAutoSnapshotStore.Listener? = null

    override fun onCreateScreen(intent: Intent): Screen {
        RideRelayEngine.ensure(carContext)
        ensureNavigationCoordinator()
        return AndroidAutoNavigationScreen(carContext)
    }

    private fun ensureNavigationCoordinator() {
        if (navigationCoordinator != null) return
        var coordinator: AndroidAutoNavigationCoordinator? = null
        val host = AndroidAutoNavigationManagerHost(
            carContext = carContext,
            onStopNavigation = { coordinator?.hostStoppedNavigation() },
        )
        val createdCoordinator = AndroidAutoNavigationCoordinator(
            host = host,
            notification = AndroidAutoNavigationNotifier(carContext),
        ) { type, projection, reason ->
            ProjectedRideChannel.navigationEvent(
                type = type,
                navigationSessionId = projection.route?.navigationSessionId,
                routeId = projection.route?.id,
                reason = reason,
                projectionSequence = projection.sequence,
            ) {}
        }
        coordinator = createdCoordinator
        navigationCoordinator = createdCoordinator
        val listener = AndroidAutoSnapshotStore.Listener {
            createdCoordinator.accept(AndroidAutoSnapshotStore.latest?.androidAutoNavigation)
        }
        snapshotListener = listener
        AndroidAutoSnapshotStore.addListener(listener)
        createdCoordinator.accept(AndroidAutoSnapshotStore.latest?.androidAutoNavigation)
        lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onDestroy(owner: LifecycleOwner) {
                    snapshotListener?.let(AndroidAutoSnapshotStore::removeListener)
                    snapshotListener = null
                    navigationCoordinator?.close()
                    navigationCoordinator = null
                }
            },
        )
    }
}
