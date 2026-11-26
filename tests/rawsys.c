/* rawsys.exe - exercise Wine's Syscall User Dispatch path the way anti-cheat
 * code does: take a syscall number from an ntdll stub and execute the raw
 * `syscall` instruction from our own code (outside libc, so the kernel traps
 * it: SIGSYS on stock Wine, the direct upcall with proton-lunar).
 *   tests/run-rawsys.sh <compatibility tool directory> [more tools...]
 *   rawsys.exe <result file> [iterations]
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef LONG (WINAPI *qst_fn)(LARGE_INTEGER *);

/* rcx = arg, edx = syscall id; Win64 ABI */
extern LONG raw_syscall1(void *arg, ULONG id);
/* same, with every callee-saved GPR and xmm6-15 set to markers around the
 * syscall; returns a bit mask of registers that came back changed, bit 30 =
 * status != 0 */
extern ULONG regcheck(void *arg, ULONG id);

__asm__(
	".text\n"
	".globl raw_syscall1\n"
	"raw_syscall1:\n\t"
	"movl %edx,%eax\n\t"
	"movq %rcx,%r10\n\t"
	"syscall\n\t"
	"ret\n"

	".globl regcheck\n"
	"regcheck:\n\t"
	"pushq %rbx\n\tpushq %rbp\n\tpushq %rdi\n\tpushq %rsi\n\t"
	"pushq %r12\n\tpushq %r13\n\tpushq %r14\n\tpushq %r15\n\t"
	"subq $168,%rsp\n\t"                 /* 16-byte aligned, 10 xmm save slots */
	"movdqu %xmm6,0(%rsp)\n\tmovdqu %xmm7,16(%rsp)\n\tmovdqu %xmm8,32(%rsp)\n\t"
	"movdqu %xmm9,48(%rsp)\n\tmovdqu %xmm10,64(%rsp)\n\tmovdqu %xmm11,80(%rsp)\n\t"
	"movdqu %xmm12,96(%rsp)\n\tmovdqu %xmm13,112(%rsp)\n\tmovdqu %xmm14,128(%rsp)\n\t"
	"movdqu %xmm15,144(%rsp)\n\t"
	"movabsq $0x1111111111111111,%rbx\n\t"
	"movabsq $0x2222222222222222,%rbp\n\t"
	"movabsq $0x3333333333333333,%rdi\n\t"
	"movabsq $0x4444444444444444,%rsi\n\t"
	"movabsq $0x5555555555555555,%r12\n\t"
	"movabsq $0x6666666666666666,%r13\n\t"
	"movabsq $0x7777777777777777,%r14\n\t"
	"movabsq $0x8888888888888888,%r15\n\t"
	"movabsq $0x0606060606060606,%rax\n\tmovq %rax,%xmm6\n\tpinsrq $1,%rax,%xmm6\n\t"
	"movabsq $0x0f0f0f0f0f0f0f0f,%rax\n\tmovq %rax,%xmm15\n\tpinsrq $1,%rax,%xmm15\n\t"
	"movabsq $0x0909090909090909,%rax\n\tmovq %rax,%xmm9\n\tpinsrq $1,%rax,%xmm9\n\t"
	"movl %edx,%eax\n\t"
	"movq %rcx,%r10\n\t"
	"syscall\n\t"
	"movl %eax,%r9d\n\t"                 /* status */
	"xorl %eax,%eax\n\t"
	"movabsq $0x1111111111111111,%rcx\n\tcmpq %rcx,%rbx\n\tje 1f\n\torl $1,%eax\n1:\t"
	"movabsq $0x2222222222222222,%rcx\n\tcmpq %rcx,%rbp\n\tje 1f\n\torl $2,%eax\n1:\t"
	"movabsq $0x3333333333333333,%rcx\n\tcmpq %rcx,%rdi\n\tje 1f\n\torl $4,%eax\n1:\t"
	"movabsq $0x4444444444444444,%rcx\n\tcmpq %rcx,%rsi\n\tje 1f\n\torl $8,%eax\n1:\t"
	"movabsq $0x5555555555555555,%rcx\n\tcmpq %rcx,%r12\n\tje 1f\n\torl $16,%eax\n1:\t"
	"movabsq $0x6666666666666666,%rcx\n\tcmpq %rcx,%r13\n\tje 1f\n\torl $32,%eax\n1:\t"
	"movabsq $0x7777777777777777,%rcx\n\tcmpq %rcx,%r14\n\tje 1f\n\torl $64,%eax\n1:\t"
	"movabsq $0x8888888888888888,%rcx\n\tcmpq %rcx,%r15\n\tje 1f\n\torl $128,%eax\n1:\t"
	"movabsq $0x0606060606060606,%rcx\n\t"
	"movq %xmm6,%rdx\n\tcmpq %rcx,%rdx\n\tjne 2f\n\tpextrq $1,%xmm6,%rdx\n\tcmpq %rcx,%rdx\n\tje 1f\n2:\torl $256,%eax\n1:\t"
	"movabsq $0x0909090909090909,%rcx\n\t"
	"movq %xmm9,%rdx\n\tcmpq %rcx,%rdx\n\tjne 2f\n\tpextrq $1,%xmm9,%rdx\n\tcmpq %rcx,%rdx\n\tje 1f\n2:\torl $512,%eax\n1:\t"
	"movabsq $0x0f0f0f0f0f0f0f0f,%rcx\n\t"
	"movq %xmm15,%rdx\n\tcmpq %rcx,%rdx\n\tjne 2f\n\tpextrq $1,%xmm15,%rdx\n\tcmpq %rcx,%rdx\n\tje 1f\n2:\torl $1024,%eax\n1:\t"
	"testl %r9d,%r9d\n\tje 1f\n\torl $0x40000000,%eax\n1:\t"
	"movdqu 0(%rsp),%xmm6\n\tmovdqu 16(%rsp),%xmm7\n\tmovdqu 32(%rsp),%xmm8\n\t"
	"movdqu 48(%rsp),%xmm9\n\tmovdqu 64(%rsp),%xmm10\n\tmovdqu 80(%rsp),%xmm11\n\t"
	"movdqu 96(%rsp),%xmm12\n\tmovdqu 112(%rsp),%xmm13\n\tmovdqu 128(%rsp),%xmm14\n\t"
	"movdqu 144(%rsp),%xmm15\n\t"
	"addq $168,%rsp\n\t"
	"popq %r15\n\tpopq %r14\n\tpopq %r13\n\tpopq %r12\n\t"
	"popq %rsi\n\tpopq %rdi\n\tpopq %rbp\n\tpopq %rbx\n\t"
	"ret\n");

