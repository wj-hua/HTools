package com.mino.htools.scanner.data

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "scan_history")
data class ScanHistoryEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val content: String,
    val scannedAt: Long,
    val source: ScanSource,
    val resultType: ScanResultType = ScanResultType.TEXT,
    val isFavorite: Boolean = false,
)

enum class ScanSource {
    CAMERA,
    GALLERY,
    SHARE,
}
