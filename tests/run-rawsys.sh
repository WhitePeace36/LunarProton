#!/usr/bin/env bash
# run-rawsys.sh - end-to-end check of the Syscall User Dispatch path.
#
#   tests/run-rawsys.sh <compatibility tool dir> [<tool dir> ...]
#   e.g. tests/run-rawsys.sh ~/.steam/root/compatibilitytools.d/GE-Proton11-14 \
#                            ~/.steam/root/compatibilitytools.d/GE-Proton11-14-lunar
#
# Builds tests/rawsys.c into a Windows program that, like anti-cheat code,
# takes NtQuerySystemTime's syscall number from ntdll and executes the raw
# syscall instruction itself, so the kernel traps every call (SIGSYS on stock
# Proton, the direct upcall with proton-lunar on a kernel with linux-lunar
# 0014). For each tool it runs the program in a fresh prefix and prints:
# whether the result matches the ntdll call, whether the callee-saved
# registers survive, the cost per raw syscall and the thread's kernel share.
#
# Needs a display (run it in your desktop session; without one Wine's
# explorer cannot start and proton run hangs) and a mingw-w64 compiler, or
# podman/docker with a Steam Runtime SDK image (the one the build pulled).
# Env: RAWSYS_ITERATIONS (default 1000000), plus anything to pass to proton,
# e.g. WINE_DISABLE_FAST_XSAVE=1.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
gen="$here/gen/rawsys"
iters="${RAWSYS_ITERATIONS:-1000000}"
die() { echo "run-rawsys: $*" >&2; exit 1; }

(( $# )) || { sed -n '2,20s/^# \{0,1\}//p' "$0"; exit 1; }
[[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || die "no DISPLAY or WAYLAND_DISPLAY: run it in your desktop session"
[[ "$iters" =~ ^[1-9][0-9]*$ ]] || die "RAWSYS_ITERATIONS must be a positive number"

client="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}"
if [[ -z "$client" ]]; then
	for d in "$HOME/.steam/root" "$HOME/.local/share/Steam"; do
		[[ -d "$d" ]] && { client="$(readlink -f "$d")"; break; }
	done
fi
[[ -n "$client" ]] || die "Steam not found; set STEAM_COMPAT_CLIENT_INSTALL_PATH"

mkdir -p "$gen"
exe="$gen/rawsys.exe"
if [[ ! -f "$exe" || "$here/rawsys.c" -nt "$exe" ]]; then
	if command -v x86_64-w64-mingw32-gcc >/dev/null; then
		x86_64-w64-mingw32-gcc -O2 -Wall -o "$exe" "$here/rawsys.c"
	else
		engine=""
		for e in podman docker; do command -v "$e" >/dev/null && { engine=$e; break; }; done
		[[ -n "$engine" ]] || die "need x86_64-w64-mingw32-gcc, or podman/docker with a Steam Runtime SDK image"
		image=$("$engine" images --format '{{.Repository}}:{{.Tag}}' | grep -m1 -E 'steamrt[0-9]*/sdk|sniper/sdk' || true)
		[[ -n "$image" ]] || die "no Steam Runtime SDK image found for $engine (build proton-lunar once, or install mingw-w64-gcc)"
		"$engine" run --rm -v "$here:$here:z" -w "$here" "$image" \
			x86_64-w64-mingw32-gcc -O2 -Wall -o "$exe" "$here/rawsys.c"
	fi
fi

winpath() { local p="${1//\//\\}"; echo "Z:$p"; }
rc=0
for tool in "$@"; do
	tool="$(readlink -f "$tool")"
	[[ -x "$tool/proton" ]] || die "$tool/proton not found"
	name="$(basename "$tool")"
	out="$gen/run-$name"
	rm -rf "$out"
	mkdir -p "$out/prefix"
	echo "== $name"
	if ! STEAM_COMPAT_DATA_PATH="$out/prefix" STEAM_COMPAT_CLIENT_INSTALL_PATH="$client" \
		SteamAppId=0 SteamGameId=0 WINEDEBUG=-all \
		timeout 300 "$tool/proton" run "$(winpath "$exe")" "$(winpath "$out/result.txt")" "$iters" \
		> "$out/stdout.txt" 2> "$out/stderr.txt"; then
		rc=1
	fi
	if [[ -f "$out/result.txt" ]]; then
		tr -d '\r' < "$out/result.txt" | sed 's/^/   /'
		grep -q 'RESULT: ok' "$out/result.txt" || rc=1
	else
		echo "   no result (see $out/stderr.txt)"
		rc=1
	fi
done
exit $rc
