#!/usr/bin/env bash
# 禁止文件扩展名与单文件大小门槛（SPEC §16.4、§19）。
set -euo pipefail

fail=0
mapfile -t files < <(git ls-files -z | tr '\0' '\n')

for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.exe|*.dll|*.bin|*.gpr|*.rep|*.pcap|*.pcapng)
      echo "FORBIDDEN EXTENSION: $f" >&2
      fail=1
      ;;
  esac
done

# 单文件大小门槛：1 MiB（仓库无任何需要大文件的内容）。
limit=$((1024 * 1024))
while IFS= read -r -d '' f; do
  size=$(stat -c%s "$f" 2>/dev/null || echo 0)
  if [ "$size" -gt "$limit" ]; then
    echo "FILE TOO LARGE: $f ($size bytes > $limit)" >&2
    fail=1
  fi
done < <(git ls-files -z)

# 确认 Git LFS 未被用于绕过限制。
if [ -f .gitattributes ] && grep -q 'filter=lfs' .gitattributes; then
  echo "GIT LFS NOT ALLOWED in this repository" >&2
  fail=1
fi

exit $fail
