package com.mino.htools.scanner.data

import android.content.Context

enum class AutoCleanupPeriod(val days: Int?, val displayName: String) {
    NEVER(null, "永不"),
    ONE_DAY(1, "1 天后"),
    SEVEN_DAYS(7, "7 天后"),
    THIRTY_DAYS(30, "30 天后"),
    NINETY_DAYS(90, "90 天后"),
}

class ScanPreferences(context: Context) {
    private val preferences = context.getSharedPreferences("scan_preferences", Context.MODE_PRIVATE)

    var privacyMode: Boolean
        get() = preferences.getBoolean(KEY_PRIVACY_MODE, false)
        set(value) {
            preferences.edit().putBoolean(KEY_PRIVACY_MODE, value).apply()
        }

    var autoCleanupPeriod: AutoCleanupPeriod
        get() = runCatching {
            AutoCleanupPeriod.valueOf(
                preferences.getString(KEY_AUTO_CLEANUP, AutoCleanupPeriod.NEVER.name)
                    ?: AutoCleanupPeriod.NEVER.name,
            )
        }.getOrDefault(AutoCleanupPeriod.NEVER)
        set(value) {
            preferences.edit().putString(KEY_AUTO_CLEANUP, value.name).apply()
        }

    var continuousScan: Boolean
        get() = preferences.getBoolean(KEY_CONTINUOUS_SCAN, false)
        set(value) {
            preferences.edit().putBoolean(KEY_CONTINUOUS_SCAN, value).apply()
        }

    var vibrationEnabled: Boolean
        get() = preferences.getBoolean(KEY_VIBRATION, true)
        set(value) {
            preferences.edit().putBoolean(KEY_VIBRATION, value).apply()
        }

    var duplicateDelaySeconds: Int
        get() = preferences.getInt(KEY_DUPLICATE_DELAY, DEFAULT_DUPLICATE_DELAY_SECONDS)
            .coerceIn(1, 10)
        set(value) {
            preferences.edit().putInt(KEY_DUPLICATE_DELAY, value.coerceIn(1, 10)).apply()
        }

    private companion object {
        const val KEY_PRIVACY_MODE = "privacy_mode"
        const val KEY_AUTO_CLEANUP = "auto_cleanup"
        const val KEY_CONTINUOUS_SCAN = "continuous_scan"
        const val KEY_VIBRATION = "vibration"
        const val KEY_DUPLICATE_DELAY = "duplicate_delay"
        const val DEFAULT_DUPLICATE_DELAY_SECONDS = 3
    }
}
