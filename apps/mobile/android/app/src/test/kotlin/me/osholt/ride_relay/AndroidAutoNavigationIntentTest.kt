package me.osholt.ride_relay

import android.content.Intent
import android.net.Uri
import androidx.car.app.CarContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AndroidAutoNavigationIntentTest {
    @Test
    fun `parses Assistant query with two wheeler mode`() {
        val request = AndroidAutoNavigationIntent.parse(
            Intent(CarContext.ACTION_NAVIGATE).apply {
                data = Uri.parse("geo:0,0?q=Puy+Mary&mode=l&intent=navigation&entry=assistant")
            },
        )!!

        assertEquals("Puy Mary", request.query)
        assertEquals(0.0, request.latitude!!, 0.0)
        assertEquals(0.0, request.longitude!!, 0.0)
        assertEquals(AndroidAutoNavigationIntent.Operation.NAVIGATE, request.operation)
        assertFalse(request.offline)
    }

    @Test
    fun `parses coordinates directions add stop and offline variants`() {
        val directions = parse("geo:45.052,2.711?intent=directions")!!
        val addStop = parse("geo:45.052,2.711?q=Salers&intent=add_a_stop")!!
        val offline = parse("geo.offline:45.052,2.711")!!

        assertEquals(AndroidAutoNavigationIntent.Operation.DIRECTIONS, directions.operation)
        assertEquals("45.05200, 2.71100", directions.label)
        assertEquals(AndroidAutoNavigationIntent.Operation.ADD_STOP, addStop.operation)
        assertEquals("Salers", addStop.label)
        assertTrue(offline.offline)
    }

    @Test
    fun `rejects non navigation malformed and unsupported requests`() {
        assertNull(
            AndroidAutoNavigationIntent.parse(
                Intent(Intent.ACTION_VIEW, Uri.parse("geo:45.052,2.711")),
            ),
        )
        assertNull(parse("https://example.com"))
        assertNull(parse("geo:95,2"))
        assertNull(parse("geo:0,0?intent=unsupported"))
        assertNull(parse("geo:0,0?q=%ZZ"))
        assertNull(parse("geo:0,0"))
    }

    private fun parse(uri: String): AndroidAutoNavigationIntent? =
        AndroidAutoNavigationIntent.parse(
            Intent(CarContext.ACTION_NAVIGATE).apply { data = Uri.parse(uri) },
        )
}
