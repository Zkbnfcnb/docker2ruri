#!/usr/bin/env bash
# 本地 lint：shellcheck（warning 及以上）+ bash 语法检查。
# CI 直接调用本脚本。
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "错误: 需要 shellcheck，请先安装（apt install shellcheck / brew install shellcheck）" >&2
    exit 1
fi

shellcheck -S warning docker.sh tests/*.sh
bash -n docker.sh tests/*.sh
echo "lint/syntax OK (shellcheck $(shellcheck --version | awk '/^version:/ {print $2}'))"
