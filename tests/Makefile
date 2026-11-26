# Tests for the lunar Wine patches, run by ./proton-lunar.sh --test against
# the prepared wine/dlls/ntdll/unix/signal_x86_64.c. They run Wine's real
# assembly (extracted from that file) in a userspace harness, no Wine build.
#
#   make upcall WINE=<file>   SUD upcall entry points: syscall frame, every
#                             register, red zone, the dispatch-disabled retry
#   make xsave WINE=<file>    dispatcher save without xsavec64 against
#                             xsavec64, field by field, in four CPU states
#   make bench WINE=<file>    user-side cost of one syscall with and without
#                             both patches (kernel part not included)
WINE ?=
GEN = gen

all:
	@echo "make upcall|xsave|bench WINE=<patched signal_x86_64.c>"

$(GEN)/handlers.inc $(GEN)/dispatcher.inc: FORCE
	@test -n "$(WINE)" || { echo "set WINE"; exit 1; }
	@mkdir -p $(GEN)
	@python3 extract_handlers.py $(WINE) handlers > $(GEN)/handlers.inc 2>/dev/null || : > $(GEN)/handlers.inc
	@python3 extract_handlers.py $(WINE) dispatcher > $(GEN)/dispatcher.inc

upcall: $(GEN)/handlers.inc
	$(CC) -O2 -Wall -I $(GEN) test_upcall.c -o $(GEN)/test_upcall
	$(GEN)/test_upcall

xsave: $(GEN)/dispatcher.inc
	$(CC) -O2 -mno-red-zone -Wall -Wno-unused-function -I $(GEN) test_xsave.c -o $(GEN)/test_xsave
	@$(GEN)/test_xsave; r=$$?; [ $$r -eq 0 ] || [ $$r -eq 77 ]	# 77: skipped, CPU without XSAVEC

bench: $(GEN)/dispatcher.inc
	$(CC) -O2 -mno-red-zone -Wall -Wno-unused-function -I $(GEN) bench_qpc.c -o $(GEN)/bench_qpc
	$(GEN)/bench_qpc

clean:
	rm -rf $(GEN)

FORCE:
.PHONY: all upcall xsave bench clean FORCE
