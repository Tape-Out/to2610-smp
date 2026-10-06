# to2610-smp

A symmetric two-core chip for the ECOS 2610 shuttle: [`to2610-amp`](https://github.com/Tape-Out/to2610-amp) with numbered harts, both cores entering the same image, and a bus arbiter that makes the atomic instructions hold across cores.

![maturity](https://img.shields.io/badge/maturity-simulated-yellow) ![license](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0%20OR%20MulanPSL--2.0-blue)

The core is upstream's KianV, its submodule untouched, taken from [`gf180mcu-kianv-rv32ima-sv32`](https://github.com/Tape-Out/gf180mcu-kianv-rv32ima-sv32); the peripherals and the pads are those of [`to2610-soc`](https://github.com/Tape-Out/to2610-soc); the second core, its CLINT and the inter-core page come from `to2610-amp`. What this repository adds:

| File | What |
|:--:|:--:|
| `patch/smp.patch` | a `HART_ID` parameter down to `mhartid`; three states of the atomics brought out of `main_fsm` and an abort brought in; the second core reset to `0x8000_0000` |
| `hwsrc/smp_arb.v` | the arbiter: round-robin, the bus lock for AMOs, the reservations for LR and SC |

The functions, the registers, the pad table, the tests and the limits are in [`docs/流片说明.md`](docs/流片说明.md); the tape-out report is generated from that file.

## What the core lacked for two harts

| In the core | With two cores | Here |
|:--:|:--:|:--:|
| `mhartid` reads 0 | both cores look the same to software | a parameter, 0 and 1 |
| an AMO is a read and a write on the bus, three cycles apart | the other core can write in between | the arbiter keeps the bus with a core from its AMO read until its AMO write |
| LR sets one bit, without an address; SC looks at that bit only | a store from the other core does not clear it | the arbiter records the word each core reserved, drops the reservation when the other core writes that word, and decides the SC in the cycle it would reach the bus |

An SC whose reservation is gone, or that addresses another word, never reaches the bus; the core is told and takes its failing path. Deciding and writing are one event, so no window is left between a check inside the core and the write.

## Starting the second core

Only the first core runs after reset. Writing 1 to `RUN` at `0x4004_0004` releases the second; it starts at `0x8000_0000`, where the boot loader has put the payload, so both cores enter the same code and part ways on `mhartid`. Writing 0 takes it back, after the bus access it has in flight has completed.

Each core has its own CLINT, at `0x0200_0000` and `0x0300_0000`; an inter-processor interrupt is a write to the other core's `msip`.

## Testing and tape-out

```console
$ ran run to2610-smp src                  # assemble build/src
$ ran test to2610-smp                     # the arbiter alone, then the chip tests
$ ran asic to2610-smp                     # to2610_smp.v, ecc at 50 MHz, report.json
```

`arb` drives the arbiter with two model cores and a slow slave, then plants seven faults in it, one at a time; each must turn the test red. `chip` runs on the Verilog file that goes to the shuttle: the tests of `to2610-kvc` and `to2610-soc` unchanged, then `htest/smp`, one program on both cores. Its first shared counter is incremented without any atomics and must lose updates; the next three, with `amoadd`, a spinlock on `amoswap`, and LR/SC, must not.

## License

任选其一：

- [MIT](LICENSE-MIT)
- [Apache 2.0](LICENSE-APACHE)
- [木兰宽松许可证 第2版](LICENSE-MULAN)

`SPDX-License-Identifier: MIT OR Apache-2.0 OR MulanPSL-2.0`

The upstream sources keep their own licence: Apache-2.0.

除非另行说明，你提交的贡献按上述三者同时授权，不附加其他条件。
