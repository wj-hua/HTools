package com.mino.htools.scanner

import com.mino.htools.scanner.data.ScanHistoryEntity
import com.mino.htools.scanner.data.ScanHistoryRepository
import com.mino.htools.scanner.data.ScanSource
import com.mino.htools.scanner.data.ScanResultType
import com.mino.htools.scanner.data.AutoCleanupPeriod
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ScanHistoryViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `camera and gallery scans are both recorded including duplicates`() = runTest(dispatcher) {
        val repository = FakeScanHistoryRepository()
        val viewModel = ScanHistoryViewModel(repository, currentTimeMillis = { 1234L })

        viewModel.recordScan("same-content", ScanSource.CAMERA, ScanResultType.TEXT)
        viewModel.recordScan("same-content", ScanSource.GALLERY, ScanResultType.URL)
        advanceUntilIdle()

        assertEquals(
            listOf(
                RecordedScan("same-content", 1234L, ScanSource.CAMERA, ScanResultType.TEXT),
                RecordedScan("same-content", 1234L, ScanSource.GALLERY, ScanResultType.URL),
            ),
            repository.recorded,
        )
    }

    @Test
    fun `blank scan is ignored`() = runTest(dispatcher) {
        val repository = FakeScanHistoryRepository()
        val viewModel = ScanHistoryViewModel(repository)

        viewModel.recordScan("   ", ScanSource.CAMERA, ScanResultType.TEXT)
        advanceUntilIdle()

        assertEquals(emptyList<RecordedScan>(), repository.recorded)
    }

    @Test
    fun `delete and clear are forwarded to repository`() = runTest(dispatcher) {
        val repository = FakeScanHistoryRepository()
        val viewModel = ScanHistoryViewModel(repository)

        viewModel.deleteScan(42L)
        viewModel.clearHistory()
        advanceUntilIdle()

        assertEquals(listOf(42L), repository.deletedIds)
        assertEquals(1, repository.clearCount)
    }

    @Test
    fun `privacy mode prevents new history and cleanup uses selected cutoff`() = runTest(dispatcher) {
        val repository = FakeScanHistoryRepository()
        val viewModel = ScanHistoryViewModel(
            repository,
            currentTimeMillis = { 10L * 24L * 60L * 60L * 1_000L },
        )

        viewModel.setPrivacyMode(true)
        viewModel.recordScan("private", ScanSource.CAMERA, ScanResultType.TEXT)
        viewModel.setAutoCleanupPeriod(AutoCleanupPeriod.SEVEN_DAYS)
        advanceUntilIdle()

        assertEquals(emptyList<RecordedScan>(), repository.recorded)
        assertEquals(listOf(3L * 24L * 60L * 60L * 1_000L), repository.cleanupCutoffs)
    }
}

private data class RecordedScan(
    val content: String,
    val scannedAt: Long,
    val source: ScanSource,
    val resultType: ScanResultType,
)

private class FakeScanHistoryRepository : ScanHistoryRepository {
    private val history = MutableStateFlow<List<ScanHistoryEntity>>(emptyList())
    val recorded = mutableListOf<RecordedScan>()
    val deletedIds = mutableListOf<Long>()
    var clearCount = 0
    val cleanupCutoffs = mutableListOf<Long>()

    override fun observeHistory(): Flow<List<ScanHistoryEntity>> = history

    override suspend fun add(
        content: String,
        scannedAt: Long,
        source: ScanSource,
        resultType: ScanResultType,
    ) {
        recorded += RecordedScan(content, scannedAt, source, resultType)
    }

    override suspend fun delete(id: Long) {
        deletedIds += id
    }

    override suspend fun setFavorite(id: Long, isFavorite: Boolean) = Unit

    override suspend fun deleteOlderThan(cutoff: Long) {
        cleanupCutoffs += cutoff
    }

    override suspend fun clear() {
        clearCount += 1
    }
}
