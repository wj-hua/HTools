package com.mino.htools.scanner.data

import kotlinx.coroutines.flow.Flow

interface ScanHistoryRepository {
    fun observeHistory(): Flow<List<ScanHistoryEntity>>

    suspend fun add(content: String, scannedAt: Long, source: ScanSource, resultType: ScanResultType)

    suspend fun delete(id: Long)

    suspend fun setFavorite(id: Long, isFavorite: Boolean)

    suspend fun deleteOlderThan(cutoff: Long)

    suspend fun clear()
}

class RoomScanHistoryRepository(
    private val dao: ScanHistoryDao,
) : ScanHistoryRepository {
    override fun observeHistory(): Flow<List<ScanHistoryEntity>> = dao.observeAll()

    override suspend fun add(
        content: String,
        scannedAt: Long,
        source: ScanSource,
        resultType: ScanResultType,
    ) {
        dao.insert(
            ScanHistoryEntity(
                content = content,
                scannedAt = scannedAt,
                source = source,
                resultType = resultType,
            ),
        )
    }

    override suspend fun delete(id: Long) {
        dao.deleteById(id)
    }

    override suspend fun setFavorite(id: Long, isFavorite: Boolean) {
        dao.setFavorite(id, isFavorite)
    }

    override suspend fun deleteOlderThan(cutoff: Long) {
        dao.deleteOlderThan(cutoff)
    }

    override suspend fun clear() {
        dao.clear()
    }
}
