package com.mino.htools.scanner

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.Slider
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mino.htools.scanner.data.AutoCleanupPeriod

@Composable
fun SettingsScreen(
    privacyMode: Boolean,
    autoCleanupPeriod: AutoCleanupPeriod,
    continuousScan: Boolean,
    vibrationEnabled: Boolean,
    duplicateDelaySeconds: Int,
    onBack: () -> Unit,
    onPrivacyModeChange: (Boolean) -> Unit,
    onAutoCleanupPeriodChange: (AutoCleanupPeriod) -> Unit,
    onContinuousScanChange: (Boolean) -> Unit,
    onVibrationEnabledChange: (Boolean) -> Unit,
    onDuplicateDelayChange: (Int) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFFF7F4EF))
            .padding(WindowInsets.statusBars.asPaddingValues())
            .padding(bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding())
            .verticalScroll(rememberScrollState()),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack, modifier = Modifier.size(48.dp)) {
                Text("‹", color = Color(0xFF1F2421), fontSize = 38.sp)
            }
            Text(
                "扫描设置",
                modifier = Modifier.weight(1f),
                color = Color(0xFF1F2421),
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
            )
        }

        Text(
            "扫描行为",
            modifier = Modifier.padding(horizontal = 22.dp, vertical = 8.dp),
            color = Color(0xFF1F2421),
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp),
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.cardColors(containerColor = Color.White),
        ) {
            Column {
                SettingSwitchRow(
                    title = "连续扫码",
                    detail = "识别后不弹出结果页，自动继续扫描并保存记录",
                    checked = continuousScan,
                    onCheckedChange = onContinuousScanChange,
                )
                SettingSwitchRow(
                    title = "成功时振动",
                    detail = "每次成功识别后提供触觉反馈",
                    checked = vibrationEnabled,
                    onCheckedChange = onVibrationEnabledChange,
                )
                Column(modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp)) {
                    Text(
                        "相同内容间隔：$duplicateDelaySeconds 秒",
                        color = Color(0xFF1F2421),
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        "连续扫码时，在此时间内忽略重复内容",
                        color = Color(0xFF5C635D),
                        fontSize = 13.sp,
                        modifier = Modifier.padding(top = 3.dp),
                    )
                    Slider(
                        value = duplicateDelaySeconds.toFloat(),
                        onValueChange = { onDuplicateDelayChange(it.toInt().coerceIn(1, 10)) },
                        valueRange = 1f..10f,
                        steps = 8,
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(24.dp))
        Text(
            "隐私与存储",
            modifier = Modifier.padding(horizontal = 22.dp, vertical = 8.dp),
            color = Color(0xFF1F2421),
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp),
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.cardColors(containerColor = Color.White),
        ) {
            SettingSwitchRow(
                title = "隐私模式",
                detail = "开启后，新扫描结果不会写入历史记录",
                checked = privacyMode,
                onCheckedChange = onPrivacyModeChange,
            )
        }

        Spacer(modifier = Modifier.height(18.dp))
        Text(
            "自动清理未收藏记录",
            modifier = Modifier.padding(horizontal = 22.dp),
            color = Color(0xFF1F2421),
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            "收藏记录不会被自动清理",
            modifier = Modifier.padding(horizontal = 22.dp, vertical = 5.dp),
            color = Color(0xFF5C635D),
            fontSize = 13.sp,
        )
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp, vertical = 8.dp),
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.cardColors(containerColor = Color.White),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
                AutoCleanupPeriod.entries.forEach { period ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onAutoCleanupPeriodChange(period) }
                            .padding(horizontal = 12.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(
                            selected = autoCleanupPeriod == period,
                            onClick = { onAutoCleanupPeriodChange(period) },
                        )
                        Text(
                            period.displayName,
                            color = Color(0xFF1F2421),
                            fontSize = 15.sp,
                            modifier = Modifier.padding(start = 6.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingSwitchRow(
    title: String,
    detail: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onCheckedChange(!checked) }
            .padding(18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                color = Color(0xFF1F2421),
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                detail,
                color = Color(0xFF5C635D),
                fontSize = 13.sp,
                lineHeight = 19.sp,
                modifier = Modifier.padding(top = 4.dp, end = 12.dp),
            )
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}
