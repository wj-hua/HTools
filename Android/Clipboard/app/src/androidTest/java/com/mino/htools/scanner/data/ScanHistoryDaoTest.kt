package com.mino.htools.scanner.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ScanHistoryDaoTest {
    private lateinit var database: ScanHistoryDatabase
    private lateinit var dao: ScanHistoryDao

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, ScanHistoryDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        dao = database.scanHistoryDao()
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun history_isNewestFirstAndKeepsDuplicateContent() = runTest {
        dao.insert(ScanHistoryEntity(content = "same", scannedAt = 100L, source = ScanSource.CAMERA))
        dao.insert(ScanHistoryEntity(content = "same", scannedAt = 200L, source = ScanSource.GALLERY))
        dao.insert(ScanHistoryEntity(content = "other", scannedAt = 200L, source = ScanSource.CAMERA))

        val history = dao.observeAll().first()

        assertEquals(listOf("other", "same", "same"), history.map { it.content })
        assertEquals(listOf(ScanSource.CAMERA, ScanSource.GALLERY, ScanSource.CAMERA), history.map { it.source })
        assertEquals(listOf(200L, 200L, 100L), history.map { it.scannedAt })
    }

    @Test
    fun deleteAndClear_removeExpectedRecords() = runTest {
        dao.insert(ScanHistoryEntity(content = "first", scannedAt = 100L, source = ScanSource.CAMERA))
        dao.insert(ScanHistoryEntity(content = "second", scannedAt = 200L, source = ScanSource.GALLERY))

        val second = dao.observeAll().first().first()
        dao.deleteById(second.id)
        assertEquals(listOf("first"), dao.observeAll().first().map { it.content })

        dao.clear()
        assertEquals(emptyList<ScanHistoryEntity>(), dao.observeAll().first())
    }

    @Test
    fun favoriteRecords_areNotAutomaticallyDeleted() = runTest {
        dao.insert(ScanHistoryEntity(content = "old", scannedAt = 100L, source = ScanSource.CAMERA))
        dao.insert(ScanHistoryEntity(content = "favorite", scannedAt = 100L, source = ScanSource.CAMERA))
        val favorite = dao.observeAll().first().first()
        dao.setFavorite(favorite.id, true)

        dao.deleteOlderThan(200L)

        val remaining = dao.observeAll().first()
        assertEquals(listOf("favorite"), remaining.map { it.content })
        assertEquals(listOf(true), remaining.map { it.isFavorite })
    }
}
