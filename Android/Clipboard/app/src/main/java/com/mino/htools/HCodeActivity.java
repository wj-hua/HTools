package com.mino.htools;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import android.webkit.CookieManager;
import android.text.InputType;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.LinearLayout;
import org.json.JSONObject;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.net.ssl.HttpsURLConnection;

public final class HCodeActivity extends Activity {
    private static final int FILE_REQUEST = 1;
    private WebView webView;
    private SharedPreferences preferences;
    private ValueCallback<Uri[]> fileCallback;

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_hcode);
        Ui.applyInsets(this);
        preferences = getSharedPreferences("hcode", MODE_PRIVATE);
        webView = findViewById(R.id.hcode_webview);
        webView.getSettings().setJavaScriptEnabled(true);
        webView.getSettings().setDomStorageEnabled(true);
        webView.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri url = request.getUrl();
                Uri address = Uri.parse(preferences.getString("address", ""));
                if ("https".equalsIgnoreCase(url.getScheme()) && url.getHost() != null
                        && url.getHost().equalsIgnoreCase(address.getHost()) && url.getPort() == address.getPort()) return false;
                if ("https".equalsIgnoreCase(url.getScheme()) || "http".equalsIgnoreCase(url.getScheme()) || "mailto".equalsIgnoreCase(url.getScheme())) {
                    try { startActivity(new Intent(Intent.ACTION_VIEW, url)); } catch (ActivityNotFoundException ignored) { }
                }
                return true;
            }
        });
        webView.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (fileCallback != null) fileCallback.onReceiveValue(null);
                fileCallback = callback;
                try {
                    startActivityForResult(params.createIntent(), FILE_REQUEST);
                    return true;
                } catch (ActivityNotFoundException e) {
                    fileCallback = null;
                    return false;
                }
            }
        });
        findViewById(R.id.hcode_back).setOnClickListener(v -> navigateBack());
        findViewById(R.id.hcode_reload).setOnClickListener(v -> webView.reload());
        findViewById(R.id.hcode_settings).setOnClickListener(v -> showAddressDialog());
        String address = preferences.getString("address", "");
        if (savedInstanceState != null && webView.restoreState(savedInstanceState) != null) return;
        if (address.isEmpty()) showAddressDialog(); else openAddress(address);
    }

    private void showAddressDialog() {
        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        input.setHint("https://");
        input.setText(preferences.getString("address", ""));
        LinearLayout container = new LinearLayout(this);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        container.setPadding(padding, 0, padding, 0);
        container.setOrientation(LinearLayout.VERTICAL);
        container.addView(input, new LinearLayout.LayoutParams(-1, -2));
        EditText password = new EditText(this);
        password.setSingleLine(true);
        password.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        password.setHint(R.string.hcode_password_hint);
        container.addView(password, new LinearLayout.LayoutParams(-1, -2));
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle(R.string.hcode_address)
                .setMessage(R.string.hcode_address_message).setView(container)
                .setNegativeButton(R.string.cancel, (d, which) -> {
                    if (preferences.getString("address", "").isEmpty()) finish();
                }).setPositiveButton(R.string.hcode_connect, null).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String address = input.getText().toString().trim();
            Uri uri = Uri.parse(address);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null || uri.getUserInfo() != null) {
                input.setError(getString(R.string.hcode_address_invalid));
                return;
            }
            String previous = preferences.getString("address", "");
            String token = password.getText().toString().trim();
            if (!address.equals(previous)) clearToken();
            preferences.edit().putString("address", address).apply();
            if (!token.isEmpty()) {
                try { saveToken(token); } catch (Exception e) {
                    password.setError(getString(R.string.hcode_password_save_failed));
                    return;
                }
            }
            openAddress(address);
            dialog.dismiss();
        }));
        dialog.setOnCancelListener(ignored -> { if (preferences.getString("address", "").isEmpty()) finish(); });
        dialog.show();
    }

    private SecretKey tokenKey() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        SecretKey key = (SecretKey) store.getKey("hcode_remote_token", null);
        if (key != null) return key;
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder("hcode_remote_token",
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }

    private void saveToken(String token) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, tokenKey());
        preferences.edit().putString("token_iv", Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP))
                .putString("token_ciphertext", Base64.encodeToString(cipher.doFinal(token.getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP)).apply();
    }

    private void clearToken() {
        preferences.edit().remove("token_iv").remove("token_ciphertext").apply();
    }

    private String readToken() throws Exception {
        String iv = preferences.getString("token_iv", "");
        String encrypted = preferences.getString("token_ciphertext", "");
        if (iv.isEmpty() || encrypted.isEmpty()) return "";
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, tokenKey(), new GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)));
        return new String(cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP)), StandardCharsets.UTF_8);
    }

    private void openAddress(String address) {
        final String token;
        try { token = readToken(); } catch (Exception e) {
            clearToken();
            webView.loadUrl(address);
            return;
        }
        if (token.isEmpty()) { webView.loadUrl(address); return; }
        new Thread(() -> {
            String cookie = null;
            HttpsURLConnection connection = null;
            try {
                URL endpoint = new URL(new URL(address), "api/login");
                connection = (HttpsURLConnection) endpoint.openConnection();
                connection.setRequestMethod("POST");
                connection.setConnectTimeout(15000);
                connection.setReadTimeout(15000);
                connection.setInstanceFollowRedirects(false);
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json");
                connection.setRequestProperty("X-HCode-Remote", "1");
                byte[] body = new JSONObject().put("token", token).toString().getBytes(StandardCharsets.UTF_8);
                try (java.io.OutputStream output = connection.getOutputStream()) { output.write(body); }
                if (connection.getResponseCode() == 200) cookie = connection.getHeaderField("Set-Cookie");
            } catch (Exception ignored) {
                // The page shows the normal login or connection error if automatic login fails.
            } finally {
                if (connection != null) connection.disconnect();
            }
            String loginCookie = cookie;
            runOnUiThread(() -> {
                if (isFinishing() || isDestroyed() || !address.equals(preferences.getString("address", ""))) return;
                if (loginCookie != null) {
                    CookieManager.getInstance().setCookie(address, loginCookie, success -> {
                        if (success) CookieManager.getInstance().flush();
                        if (!isFinishing() && !isDestroyed() && address.equals(preferences.getString("address", ""))) webView.loadUrl(address);
                    });
                } else webView.loadUrl(address);
            });
        }).start();
    }

    private void navigateBack() {
        if (webView.canGoBack()) webView.goBack(); else finish();
    }

    @Override public void onBackPressed() { navigateBack(); }
    @Override protected void onSaveInstanceState(Bundle outState) {
        webView.saveState(outState);
        super.onSaveInstanceState(outState);
    }
    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == FILE_REQUEST && fileCallback != null) {
            fileCallback.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(resultCode, data));
            fileCallback = null;
        }
    }
    @Override protected void onDestroy() {
        if (fileCallback != null) fileCallback.onReceiveValue(null);
        ((android.view.ViewGroup) webView.getParent()).removeView(webView);
        webView.destroy();
        super.onDestroy();
    }
}
