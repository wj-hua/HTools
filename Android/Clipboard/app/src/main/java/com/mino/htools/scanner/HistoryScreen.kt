package com.mino.htools.scanner

import com.mino.htools.R
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mino.htools.scanner.data.ScanHistoryEntity
import com.mino.htools.scanner.data.ScanSource
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun HistoryScreen(
    items: List<ScanHistoryEntity>,
    onBack: () -> Unit,
    onCopy: (String) -> Unit,
    onShare: (String) -> Unit,
    onSmartAction: (SmartScanResult) -> Unit,
    onToggleFavorite: (Long, Boolean) -> Unit,
    onDelete: (Long) -> Unit,
    onClear: () -> Unit,
    onExportCsv: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var itemPendingDelete by rememberSaveable { mutableStateOf<Long?>(null) }
    var showClearConfirmation by rememberSaveable { mutableStateOf(false) }
    val filteredItems = if (query.isBlank()) {
        items
    } else {
        items.filter {
            it.content.contains(query.trim(), ignoreCase = true) ||
                it.resultType.displayName.contains(query.trim(), ignoreCase = true)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFFF7F4EF))
            .padding(WindowInsets.statusBars.asPaddingValues()),
    ) {
        HistoryTopBar(
            hasItems = items.isNotEmpty(),
            onBack = onBack,
            onClear = { showClearConfirmation = true },
            onExportCsv = onExportCsv,
            onOpenSettings = onOpenSettings,
        )
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp, vertical = 4.dp),
            singleLine = true,
            label = { Text("搜索历史记录") },
            placeholder = { Text("输入内容或域名") },
            shape = RoundedCornerShape(16.dp),
        )
        when {
            items.isEmpty() -> EmptyHistory(modifier = Modifier.weight(1f))
            filteredItems.isEmpty() -> EmptySearch(modifier = Modifier.weight(1f))
            else -> LazyColumn(
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(
                    start = 18.dp,
                    end = 18.dp,
                    top = 8.dp,
                    bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 18.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(filteredItems, key = { it.id }) { item ->
                    HistoryItem(
                        item = item,
                        onCopy = { onCopy(item.content) },
                        onShare = { onShare(item.content) },
                        onSmartAction = {
                            onSmartAction(parseScanResult(item.content, item.resultType))
                        },
                        onToggleFavorite = {
                            onToggleFavorite(item.id, !item.isFavorite)
                        },
                        onDelete = { itemPendingDelete = item.id },
                    )
                }
            }
        }
    }

    itemPendingDelete?.let { id ->
        AlertDialog(
            onDismissRequest = { itemPendingDelete = null },
            title = { Text("删除这条记录？") },
            text = { Text("删除后无法恢复。") },
            confirmButton = {
                TextButton(onClick = {
                    onDelete(id)
                    itemPendingDelete = null
                }) { Text("删除", color = Color(0xFFB3261E)) }
            },
            dismissButton = {
                TextButton(onClick = { itemPendingDelete = null }) { Text("取消") }
            },
        )
    }

    if (showClearConfirmation) {
        AlertDialog(
            onDismissRequest = { showClearConfirmation = false },
            title = { Text("清空全部历史记录？") },
            text = { Text("所有扫描记录都会被永久删除。") },
            confirmButton = {
                TextButton(onClick = {
                    onClear()
                    showClearConfirmation = false
                }) { Text("全部清空", color = Color(0xFFB3261E)) }
            },
            dismissButton = {
                TextButton(onClick = { showClearConfirmation = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun HistoryTopBar(
    hasItems: Boolean,
    onBack: () -> Unit,
    onClear: () -> Unit,
    onExportCsv: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(
            onClick = onBack,
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Color(0xFFC4612F).copy(alpha = 0.1f))
                .border(1.5.dp, Color(0xFFC4612F).copy(alpha = 0.25f), RoundedCornerShape(12.dp)),
        ) {
            Image(
                painter = painterResource(id = R.drawable.ic_back_hand_drawn),
                contentDescription = "返回",
                modifier = Modifier.size(24.dp),
                colorFilter = androidx.compose.ui.graphics.ColorFilter.tint(Color(0xFF1F2421)),
            )
        }
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = "扫描历史",
            color = Color(0xFF1F2421),
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = onExportCsv, enabled = hasItems) {
            Text("CSV", color = if (hasItems) Color(0xFF356B3A) else Color(0xFF9A9389))
        }
        TextButton(onClick = onOpenSettings) {
            Text("设置", color = Color(0xFFC4612F))
        }
        TextButton(onClick = onClear, enabled = hasItems) {
            Text("清空", color = if (hasItems) Color(0xFFB3261E) else Color(0xFF9A9389))
        }
    }
}

@Composable
private fun EmptyHistory(modifier: Modifier = Modifier) {
    EmptyMessage(modifier, "📋", "还没有扫描记录", "扫描二维码或从相册识别后会显示在这里")
}

@Composable
private fun EmptySearch(modifier: Modifier = Modifier) {
    EmptyMessage(modifier, "⌕", "没有找到匹配记录", "换个关键词试试")
}

@Composable
private fun EmptyMessage(modifier: Modifier, icon: String, title: String, detail: String) {
    Box(modifier = modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(text = icon, color = Color(0xFF5C635D), fontSize = 52.sp)
            Spacer(modifier = Modifier.height(16.dp))
            Text(title, color = Color(0xFF1F2421), fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            Spacer(modifier = Modifier.height(8.dp))
            Text(detail, color = Color(0xFF5C635D), fontSize = 14.sp)
        }
    }
}

@Composable
private fun HistoryItem(
    item: ScanHistoryEntity,
    onCopy: () -> Unit,
    onShare: () -> Unit,
    onSmartAction: () -> Unit,
    onToggleFavorite: () -> Unit,
    onDelete: () -> Unit,
) {
    val smartResult = parseScanResult(item.content, item.resultType)
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = Color.White),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(999.dp))
                            .background(Color(0xFFF2E3D6))
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                    ) {
                        Text(
                            text = "${item.resultType.icon} ${item.resultType.displayName}",
                            color = Color(0xFFC4612F),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                    Text(
                        item.source.displayName(),
                        color = Color(0xFF5C635D),
                        fontSize = 11.sp,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(item.scannedAt.displayTime(), color = Color(0xFF5C635D), fontSize = 12.sp)
                    TextButton(onClick = onToggleFavorite) {
                        Text(
                            if (item.isFavorite) "★" else "☆",
                            color = if (item.isFavorite) Color(0xFFE09A16) else Color(0xFF5C635D),
                            fontSize = 22.sp,
                        )
                    }
                }
            }
            Text(
                text = item.content,
                color = Color(0xFF1F2421),
                fontSize = 15.sp,
                lineHeight = 22.sp,
                maxLines = 4,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp)
                    .background(Color(0xFFFBF9F5), RoundedCornerShape(14.dp))
                    .border(1.dp, Color(0xFFE7E1D7), RoundedCornerShape(14.dp))
                    .padding(13.dp),
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onDelete) { Text("删除", color = Color(0xFFB3261E)) }
                TextButton(onClick = onCopy) { Text("复制", color = Color(0xFF1F2421)) }
                TextButton(onClick = onShare) { Text("分享", color = Color(0xFF1F2421)) }
                smartResult.actionLabel?.let { label ->
                    Button(
                        onClick = onSmartAction,
                        shape = RoundedCornerShape(999.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF4CAF50)),
                        contentPadding = PaddingValues(horizontal = 10.dp),
                    ) {
                        Text(
                            text = label,
                            fontSize = 13.sp,
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Clip,
                        )
                    }
                }
            }
        }
    }
}

private fun ScanSource.displayName(): String = when (this) {
    ScanSource.CAMERA -> "相机扫描"
    ScanSource.GALLERY -> "相册识别"
    ScanSource.SHARE -> "系统分享"
}

private fun Long.displayTime(): String =
    SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date(this))
