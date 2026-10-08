#!/usr/bin/env bash
# 拼出这一颗的源码树 build/src：先让 to2610-amp 拼好它的那一份（to2610-kvc 加第二个核、它的 CLINT 与核间那一页），
# 套上 patch/smp.patch（核的编号、原子指令的三个状态引出来、第二个核从 SDRAM 起），仲裁换成本仓 hwsrc 里管预留的那一个。
# 用法：setup.sh <gf180mcu-kianv-rv32ima-sv32 仓> <to2610-amp 仓>
set -euo pipefail
cd "$(dirname "$0")/.."
K=$(realpath "$1")
M=$(realpath "$2")
rm -rf build/src
mkdir -p build
bash "$M/htest/setup.sh" "$K" > /dev/null
cp -r "$M/build/src" build/src
patch -s -p1 -d build < patch/smp.patch
rm build/src/amp_arb.v
cp hwsrc/*.v build/src/
echo "build/src：$(find build/src -name '*.v' -o -name '*.sv' | wc -l) 个源文件"
