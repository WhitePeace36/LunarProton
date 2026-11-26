#!/usr/bin/env bash
# threadtime.sh - user vs. system CPU time of a process's busiest threads.
#
#   sudo tools/threadtime.sh <pid | process name> [seconds] [threads]
#
# Samples /proc/<pid>/task/*/stat twice, <seconds> apart (default 30), and
# prints the <threads> busiest threads (default 5) with their user and system
# time. A name is matched with pgrep -f; of several matches the one that has
# used the most CPU so far is taken (for a game: its .exe, e.g. Discovery.exe
# for THE FINALS).
#
# With the SUD direct upcall, raw Windows syscalls no longer go through a
# SIGSYS signal frame, so the game thread's system share should drop compared
# with the same scene on stock GE-Proton. Root is only needed to read another
# user's processes.
set -euo pipefail

die() { echo "threadtime: $*" >&2; exit 1; }
[[ $# -ge 1 ]] || { sed -n '2,15s/^# \{0,1\}//p' "$0"; exit 1; }
target="$1" secs="${2:-30}" top="${3:-5}"
[[ "$secs" =~ ^[0-9]+$ && "$secs" -gt 0 ]] || die "seconds must be a positive number"
[[ "$top" =~ ^[0-9]+$ && "$top" -gt 0 ]] || die "threads must be a positive number"

# utime + stime of a process, from the fields after the last ')' of its stat
cputime() { awk '{ sub(/.*\) /, ""); split($0, f, " "); print f[12] + f[13] }' "/proc/$1/stat" 2>/dev/null || echo 0; }

if [[ "$target" =~ ^[0-9]+$ ]]; then
	pid="$target"
else
	pid="" best=-1
	for p in $(pgrep -f -- "$target" || true); do
		# not ourselves, nor the sudo/shell that started us with the name
		grep -qa threadtime "/proc/$p/cmdline" 2>/dev/null && continue
		t=$(cputime "$p")
		[[ -d "/proc/$p" ]] || continue  # already gone (e.g. pgrep's subshell)
		(( t > best )) && { best=$t; pid=$p; }
	done
	[[ -n "$pid" ]] || die "no process matches \"$target\""
fi
[[ -d "/proc/$pid" ]] || die "no process $pid"

# one line per thread: tid utime stime
snap() {
	local s
	for s in /proc/"$pid"/task/*/stat; do
		awk -v tid="$(basename "$(dirname "$s")")" \
			'{ sub(/.*\) /, ""); split($0, f, " "); print tid, f[12], f[13] }' "$s" 2>/dev/null || true
	done
}

hz=$(getconf CLK_TCK)
echo "process $pid ($(tr '\0' ' ' < "/proc/$pid/cmdline" | cut -c1-80)), ${secs} s"
a=$(snap)
sleep "$secs"
b=$(snap)

{
	printf '%s\n' "$a" | sed 's/^/A /'
	printf '%s\n' "$b" | sed 's/^/B /'
} | awk -v hz="$hz" -v secs="$secs" -v top="$top" -v pid="$pid" '
	$1 == "A" { u0[$2] = $3; s0[$2] = $4; next }
	$1 == "B" && ($2 in u0) {
		du = ($3 - u0[$2]) / hz; ds = ($4 - s0[$2]) / hz
		if (du + ds > 0) { n++; tid[n] = $2; U[n] = du; S[n] = ds }
		tu += du; ts += ds
	}
	END {
		# sort by total time, busiest first
		for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
			if (U[j] + S[j] > U[i] + S[i]) {
				t = tid[i]; tid[i] = tid[j]; tid[j] = t
				t = U[i]; U[i] = U[j]; U[j] = t
				t = S[i]; S[i] = S[j]; S[j] = t
			}
		printf "%-8s %-16s %8s %8s %7s %6s\n", "tid", "name", "user s", "sys s", "sys %", "cpu %"
		for (i = 1; i <= n && i <= top; i++) {
			name = ""; f = "/proc/" pid "/task/" tid[i] "/comm"
			if ((getline name < f) <= 0) name = "?"; close(f)
			printf "%-8s %-16s %8.2f %8.2f %6.1f%% %5.0f%%\n", tid[i], name, U[i], S[i],
				100 * S[i] / (U[i] + S[i]), 100 * (U[i] + S[i]) / secs
		}
		if (tu + ts > 0)
			printf "%-8s %-16s %8.2f %8.2f %6.1f%% %5.0f%%\n", "all", "(" n " threads)", tu, ts,
				100 * ts / (tu + ts), 100 * (tu + ts) / secs
		else
			print "no CPU time used in the interval"
	}'
