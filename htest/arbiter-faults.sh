#!/usr/bin/env bash
# 整片这一层的变异：把仲裁里的一条规矩去掉（埋错的写法取 htest/arb.sh 的那张表，不另抄一份），重出 .v，
# 两个核一起的那一段要红在对应的那一句上。脚本里的 expect 都拿掉、只留 done，让程序跑到底，看是哪几句 BAD；
# 卡住没跑到 done 的也算红，但该红的那一句得在卡住之前就红了。
# 在临时的工作区里做（别的仓软链接过来，本仓拷一份），不动真的仓。
# 用法：arbiter-faults.sh <输出目录> <gf180mcu-kianv-rv32ima-sv32 仓> <to2610-kvc 仓>      MUTS=名字,名字 只跑这几条
set -u
cd "$(dirname "$0")/.."
here=$PWD
O=$(realpath -m "$1")
K=$(realpath "$2")
L=$(realpath "$3")
rm -rf "$O"
mkdir -p "$O/ws/to2610-smp"
# 照这次息壤的搜索路径去链：流水线上各个依赖不在本仓旁边
for r in $(grep -o -- '-p [^ ]*' <<< "$XIRANG" | cut -c4-) "$here/.."; do
  for d in "$r"/*/; do
    n=$(basename "$d")
    [ "$n" = to2610-smp ] || [ -e "$O/ws/$n" ] || ln -s "$(realpath "$d")" "$O/ws/$n"
  done
done
tar cf - --exclude=build --exclude=.git . | tar xf - -C "$O/ws/to2610-smp"
RAN="${XIRANG%% -p *} -p $O/ws"
R=$O/ws/to2610-smp

make -s -C "$L/sw/boot" O="$O/boot" || exit 1
make -s -C htest/smp O="$O/smp" || exit 1
python3 "$L/sw/pack.py" "$O/boot/boot.bin" "$O/smp/smp.bin" "$O/smp.flash" > /dev/null || exit 1
echo "expect done" > "$O/script"

# 名字~该红的那一句（空格写成下划线）。表里另外几条（nofair、nocool、leak、nogo）在这段程序里看不出来，由单元测试管；
# noaddr 也是：核里的预留同样记着地址（黑盒仓的 lrsc 补丁），写错了字的 SC 在核里就判了失败，到不了仲裁
WANT='nolock~amo
noresv~lrsc
nokill~kill'

# 出 .v、编仿真器、跑两个核的那一段。回 BAD 的那几句（空格隔开），没跑到 done 的末尾加 stuck
one() {
  local C=$1 top stuck=
  rm -rf "$C" && mkdir -p "$C"
  (cd "$R" && $RAN asic to2610-smp --no-run -o "$C/asic" > "$C/asic.log" 2>&1) || { echo "出 .v 没成：$(tail -n 2 "$C/asic.log" | tr '\n' ' ')"; return 1; }
  top=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['top'])" "$C/asic/report.json")
  python3 "$L/htest/shim.py" "$C/asic/report.json" > "$C/tb.v"
  bash "$K/htest/sim.sh" "$C/sim" "$C/tb.v" "$C/asic/$top.v" > "$C/sim.log" 2>&1 || { echo "仿真器没编成"; return 1; }
  "$C/sim/Vtb" +flash="$O/smp.flash@0" +script="$O/script" +max=40000000 > "$C/smp.log" 2> "$C/smp.err" || stuck=stuck
  tr -d '\r' < "$C/smp.log" | sed -n 's/^\(.*\) BAD .*/\1/p' | tr ' ' '_' | tr '\n' ' '
  echo "$stuck"
}

got=$(one "$O/clean")
rc=$?
if [ $rc -ne 0 ] || [ -n "${got// /}" ]; then
  echo "原样没过：$got"
  exit 1
fi
echo "原样：$(tr -d '\r' < "$O/clean/smp.log" | grep -ac ' ok ') 句都是 ok"

bad=0
count=0
while IFS='~' read -r name want; do
  case ",${MUTS:-$name}," in *",$name,"*) ;; *) continue ;; esac
  count=$((count + 1))
  expr=$(grep -a "^  \"$name~" htest/arb.sh | sed 's/^  "//; s/"$//' | cut -d'~' -f2)
  [ -n "$expr" ] || { echo "$name：arb.sh 的表里没有"; bad=1; continue; }
  sed -e "$expr" hwsrc/smp_arb.v > "$R/hwsrc/smp_arb.v"
  if cmp -s hwsrc/smp_arb.v "$R/hwsrc/smp_arb.v"; then
    echo "$name 没埋上"
    bad=1
    continue
  fi
  got=$(one "$O/mut-$name")
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "$name：$got"
    bad=1
  elif grep -qw -- "$want" <<< "$got"; then
    echo "$name 红了：$got"
  else
    echo "$name 埋了错，$want 那一句没红（红的是：${got:-没有}）"
    bad=1
  fi
done <<< "$WANT"
cp hwsrc/smp_arb.v "$R/hwsrc/smp_arb.v"
[ $bad -eq 0 ] || { echo "有埋错没被抓到"; exit 1; }
echo "整片的变异：原样过，$count 处埋错都红在该红的那一句上"
