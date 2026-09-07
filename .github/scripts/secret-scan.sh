#!/usr/bin/env bash
# secret scan：扫描已跟踪文件中的常见密钥形态（SPEC §19）。
set -euo pipefail

# 已跟踪文件列表
mapfile -t files < <(git ls-files -z | tr '\0' '\n')

fail=0
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    # 常见 secret 模式（误报容忍：仅匹配高置信形态）
    if grep -nEI \
        -e 'AKIA[0-9A-Z]{16}' \
        -e '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----' \
        -e 'ghp_[A-Za-z0-9]{36}' \
        -e 'xox[abp]-[A-Za-z0-9-]{10,}' \
        -e 'sk-[A-Za-z0-9]{20,}' \
        "$f" 2>/dev/null; then
        echo "SECRET PATTERN FOUND in $f" >&2
        fail=1
    fi
done

# 真实设备标识形态（MAC 地址、序列号样式）——文档中禁止真实地址。
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    case "$f" in
    *.md | *.txt | *.rs | *.toml | *.yml | *.yaml)
        if grep -nEi '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "$f" 2>/dev/null; then
            echo "POTENTIAL REAL MAC ADDRESS in $f（文档/代码不得包含真实地址）" >&2
            fail=1
        fi
        ;;
    esac
done

exit $fail
