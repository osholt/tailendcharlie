package me.osholt.ride_relay

import android.content.Intent
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Locale

/** A bounded public Android navigation intent, ready for an in-car confirmation screen. */
internal data class AndroidAutoNavigationIntent(
    val query: String?,
    val latitude: Double?,
    val longitude: Double?,
    val operation: Operation,
    val offline: Boolean,
) {
    enum class Operation {
        NAVIGATE,
        DIRECTIONS,
        ADD_STOP,
    }

    val label: String
        get() = query ?: "${formatCoordinate(latitude!!)}, ${formatCoordinate(longitude!!)}"

    companion object {
        private const val CAR_ACTION_NAVIGATE = "androidx.car.app.action.NAVIGATE"
        private const val PHONE_ACTION_NAVIGATE = "android.intent.action.NAVIGATE"

        fun parse(intent: Intent?): AndroidAutoNavigationIntent? {
            val candidate = intent ?: return null
            if (candidate.action !in setOf(CAR_ACTION_NAVIGATE, PHONE_ACTION_NAVIGATE)) return null
            val raw = candidate.dataString?.trim()?.takeIf(String::isNotEmpty) ?: return null
            val scheme = raw.substringBefore(':').lowercase()
            if (scheme != "geo" && scheme != "geo.offline") return null
            val payload = raw.substringAfter(':', missingDelimiterValue = "")
            if (payload.isEmpty() || '#' in payload) return null
            val coordinateText = payload.substringBefore('?')
            val parameters = queryParameters(payload.substringAfter('?', missingDelimiterValue = ""))
            val query = parameters["q"]?.trim()?.take(MAX_QUERY_LENGTH)
                ?.takeIf(String::isNotEmpty)
            val coordinates = parseCoordinates(coordinateText)
            if (query == null && coordinates == null) return null
            if (query == null && coordinates == (0.0 to 0.0)) return null
            val operation = when (parameters["intent"]?.lowercase()) {
                null, "", "navigation" -> Operation.NAVIGATE
                "directions" -> Operation.DIRECTIONS
                "add_a_stop" -> Operation.ADD_STOP
                else -> return null
            }
            return AndroidAutoNavigationIntent(
                query = query,
                latitude = coordinates?.first,
                longitude = coordinates?.second,
                operation = operation,
                offline = scheme == "geo.offline",
            )
        }

        private fun queryParameters(raw: String): Map<String, String> = buildMap {
            raw.split('&').take(MAX_PARAMETERS).forEach { pair ->
                if (pair.isEmpty()) return@forEach
                val key = decode(pair.substringBefore('='))?.lowercase() ?: return@forEach
                val value = decode(pair.substringAfter('=', missingDelimiterValue = ""))
                    ?: return@forEach
                if (key.isNotEmpty() && key !in this) put(key, value)
            }
        }

        private fun decode(value: String): String? = try {
            URLDecoder.decode(value, StandardCharsets.UTF_8.name())
        } catch (_: IllegalArgumentException) {
            null
        }

        private fun parseCoordinates(raw: String): Pair<Double, Double>? {
            val values = raw.split(',', limit = 2)
            if (values.size != 2) return null
            val latitude = values[0].toDoubleOrNull() ?: return null
            val longitude = values[1].toDoubleOrNull() ?: return null
            if (!latitude.isFinite() || !longitude.isFinite()) return null
            if (latitude !in -90.0..90.0 || longitude !in -180.0..180.0) return null
            return latitude to longitude
        }

        private fun formatCoordinate(value: Double): String = "%.5f".format(Locale.US, value)

        private const val MAX_QUERY_LENGTH = 180
        private const val MAX_PARAMETERS = 16
    }
}
