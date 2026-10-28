package com.mino.htools.scanner

import com.mino.htools.scanner.data.ScanResultType
import org.junit.Assert.assertEquals
import org.junit.Test

class ScanResultParserTest {
    @Test
    fun `recognizes supported smart result types`() {
        val samples = mapOf(
            "https://example.com/path" to ScanResultType.URL,
            "WIFI:T:WPA;S:Campus;P:secret;;" to ScanResultType.WIFI,
            "tel:+16505551234" to ScanResultType.PHONE,
            "student@example.edu" to ScanResultType.EMAIL,
            "MECARD:N:Lee,Mino;TEL:+16505551234;EMAIL:mino@example.com;;" to
                ScanResultType.CONTACT,
            "geo:37.422,-122.084?q=Googleplex" to ScanResultType.MAP,
            "ordinary text" to ScanResultType.TEXT,
        )

        samples.forEach { (value, expectedType) ->
            assertEquals(value, expectedType, parseScanResult(value).type)
        }
    }

    @Test
    fun `wifi and contact details are parsed for actions`() {
        val wifi = parseScanResult("WIFI:T:WPA;S:Campus\\;Guest;P:secret;;")
        assertEquals("Campus;Guest", wifi.wifiName)

        val contact = parseScanResult(
            "BEGIN:VCARD\nVERSION:3.0\nFN:Mino Lee\nTEL:+16505551234\nEMAIL:mino@example.com\nEND:VCARD",
        )
        assertEquals("Mino Lee", contact.contactName)
        assertEquals("+16505551234", contact.phone)
        assertEquals("mino@example.com", contact.email)
    }
}
