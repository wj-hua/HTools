package com.mino.htools.scanner.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface ScanHistoryDao {
    @Query("SELECT * FROM scan_history ORDER BY scannedAt DESC, id DESC")
    fun observeAll(): Flow<List<ScanHistoryEntity>>

    @Insert
    suspend fun insert(item: ScanHistoryEntity)

    @Query("DELETE FROM scan_history WHERE id = :id")
    suspend fun deleteById(id: Long)

    @Query("UPDATE scan_history SET isFavorite = :isFavorite WHERE id = :id")
    suspend fun setFavorite(id: Long, isFavorite: Boolean)

    @Query("DELETE FROM scan_history WHERE scannedAt < :cutoff AND isFavorite = 0")
    suspend fun deleteOlderThan(cutoff: Long)

    @Query("DELETE FROM scan_history")
    suspend fun clear()
}
