/* 两个核跑同一份程序，由引导程序搬进 SDRAM。第一个核报数，第二个核听它的口令干活。
 *   一个核时 SC 的三条规矩：有预留才写得成、没预留写不成、预留的不是这个字也写不成
 *   两个核各加 N 次同一个数，四种加法：
 *     直接读了加一再写   必须丢数，丢了才说明两个核真的在抢；不丢的话后面三项什么也证明不了
 *     amoadd             一个不丢
 *     amoswap 做的自旋锁 一个不丢，而且确实等过锁
 *     LR 与 SC           一个不丢，而且确实有过写不成重来的
 *   两个核跑的是同一段循环，步子一样就会一直错开、谁也碰不上谁，所以每圈垫几条指令，两个核垫的不一样
 *   预留跨核作废：第一个核 LR 之后第二个核写了同一个字，SC 写不成；写的是别的字，SC 照样写成
 *   核间中断两个方向各一次，第二个核自己的计时器中断一次
 *   收回第二个核它就停，再放开它从头来
 */
#include <stdint.h>

#define REG(a) (*(volatile uint32_t *)(a))
#define LSR (*(volatile uint8_t *)0x10000005)
#define CSR_R(n) ({ uint32_t v_; __asm__ volatile("csrr %0, " #n : "=r"(v_)); v_; })
#define CSR_W(n, v) __asm__ volatile("csrw " #n ", %0" : : "r"((uint32_t)(v)))
#define CSR_S(n, v) __asm__ volatile("csrs " #n ", %0" : : "r"((uint32_t)(v)))

#define CTL 0x40040000u
#define RUN (CTL + 0x04)
#define CLINT_A 0x02000000u
#define CLINT_B 0x03000000u
#define MSIP 0x0000
#define MTIMECMP 0x4000
#define MTIME 0xbff8

#define N 200

enum { PLAIN = 1, AMO, SPIN, LRSC, POKE_CELL, POKE_OTHER, IPI, TICK };

static volatile uint32_t cmd, ack, hart_b, beat, oops_b;
static volatile uint32_t plain, added, lock, locked, cond;
static volatile uint32_t retry[2], waits[2], soft[2], tick_b;
static volatile uint32_t cell, other;
static uint32_t seq;

static void putch(char c) {
  while (!(LSR & 0x60)) {}
  REG(0x10000000) = c;
}

static void say(const char *s) {
  while (*s) putch(*s++);
}

static void hex(uint32_t v) {
  for (int i = 28; i >= 0; i -= 4) putch("0123456789abcdef"[v >> i & 15]);
}

static void verdict(const char *what, uint32_t bad, uint32_t detail) {
  say(what);
  say(bad ? " BAD " : " ok ");
  hex(detail);
  if (bad && oops_b) {
    say(" hart b trap ");
    hex(oops_b);
  }
  putch('\n');
}

static inline uint32_t amoswap(volatile uint32_t *p, uint32_t v) {
  uint32_t r;
  __asm__ volatile("amoswap.w %0, %1, (%2)" : "=&r"(r) : "r"(v), "r"(p) : "memory");
  return r;
}

static inline void amoadd(volatile uint32_t *p, uint32_t v) {
  uint32_t r;
  __asm__ volatile("amoadd.w %0, %1, (%2)" : "=&r"(r) : "r"(v), "r"(p) : "memory");
}

static inline uint32_t lr(volatile uint32_t *p) {
  uint32_t r;
  __asm__ volatile("lr.w %0, (%1)" : "=&r"(r) : "r"(p) : "memory");
  return r;
}

/* 回 0 是写成了 */
static inline uint32_t sc(volatile uint32_t *p, uint32_t v) {
  uint32_t r;
  __asm__ volatile("sc.w %0, %1, (%2)" : "=&r"(r) : "r"(v), "r"(p) : "memory");
  return r;
}

static void work(uint32_t what, uint32_t me) {
  for (uint32_t i = 0; i < N; i++) {
    for (volatile uint32_t d = 0; d < ((me ? i >> 1 : i) & 3); d++) {}
    switch (what) {
      case PLAIN: {
        uint32_t t = plain;
        for (volatile uint32_t d = 0; d < (i & 1); d++) {}
        plain = t + 1;
        break;
      }
      case AMO:
        amoadd(&added, 1);
        break;
      case SPIN: {
        while (amoswap(&lock, 1)) waits[me]++;
        uint32_t t = locked;
        /* 读与写之间隔开几条指令，锁不住的话这里一定丢数 */
        for (volatile uint32_t d = 0; d < 2; d++) {}
        locked = t + 1;
        lock = 0;
        break;
      }
      case LRSC:
        for (;;) {
          uint32_t v = lr(&cond);
          if (!sc(&cond, v + 1)) break;
          retry[me]++;
        }
        break;
    }
  }
}

__attribute__((interrupt("machine"), aligned(4))) static void trap_a(void) {
  uint32_t c = CSR_R(mcause);
  if (c == 0x80000003) {
    REG(CLINT_A + MSIP) = 0;
    soft[0]++;
  } else {
    say("trap ");
    hex(c);
    putch(' ');
    hex(CSR_R(mepc));
    putch('\n');
    for (;;) {}
  }
}

__attribute__((interrupt("machine"), aligned(4))) static void trap_b(void) {
  uint32_t c = CSR_R(mcause);
  if (c == 0x80000003) {
    REG(CLINT_B + MSIP) = 0;
    soft[1]++;
  } else if (c == 0x80000007) {
    REG(CLINT_B + MTIMECMP + 4) = 0xffffffff;
    tick_b++;
  } else {
    /* 串口归第一个核：这里只留下原因，由它报 */
    oops_b = c;
    for (;;) {}
  }
}

