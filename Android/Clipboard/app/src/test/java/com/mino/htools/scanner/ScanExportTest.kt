package com.mino.htools.scanner

import com.mino.htools.scanner.data.ScanHistoryEntity
import com.mino.htools.scanner.data.ScanResultType
import com.mino.htools.scanner.data.ScanSource
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScanExportTest {
    @Test
    fun `csv escapes commas quotes and new lines`() {
        val csv = buildScanHistoryCsv(
            listOf(
                ScanHistoryEntity(
                    id = 7,
                    content = "hello,\"mino\"\nnext",
                    scannedAt = 0,
                    source = ScanSource.SHARE,
                    resultType = ScanResultType.TEXT,
                    isFavorite = true,
                ),
            ),
        )

        assertTrue(csv.startsWith("id,content,type,source,scanned_at,favorite\n"))
        assertTrue(csv.contains("\"hello,\"\"mino\"\"\nnext\""))
        assertTrue(csv.contains(",TEXT,SHARE,"))
        assertTrue(csv.trimEnd().endsWith(",true"))
    }

    @Test
    fun `continuous gate suppresses same content only during delay`() {
        var time = 1_000L
        val gate = ContinuousScanGate { time }

        assertTrue(gate.accept("A", 3))
        assertFalse(gate.accept("A", 3))
        assertTrue(gate.accept("B", 3))
        time = 4_000L
        assertTrue(gate.accept("A", 3))
    }

    @Test
    fun `csv prevents spreadsheet formula execution`() {
        val csv = buildScanHistoryCsv(
            listOf(
                ScanHistoryEntity(
                    content = "=HYPERLINK(\"https://unsafe.example\")",
                    scannedAt = 0,
                    source = ScanSource.CAMERA,
                ),
            ),
        )

        assertTrue(csv.contains("\"'=HYPERLINK(\"\"https://unsafe.example\"\")\""))
    }
}
