package me.osholt.ride_relay

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidAutoDiscoveryContractTest {
    private val androidNamespace = "http://schemas.android.com/apk/res/android"
    private val shippedManifest = File("src/main/AndroidManifest.xml")
    private val preservedManifest = File("src/androidAuto/AndroidManifest.xml")

    @Test
    fun phoneReleaseDoesNotPublishAndroidAutoCapabilities() {
        val manifest = parseXml(shippedManifest)
        val forbidden = setOf(
            "androidx.car.app.NAVIGATION_TEMPLATES",
            "androidx.car.app.ACCESS_SURFACE",
            "com.google.android.gms.car.application",
            "androidx.car.app.CarAppService",
            "androidx.car.app.category.NAVIGATION",
            "androidx.car.app.action.NAVIGATE",
            "me.osholt.ride_relay.TailEndCharlieCarAppService",
            ".TailEndCharlieCarAppService",
        )

        assertFalse(
            "The phone/Play manifest must not expose Android Auto",
            manifest.allAndroidAttributeValues().any(forbidden::contains),
        )
    }

    @Test
    fun futureVariantPreservesAndroidAutoSurfaceAndDiscoveryContract() {
        val manifest = parseXml(preservedManifest)
        val values = manifest.allAndroidAttributeValues()

        assertTrue(values.contains("androidx.car.app.NAVIGATION_TEMPLATES"))
        assertTrue(values.contains("androidx.car.app.ACCESS_SURFACE"))
        assertTrue(values.contains("com.google.android.gms.car.application"))
        assertTrue(values.contains("@xml/automotive_app_desc"))
        assertTrue(values.contains("androidx.car.app.CarAppService"))
        assertTrue(values.contains("androidx.car.app.category.NAVIGATION"))
        assertTrue(values.contains("androidx.car.app.action.NAVIGATE"))
        assertTrue(values.contains("geo"))
    }

    @Test
    fun descriptorDeclaresTemplateCarApp() {
        val descriptor = parseXml(File("src/main/res/xml/automotive_app_desc.xml"))
        val uses = descriptor.getElementsByTagName("uses")

        assertEquals(1, uses.length)
        assertEquals("template", uses.item(0).attributes.getNamedItem("name").nodeValue)
    }

    private fun org.w3c.dom.Document.allAndroidAttributeValues(): Set<String> {
        val values = mutableSetOf<String>()
        val elements = getElementsByTagName("*")
        for (index in 0 until elements.length) {
            val attributes = elements.item(index).attributes ?: continue
            for (attributeIndex in 0 until attributes.length) {
                val attribute = attributes.item(attributeIndex)
                if (attribute.namespaceURI == androidNamespace) values += attribute.nodeValue
            }
        }
        return values
    }

    private fun parseXml(file: File) =
        DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
        }.newDocumentBuilder().parse(file)
}
