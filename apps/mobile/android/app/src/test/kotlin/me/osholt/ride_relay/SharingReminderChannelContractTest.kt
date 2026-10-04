package me.osholt.ride_relay

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class SharingReminderChannelContractTest {
    @Test
    fun `Dart and Android keep the same channel contract`() {
        val dart = File("../../lib/services/sharing_reminder_notifier.dart")
        assertTrue(dart.isFile)
        val source = dart.readText()

        assertTrue(source.contains(SharingReminderChannel.CHANNEL))
        assertTrue(source.contains("'${SharingReminderChannel.METHOD_SHOW}'"))
        assertTrue(source.contains("'${SharingReminderChannel.METHOD_CLEAR}'"))
    }
}
