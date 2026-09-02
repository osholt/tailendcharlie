package me.osholt.ride_relay

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Owns exactly one short Android audio-focus lease for spoken driving audio.
 *
 * FlutterTTS's optional focus flag does not report a denied request and its
 * listener ignores focus loss. Keeping the lease here lets calls, Assistant and
 * another navigation app stop a prompt instead of speaking over one another.
 */
internal object SpokenAudioFocusChannel {
    internal const val CHANNEL = "me.osholt.ride_relay/spoken_audio_focus"
    internal const val METHOD_ACQUIRE = "acquire"
    internal const val METHOD_ABANDON = "abandon"
    internal const val METHOD_FOCUS_LOST = "focusLost"

    private data class Lease(
        val id: Int,
        val listener: AudioManager.OnAudioFocusChangeListener,
        val request: AudioFocusRequest?,
    )

    private var channel: MethodChannel? = null
    private var audioManager: AudioManager? = null
    private var lease: Lease? = null
    private var nextRequestId = 0

    fun attach(context: Context, engine: FlutterEngine) {
        audioManager = context.applicationContext.getSystemService(AudioManager::class.java)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also { target ->
            target.setMethodCallHandler { call, result ->
                when (call.method) {
                    METHOD_ACQUIRE -> {
                        val audioClass = call.argument<String>("audioClass")
                        if (audioClass != "navigation" && audioClass != "safety") {
                            result.error("invalid_audio_class", "A spoken audio class is required.", null)
                        } else {
                            val requestId = acquire(audioClass)
                            result.success(
                                mapOf(
                                    "granted" to (requestId != null),
                                    "requestId" to requestId,
                                ),
                            )
                        }
                    }
                    METHOD_ABANDON -> {
                        abandon(call.argument<Number>("requestId")?.toInt())
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    @Synchronized
    private fun acquire(audioClass: String): Int? {
        // A settings preview or second renderer must not steal the lease while
        // an imminent driving prompt is still playing. It can try again after
        // that owner completes or is interrupted.
        if (lease != null) return null
        val manager = audioManager ?: return null
        val requestId = ++nextRequestId
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            if (change < AudioManager.AUDIOFOCUS_GAIN) {
                focusLost(requestId)
            }
        }
        val policy = SpokenAudioFocusPolicy.forClass(audioClass)
        val attributes = AudioAttributes.Builder()
            .setUsage(policy.usage)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

        val request: AudioFocusRequest?
        val outcome: Int
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            request = AudioFocusRequest.Builder(policy.focusGain)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(listener)
                .build()
            outcome = manager.requestAudioFocus(request)
        } else {
            request = null
            @Suppress("DEPRECATION")
            outcome = manager.requestAudioFocus(
                listener,
                AudioManager.STREAM_MUSIC,
                policy.focusGain,
            )
        }
        if (outcome != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return null
        lease = Lease(requestId, listener, request)
        return requestId
    }

    private fun focusLost(requestId: Int) {
        val shouldNotify = synchronized(this) {
            if (lease?.id != requestId) return@synchronized false
            abandonLocked()
            true
        }
        if (!shouldNotify) return
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod(METHOD_FOCUS_LOST, mapOf("requestId" to requestId))
        }
    }

    @Synchronized
    private fun abandon(requestId: Int?) {
        if (requestId != null && lease?.id != requestId) return
        abandonLocked()
    }

    private fun abandonLocked() {
        val current = lease ?: return
        lease = null
        val manager = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            current.request?.let(manager::abandonAudioFocusRequest)
        } else {
            @Suppress("DEPRECATION")
            manager.abandonAudioFocus(current.listener)
        }
    }
}

internal data class SpokenAudioFocusPolicy(val usage: Int, val focusGain: Int) {
    companion object {
        fun forClass(audioClass: String) = SpokenAudioFocusPolicy(
            usage = if (audioClass == "safety") {
                AudioAttributes.USAGE_ASSISTANCE_SONIFICATION
            } else {
                AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
            },
            focusGain = AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
        )
    }
}
