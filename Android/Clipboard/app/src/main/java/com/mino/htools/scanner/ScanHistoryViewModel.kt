package com.mino.htools.scanner

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.mino.htools.scanner.data.RoomScanHistoryRepository
import com.mino.htools.scanner.data.AutoCleanupPeriod
import com.mino.htools.scanner.data.ScanHistoryDatabase
import com.mino.htools.scanner.data.ScanHistoryEntity
import com.mino.htools.scanner.data.ScanHistoryRepository
import com.mino.htools.scanner.data.ScanPreferences
import com.mino.htools.scanner.data.ScanResultType
import com.mino.htools.scanner.data.ScanSource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class ScanHistoryViewModel(
    private val repository: ScanHistoryRepository,
    private val preferences: ScanPreferences? = null,
    private val currentTimeMillis: () -> Long = System::currentTimeMillis,
) : ViewModel() {
    val history: StateFlow<List<ScanHistoryEntity>> = repository.observeHistory()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val privacyMode = MutableStateFlow(preferences?.privacyMode ?: false)
    val autoCleanupPeriod = MutableStateFlow(
        preferences?.autoCleanupPeriod ?: AutoCleanupPeriod.NEVER,
    )
    val continuousScan = MutableStateFlow(preferences?.continuousScan ?: false)
    val vibrationEnabled = MutableStateFlow(preferences?.vibrationEnabled ?: true)
    val duplicateDelaySeconds = MutableStateFlow(preferences?.duplicateDelaySeconds ?: 3)

    init {
        cleanExpiredHistory()
    }

    fun recordScan(content: String, source: ScanSource, resultType: ScanResultType) {
        if (content.isBlank()) return
        if (privacyMode.value) return
        viewModelScope.launch {
            repository.add(content, currentTimeMillis(), source, resultType)
        }
    }

    fun deleteScan(id: Long) {
        viewModelScope.launch {
            repository.delete(id)
        }
    }

    fun clearHistory() {
        viewModelScope.launch {
            repository.clear()
        }
    }

    fun setFavorite(id: Long, isFavorite: Boolean) {
        viewModelScope.launch {
            repository.setFavorite(id, isFavorite)
        }
    }

    fun setPrivacyMode(enabled: Boolean) {
        preferences?.privacyMode = enabled
        privacyMode.value = enabled
    }

    fun setAutoCleanupPeriod(period: AutoCleanupPeriod) {
        preferences?.autoCleanupPeriod = period
        autoCleanupPeriod.value = period
        cleanExpiredHistory()
    }

    fun setContinuousScan(enabled: Boolean) {
        preferences?.continuousScan = enabled
        continuousScan.value = enabled
    }

    fun setVibrationEnabled(enabled: Boolean) {
        preferences?.vibrationEnabled = enabled
        vibrationEnabled.value = enabled
    }

    fun setDuplicateDelaySeconds(seconds: Int) {
        val normalized = seconds.coerceIn(1, 10)
        preferences?.duplicateDelaySeconds = normalized
        duplicateDelaySeconds.value = normalized
    }

    private fun cleanExpiredHistory() {
        val days = autoCleanupPeriod.value.days ?: return
        val cutoff = currentTimeMillis() - days * MILLIS_PER_DAY
        viewModelScope.launch {
            repository.deleteOlderThan(cutoff)
        }
    }

    companion object {
        private const val MILLIS_PER_DAY = 24L * 60L * 60L * 1_000L

        fun factory(context: Context): ViewModelProvider.Factory {
            val repository = RoomScanHistoryRepository(
                ScanHistoryDatabase.getInstance(context).scanHistoryDao(),
            )
            val preferences = ScanPreferences(context)
            return object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T {
                    require(modelClass.isAssignableFrom(ScanHistoryViewModel::class.java))
                    return ScanHistoryViewModel(repository, preferences) as T
                }
            }
        }
    }
}
