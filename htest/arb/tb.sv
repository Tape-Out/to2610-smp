// smp_arb 的单元测试：两个假的核、一个应答晚若干拍的假从设备。
//   轮转   换人之前至少空三拍；对面在等的时候同一边不连着用两次；没在访问时地址线是 0
//   AMO    两边各做 N 次「读、隔三拍、写回加一」，一个不丢；锁着的时候总线上不出现另一边的访问
//   LR/SC  两边各做 N 次带重试的加一，一个不丢，而且确实有过写不成的
//   定向   没预留的 SC、写错字的 SC、对面写了同一个字、对面写了别的字
//   收回   第二个核访问到一半时撤掉 b_run，b_go 等这次访问做完才落
`timescale 1ns / 1ps
module tb;
  localparam int N = 40;

  reg clk = 0, resetn = 0;
  always #5 clk = ~clk;

  reg         a_valid = 0, a_lock = 0, a_lr = 0, a_sc = 0;
  reg  [ 3:0] a_wstrb = 0;
  reg  [33:0] a_addr = 0;
  reg  [31:0] a_wdata = 0;
  wire        a_ready, a_fault, a_scfail;
  reg         b_valid = 0, b_lock = 0, b_lr = 0, b_sc = 0;
  reg  [ 3:0] b_wstrb = 0;
  reg  [33:0] b_addr = 0;
  reg  [31:0] b_wdata = 0;
  wire        b_ready, b_fault, b_scfail;
  reg         b_run = 0;
  wire        b_go;

  wire        valid, instr;
  wire [ 3:0] wstrb;
  wire [33:0] addr;
  wire [31:0] wdata;
  reg         ready = 0;

  // 总线上的 instr 这一位在这里当「是谁」用：第一个核给 0，第二个核给 1
  smp_arb dut (
      .clk     (clk),
      .resetn  (resetn),
      .a_valid (a_valid),
      .a_wstrb (a_wstrb),
      .a_addr  (a_addr),
      .a_wdata (a_wdata),
      .a_instr (1'b0),
      .a_lock  (a_lock),
      .a_lr    (a_lr),
      .a_sc    (a_sc),
      .a_ready (a_ready),
      .a_fault (a_fault),
      .a_scfail(a_scfail),
      .b_valid (b_valid),
      .b_wstrb (b_wstrb),
      .b_addr  (b_addr),
      .b_wdata (b_wdata),
      .b_instr (1'b1),
      .b_lock  (b_lock),
      .b_lr    (b_lr),
      .b_sc    (b_sc),
      .b_ready (b_ready),
      .b_fault (b_fault),
      .b_scfail(b_scfail),
      .b_run   (b_run),
      .b_go    (b_go),
      .valid   (valid),
      .wstrb   (wstrb),
      .addr    (addr),
      .wdata   (wdata),
      .instr   (instr),
      .ready   (ready),
      .fault   (1'b0)
  );

  reg  [31:0] mem  [0:15];
  // 被拦下的 SC 不上总线，那一拍地址线是 0；假的核读数取自己的地址
  wire [31:0] rdata = mem[valid ? addr[5:2] : 4'd0];
  int         lat = 0, cnt = 0;
  always @(posedge clk) begin
    ready <= valid && !ready && cnt >= lat;
    cnt   <= valid && !ready ? cnt + 1 : 0;
    if (valid && ready && |wstrb) mem[addr[5:2]] <= wdata;
  end

  int errs = 0;
  task automatic check(input bit ok, input string what);
    if (!ok) begin
      errs++;
      $display("FAIL %s（%0t）", what, $time);
    end
  endtask

  // 监视：换人前的空拍、锁着的时候不换人、对面在等的时候不连着用
  reg valid_q = 0, last = 0, lk = 0, lk_b = 0, prev_b = 0, waited = 0;
  int since = 100;
  always @(posedge clk) begin
    valid_q <= valid;
    if (valid && ready) begin
      if ($test$plusargs("trace"))
        $display("%0t %s w%0d %s %0h/%0h lock %b%b", $time, instr ? "b" : "a", addr[5:2], |wstrb ? "wr" : "rd", wdata, rdata, a_lock, b_lock);
      since <= 0;
      last  <= instr;
      check(!(lk && instr != lk_b), "锁着的时候总线上出现了另一边的访问");
      if ((instr ? b_lock : a_lock) && wstrb == 4'h0) begin
        lk   <= 1'b1;
        lk_b <= instr;
      end else if (lk && instr == lk_b && |wstrb) lk <= 1'b0;
    end else since <= since + 1;
    if (valid && !valid_q && instr != last) check(since >= 3, "换人之前没空够三拍");
    if (resetn && !valid) check(addr == 0 && wstrb == 0 && !instr, "没在访问，总线上却有地址或写选通");
    // 轮转看核这一侧：被拦下的 SC 不上总线，也算轮到过一次
    if (a_valid && a_ready || b_valid && b_ready) begin
      check(!(b_ready == prev_b && waited && !(lk && lk_b == b_ready)), "对面在等，同一边又用了一次");
      prev_b <= b_ready;
      waited <= b_ready ? a_valid : b_valid;
    end
  end

  `define MASTER(p) \
    task automatic p``_x(input [31:0] w, input [3:0] ws, input [31:0] wd, input lr, input sc, \
                          output [31:0] rd, output fail); \
      p``_addr <= {w, 2'b00}; p``_wstrb <= ws; p``_wdata <= wd; p``_lr <= lr; p``_sc <= sc; p``_valid <= 1'b1; \
      if (p``_amo_on) p``_lock <= 1'b1; \
      @(posedge clk); \
      forever begin \
        @(posedge clk); \
        if (p``_ready) begin rd = rdata; fail = p``_scfail; break; end \
      end \
      p``_valid <= 1'b0; p``_lr <= 1'b0; p``_sc <= 1'b0; \
      if (|ws) p``_lock <= 1'b0; \
      p``_wstrb <= 4'h0; \
      @(posedge clk); \
    endtask \
    task automatic p``_amo(input [31:0] w); \
      reg [31:0] v, d; reg f; \
      p``_amo_on = 1'b1; \
      p``_x(w, 4'h0, 0, 0, 0, v, f); \
      repeat (3) @(posedge clk); \
      p``_x(w, 4'hf, v + 1, 0, 0, d, f); \
      p``_amo_on = 1'b0; \
    endtask \
    task automatic p``_inc(input [31:0] w, input int gap, inout int fails); \
      reg [31:0] v, d; reg f; \
      forever begin \
        p``_x(w, 4'h0, 0, 1, 0, v, f); \
        repeat (gap) @(posedge clk); \
        p``_x(w, 4'hf, v + 1, 0, 1, d, f); \
        if (!f) break; \
        fails++; \
      end \
    endtask

  // 核里的锁跟着状态走：读举手的那一拍起，写做完的那一拍落
  bit a_amo_on = 0, b_amo_on = 0;
  `MASTER(a)
  `MASTER(b)

  // 两个假的核各占一个进程，由 phase 对拍：1 是 AMO，2 是 LR 与 SC，3 是收回时第二个核手上的那次访问
  int        phase = 0, fa = 0, fb = 0;
  bit [3:1]  a_done = 0, b_done = 0;
  reg [31:0] v, d, bd;
  reg        f, g, bf;

  initial begin
    while (phase != 1) @(posedge clk);
    for (int i = 0; i < N; i++) begin
      a_amo(3);
      repeat (i % 3) @(posedge clk);
    end
    a_done[1] = 1;
    while (phase != 2) @(posedge clk);
    for (int i = 0; i < N; i++) a_inc(5, 1 + i % 3, fa);
    a_done[2] = 1;
  end

  initial begin
    while (phase != 1) @(posedge clk);
    for (int i = 0; i < N; i++) begin
      b_amo(3);
      repeat (i % 2) @(posedge clk);
    end
    b_done[1] = 1;
    while (phase != 2) @(posedge clk);
    for (int i = 0; i < N; i++) b_inc(5, 1 + i % 2, fb);
    b_done[2] = 1;
    while (phase != 3) @(posedge clk);
    b_x(8, 4'hf, 32'h11, 0, 0, bd, bf);
    b_done[3] = 1;
  end

  initial begin
    for (int i = 0; i < 16; i++) mem[i] = 0;
    repeat (4) @(posedge clk);
    resetn <= 1'b1;
    repeat (2) @(posedge clk);

    // AMO：两边抢同一个字
    phase = 1;
    while (!(a_done[1] && b_done[1])) @(posedge clk);
    check(mem[3] == 2 * N, $sformatf("AMO 加出来是 %0d，该是 %0d", mem[3], 2 * N));

    // LR 与 SC：两边抢同一个字
    phase = 2;
    while (!(a_done[2] && b_done[2])) @(posedge clk);
    check(mem[5] == 2 * N, $sformatf("LR/SC 加出来是 %0d，该是 %0d", mem[5], 2 * N));
    check(fa + fb > 0, "LR/SC 一次都没有写不成过，两边没抢起来");

    // 定向
    a_x(6, 4'hf, 9, 0, 1, d, f);
    check(f && mem[6] == 0, "没预留的 SC 写成了");
    a_x(6, 4'h0, 0, 1, 0, v, f);
    a_x(7, 4'hf, 9, 0, 1, d, f);
    a_x(6, 4'hf, 8, 0, 1, d, g);
    check(f && g && mem[7] == 0 && mem[6] == 0, "写错字的 SC 写成了，或者预留没被它用掉");
    a_x(6, 4'h0, 0, 1, 0, v, f);
    b_x(6, 4'hf, 32'h77, 0, 0, d, f);
    a_x(6, 4'hf, v + 1, 0, 1, d, f);
    check(f && mem[6] == 32'h77, "对面写了预留的那个字，SC 还是写成了");
    a_x(6, 4'h0, 0, 1, 0, v, f);
    b_x(7, 4'hf, 32'h55, 0, 0, d, f);
    a_x(6, 4'hf, v + 1, 0, 1, d, f);
    check(!f && mem[6] == 32'h78 && mem[7] == 32'h55, "对面写的是别的字，SC 却没写成");
    // 自己的 SC 写成之后，对面在同一个字上的预留作废
    b_x(6, 4'h0, 0, 1, 0, v, f);
    a_x(6, 4'h0, 0, 1, 0, d, f);
    a_x(6, 4'hf, d + 1, 0, 1, d, f);
    b_x(6, 4'hf, v + 1, 0, 1, d, g);
    check(!f && g && mem[6] == 32'h79, "一边的 SC 写成之后，另一边在同一个字上的 SC 也写成了");

    // 收回：访问到一半撤 b_run
    check(!b_go, "b_run 没给，b_go 却是高的");
    b_run <= 1'b1;
    repeat (2) @(posedge clk);
    check(b_go, "b_run 给了，b_go 没起来");
    lat = 6;
    phase = 3;
    repeat (4) @(posedge clk);
    b_run <= 1'b0;
    repeat (2) @(posedge clk);
    check(b_go && b_valid, "访问还没做完，b_go 就落了");
    while (!b_done[3]) @(posedge clk);
    repeat (3) @(posedge clk);
    check(!b_go && mem[8] == 32'h11, "访问做完之后 b_go 没落，或者那次写没落地");
    lat = 0;

    if (errs == 0) $display("arb ok：AMO %0d，LR/SC %0d，写不成 %0d 加 %0d 次", mem[3], mem[5], fa, fb);
    else $display("arb FAIL：%0d 处", errs);
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk);
    $display("arb FAIL：超时");
    $finish;
  end
endmodule
