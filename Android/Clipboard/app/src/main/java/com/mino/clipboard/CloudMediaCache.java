package com.mino.clipboard;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.net.Uri;
import android.os.Environment;
import android.provider.MediaStore;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.IOException;
import java.io.OutputStream;

/** MediaStore URIs work with consumers that resolve images through Android's media library. */
final class CloudMediaCache {
    private static final String PATH = Environment.DIRECTORY_PICTURES + "/小纸夹粘贴板/";
    private CloudMediaCache() {}

    static Uri image(Context context, String id, byte[] data) throws Exception {
        ContentResolver resolver = context.getContentResolver();
        var preferences = context.getSharedPreferences("cloud_media_cache", Context.MODE_PRIVATE);
        JSONArray saved = new JSONArray(preferences.getString("images", "[]"));
        JSONArray retained = new JSONArray();
        Uri uri = null;
        for (int i = 0; i < saved.length(); i++) {
            JSONObject entry = saved.getJSONObject(i);
            Uri existing = Uri.parse(entry.getString("uri"));
            if (!owned(resolver, existing)) continue;
            if (entry.getString("id").equals(id)) uri = existing;
            else retained.put(entry);
        }
        if (uri == null) {
            ContentValues values = new ContentValues();
            values.put(MediaStore.Images.Media.DISPLAY_NAME, "clipboard-" + id + ".png");
            values.put(MediaStore.Images.Media.MIME_TYPE, "image/png");
            values.put(MediaStore.Images.Media.RELATIVE_PATH, PATH);
            values.put(MediaStore.Images.Media.IS_PENDING, 1);
            uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
            if (uri == null) throw new IOException("无法创建可分享的图片");
            try {
                try (OutputStream output = resolver.openOutputStream(uri, "w")) {
                    if (output == null) throw new IOException("无法保存可分享的图片");
                    output.write(data);
                }
                values.clear();
                values.put(MediaStore.Images.Media.IS_PENDING, 0);
                if (resolver.update(uri, values, null, null) != 1) throw new IOException("无法完成图片保存");
            } catch (Exception error) {
                resolver.delete(uri, null, null);
                throw error;
            }
        }
        retained.put(new JSONObject().put("id", id).put("uri", uri.toString()));
        while (retained.length() > 50) {
            Uri oldest = Uri.parse(retained.getJSONObject(0).getString("uri"));
            // Limit deletion to this app's own clipboard album.
            if (owned(resolver, oldest)) resolver.delete(oldest, null, null);
            context.revokeUriPermission(oldest, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION);
            retained.remove(0);
        }
        if (!preferences.edit().putString("images", retained.toString()).commit()) {
            throw new IOException("无法保存图片缓存索引");
        }
        return uri;
    }

    private static boolean owned(ContentResolver resolver, Uri uri) {
        if (!"content".equals(uri.getScheme()) || !"media".equals(uri.getAuthority())) return false;
        try (var cursor = resolver.query(uri, new String[]{MediaStore.Images.Media.RELATIVE_PATH,
                MediaStore.Images.Media.OWNER_PACKAGE_NAME}, null, null, null)) {
            return cursor != null && cursor.moveToFirst() && PATH.equals(cursor.getString(0))
                    && "com.mino.clipboard".equals(cursor.getString(1));
        } catch (RuntimeException ignored) { return false; }
    }
}
