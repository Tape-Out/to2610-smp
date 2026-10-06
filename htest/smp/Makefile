O ?= build
CROSS ?= riscv64-unknown-elf-

$(O)/smp.bin: start.S smp.c link.ld
	mkdir -p $(O)
	$(CROSS)gcc -march=rv32ima_zicsr -mabi=ilp32 -Os -mno-relax -ffreestanding -nostdlib -Wl,-T,link.ld -o $(O)/smp.elf start.S smp.c
	$(CROSS)objcopy -O binary $(O)/smp.elf $@