void main_b(void) {
  CSR_W(mtvec, (uint32_t)trap_b);
  REG(CLINT_B + MTIMECMP + 4) = 0xffffffff;
  CSR_S(mie, 1 << 3 | 1 << 7);
  CSR_S(mstatus, 1 << 3);
  /* 再放开时上一条口令已经办过了 */
  uint32_t seen = cmd;
  hart_b = 0x100 | CSR_R(mhartid);
  for (;;) {
    beat++;
    uint32_t c = cmd;
    if (c == seen) continue;
    seen = c;
    switch (c & 0xff) {
      case POKE_CELL:
        cell = 0x77;
        break;
      case POKE_OTHER:
        other = 0x55;
        break;
      case IPI:
        REG(CLINT_A + MSIP) = 1;
        break;
      case TICK:
        REG(CLINT_B + MTIMECMP) = REG(CLINT_B + MTIME) + 200;
        REG(CLINT_B + MTIMECMP + 4) = REG(CLINT_B + MTIME + 4);
        break;
      default:
        work(c & 0xff, 1);
    }
    ack = c;
  }
}

/* 等一个条件，最多 ms 毫秒（mtime 每微秒走一格）；回 1 是没等到 */
#define UNTIL(cond, ms) ({ uint32_t t0_ = REG(CLINT_A + MTIME); \
                          while (!(cond) && REG(CLINT_A + MTIME) - t0_ < (ms) * 1000u) {} \
                          !(cond); })

/* 只让第二个核干 */
static uint32_t ask(uint32_t what) {
  uint32_t c = ++seq << 8 | what;
  cmd = c;
  return UNTIL(ack == c, 100);
}

/* 两个核一起干 */
static uint32_t both(uint32_t what) {
  uint32_t c = ++seq << 8 | what;
  cmd = c;
  work(what, 0);
  return UNTIL(ack == c, 300);
}

int main(void) {
  /* 主频寄存器是 8.8 定点的兆赫 */
  uint32_t hz = (REG(0x10000014) & 0xffff) * 15625 / 4;
  REG(0x1000000c) = hz / 115200;
  say("to2610 smp\n");
  CSR_W(mtvec, (uint32_t)trap_a);
  CSR_S(mie, 1 << 3);
  CSR_S(mstatus, 1 << 3);

  verdict("ident", REG(CTL) != 0x534d5031 || REG(RUN) != 0, REG(CTL));
  verdict("hart", CSR_R(mhartid) != 0, CSR_R(mhartid));

  cell = 5;
  other = 3;
  uint32_t v = lr(&cell);
  uint32_t f = sc(&cell, v + 1);
  verdict("sc same", f != 0 || cell != 6, cell);
  f = sc(&cell, 9);
  verdict("sc alone", f == 0 || cell != 6, cell);
  lr(&cell);
  f = sc(&other, 7);
  /* 写错了字的那一次也把预留用掉了 */
  uint32_t g = sc(&cell, 8);
  verdict("sc other", f == 0 || g == 0 || other != 3 || cell != 6, other << 16 | cell);

  REG(RUN) = 1;
  uint32_t bad = UNTIL(hart_b != 0, 100);
  verdict("hart b", bad || hart_b != 0x101, hart_b);

  bad = both(PLAIN);
  say("plain ");
  hex(plain);
  putch('\n');
  verdict("race", bad || plain >= 2 * N, bad);
  bad = both(AMO);
  verdict("amo", bad || added != 2 * N, added);
  bad = both(SPIN);
  say("waits ");
  hex(waits[0]);
  putch(' ');
  hex(waits[1]);
  putch('\n');
  verdict("spin", bad || locked != 2 * N || lock != 0 || waits[0] + waits[1] == 0, locked);
  bad = both(LRSC);
  say("retry ");
  hex(retry[0]);
  putch(' ');
  hex(retry[1]);
  putch('\n');
  verdict("lrsc", bad || cond != 2 * N || retry[0] + retry[1] == 0, cond);

  cell = 5;
  v = lr(&cell);
  bad = ask(POKE_CELL);
  f = sc(&cell, v + 1);
  verdict("kill", bad || f == 0 || cell != 0x77, cell);
  v = lr(&cell);
  bad = ask(POKE_OTHER);
  f = sc(&cell, v + 1);
  verdict("keep", bad || f != 0 || cell != 0x78 || other != 0x55, cell);

  bad = ask(IPI) | UNTIL(soft[0] == 1, 100);
  REG(CLINT_B + MSIP) = 1;
  bad |= UNTIL(soft[1] == 1, 100);
  verdict("ipi", bad || REG(CLINT_A + MSIP) != 0 || REG(CLINT_B + MSIP) != 0, soft[1] << 16 | soft[0]);
  bad = ask(TICK) | UNTIL(tick_b == 1, 100);
  verdict("tick", bad, tick_b);

  REG(RUN) = 0;
  for (volatile uint32_t i = 0; i < 200; i++) {}
  uint32_t b0 = beat;
  for (volatile uint32_t i = 0; i < 2000; i++) {}
  verdict("stop", beat != b0 || REG(RUN) != 0, REG(RUN));
  hart_b = 0;
  REG(RUN) = 1;
  bad = UNTIL(hart_b != 0, 100) | ask(POKE_OTHER);
  verdict("again", bad || hart_b != 0x101, hart_b);
  say("done\n");
  for (;;) {}
}
