package com.mino.clipboard;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.database.sqlite.SQLiteException;
import android.os.Build;
import android.os.Bundle;
import android.widget.EditText;
import android.widget.TextView;
import android.widget.Toast;
import android.window.OnBackInvokedDispatcher;

public final class EditorActivity extends Activity {
    static final String EXTRA_ID = "clip_id";
    private static final int MAX_CONTENT_LENGTH = 100_000;
    private ClipStore store;
    private EditText contentInput;
    private long id;
    private String originalContent = "";

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(R.layout.activity_editor);
        Ui.applyInsets(this);
        store = new ClipStore(this);
        contentInput = findViewById(R.id.content_input);
        id = getIntent().getLongExtra(EXTRA_ID, -1);
        ((TextView) findViewById(R.id.editor_heading)).setText(id == -1 ? R.string.new_title : R.string.edit_title);
        if (state != null) {
            originalContent = state.getString("original_content", "");
        } else if (id != -1) {
            try {
                Clip clip = store.find(id);
                if (clip == null) {
                    toast(R.string.missing_clip);
                    finish();
                    return;
                }
                originalContent = clip.content;
            } catch (SQLiteException exception) {
                toast(R.string.load_failed);
                finish();
                return;
            }
        }
        contentInput.setText(originalContent);
        contentInput.addTextChangedListener(Ui.onTextChanged(this::updateCount));
        updateCount();
        findViewById(R.id.save).setOnClickListener(view -> save());
        findViewById(R.id.back).setOnClickListener(view -> confirmExit());
        findViewById(R.id.paste).setOnClickListener(view -> paste());
        if (Build.VERSION.SDK_INT >= 33) {
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    OnBackInvokedDispatcher.PRIORITY_DEFAULT, this::confirmExit);
        }
    }

    @Override protected void onSaveInstanceState(Bundle state) {
        state.putString("original_content", originalContent);
        super.onSaveInstanceState(state);
    }

    @Override protected void onDestroy() {
        store.close();
        super.onDestroy();
    }

    @SuppressWarnings("deprecation")
    @Override public void onBackPressed() {
        confirmExit();
    }

    private void updateCount() {
        ((TextView) findViewById(R.id.character_count)).setText(getString(R.string.character_count,
                Ui.characterCount(contentInput.getText().toString())));
    }

    private void save() {
        String content = contentInput.getText().toString();
        if (content.trim().isEmpty()) {
            contentInput.setError(getString(R.string.content_required));
            contentInput.requestFocus();
            return;
        }
        try {
            if (!store.save(id, content)) {
                toast(R.string.missing_clip);
                return;
            }
            toast(R.string.saved);
            finish();
        } catch (SQLiteException exception) {
            toast(R.string.save_failed);
        }
    }

    private void paste() {
        try {
            ClipboardManager clipboard = getSystemService(ClipboardManager.class);
            ClipData clip = clipboard.getPrimaryClip();
            CharSequence text = clip != null && clip.getItemCount() > 0 ? clip.getItemAt(0).getText() : null;
            if (text == null || text.length() == 0) {
                toast(R.string.clipboard_empty);
                return;
            }
            int start = Math.max(0, contentInput.getSelectionStart());
            int end = Math.max(0, contentInput.getSelectionEnd());
            int from = Math.min(start, end);
            int to = Math.max(start, end);
            if ((long) contentInput.length() - (to - from) + text.length() > MAX_CONTENT_LENGTH) {
                toast(R.string.too_long);
                return;
            }
            contentInput.getText().replace(from, to, text.toString());
            contentInput.requestFocus();
            contentInput.setSelection(from + text.length());
        } catch (RuntimeException exception) {
            toast(R.string.clipboard_unavailable);
        }
    }

    private void confirmExit() {
        if (contentInput.getText().toString().equals(originalContent)) {
            finish();
            return;
        }
        new AlertDialog.Builder(this)
                .setTitle(R.string.discard_title)
                .setNegativeButton(R.string.keep_editing, null)
                .setPositiveButton(R.string.discard, (dialog, which) -> finish())
                .show();
    }

    private void toast(int message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
    }
}
