#!/usr/bin/env bash
# Linux 在这一颗上从 Flash 起到 shell 要仿几个小时，托管机的一个作业放不下，分几棒跑（做法同 to2610-soc）。
# 整片测试把编好的仿真器放在 build/relay，两份镜像各一个子目录（Flash 镜像与脚本）：
#   linux  to2610-kvc 的单核镜像原样，第二个核不放开
#   smp    本仓 sw/linux 的两核镜像，固件放开第二个核，内核把它带起来，再跑并发那几句
# 每一棒跑满 LINUX_LEG 秒就把断点存在子目录里，下一棒接着同一份脚本往下走；走完了放一个 done，后面的棒直接收工。
# to2610-smt 的两串接力也用这一份，接力目录给它自己仓里的。
# 用法：linux-boot.sh <输出目录> <to2610-kvc 仓> <linux|smp> [接力目录，默认本仓的 build/relay]
set -euo pipefail
O=$(realpath -m "$1")
L=$(realpath "$2")
which=$3
R=$(realpath -m "${4:-$(dirname "$0")/../build/relay}")
D=$R/$which
rm -rf "$O"
mkdir -p "$O"
case "$which" in
  linux) name=linux what="to2610-kvc 的镜像原样在这一颗上从 Flash 起到 shell，跑它的那组命令：第二个 hart 没放开，起的是一份单核的 Linux" ;;
  smp) name=linux-smp what="两核的镜像在这一颗上从 Flash 起到 shell：固件放开第二个 hart，内核把它带起来；/proc/cpuinfo 里两个处理器，apptest 十项，两个忙循环各占一个，核间中断两边都有" ;;
  *) echo "第三个参数是 linux 或 smp"; exit 1 ;;
esac
if [ -f "$D/done" ]; then
  echo "前面的棒已经走完"
  python3 "$L/htest/junit.py" "$O/results.xml" "$name=0:0:$what（前面的棒走完的）"
  exit 0
fi
for f in "$R/Vtb" "$D/linux.flash" "$D/script"; do
  [ -s "$f" ] || { echo "没有 $f：先跑整片测试"; exit 1; }
done
chmod +x "$R/Vtb"
from=()
[ -s "$D/ckpt" ] && from=(+restore="$D/ckpt")
t0=$SECONDS
rc=0
"$R/Vtb" +flash="$D/linux.flash@0" +script="$D/script" +pace=600000 +max=40000000000 +beat=1000000000 \
  "${from[@]}" +stop="${LINUX_LEG:-16200}s@$D/next" > "$O/linux.log" 2> "$O/linux.err" || rc=$?
tail -n 3 "$O/linux.err"
cat "$O/linux.log" >> "$D/console.log"
if [ $rc = 0 ] && grep -q '^停在这里' "$O/linux.err"; then
  mv "$D/next" "$D/ckpt"
  mv "$D/next.tb" "$D/ckpt.tb"
  echo "这一棒跑满了时限，断点交给下一棒"
  python3 "$L/htest/junit.py" "$O/results.xml" "$name-leg=0:$((SECONDS - t0)):这一棒跑满时限，断点交给下一棒"
  exit 0
fi
[ $rc = 0 ] && touch "$D/done"
python3 "$L/htest/junit.py" "$O/results.xml" "$name=$rc:$((SECONDS - t0)):$what"
cp "$D/console.log" "$O/console.log"
exit $rc
