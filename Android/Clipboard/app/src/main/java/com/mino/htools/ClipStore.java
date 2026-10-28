package com.mino.htools;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.database.sqlite.SQLiteStatement;

import java.util.ArrayList;
import java.util.List;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;

/** SQLite is the source of truth; mutations are committed before the UI reports success. */
final class ClipStore extends SQLiteOpenHelper {
    ClipStore(Context context) {
        super(context, "clips.db", null, 2);
    }

    @Override public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE clips (id INTEGER PRIMARY KEY AUTOINCREMENT, "
                + "title TEXT NOT NULL, content TEXT NOT NULL, updated_at INTEGER NOT NULL, "
                + "sort_order INTEGER NOT NULL DEFAULT 0)");
    }

    @Override public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE clips ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0");
            // Preserve the order users saw before upgrading, without recreating their records.
            List<Long> ids = new ArrayList<>();
            try (Cursor cursor = db.query("clips", new String[]{"id"}, null, null,
                    null, null, "updated_at DESC, id DESC")) {
                while (cursor.moveToNext()) ids.add(cursor.getLong(0));
            }
            writeOrder(db, ids);
        }
    }

    List<Clip> search(String query) {
        List<Clip> clips = new ArrayList<>();
        String selection = "instr(lower(content), lower(?)) > 0";
        try (Cursor cursor = getReadableDatabase().query("clips", null, selection,
                new String[]{query}, null, null, "sort_order ASC, id DESC")) {
            while (cursor.moveToNext()) clips.add(read(cursor));
        }
        return clips;
    }

    Clip find(long id) {
        try (Cursor cursor = getReadableDatabase().query("clips", null, "id = ?",
                new String[]{Long.toString(id)}, null, null, null)) {
            return cursor.moveToFirst() ? read(cursor) : null;
        }
    }

    boolean save(long id, String content) {
        ContentValues values = new ContentValues();
        values.put("content", content);
        values.put("updated_at", System.currentTimeMillis());
        if (id == -1) {
            // Keep the legacy column for database compatibility; content is the only editable text.
            values.put("title", "");
            SQLiteDatabase db = getWritableDatabase();
            db.beginTransaction();
            try {
                try (SQLiteStatement first = db.compileStatement("SELECT COALESCE(MIN(sort_order), 0) - 1 FROM clips")) {
                    values.put("sort_order", first.simpleQueryForLong());
                }
                db.insertOrThrow("clips", null, values);
                db.setTransactionSuccessful();
                return true;
            } finally {
                db.endTransaction();
            }
        }
        return getWritableDatabase().update("clips", values, "id = ?", new String[]{Long.toString(id)}) == 1;
    }

    boolean delete(long id) {
        return getWritableDatabase().delete("clips", "id = ?", new String[]{Long.toString(id)}) == 1;
    }

    boolean reorder(List<Long> orderedIds) {
        Set<Long> selected = new HashSet<>(orderedIds);
        if (selected.size() != orderedIds.size()) return false;
        SQLiteDatabase db = getWritableDatabase();
        db.beginTransaction();
        try {
            List<Long> allIds = new ArrayList<>();
            int matches = 0;
            try (Cursor cursor = db.query("clips", new String[]{"id"}, null, null,
                    null, null, "sort_order ASC, id DESC")) {
                while (cursor.moveToNext()) {
                    long id = cursor.getLong(0);
                    allIds.add(id);
                    if (selected.contains(id)) matches++;
                }
            }
            if (matches != orderedIds.size()) return false;
            // Search results can be reordered too; unseen records keep their existing slots.
            Iterator<Long> replacements = orderedIds.iterator();
            for (int i = 0; i < allIds.size(); i++) {
                if (selected.contains(allIds.get(i))) allIds.set(i, replacements.next());
            }
            writeOrder(db, allIds);
            db.setTransactionSuccessful();
            return true;
        } finally {
            db.endTransaction();
        }
    }

    private void writeOrder(SQLiteDatabase db, List<Long> ids) {
        try (SQLiteStatement update = db.compileStatement("UPDATE clips SET sort_order = ? WHERE id = ?")) {
            for (int i = 0; i < ids.size(); i++) {
                update.bindLong(1, i);
                update.bindLong(2, ids.get(i));
                if (update.executeUpdateDelete() != 1) throw new android.database.sqlite.SQLiteException("Missing clip while saving order");
            }
        }
    }

    private Clip read(Cursor cursor) {
        return new Clip(cursor.getLong(cursor.getColumnIndexOrThrow("id")),
                cursor.getString(cursor.getColumnIndexOrThrow("content")),
                cursor.getLong(cursor.getColumnIndexOrThrow("updated_at")));
    }
}
