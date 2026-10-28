package com.mino.htools.scanner

import com.mino.htools.scanner.data.ScanResultType

data class SmartScanResult(
    val rawValue: String,
    val type: ScanResultType,
    val title: String,
    val subtitle: String? = null,
    val actionLabel: String? = null,
    val phone: String? = null,
    val email: String? = null,
    val contactName: String? = null,
    val mapUri: String? = null,
    val wifiName: String? = null,
)

fun parseScanResult(
    rawValue: String,
    typeHint: ScanResultType? = null,
): SmartScanResult {
    val parsed = parseScanResultAutomatically(rawValue)
    if (typeHint == null || typeHint == parsed.type) return parsed
    val value = rawValue.trim()
    return when (typeHint) {
        ScanResultType.URL -> SmartScanResult(
            rawValue = value,
            type = typeHint,
            title = value.simpleWebDomain() ?: value,
            subtitle = value,
            actionLabel = "安全访问",
        )
        ScanResultType.WIFI -> parseWifi(value) ?: SmartScanResult(
            rawValue = value,
            type = typeHint,
            title = "Wi-Fi 网络",
            subtitle = value,
            actionLabel = "打开 Wi-Fi",
        )
        ScanResultType.PHONE -> {
            val phone = value.removePrefixIgnoreCase("tel:")
            SmartScanResult(
                rawValue = value,
                type = typeHint,
                title = phone,
                actionLabel = "拨打电话",
                phone = phone,
            )
        }
        ScanResultType.EMAIL -> {
            val email = value.removePrefixIgnoreCase("mailto:").substringBefore("?")
            SmartScanResult(
                rawValue = value,
                type = typeHint,
                title = email,
                actionLabel = "写邮件",
                email = email,
            )
        }
        ScanResultType.CONTACT -> parseContact(value) ?: SmartScanResult(
            rawValue = value,
            type = typeHint,
            title = "新联系人",
            subtitle = value,
            actionLabel = "添加联系人",
        )
        ScanResultType.MAP -> SmartScanResult(
            rawValue = value,
            type = typeHint,
            title = "地图位置",
            subtitle = value,
            actionLabel = "打开地图",
            mapUri = value,
        )
        ScanResultType.TEXT -> SmartScanResult(
            rawValue = value,
            type = typeHint,
            title = "文本内容",
            subtitle = value,
        )
    }
}

private fun parseScanResultAutomatically(rawValue: String): SmartScanResult {
    val value = rawValue.trim()
    parseWifi(value)?.let { return it }
    parseContact(value)?.let { return it }

    if (value.startsWith("geo:", ignoreCase = true)) {
        val label = value.substringAfter("q=", "").takeIf { it.isNotBlank() }
            ?.replace("+", " ")
        return SmartScanResult(
            rawValue = value,
            type = ScanResultType.MAP,
            title = label ?: "地图位置",
            subtitle = value,
            actionLabel = "打开地图",
            mapUri = value,
        )
    }

    val telephone = value.removePrefixIgnoreCase("tel:").takeIf {
        value.startsWith("tel:", ignoreCase = true)
    } ?: value.takeIf { PHONE_REGEX.matches(it) }
    if (telephone != null) {
        val normalized = telephone.trim()
        return SmartScanResult(
            rawValue = value,
            type = ScanResultType.PHONE,
            title = normalized,
            actionLabel = "拨打电话",
            phone = normalized,
        )
    }

    val mailAddress = value.removePrefixIgnoreCase("mailto:").substringBefore("?").takeIf {
        value.startsWith("mailto:", ignoreCase = true)
    } ?: value.takeIf { EMAIL_REGEX.matches(it) }
    if (mailAddress != null) {
        return SmartScanResult(
            rawValue = value,
            type = ScanResultType.EMAIL,
            title = mailAddress,
            actionLabel = "写邮件",
            email = mailAddress,
        )
    }

    if (value.looksLikeWebUrl()) {
        return SmartScanResult(
            rawValue = value,
            type = ScanResultType.URL,
            title = value.simpleWebDomain() ?: value,
            subtitle = value,
            actionLabel = "安全访问",
        )
    }

    return SmartScanResult(
        rawValue = value,
        type = ScanResultType.TEXT,
        title = "文本内容",
        subtitle = value,
    )
}

