#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
app_dir="$project_root/dist/HTools.app"
contents_dir="$app_dir/Contents"

# 稳定签名身份。
#
# 必须用固定证书签名，不能用 ad-hoc（codesign --sign -）：macOS 的「本地网络」
# 和「辅助功能」权限对 ad-hoc 应用是按代码哈希记录的，每次重新 build 哈希都会变，
# 之前授予的权限随即失效，表现为能发现设备却连不上（adb pair 失败）、
# 常用文本无法自动粘贴。用固定证书签名后，
# 权限记录基于签名身份，可跨重建保留。
#
# 可用 HTOOLS_SIGN_IDENTITY 指定证书哈希或名称；留空则自动挑选钥匙串里第一个
# 有效的代码签名身份（跳过已吊销/失效的）。
select_sign_identity() {
    if [[ -n "${HTOOLS_SIGN_IDENTITY:-}" ]]; then
        print -r -- "$HTOOLS_SIGN_IDENTITY"
        return 0
    fi

    # find-identity 会把吊销/失效的证书标注为 (CSSMERR_...)，需要排除。
    local line
    while IFS= read -r line; do
        [[ "$line" == *CSSMERR* ]] && continue
        if [[ "$line" =~ '^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-F]{40})[[:space:]]' ]]; then
            print -r -- "$match[1]"
            return 0
        fi
    done < <(security find-identity -v -p codesigning)

    return 1
}

if ! sign_identity="$(select_sign_identity)"; then
    print -u2 "错误：钥匙串里没有可用的代码签名身份。"
    print -u2 "请在 Xcode（Settings → Accounts）中登录 Apple ID 生成开发证书，"
    print -u2 "或用 HTOOLS_SIGN_IDENTITY 指定一个身份。"
    exit 1
fi

cd "$project_root"
swift build -c release

if [[ -d "$app_dir" ]]; then
    /bin/rm -rf "$app_dir"
fi

/bin/mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
/bin/cp "$project_root/.build/release/HTools" "$contents_dir/MacOS/HTools"
/bin/cp "$project_root/AppResources/Info.plist" "$contents_dir/Info.plist"
/bin/cp "$project_root/AppResources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"

# 不用 --deep（已废弃且对单可执行文件的 bundle 没有必要）。
/usr/bin/codesign --force --sign "$sign_identity" --timestamp=none "$app_dir"

print "已生成：$app_dir"
print "签名身份：$(/usr/bin/codesign -dvv "$app_dir" 2>&1 | /usr/bin/grep '^Authority=' | /usr/bin/head -1)"
