package me.osholt.ride_relay

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Posts and removes the one notification behind the "are you still riding?"
 * question (#859), for a rider whose phone is in a pocket.
 *
 * All the judgement is in Dart: this decides nothing and keeps no state. It is
 * registered on the process-wide engine rather than on the activity, like
 * [SpokenAudioFocusChannel], because the rider it is for has usually left the app
 * and the activity may be gone while the ride's location service keeps the
 * process, and Dart, running.
 *
 * The notification needs the permission the push flow already asks for at the
 * start of a group ride. A phone that refused it simply never shows this: the
 * question is still in the app and its countdown does not wait to be read.
 */
internal object SharingReminderChannel {
    internal const val CHANNEL = "me.osholt.ride_relay/sharing_reminder"
    internal const val METHOD_SHOW = "show"
    internal const val METHOD_CLEAR = "clear"

    private const val NOTIFICATION_CHANNEL_ID = "location_sharing_reminders"
    private const val NOTIFICATION_ID = 7410

    fun attach(context: Context, engine: FlutterEngine) {
        val application = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                METHOD_SHOW -> {
                    val title = call.argument<String>("title")
                    val body = call.argument<String>("body")
                    if (title.isNullOrEmpty() || body.isNullOrEmpty()) {
                        result.error("invalid_arguments", "A title and a body are required.", null)
                    } else {
                        result.success(show(application, title, body))
                    }
                }
                METHOD_CLEAR -> {
                    NotificationManagerCompat.from(application).cancel(NOTIFICATION_ID)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Whether the notification was posted. False when notifications are off. */
    private fun show(context: Context, title: String, body: String): Boolean {
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return false
        ensureChannel(context)
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                context,
                NOTIFICATION_ID,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val notification = NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_navigation_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .apply { contentIntent?.let(::setContentIntent) }
            .build()
        return try {
            manager.notify(NOTIFICATION_ID, notification)
            true
        } catch (_: SecurityException) {
            // Android 13+ can deny the permission between the check and the post.
            // The question is still in the app.
            false
        }
    }

    private fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Location sharing reminders",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Asks whether you are still riding with your group, and tells you if " +
                    "location sharing has stopped"
            },
        )
    }
}
