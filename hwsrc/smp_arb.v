// 两个核共用 KianV 的片上总线。轮转与 to2610-amp 的那一个相同：一次访问从举手到应答做完才换人，换人之前空三拍；
// 对面在等的时候刚用完的那个核不能接着再用，除非它正锁着总线。
// 另外管原子指令的三件事，都以核引出来的状态为准：
//   AMO  读与写之间不换人。占着总线的核在 AMO 里时，另一个核等它写完
//   LR   记下这个核读的那个字。另一个核写了同一个字，预留作废
//   SC   轮到它写时预留已经作废、或写的不是预留的那个字，这一笔不上总线，回给核「没写成」
// 核里的预留记着地址，但只看得见自己的读写，单核够用。两个核时成败在总线这一处裁决，核里的预留只管试不试。
//
// 收回第二个核要等它手上那一次访问做完：访问到一半撤掉请求，SDRAM 那头还会把它做完，应答就落到下一次访问头上。
//
// 没在访问的时候地址、写选通、指令标记都给 0，与单个核空闲时一样。SoC 里外设区的应答是照「上一拍的地址
// 在不在外设区」预先算的：排队的那个核要是把地址漏到总线上，轮到它时第一拍就被当成做完，读回来的是 0。
`default_nettype none
module smp_arb (
    input  wire        clk,
    input  wire        resetn,

    input  wire        a_valid,
    input  wire [ 3:0] a_wstrb,
    input  wire [33:0] a_addr,
    input  wire [31:0] a_wdata,
    input  wire        a_instr,
    input  wire        a_lock,
    input  wire        a_lr,
    input  wire        a_sc,
    output wire        a_ready,
    output wire        a_fault,
    output wire        a_scfail,

    input  wire        b_valid,
    input  wire [ 3:0] b_wstrb,
    input  wire [33:0] b_addr,
    input  wire [31:0] b_wdata,
    input  wire        b_instr,
    input  wire        b_lock,
    input  wire        b_lr,
    input  wire        b_sc,
    output wire        b_ready,
    output wire        b_fault,
    output wire        b_scfail,

    input  wire        b_run,
    output reg         b_go,

    output wire        valid,
    output wire [ 3:0] wstrb,
    output wire [33:0] addr,
    output wire [31:0] wdata,
    output wire        instr,
    input  wire        ready,
    input  wire        fault
);
  reg busy, own_b, last_b;
  reg [1:0] cool;
  reg held, held_b;
  reg rv_a, rv_b;
  reg [31:0] ra_a, ra_b;
  reg nack;

  // 被对面的锁挡着的不算在等
  wire        hold_a = held && !held_b && a_lock;
  wire        hold_b = held && held_b && b_lock;
  wire        a_want = a_valid && !hold_b;
  wire        b_want = b_valid && !hold_a;
  wire        can_a = a_want && (last_b ? cool == 2'd0 : !b_want);
  wire        can_b = b_want && (last_b ? !a_want : cool == 2'd0);
  wire        sel_b = busy ? own_b : can_b;
  wire        act = busy ? (own_b ? b_valid : a_valid) : (can_a || can_b);

  wire [ 3:0] s_wstrb = sel_b ? b_wstrb : a_wstrb;
  wire [33:0] s_addr = sel_b ? b_addr : a_addr;
  wire [31:0] word = s_addr[33:2];
  wire        wr = |s_wstrb;
  wire        s_lock = sel_b ? b_lock : a_lock;
  wire        s_lr = sel_b ? b_lr : a_lr;
  wire        s_sc = sel_b ? b_sc : a_sc;
  wire        s_rv = sel_b ? rv_b && ra_b == word : rv_a && ra_a == word;

  // SC 的那一笔写；预留不成立就不让它上总线，晚一拍回应答，与片上外设的应答同一个节拍
  wire        scw = act && s_sc && wr;
  wire        drop = scw && !s_rv;
  wire        done = act && (drop ? nack : ready || fault);
  wire        good = done && (drop || !fault);

  always @(posedge clk) begin
    if (!resetn) begin
      busy   <= 1'b0;
      own_b  <= 1'b0;
      last_b <= 1'b0;
      cool   <= 2'd0;
      held   <= 1'b0;
      held_b <= 1'b0;
      rv_a   <= 1'b0;
      rv_b   <= 1'b0;
      ra_a   <= 32'h0;
      ra_b   <= 32'h0;
      nack   <= 1'b0;
      b_go   <= 1'b0;
    end else begin
      nack <= drop && !nack;
      if (cool != 2'd0) cool <= cool - 2'd1;
      if (done || (busy && !act)) begin
        busy   <= 1'b0;
        last_b <= sel_b;
        cool   <= 2'd3;
      end else if (act) begin
        busy  <= 1'b1;
        own_b <= sel_b;
      end

      if (act && s_lock) begin
        held   <= 1'b1;
        held_b <= sel_b;
      end else if (held && !(held_b ? b_lock : a_lock)) begin
        // 写完了，或者半路进了异常
        held <= 1'b0;
      end

      if (good && s_lr && !wr) begin
        // 取页表的那几次读也会记进来，后面真正的那一次读盖掉它们
        if (sel_b) begin
          rv_b <= 1'b1;
          ra_b <= word;
        end else begin
          rv_a <= 1'b1;
          ra_a <= word;
        end
      end
      if (good && wr && !drop) begin
        if (sel_b && ra_a == word) rv_a <= 1'b0;
        if (!sel_b && ra_b == word) rv_b <= 1'b0;
      end
      if (good && scw) begin
        if (sel_b) rv_b <= 1'b0;
        else rv_a <= 1'b0;
      end

      if (b_run) b_go <= 1'b1;
      else if (!(act && sel_b)) b_go <= 1'b0;
    end
  end

  assign valid    = act && !drop;
  assign wstrb    = valid ? s_wstrb : 4'h0;
  assign addr     = valid ? s_addr : 34'h0;
  assign wdata    = sel_b ? b_wdata : a_wdata;
  assign instr    = valid && (sel_b ? b_instr : a_instr);
  assign a_ready  = act && !sel_b && (drop ? nack : ready);
  assign a_fault  = act && !sel_b && !drop && fault;
  assign a_scfail = act && !sel_b && drop && nack;
  assign b_ready  = act && sel_b && (drop ? nack : ready);
  assign b_fault  = act && sel_b && !drop && fault;
  assign b_scfail = act && sel_b && drop && nack;
endmodule
`default_nettype wire
