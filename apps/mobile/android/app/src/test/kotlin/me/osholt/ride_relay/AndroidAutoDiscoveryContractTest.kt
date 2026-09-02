package me.osholt.ride_relay

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidAutoDiscoveryContractTest {
    @Test
    fun manifestAllowsAndroidAutoToRenderTheNavigationSurface() {
        val manifest = parseXml(File("src/main/AndroidManifest.xml"))
        val permissions = manifest.getElementsByTagName("uses-permission")
        val androidNamespace = "http://schemas.android.com/apk/res/android"

        val surfacePermission = (0 until permissions.length)
            .map { permissions.item(it) }
            .firstOrNull {
                it.attributes
                    ?.getNamedItemNS(androidNamespace, "name")
                    ?.nodeValue == "androidx.car.app.ACCESS_SURFACE"
            }

        assertNotNull(
            "Android Auto navigation surface permission is missing",
            surfacePermission,
        )
    }

    @Test
    fun manifestPublishesAndroidAutoTemplateDescriptor() {
        val manifest = parseXml(File("src/main/AndroidManifest.xml"))
        val metadata = manifest.getElementsByTagName("meta-data")
        val androidNamespace = "http://schemas.android.com/apk/res/android"

        val discoveryEntry = (0 until metadata.length)
            .map { metadata.item(it) }
            .firstOrNull {
                it.attributes
                    ?.getNamedItemNS(androidNamespace, "name")
                    ?.nodeValue == "com.google.android.gms.car.application"
            }

        assertNotNull("Android Auto discovery metadata is missing", discoveryEntry)
        assertEquals(
            "@xml/automotive_app_desc",
            discoveryEntry!!.attributes
                ?.getNamedItemNS(androidNamespace, "resource")
                ?.nodeValue,
        )
    }

    @Test
    fun descriptorDeclaresTemplateCarApp() {
        val descriptor = parseXml(File("src/main/res/xml/automotive_app_desc.xml"))
        val uses = descriptor.getElementsByTagName("uses")

        assertEquals(1, uses.length)
        assertEquals("template", uses.item(0).attributes.getNamedItem("name").nodeValue)
    }

    @Test
    fun manifestPublishesTheAssistantNavigationContract() {
        val manifest = parseXml(File("src/main/AndroidManifest.xml"))
        val androidNamespace = "http://schemas.android.com/apk/res/android"
        val filters = manifest.getElementsByTagName("intent-filter")
        val matchingFilter = (0 until filters.length)
            .map { filters.item(it) }
            .firstOrNull { filter ->
                val actions = filter.childNodes
                (0 until actions.length).map { actions.item(it) }.any { child ->
                    child.nodeName == "action" &&
                        child.attributes?.getNamedItemNS(androidNamespace, "name")?.nodeValue ==
                        "androidx.car.app.action.NAVIGATE"
                }
            }

        assertNotNull("Gemini/Assistant navigation action is missing", matchingFilter)
        val schemes = matchingFilter!!.childNodes
        assertTrue(
            (0 until schemes.length).map { schemes.item(it) }.any { child ->
                child.nodeName == "data" &&
                    child.attributes?.getNamedItemNS(androidNamespace, "scheme")?.nodeValue == "geo"
            },
        )
    }

    private fun parseXml(file: File) =
        DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
        }.newDocumentBuilder().parse(file)
}
