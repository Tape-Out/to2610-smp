#!/usr/bin/env bash
# 仲裁的单元测试：hwsrc/smp_arb.v 原样跑一遍要过；再逐个埋错（八处），每个都要红。埋了错还过，就是测试没有量到那一条。
# 用法：arb.sh <输出目录> <to2610-kvc 仓>
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
L=$(realpath "$2")
rm -rf "$O"
mkdir -p "$O"

# 名字、要改掉的那一句（sed 的表达式）、它对应的规矩
muts=(
  "nolock~s/a_valid \&\& !hold_b;/a_valid;/; s/b_valid \&\& !hold_a;/b_valid;/~AMO 的读与写之间不换人"
  "nofair~s/: !b_want);/: 1'b1);/; s/: cool == 2'd0);/: cool == 2'd0) \&\& !can_a;/~对面在等的时候不连着用"
  "noresv~s/wire        drop = scw && !s_rv;/wire        drop = 1'b0;/~SC 的成败在总线上裁决"
  "nokill~s/if (sel_b && ra_a == word) rv_a <= 1'b0;//; s/if (!sel_b && ra_b == word) rv_b <= 1'b0;//~另一个核写了同一个字，预留作废"
  "noaddr~s/rv_b && ra_b == word : rv_a && ra_a == word/rv_b : rv_a/~SC 写的得是预留的那个字"
  "nocool~s/cool   <= 2'd3;/cool   <= 2'd0;/~换人之前空三拍"
  "leak~s/valid ? s_addr : 34'h0/s_addr/~没在访问时地址线是 0"
  "nogo~s/else if (!(act \&\& sel_b)) b_go <= 1'b0;/else b_go <= 1'b0;/~收回第二个核等它手上的访问做完"
)

one() {
  local name=$1 expr=$2 d="$O/$1"
  mkdir -p "$d"
  sed "$expr" hwsrc/smp_arb.v > "$d/smp_arb.v"
  if [ -n "$expr" ] && cmp -s hwsrc/smp_arb.v "$d/smp_arb.v"; then
    echo "$name：这一句没改上" > "$d/run.log"
    return 2
  fi
  verilator --binary --timing -Wno-fatal -Wno-lint --top-module tb -Mdir "$d/obj" -o sim \
    htest/arb/tb.sv "$d/smp_arb.v" > "$d/build.log" 2>&1 || { tail -n 5 "$d/build.log"; return 3; }
  "$d/obj/sim" > "$d/run.log" 2>&1 || true
  grep -q '^arb ok' "$d/run.log"
}

res=()
t0=$SECONDS
rc=0
one clean "" || rc=$?
tail -n 3 "$O/clean/run.log"
res+=("clean=$rc:$((SECONDS - t0)):仲裁原样：轮转、AMO 两边各四十次、LR 与 SC 两边各四十次、五条定向、收回")
for m in "${muts[@]}"; do
  IFS='~' read -r name expr what <<< "$m"
  t0=$SECONDS
  rc=0
  one "$name" "$expr" || rc=$?
  # 埋了错：测试红（返回 1）才算这一项过
  case $rc in
    1) v=0; echo "$name 红了：$(grep -m1 FAIL "$O/$name/run.log")" ;;
    0) v=1; echo "$name 埋了错还是过，测试没量到「$what」" ;;
    *) v=1; echo "$name 没跑成（$rc）：$(tail -n 1 "$O/$name/run.log" 2>/dev/null)" ;;
  esac
  res+=("$name=$v:$((SECONDS - t0)):埋错「$what」之后测试要红")
done

python3 "$L/htest/junit.py" "$O/results.xml" "${res[@]}"
printf '%s\n' "${res[@]}"
if grep -q '<failure' "$O/results.xml"; then echo "有用例没过"; exit 1; fi
echo "仲裁单元测试 ${#res[@]} 项全过"
