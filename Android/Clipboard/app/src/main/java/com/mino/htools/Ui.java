package com.mino.htools;

import android.app.Activity;
import android.os.Build;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.view.WindowInsets;

final class Ui {
    private Ui() {}

    static void applyInsets(Activity activity) {
        View root = activity.findViewById(R.id.root);
        int left = root.getPaddingLeft();
        int top = root.getPaddingTop();
        int right = root.getPaddingRight();
        int bottom = root.getPaddingBottom();
        // Target 35 is edge-to-edge; preserve the XML spacing and avoid system bars / keyboard.
        if (Build.VERSION.SDK_INT >= 30) {
            activity.getWindow().setDecorFitsSystemWindows(false);
            root.setOnApplyWindowInsetsListener((view, insets) -> {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars()
                        | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                view.setPadding(left + bars.left, top + bars.top,
                        right + bars.right, bottom + bars.bottom);
                return insets;
            });
            root.requestApplyInsets();
        }
    }

    static TextWatcher onTextChanged(Runnable action) {
        return new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) {
                action.run();
            }
            @Override public void afterTextChanged(Editable s) {}
        };
    }

    static int characterCount(String text) {
        return text.codePointCount(0, text.length());
    }
}
