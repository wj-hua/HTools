package com.mino.htools;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

import com.mino.htools.scanner.ScanActivity;

public final class HomeActivity extends Activity {
    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_home);
        Ui.applyInsets(this);
        findViewById(R.id.scan_card).setOnClickListener(view -> startActivity(new Intent(this, ScanActivity.class)));
        findViewById(R.id.clip_card).setOnClickListener(view -> startActivity(new Intent(this, MainActivity.class)));
    }
}
