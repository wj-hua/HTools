package com.mino.htools.scanner.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.TypeConverter
import androidx.room.TypeConverters
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [ScanHistoryEntity::class],
    version = 2,
    exportSchema = false,
)
@TypeConverters(ScanSourceConverter::class, ScanResultTypeConverter::class)
abstract class ScanHistoryDatabase : RoomDatabase() {
    abstract fun scanHistoryDao(): ScanHistoryDao

    companion object {
        @Volatile
        private var instance: ScanHistoryDatabase? = null

        fun getInstance(context: Context): ScanHistoryDatabase {
            return instance ?: synchronized(this) {
                instance ?: Room.databaseBuilder(
                    context.applicationContext,
                    ScanHistoryDatabase::class.java,
                    "scan-history.db",
                ).addMigrations(MIGRATION_1_2)
                    .build()
                    .also { instance = it }
            }
        }

        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(database: SupportSQLiteDatabase) {
                database.execSQL(
                    "ALTER TABLE scan_history ADD COLUMN resultType TEXT NOT NULL DEFAULT 'TEXT'",
                )
                database.execSQL(
                    "ALTER TABLE scan_history ADD COLUMN isFavorite INTEGER NOT NULL DEFAULT 0",
                )
            }
        }
    }
}

class ScanSourceConverter {
    @TypeConverter
    fun fromSource(source: ScanSource): String = source.name

    @TypeConverter
    fun toSource(value: String): ScanSource = ScanSource.valueOf(value)
}

class ScanResultTypeConverter {
    @TypeConverter
    fun fromType(type: ScanResultType): String = type.name

    @TypeConverter
    fun toType(value: String): ScanResultType =
        runCatching { ScanResultType.valueOf(value) }.getOrDefault(ScanResultType.TEXT)
}
