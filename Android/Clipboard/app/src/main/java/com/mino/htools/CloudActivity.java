package com.mino.htools;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.os.Bundle;
import android.os.Build;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import org.json.JSONObject;
import org.json.JSONArray;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.Arrays;
import java.util.Comparator;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;

public final class CloudActivity extends Activity {
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final ExecutorService thumbnails = Executors.newFixedThreadPool(2);
    private LinearLayout records;
    private TextView status;
    private Button refresh;
    private String pendingId;
    private String pendingText;
    private boolean pendingImage;
    private boolean loading;
    private volatile int generation;
    private final android.os.Handler pollHandler = new android.os.Handler(android.os.Looper.getMainLooper());
    private final Runnable poll = new Runnable() {
        @Override public void run() { load(); pollHandler.postDelayed(this, 10000); }
    };
    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        LinearLayout root = column();
        root.setId(R.id.root);
        root.setPadding(dp(16), dp(12), dp(16), dp(8));
        setContentView(root);
        Ui.applyInsets(this);
        LinearLayout header = row();
        Button back = button("返回", () -> finish());
        header.addView(back);
        TextView title = text("跨设备粘贴板", 22);
        header.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
        header.addView(button("连接", this::pair));
        root.addView(header);
        status = text("", 13);
        root.addView(status);
        refresh = button("刷新云端记录", this::load);
        root.addView(refresh);
        ScrollView scroll = new ScrollView(this);
        records = column();
        scroll.addView(records);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        if (savedInstanceState != null) {
            pendingId = savedInstanceState.getString("pendingId");
            pendingText = savedInstanceState.getString("pendingText");
            pendingImage = savedInstanceState.getBoolean("pendingImage");
        }
    }
    @Override protected void onResume() { super.onResume(); pollHandler.post(poll); }
    @Override protected void onPause() { pollHandler.removeCallbacks(poll); super.onPause(); }
    @Override protected void onDestroy() { executor.shutdownNow(); thumbnails.shutdownNow(); super.onDestroy(); }
    @Override protected void onSaveInstanceState(Bundle state) {
        state.putString("pendingId", pendingId);
        state.putString("pendingText", pendingText);
        state.putBoolean("pendingImage", pendingImage);
        super.onSaveInstanceState(state);
    }
    private void pair() {
        EditText input = new EditText(this);
        input.setHint("粘贴 Mac 的 Android 配对信息");
        input.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD);
        input.setMinLines(3);
        input.setPadding(dp(16), dp(12), dp(16), dp(12));
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("连接阿里云粘贴板")
                .setMessage("在 Mac 的跨设备粘贴板页面复制配对信息，再粘贴到这里。")
                .setView(input).setNegativeButton("取消", null).setPositiveButton("连接", null).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
            String config = input.getText().toString().trim();
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(false);
            executor.execute(() -> {
                try {
                    CloudApi.pair(this, config);
                    ui(() -> { dialog.dismiss(); toast("连接成功"); load(); });
                } catch (Exception error) {
                    ui(() -> { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(true); input.setError(errorMessage(error)); });
                }
            });
        }));
        dialog.show();
    }
    private void load() {
        if (loading) return;
        CloudApi api = new CloudApi(this);
        if (!api.configured()) { status.setText(R.string.cloud_unpaired); return; }
        loading = true;
        refresh.setEnabled(false);
        executor.execute(() -> {
            try {
                JSONObject response = api.list();
                ui(() -> {
                    try {
                        int days = response.optInt("retentionDays", 0);
                        JSONArray items = response.getJSONArray("items");
                        status.setText(getString(R.string.cloud_count, items.length(), days > 0 ? getString(R.string.cloud_retention, days) : ""));
                        // Avoid repeatedly rebuilding thumbnails when the list is unchanged.
                        String signature = items.toString();
                        if (!signature.equals(records.getTag())) {
                            records.setTag(signature);
                            generation++;
                            records.removeAllViews();
                            if (items.length() == 0) records.addView(text("暂无记录，请在 Mac 开启自动同步后复制文本或图片。", 16));
                            for (int i = 0; i < items.length(); i++) addItem(items.getJSONObject(i), api, generation);
                        }
                    } catch (Exception error) { showError(error); }
                    loading = false;
                    refresh.setEnabled(true);
                });
            } catch (Exception error) { ui(() -> { status.setText(errorMessage(error)); loading = false; refresh.setEnabled(true); }); }
        });
    }
    private void addItem(JSONObject item, CloudApi api, int currentGeneration) throws Exception {
        String id = item.getString("id");
        boolean image = item.getString("kind").equals("image");
        String content = image ? null : item.getString("text");
        LinearLayout card = column();
        card.setPadding(dp(14), dp(12), dp(14), dp(8));
        card.setBackgroundResource(R.drawable.bg_card);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.setMargins(0, dp(8), 0, 0);
        records.addView(card, params);
        if (image) {
            ImageView preview = new ImageView(this);
            preview.setContentDescription("云端图片");
            preview.setScaleType(ImageView.ScaleType.FIT_CENTER);
            card.addView(preview, new LinearLayout.LayoutParams(-1, dp(180)));
            TextView imageStatus = text("正在加载图片…", 12);
            card.addView(imageStatus);
            thumbnails.execute(() -> {
                if (generation != currentGeneration) return;
                try {
                    byte[] data = api.content(id);
                    BitmapFactory.Options options = new BitmapFactory.Options();
                    options.inJustDecodeBounds = true;
                    BitmapFactory.decodeByteArray(data, 0, data.length, options);
                    if (options.outWidth <= 0 || options.outHeight <= 0) throw new java.io.IOException("图片格式不正确");
                    options.inSampleSize = 1;
                    while (options.outWidth / options.inSampleSize > 800 || options.outHeight / options.inSampleSize > 800) options.inSampleSize *= 2;
                    options.inJustDecodeBounds = false;
                    Bitmap bitmap = BitmapFactory.decodeByteArray(data, 0, data.length, options);
                    if (bitmap == null) throw new java.io.IOException("图片加载失败");
                    ui(() -> { if (generation == currentGeneration) { preview.setImageBitmap(bitmap); imageStatus.setVisibility(View.GONE); } });
                } catch (Exception error) { ui(() -> { if (generation == currentGeneration) imageStatus.setText(errorMessage(error)); }); }
            });
        } else {
            TextView body = text(content, 16);
            body.setMaxLines(6);
            card.addView(body);
            body.setOnClickListener(v -> new AlertDialog.Builder(this).setTitle("文本内容")
                    .setMessage(content).setPositiveButton("复制", (d, w) -> copyText(content)).setNegativeButton("关闭", null).show());
        }
        String date = new SimpleDateFormat("MM/dd HH:mm", Locale.CHINA).format(new Date(item.getLong("createdAt")));
        card.addView(text((image ? "图片" : "文本") + " · " + date + " · " + android.text.format.Formatter.formatShortFileSize(this, item.getLong("byteCount")), 12));
        LinearLayout actions = row();
        actions.addView(button(image ? "复制图片" : "复制文本", () -> {
            if (!image) copyText(content);
            else copyImage(id, api);
        }));
        actions.addView(button("下载", () -> {
            if (pendingId != null) return;
            pendingId = id; pendingText = content; pendingImage = image;
            Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType(image ? "image/png" : "text/plain").putExtra(Intent.EXTRA_TITLE, "clipboard-" + id.substring(0, 8) + (image ? ".png" : ".txt"));
            startActivityForResult(intent, 100);
        }));
        card.addView(actions);
        if (image && Build.VERSION.SDK_INT >= 29) {
            card.addView(text(getString(R.string.cloud_image_copy_hint), 12));
        }
    }
    private void copyText(String text) {
        try {
            getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("云端文本", text));
            if (Build.VERSION.SDK_INT < 33) toast("已复制");
        } catch (RuntimeException error) { showError(error); }
    }
    private void copyImage(String id, CloudApi api) {
        toast("正在准备图片…");
        executor.execute(() -> {
            try {
                byte[] data = api.content(id);
                Uri uri;
                if (Build.VERSION.SDK_INT >= 29) {
                    uri = CloudMediaCache.image(this, id, data);
                } else {
                    File directory = new File(getFilesDir(), "cloud-images");
                    if (!directory.isDirectory() && !directory.mkdirs()) throw new java.io.IOException("无法保存图片");
                    File image = new File(directory, id + ".png");
                    try (FileOutputStream output = new FileOutputStream(image)) { output.write(data); }
                    image.setLastModified(System.currentTimeMillis());
                    File[] files = directory.listFiles();
                    if (files != null) {
                        Arrays.sort(files, Comparator.comparingLong(File::lastModified).reversed());
                        for (int i = 50; i < files.length; i++) {
                            if (files[i].delete()) {
                                revokeUriPermission(imageUri(files[i]), Intent.FLAG_GRANT_READ_URI_PERMISSION);
                            }
                        }
                    }
                    uri = imageUri(image);
                }
                // SystemUI cannot forward its clipboard grant on some Android builds.
                // Grant only this copied image to WeChat, which may receive it via SystemUI.
                try {
                    getPackageManager().getPackageInfo("com.tencent.mm", 0);
                    grantUriPermission("com.tencent.mm", uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
                } catch (android.content.pm.PackageManager.NameNotFoundException ignored) {
                    // WeChat is optional; normal clipboard consumers receive Android's grant.
                }
                ui(() -> {
                    try {
                        getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newUri(getContentResolver(), "云端图片", uri));
                        if (Build.VERSION.SDK_INT < 33) toast("图片已复制");
                    } catch (RuntimeException error) { showError(error); }
                });
            } catch (Exception error) { ui(() -> showError(error)); }
        });
    }
    private Uri imageUri(File image) {
        return Uri.parse("content://" + getPackageName() + ".cloudimages/" + image.getName());
    }

    @Override protected void onActivityResult(int request, int result, Intent intent) {
        super.onActivityResult(request, result, intent);
        if (request != 100) return;
        String id = pendingId; String text = pendingText; boolean image = pendingImage;
        pendingId = null; pendingText = null;
        if (result != RESULT_OK || intent == null || intent.getData() == null || id == null) return;
        Uri uri = intent.getData();
        CloudApi api = new CloudApi(this);
        executor.execute(() -> {
            try {
                byte[] data = image ? api.content(id) : text.getBytes(StandardCharsets.UTF_8);
                try (OutputStream output = getContentResolver().openOutputStream(uri, "wt")) {
                    if (output == null) throw new java.io.IOException("无法写入所选位置");
                    output.write(data);
                }
                ui(() -> toast("已下载到所选位置"));
            } catch (Exception error) { ui(() -> showError(error)); }
        });
    }
    private void ui(Runnable action) { runOnUiThread(() -> { if (!isFinishing() && !isDestroyed()) action.run(); }); }
    private void showError(Exception error) { new AlertDialog.Builder(this).setTitle("操作失败").setMessage(errorMessage(error)).setPositiveButton("好", null).show(); }
    private String errorMessage(Exception error) { return error.getLocalizedMessage() == null ? "操作失败，请重试" : error.getLocalizedMessage(); }
    private void toast(String message) { Toast.makeText(this, message, Toast.LENGTH_SHORT).show(); }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private LinearLayout column() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); return layout; }
    private LinearLayout row() { LinearLayout layout = new LinearLayout(this); layout.setGravity(android.view.Gravity.CENTER_VERTICAL); return layout; }
    private TextView text(String value, int size) { TextView view = new TextView(this); view.setText(value); view.setTextSize(size); view.setTextColor(getColor(size <= 13 ? R.color.muted : R.color.ink)); view.setPadding(0, dp(6), 0, dp(6)); return view; }
    private Button button(String label, Runnable action) { Button view = new Button(this, null, 0, R.style.QuietButton); view.setText(label); view.setOnClickListener(v -> action.run()); return view; }
}