static double ft_s(FILETIME f) { return (((ULONGLONG)f.dwHighDateTime << 32) | f.dwLowDateTime) / 1e7; }

int main(int argc, char **argv)
{
	FILE *out = argc > 1 ? fopen(argv[1], "w") : stdout;
	long n = argc > 2 ? atol(argv[2]) : 1000000;
	HMODULE nt = GetModuleHandleA("ntdll.dll");
	qst_fn qst = (qst_fn)GetProcAddress(nt, "NtQuerySystemTime");
	const unsigned char *stub = (const unsigned char *)qst;
	LARGE_INTEGER t_nt, t_raw, f, a, b;
	FILETIME c0, e0, k0, u0, k1, u1;
	ULONG id, bad;
	LONG st_nt, st_raw;
	int fails = 0;

	if (!out) return 2;
	if (!stub || memcmp(stub, "\x4c\x8b\xd1\xb8", 4)) {
		fprintf(out, "FAIL: unexpected NtQuerySystemTime stub %02x %02x %02x %02x\n",
			stub ? stub[0] : 0, stub ? stub[1] : 0, stub ? stub[2] : 0, stub ? stub[3] : 0);
		return 1;
	}
	memcpy(&id, stub + 4, 4);
	fprintf(out, "NtQuerySystemTime syscall id 0x%lx\n", id);

	/* correctness: raw result equals the ntdll call */
	st_nt = qst(&t_nt);
	st_raw = raw_syscall1(&t_raw, id);
	fprintf(out, "ntdll: status %08lx, raw: status %08lx, delta %lld x100ns\n",
		st_nt, st_raw, t_raw.QuadPart - t_nt.QuadPart);
	if (st_nt || st_raw || t_raw.QuadPart < t_nt.QuadPart || t_raw.QuadPart - t_nt.QuadPart > 10000000) fails++;

	/* registers across a trapped syscall, repeated */
	bad = 0;
	for (int i = 0; i < 100000; i++) bad |= regcheck(&t_raw, id);
	fprintf(out, "callee-saved registers after 100000 raw syscalls: %s (mask %#lx)\n", bad ? "CHANGED" : "ok", bad);
	if (bad) fails++;

	/* cost: ntdll path (no trap) vs raw path (trapped), with thread times */
	QueryPerformanceFrequency(&f);
	QueryPerformanceCounter(&a);
	for (long i = 0; i < n; i++) qst(&t_nt);
	QueryPerformanceCounter(&b);
	fprintf(out, "ntdll call: %.0f ns/call\n", (double)(b.QuadPart - a.QuadPart) / f.QuadPart / n * 1e9);

	GetThreadTimes(GetCurrentThread(), &c0, &e0, &k0, &u0);
	QueryPerformanceCounter(&a);
	for (long i = 0; i < n; i++) raw_syscall1(&t_raw, id);
	QueryPerformanceCounter(&b);
	GetThreadTimes(GetCurrentThread(), &c0, &e0, &k1, &u1);
	double us = ft_s(u1) - ft_s(u0), ks = ft_s(k1) - ft_s(k0);
	fprintf(out, "raw syscall: %.0f ns/call, thread user %.2f s, kernel %.2f s (kernel share %.0f%%)\n",
		(double)(b.QuadPart - a.QuadPart) / f.QuadPart / n * 1e9, us, ks, us + ks > 0 ? 100 * ks / (us + ks) : 0);
	fprintf(out, "%s\n", fails ? "RESULT: FAIL" : "RESULT: ok");
	fclose(out);
	return fails;
}
