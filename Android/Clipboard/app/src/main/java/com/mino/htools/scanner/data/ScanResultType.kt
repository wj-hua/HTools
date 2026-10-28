package com.mino.htools.scanner.data

enum class ScanResultType(val displayName: String, val icon: String) {
    URL("网址", "🔗"),
    WIFI("Wi-Fi", "◉"),
    PHONE("电话", "☎"),
    EMAIL("邮箱", "✉"),
    CONTACT("联系人", "♙"),
    MAP("地图", "⌖"),
    TEXT("文本", "▤"),
}