private fun parseWifi(value: String): SmartScanResult? {
    if (!value.startsWith("WIFI:", ignoreCase = true)) return null
    val fields = splitEscaped(value.substringAfter(":"))
        .mapNotNull {
            val separator = it.indexOf(':')
            if (separator <= 0) null
            else it.substring(0, separator).uppercase() to unescapeWifi(it.substring(separator + 1))
        }
        .toMap()
    val name = fields["S"].orEmpty().ifBlank { "未命名网络" }
    val security = fields["T"].orEmpty().ifBlank { "开放网络" }
    return SmartScanResult(
        rawValue = value,
        type = ScanResultType.WIFI,
        title = name,
        subtitle = "安全类型：$security",
        actionLabel = "打开 Wi-Fi",
        wifiName = name,
    )
}

private fun parseContact(value: String): SmartScanResult? {
    val isMeCard = value.startsWith("MECARD:", ignoreCase = true)
    val isVCard = value.startsWith("BEGIN:VCARD", ignoreCase = true)
    if (!isMeCard && !isVCard) return null

    val normalized = value.replace("\r\n", "\n")
    val name = if (isMeCard) {
        meCardValue(normalized, "N")
    } else {
        vCardValue(normalized, "FN") ?: vCardValue(normalized, "N")?.replace(";", " ")
    }?.trim()
    val phone = if (isMeCard) meCardValue(normalized, "TEL") else vCardValue(normalized, "TEL")
    val email = if (isMeCard) meCardValue(normalized, "EMAIL") else vCardValue(normalized, "EMAIL")
    return SmartScanResult(
        rawValue = value,
        type = ScanResultType.CONTACT,
        title = name?.ifBlank { null } ?: "新联系人",
        subtitle = listOfNotNull(phone, email).joinToString(" · ").ifBlank { null },
        actionLabel = "添加联系人",
        phone = phone,
        email = email,
        contactName = name,
    )
}

private fun meCardValue(value: String, key: String): String? =
    Regex("(?:^|;)$key:((?:\\\\.|[^;])*)", RegexOption.IGNORE_CASE)
        .find(value.substringAfter(":"))
        ?.groupValues
        ?.get(1)
        ?.replace("\\;", ";")
        ?.replace("\\:", ":")

private fun vCardValue(value: String, key: String): String? =
    value.lineSequence()
        .firstOrNull { it.substringBefore(":").substringBefore(";").equals(key, ignoreCase = true) }
        ?.substringAfter(":", "")
        ?.takeIf { it.isNotBlank() }

private fun splitEscaped(value: String): List<String> {
    val parts = mutableListOf<String>()
    val current = StringBuilder()
    var escaped = false
    value.forEach { char ->
        when {
            escaped -> {
                current.append('\\').append(char)
                escaped = false
            }
            char == '\\' -> escaped = true
            char == ';' -> {
                parts += current.toString()
                current.clear()
            }
            else -> current.append(char)
        }
    }
    if (escaped) current.append('\\')
    if (current.isNotEmpty()) parts += current.toString()
    return parts
}

private fun unescapeWifi(value: String): String =
    value.replace("\\;", ";")
        .replace("\\:", ":")
        .replace("\\,", ",")
        .replace("\\\\", "\\")

private fun String.removePrefixIgnoreCase(prefix: String): String =
    if (startsWith(prefix, ignoreCase = true)) substring(prefix.length) else this

private val EMAIL_REGEX = Regex("^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$", RegexOption.IGNORE_CASE)
private val PHONE_REGEX = Regex("^\\+?[0-9][0-9 ()-]{5,}[0-9]$")
private val WEB_URL_REGEX = Regex(
    "^(?:https?://)?(?:[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?\\.)+[A-Z]{2,}(?::\\d{1,5})?(?:[/?#].*)?$",
    RegexOption.IGNORE_CASE,
)

private fun String.looksLikeWebUrl(): Boolean =
    isNotBlank() && none { it.isWhitespace() } && WEB_URL_REGEX.matches(this)

private fun String.simpleWebDomain(): String? {
    val withoutScheme = substringAfter("://", this)
    return withoutScheme.substringBefore("/").substringBefore("?").substringBefore("#")
        .substringBefore(":")
        .removePrefix("www.")
        .takeIf { it.isNotBlank() }
}
