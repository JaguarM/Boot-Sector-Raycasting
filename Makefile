# ============================================================================
# Makefile for the 512-byte boot sector raycaster (NASM, play in QEMU)
# ============================================================================

ASM      = nasm
SRC      = raycaster.asm
BIN      = raycaster.bin
FLOPPY   = floppy.img
LST      = raycaster.lst

# The original (FASM syntax, but NASM assembles it to the same bytes)
ORIG_SRC = Boot-Sector-Raycasting.asm
ORIG_BIN = original.bin
ORIG_IMG = original.img

# VS Code installed as a snap hands its own GTK/GLib paths to its terminal,
# which makes QEMU's window crash. Put the original values back first.
QEMU = for v in $$(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)_VSCODE_SNAP_ORIG=.*/\1/p'); do \
	  o="$${v}_VSCODE_SNAP_ORIG"; eval "x=\$$$$o"; \
	  if [ -n "$$x" ]; then export "$$v=$$x"; else unset "$$v"; fi; done; \
	qemu-system-i386

.PHONY: all build size run-qemu run-original disasm clean

all: build size

build: $(BIN) $(FLOPPY)

$(BIN): $(SRC)
	$(ASM) -f bin $(SRC) -o $(BIN) -l $(LST)

$(FLOPPY): $(BIN)
	dd if=/dev/zero of=$(FLOPPY) bs=512 count=2880 status=none
	dd if=$(BIN) of=$(FLOPPY) conv=notrunc status=none

# Bytes in use = everything up to the label "vars" plus its 4-byte "dd 0"
size: $(BIN)
	@USED=$$(python3 -c 'import re; t=open("$(LST)").read(); print(int(re.search(r"\s([0-9A-F]{8})\s+\S+\s+vars:", t).group(1), 16) + 4)'); \
	FREE=$$((510 - USED)); \
	echo "=========================================================="; \
	echo " Boot Sector Size: 512 bytes (Signature: 0x55 0xAA)"; \
	echo " Code + Data Used: $$USED / 510 bytes ($$FREE bytes free)"; \
	echo "=========================================================="

disasm: $(BIN)
	ndisasm -b 16 -o 0x7c00 $(BIN) | less

# Play directly in QEMU
run-qemu: build
	$(QEMU) -drive format=raw,file=$(FLOPPY),if=floppy

# The original green text-mode version, for comparison
$(ORIG_IMG): $(ORIG_SRC)
	$(ASM) -f bin $(ORIG_SRC) -o $(ORIG_BIN)
	dd if=/dev/zero of=$(ORIG_IMG) bs=512 count=2880 status=none
	dd if=$(ORIG_BIN) of=$(ORIG_IMG) conv=notrunc status=none

run-original: $(ORIG_IMG)
	$(QEMU) -drive format=raw,file=$(ORIG_IMG),if=floppy

clean:
	rm -f $(BIN) $(FLOPPY) $(LST) $(ORIG_BIN) $(ORIG_IMG)
