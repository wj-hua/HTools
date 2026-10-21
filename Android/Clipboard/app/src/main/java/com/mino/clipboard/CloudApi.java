package com.mino.clipboard;

import android.content.Context;
import org.json.JSONObject;
import org.json.JSONArray;
import java.net.URL;
import javax.net.ssl.HttpsURLConnection;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

final class CloudApi {
    private final String endpoint;
    private final String token;
    CloudApi(Context context) {
        var prefs = context.getSharedPreferences("cloud", Context.MODE_PRIVATE);
        endpoint = prefs.getString("url", "");
        token = prefs.getString("token", "");
    }
    static void pair(Context context, String config) throws Exception {
        JSONObject json = new JSONObject(config);
        String endpoint = json.getString("url");
        String token = json.getString("token");
        URL url = new URL(endpoint);
        if (!url.getProtocol().equals("https") || url.getHost().isEmpty()
                || url.getUserInfo() != null || url.getQuery() != null || url.getRef() != null || token.length() < 32) {
            throw new IOException("配对信息不正确，请从 Mac 重新复制");
        }
        // Validate before replacing a working connection.
        CloudApi api = new CloudApi(endpoint, token);
        api.list();
        if (!context.getSharedPreferences("cloud", Context.MODE_PRIVATE).edit()
                .putString("url", endpoint).putString("token", token).commit()) {
            throw new IOException("无法保存连接设置");
        }
    }
    private CloudApi(String endpoint, String token) { this.endpoint = endpoint; this.token = token; }
    boolean configured() { return !endpoint.isEmpty() && !token.isEmpty(); }
    JSONObject list() throws Exception { return new JSONObject(new String(request("items"), StandardCharsets.UTF_8)); }
    byte[] content(String id) throws Exception {
        if (!id.matches("[a-f0-9-]{36}")) throw new IOException("记录编号不正确");
        return request("items/" + id + "/content");
    }
    private byte[] request(String path) throws Exception {
        if (!configured()) throw new IOException("请先粘贴 Mac 配对信息");
        HttpsURLConnection connection = (HttpsURLConnection) new URL(endpoint.replaceAll("/+$", "") + "/" + path).openConnection();
        connection.setConnectTimeout(15000);
        connection.setReadTimeout(30000);
        connection.setInstanceFollowRedirects(false);
        connection.setRequestProperty("Authorization", "Bearer " + token);
        try {
            int status = connection.getResponseCode();
            if (status != 200) {
                if (status == 401) throw new IOException("连接密钥不正确，请重新配对");
                if (status == 404) throw new IOException("记录已被清理，请刷新列表");
                throw new IOException("服务器请求失败（" + status + "）");
            }
            try (InputStream input = connection.getInputStream(); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[8192];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    if (output.size() + count > 55 * 1024 * 1024) throw new IOException("服务器返回的内容过大");
                    output.write(buffer, 0, count);
                }
                return output.toByteArray();
            }
        } finally { connection.disconnect(); }
    }
}
