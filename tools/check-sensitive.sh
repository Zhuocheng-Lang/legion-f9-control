#!/bin/sh
# 提交前敏感信息检查：真实 BLE 地址、抓包/私有材料、常见凭证。
# 只检查 git 跟踪的文件；命中即失败并打印行号。
set -eu

cd "$(dirname "$0")/.."

fail=0

report() {
    echo "check-sensitive: $1" >&2
    fail=1
}

tracked() {
    # 排除本脚本自身：它的正则文本不应触发检查
    git ls-files -z | grep -zv '^tools/check-sensitive.sh$'
}

# 1) 设备/蓝牙地址（xx:xx:xx:xx:xx:xx 形式）
if tracked | xargs -0 grep -nEI -- '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'; then
    report "发现疑似设备地址"
fi

# 2) 抓包/私有材料/二进制产物（按文件名）
if git ls-files | grep -E '\.(pcap|pcapng|rep|gpr|exe|dll|bin|pem|key)$'; then
    report "发现不应入库的敏感或二进制文件"
fi

# 3) 常见凭证
if tracked | xargs -0 grep -nEI -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[0-9A-Za-z]{36}'; then
    report "发现疑似凭证"
fi

# 4) .env 文件不应被跟踪
if git ls-files | grep -E '(^|/)\.env($|\.)'; then
    report "发现 .env 文件"
fi

if [ "$fail" -ne 0 ]; then
    echo "check-sensitive: 检查未通过，请先清理再提交" >&2
    exit 1
fi

echo "check-sensitive: 未发现敏感信息"
