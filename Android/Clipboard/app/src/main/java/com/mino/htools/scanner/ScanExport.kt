package com.mino.htools.scanner

import com.mino.htools.scanner.data.ScanHistoryEntity
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

internal fun buildScanHistoryCsv(items: List<ScanHistoryEntity>): String = buildString {
    appendLine("id,content,type,source,scanned_at,favorite")
    items.forEach { item ->
        append(item.id)
        append(',')
        append(item.content.csvCell())
        append(',')
        append(item.resultType.name)
        append(',')
        append(item.source.name)
        append(',')
        append(item.scannedAt.isoTimestamp())
        append(',')
        appendLine(item.isFavorite)
    }
}

private fun String.csvCell(): String {
    val spreadsheetSafeValue = if (firstOrNull()?.let { it in CSV_FORMULA_PREFIXES } == true) {
        "'$this"
    } else {
        this
    }
    return "\"${spreadsheetSafeValue.replace("\"", "\"\"")}\""
}

private fun Long.isoTimestamp(): String {
    val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US)
    formatter.timeZone = TimeZone.getDefault()
    return formatter.format(Date(this))
}

internal class ContinuousScanGate(
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val lastAcceptedAt = mutableMapOf<String, Long>()

    @Synchronized
    fun accept(content: String, delaySeconds: Int): Boolean {
        val timestamp = now()
        val previous = lastAcceptedAt[content]
        if (previous != null && timestamp - previous < delaySeconds * 1_000L) return false
        lastAcceptedAt[content] = timestamp
        lastAcceptedAt.entries.removeAll { timestamp - it.value > MAX_ENTRY_AGE_MILLIS }
        return true
    }

    fun reset() {
        lastAcceptedAt.clear()
    }

    private companion object {
        const val MAX_ENTRY_AGE_MILLIS = 60_000L
    }
}

private val CSV_FORMULA_PREFIXES = setOf('=', '+', '-', '@', '\t', '\r')
