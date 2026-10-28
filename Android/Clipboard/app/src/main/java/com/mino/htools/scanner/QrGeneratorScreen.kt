package com.mino.htools.scanner

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import java.io.File
import java.io.FileOutputStream

@Composable
fun QrGeneratorScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    var content by rememberSaveable { mutableStateOf("") }
    val bitmap = remember(content) {
        content.trim().takeIf { it.isNotEmpty() }?.let(::generateQrBitmap)
    }
    val saveLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("image/png"),
    ) { uri ->
        if (uri != null && bitmap != null) {
            runCatching {
                context.contentResolver.openOutputStream(uri)?.use {
                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
                } ?: error("无法打开文件")
            }.onSuccess {
                Toast.makeText(context, "二维码已保存", Toast.LENGTH_SHORT).show()
            }.onFailure {
                Toast.makeText(context, "保存失败，请重试", Toast.LENGTH_SHORT).show()
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFFF7F4EF))
            .padding(WindowInsets.statusBars.asPaddingValues())
            .padding(bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()),
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
                "二维码生成器",
                color = Color(0xFF1F2421),
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
            )
        }

        Column(
            modifier = Modifier.padding(horizontal = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            OutlinedTextField(
                value = content,
                onValueChange = { content = it.take(MAX_QR_CONTENT_LENGTH) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("二维码内容") },
                placeholder = { Text("输入网址、文字、联系方式等") },
                minLines = 3,
                maxLines = 5,
                supportingText = {
                    Text("${content.length} / $MAX_QR_CONTENT_LENGTH")
                },
                shape = RoundedCornerShape(18.dp),
            )
            Spacer(modifier = Modifier.height(18.dp))
            Card(
                modifier = Modifier.size(292.dp),
                colors = CardDefaults.cardColors(containerColor = Color.White),
                shape = RoundedCornerShape(24.dp),
                elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(18.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    if (bitmap == null) {
                        Text(
                            if (content.isBlank()) {
                                "输入内容后\n二维码会显示在这里"
                            } else {
                                "内容过长，无法生成\n请缩短后重试"
                            },
                            color = Color(0xFF777068),
                            fontSize = 16.sp,
                            lineHeight = 24.sp,
                        )
                    } else {
                        Image(
                            bitmap = bitmap.asImageBitmap(),
                            contentDescription = "生成的二维码",
                            modifier = Modifier
                                .fillMaxSize()
                                .clip(RoundedCornerShape(10.dp))
                                .border(1.dp, Color(0xFFE7E1D7), RoundedCornerShape(10.dp)),
                        )
                    }
                }
            }
            Spacer(modifier = Modifier.height(20.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Button(
                    onClick = { saveLauncher.launch("scanapp-qr.png") },
                    enabled = bitmap != null,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(999.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFC4612F)),
                ) {
                    Text("保存图片")
                }
                Button(
                    onClick = { bitmap?.let { context.shareQrBitmap(it) } },
                    enabled = bitmap != null,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(999.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF4CAF50)),
                ) {
                    Text("分享二维码")
                }
            }
        }
    }
}

private fun generateQrBitmap(content: String): Bitmap? = runCatching {
    val matrix = MultiFormatWriter().encode(
        content,
        BarcodeFormat.QR_CODE,
        QR_SIZE,
        QR_SIZE,
        mapOf(
            EncodeHintType.CHARACTER_SET to "UTF-8",
            EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
            EncodeHintType.MARGIN to 2,
        ),
    )
    Bitmap.createBitmap(QR_SIZE, QR_SIZE, Bitmap.Config.ARGB_8888).apply {
        val pixels = IntArray(QR_SIZE * QR_SIZE)
        for (y in 0 until QR_SIZE) {
            for (x in 0 until QR_SIZE) {
                pixels[y * QR_SIZE + x] =
                    if (matrix[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE
            }
        }
        setPixels(pixels, 0, QR_SIZE, 0, 0, QR_SIZE, QR_SIZE)
    }
}.getOrNull()

private fun Context.shareQrBitmap(bitmap: Bitmap) {
    runCatching {
        val directory = File(cacheDir, "shared").apply { mkdirs() }
        val file = File(directory, "scanapp-qr.png")
        FileOutputStream(file).use {
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(sendIntent, "分享二维码"))
    }.onFailure {
        if (it is ActivityNotFoundException) {
            Toast.makeText(this, "没有可分享图片的应用", Toast.LENGTH_SHORT).show()
        } else {
            Toast.makeText(this, "二维码分享失败", Toast.LENGTH_SHORT).show()
        }
    }
}

private const val QR_SIZE = 768
private const val MAX_QR_CONTENT_LENGTH = 1_500
