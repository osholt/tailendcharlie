package me.osholt.ride_relay

import android.media.AudioAttributes
import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class SpokenAudioFocusPolicyTest {
    @Test
    fun `navigation prompts request transient ducking navigation focus`() {
        val policy = SpokenAudioFocusPolicy.forClass("navigation")

        assertEquals(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE, policy.usage)
        assertEquals(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK, policy.focusGain)
    }

    @Test
    fun `safety alerts remain separate from navigation guidance`() {
        val policy = SpokenAudioFocusPolicy.forClass("safety")

        assertEquals(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION, policy.usage)
        assertEquals(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK, policy.focusGain)
    }

    @Test
    fun `Dart and Android keep the same channel contract`() {
        val dart = File("../../lib/services/spoken_guidance_audio_focus.dart")
        assertTrue(dart.isFile)
        val source = dart.readText()

        assertTrue(source.contains(SpokenAudioFocusChannel.CHANNEL))
        assertTrue(source.contains("'${SpokenAudioFocusChannel.METHOD_ACQUIRE}'"))
        assertTrue(source.contains("'${SpokenAudioFocusChannel.METHOD_ABANDON}'"))
        assertTrue(source.contains("'${SpokenAudioFocusChannel.METHOD_FOCUS_LOST}'"))
    }
}
