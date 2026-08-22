package me.osholt.ride_relay

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class AndroidAutoDiscoveryContractTest {
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

    private fun parseXml(file: File) =
        DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
        }.newDocumentBuilder().parse(file)
}
