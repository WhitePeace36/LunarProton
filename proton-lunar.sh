#!/usr/bin/env bash
# proton-lunar - build GE-Proton with the lunar Wine patches and install it.
#
#   ./proton-lunar.sh               fetch, prepare, build and install
#   ./proton-lunar.sh --build-only  fetch, prepare and build, do not install
#   ./proton-lunar.sh --prepare     only fetch and patch the sources (inspect src/)
#   ./proton-lunar.sh --install     install the last finished build
#   ./proton-lunar.sh --test        run the patch tests on the prepared sources
#   ./proton-lunar.sh --list        show the patch sets and the newest GE tags
#   ./proton-lunar.sh --uninstall   remove the installed build from Steam
#   ./proton-lunar.sh --clean       remove build/ and logs/ (--clean-all: also src/)
set -euo pipefail

_where="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$_where"
# shellcheck source=proton-lunar-config/lib.sh
source "$_where/proton-lunar-config/lib.sh"

_on_signal() {
	trap '' INT TERM HUP
	echo
	_l_warn "Interrupted. src/ may be half patched: the next run prepares it again."
	rm -f "$PL_SRC/.proton-lunar-prepared"
	exit 130
}

# -------------------------------------------------------------- fetch -------

# Revert/cherry-pick targets in GE's prep script, as "component sha", so a
# shallow clone can be given the commits it needs.
_pl_history_needs() {
	awk '/^[[:space:]]*pushd[[:space:]]/ { d = $2 }
	     /^[[:space:]]*popd/ { d = "" }
	     /git (revert|cherry-pick)/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f]{40}$/) print (d == "" ? "." : d), $i }' \
		"$PL_SRC/$GE_PREP"
}

do_fetch() {
	_l_msg "Fetching $_ge_tag"
	rm -f "$PL_SRC/.proton-lunar-prepared"
	mkdir -p "$PL_LOGS"
	local log="$PL_LOGS/fetch.log"
	: > "$log"
	if [[ -d "$PL_SRC/.git" ]]; then
		local cur
		cur=$(git -C "$PL_SRC" describe --tags --exact-match 2>/dev/null || true)
		if [[ "$cur" != "$_ge_tag" ]]; then
			_l_msg2 "Switching src/ from ${cur:-unknown} to $_ge_tag"
			rm -f "$PL_SRC/.proton-lunar-prepared"
			git -C "$PL_SRC" fetch --depth 1 origin "refs/tags/$_ge_tag:refs/tags/$_ge_tag" >>"$log" 2>&1 \
				|| _l_die "Could not fetch $_ge_tag (see $log)"
			git -C "$PL_SRC" checkout -q -f "refs/tags/$_ge_tag" >>"$log" 2>&1
		else
			_l_msg2 "src/ is at $_ge_tag"
		fi
	else
		_l_msg2 "Cloning $GE_URL"
		git clone --depth 1 --branch "$_ge_tag" "$GE_URL" "$PL_SRC" >>"$log" 2>&1 \
			|| _l_die "Could not clone $_ge_tag (see $log)"
	fi

	_l_msg2 "Updating submodules (several GB the first time)"
	git -C "$PL_SRC" submodule sync --recursive -q
	# a previous prepare left GE's and our patches in them
	git -C "$PL_SRC" submodule foreach --recursive -q 'git reset -q --hard && git clean -qfd' \
		>>"$log" 2>&1 || true
	if ! git -C "$PL_SRC" submodule update --init --recursive --depth 1 --jobs 8 >>"$log" 2>&1; then
		# One failed clone stops git before it checks out the others, so go
		# one by one. A server that refuses to send a single pinned commit
		# gets its full history fetched instead.
		_l_msg2 "Some submodules failed, retrying them one by one"
		local path failed=()
		while read -r path; do
			[[ "$(git -C "$PL_SRC" config --get "submodule.$path.update" || true)" == none ]] && continue
			git -C "$PL_SRC" submodule update --init --recursive --depth 1 -- "$path" >>"$log" 2>&1 && continue
			if [[ -e "$PL_SRC/$path/.git" ]]; then
				git -C "$PL_SRC/$path" fetch --unshallow --tags >>"$log" 2>&1 || true
			fi
			git -C "$PL_SRC" submodule update --init --recursive -- "$path" >>"$log" 2>&1 \
				|| failed+=("$path ($(git -C "$PL_SRC" config -f .gitmodules --get "submodule.$path.url" || echo '?'))")
		done < <(git -C "$PL_SRC" ls-files -s | awk '$1 == 160000 { print $4 }')
		(( ${#failed[@]} == 0 )) || _l_die "Could not fetch: ${failed[*]} (see $log)"
	fi
	# Top-level submodules (nested ones fail their parent's update above);
	# those set to update=none in src/.git/config are skipped on purpose.
	local st name bad=()
	while read -r st name; do
		[[ "$(git -C "$PL_SRC" config --get "submodule.$name.update" || true)" == none ]] || bad+=("$name")
	done < <(git -C "$PL_SRC" submodule status | awk '/^[-+U]/ { print substr($1, 1, 1), $2 }')
	(( ${#bad[@]} == 0 )) || _l_die "Not at their pinned commit: ${bad[*]} (see $log)"

	local comp sha
	while read -r comp sha; do
		git -C "$PL_SRC/$comp" cat-file -e "$sha^{commit}" 2>/dev/null && continue
		_l_msg2 "Fetching $comp commit ${sha:0:12} for GE's prep script"
		git -C "$PL_SRC/$comp" fetch --depth 2 origin "$sha" >>"$log" 2>&1 \
			|| _l_die "Could not fetch $sha in $comp (see $log)"
	done < <(_pl_history_needs)
}

# ------------------------------------------------------------ prepare -------

# Patch failures as GNU patch and git print them.
_PL_FAIL_RE='Hunk #[0-9]+ FAILED|hunks? FAILED|can.t find file to patch|Reversed \(or previously applied\) patch detected|error: patch failed|patch does not apply|malformed patch|Only garbage was found|^fatal: |error: could not (revert|apply)'

do_prepare() {
	local set_dir="$1"
	_l_msg "Preparing the sources"
	rm -f "$PL_SRC/.proton-lunar-prepared"
	mkdir -p "$PL_LOGS"

	_l_msg2 "Resetting src/ to $_ge_tag"
	git -C "$PL_SRC" reset -q --hard
	git -C "$PL_SRC" clean -qfd -e /contrib/   # contrib/: GE's wine-mono download
	git -C "$PL_SRC" submodule foreach --recursive -q 'git reset -q --hard && git clean -qfd'

	_l_msg2 "Running GE's $GE_PREP (log: logs/protonprep.log)"
	(cd "$PL_SRC" && bash "./$GE_PREP") > "$PL_LOGS/protonprep.log" 2>&1 || true
	if grep -Eq "$_PL_FAIL_RE" "$PL_LOGS/protonprep.log" ||
		[[ -n "$(find "$PL_SRC" -name '*.rej' -print -quit)" ]]; then
		grep -En "$_PL_FAIL_RE" "$PL_LOGS/protonprep.log" | head -n 5 >&2 || true
		_l_die "GE's own patches failed to apply (see $PL_LOGS/protonprep.log)"
	fi

	_l_msg2 "Patch set ${set_dir##*/}"
	local toggle comp file applied=0
	while read -r toggle comp file; do
		if _l_true "${!toggle:-false}"; then
			pl_apply "$PL_SRC/$comp" "$set_dir/$file"
			_l_msg2 "  + $comp: $(basename "$file") ($toggle)"
			applied=$((applied + 1))
		else
			_l_msg2 "  - $comp: $(basename "$file") ($toggle=false)"
		fi
	done < <(pl_series "$set_dir")

	if _l_true "$_user_patches" && [[ -d "$PL_USERPATCHES" ]]; then
		local d p target
		for d in "$PL_USERPATCHES"/*/; do
			[[ -d "$d" ]] || continue
			comp="$(basename "$d")"
			target="$PL_SRC/$comp"
			[[ "$comp" == top ]] && target="$PL_SRC"
			for p in "$d"*.patch; do
				[[ -f "$p" ]] || continue
				pl_apply "$target" "$p"
				_l_msg2 "  + $comp: $(basename "$p") (user patch)"
			done
		done
	fi

	if [[ -n "$_march" ]]; then
		local mk="$PL_SRC/Makefile.in"
		grep -Eq '^(i386|x86_64)_CFLAGS.*-march=nocona -mtune=core-avx2' "$mk" \
			|| _l_die "_march: GE's Makefile.in no longer has the expected -march flags"
		sed -i -E "/^(i386|x86_64)_CFLAGS/ s/-march=nocona -mtune=core-avx2/-march=$_march -mtune=$_march/" "$mk"
		_l_msg2 "  Compiling for -march=$_march"
	fi

	pl_fingerprint "$set_dir" > "$PL_SRC/.proton-lunar-prepared"
	_l_msg2 "Prepared ($applied lunar patches)"
}

# -------------------------------------------------------------- build -------

do_build() {
	local engine="$1"
	_l_msg "Building $PL_BUILD_NAME with $engine (log: logs/build.log)"
	mkdir -p "$PL_BUILD" "$PL_LOGS"
	# make redist moves its output to <name>/; a leftover would swallow it.
	rm -rf "${PL_BUILD:?}/$PL_BUILD_NAME" "$PL_BUILD/redist" \
		"$PL_BUILD/$PL_BUILD_NAME.tar.gz" "$PL_BUILD/$PL_BUILD_NAME.sha512sum"
	(cd "$PL_BUILD" && "$PL_SRC/configure.sh" --build-name="$PL_BUILD_NAME" \
		--container-engine="$engine") > "$PL_LOGS/configure.log" 2>&1 \
		|| {
			tail -n 20 "$PL_LOGS/configure.log" >&2
			if grep -q "unable to run the container" "$PL_LOGS/configure.log"; then
				[[ "$engine" == docker ]] && _l_warn "Is the docker service running and are you in the docker group? (sudo systemctl start docker; sudo usermod -aG docker \$USER)"
				_l_warn "Rootless podman needs no service: sudo pacman -S podman, then _container_engine=\"podman\""
			fi
			_l_die "configure.sh failed (see $PL_LOGS/configure.log)"
		}

	local args=(-j"$PL_JOBS" redist)
	_l_true "$_ccache" || args=(ENABLE_CCACHE=0 "${args[@]}")
	local start=$SECONDS
	if ! (cd "$PL_BUILD" && make "${args[@]}") 2>&1 | tee "$PL_LOGS/build.log"; then
		_l_die "Build failed (see $PL_LOGS/build.log)"
	fi
	[[ -f "$PL_BUILD/$PL_BUILD_NAME.tar.gz" ]] || _l_die "make finished but $PL_BUILD_NAME.tar.gz is missing"
	_l_msg2 "Built $PL_BUILD/$PL_BUILD_NAME.tar.gz in $(( (SECONDS - start) / 60 )) min"
}

# ------------------------------------------------------------ install -------

_pl_py_str() {
	local s="${1//\\/\\\\}"
	s="${s//\"/\\\"}"
	printf '"%s"' "$s"
}

do_install() {
	local tarball="$PL_BUILD/$PL_BUILD_NAME.tar.gz" inst
	[[ -f "$tarball" ]] || _l_die "$tarball not found; build first"
	inst="$(pl_install_dir)"
	_l_msg "Installing $PL_BUILD_NAME into $inst"
	[[ "$(tar -tzf "$tarball" | head -n1)" == "$PL_BUILD_NAME/"* ]] \
		|| _l_die "$tarball does not contain $PL_BUILD_NAME/"
	mkdir -p "$inst"
	local tmp="$inst/.$PL_BUILD_NAME.proton-lunar"
	rm -rf "$tmp"
	mkdir -p "$tmp"
	tar -xzf "$tarball" -C "$tmp"

	if (( ${#_user_settings[@]} )); then
		local kv f="$tmp/$PL_BUILD_NAME/user_settings.py"
		{
			echo "# Written by proton-lunar from _user_settings. Launch options still win."
			echo "user_settings = {"
			for kv in "${_user_settings[@]}"; do
				echo "    $(_pl_py_str "${kv%%=*}"): $(_pl_py_str "${kv#*=}"),"
			done
			echo "}"
		} > "$f"
		_l_msg2 "Default settings: ${_user_settings[*]}"
	fi

	rm -rf "${inst:?}/$PL_BUILD_NAME"
	mv "$tmp/$PL_BUILD_NAME" "$inst/$PL_BUILD_NAME"
	rmdir "$tmp"
	_l_true "$_keep_tarball" || rm -f "$tarball" "$PL_BUILD/$PL_BUILD_NAME.sha512sum"
	_l_msg2 "Installed. Restart Steam, then pick \"$PL_BUILD_NAME\" under"
	_l_msg2 "Properties > Compatibility > Force the use of a specific Steam Play compatibility tool"
	if pgrep -x steam >/dev/null 2>&1; then
		_l_warn "Steam is running: it lists new compatibility tools only after a restart"
	fi
}

do_uninstall() {
	local inst
	inst="$(pl_install_dir)"
	[[ -d "$inst/$PL_BUILD_NAME" ]] || _l_die "$PL_BUILD_NAME is not installed in $inst"
	rm -rf "${inst:?}/$PL_BUILD_NAME"
	_l_msg "Removed $inst/$PL_BUILD_NAME"
}

# --------------------------------------------------------- test, list -------

do_test() {
	local f="$PL_SRC/wine/dlls/ntdll/unix/signal_x86_64.c" targets=()
	[[ -f "$PL_SRC/.proton-lunar-prepared" ]] || _l_die "Prepare the sources first (./proton-lunar.sh --prepare)"
	command -v gcc >/dev/null || _l_die "The tests need gcc"
	grep -q '__wine_syscall_dispatcher_upcall_push' "$f" && targets+=(upcall)
	grep -q 'xinuse_fast_save' "$f" && targets+=(xsave)
	(( ${#targets[@]} )) || _l_die "No lunar Wine patch is applied, nothing to test"
	_l_msg "Testing the patched Wine dispatcher (${targets[*]})"
	make -s -C "$_where/tests" "${targets[@]}" WINE="$f"
	make -s -C "$_where/tests" clean
}

do_list() {
	local d toggle comp file
	_l_msg "Patch sets in patches/"
	for d in $(find "$PL_PATCHES" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V); do
		_l_msg2 "$d$([[ "$d" == "$_ge_tag" ]] && echo "  (selected)")"
		while read -r toggle comp file; do
			printf '       %-6s %-5s %s\n' "${!toggle:-?}" "$comp" "$(basename "$file")"
		done < <(pl_series "$PL_PATCHES/$d")
	done
	_l_msg "Newest GE-Proton releases"
	git ls-remote --tags --refs "$GE_URL" 'GE-Proton*' 2>/dev/null |
		sed 's#.*refs/tags/##' | sort -V | tail -n 5 | sed 's/^/  /' \
		|| _l_warn "Could not reach $GE_URL"
}

do_clean() {
	rm -rf "${PL_BUILD:?}" "${PL_LOGS:?}"
	_l_msg "Removed build/ and logs/"
	if [[ "${1:-}" == all ]]; then
		rm -rf "${PL_SRC:?}"
		_l_msg "Removed src/"
	fi
}

# --------------------------------------------------------------- main -------

main() {
	local mode="all"
	case "${1:-}" in
		"") ;;
		--build-only) mode=build ;;
		--prepare) mode=prepare ;;
		--install) mode=install ;;
		--test) mode=test ;;
		--list) mode=list ;;
		--uninstall) mode=uninstall ;;
		--clean) mode=clean ;;
		--clean-all) mode=clean-all ;;
		-h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
		*) _l_die "Unknown option $1 (see --help)" ;;
	esac
	# Steam's folders and rootless containers belong to your user.
	(( EUID != 0 )) || [[ "${PROTON_LUNAR_ALLOW_ROOT:-}" == 1 ]] \
		|| _l_die "Do not run proton-lunar as root (PROTON_LUNAR_ALLOW_ROOT=1 for containers/CI)"

	pl_load_options "$_where"
	pl_validate_options "$_where"
	trap '_on_signal' INT TERM HUP

	case "$mode" in
		list) do_list; return ;;
		clean) do_clean; return ;;
		clean-all) do_clean all; return ;;
		install) do_install; return ;;
		uninstall) do_uninstall; return ;;
		test) do_test; return ;;
	esac

	pl_check_tools "$mode"
	local set_dir engine=""
	[[ "$mode" == prepare ]] || engine="$(pl_container_engine)"
	[[ "$mode" == prepare ]] || pl_check_space "$PL_BUILD" 25
	pl_check_space "$PL_SRC" 15

	set_dir="$(pl_patch_set_dir)"
	if [[ -f "$PL_SRC/.proton-lunar-prepared" &&
		"$(git -C "$PL_SRC" describe --tags --exact-match 2>/dev/null)" == "$_ge_tag" &&
		"$(cat "$PL_SRC/.proton-lunar-prepared")" == "$(pl_fingerprint "$set_dir")" ]]; then
		_l_msg "Sources already prepared for this configuration"
	else
		do_fetch
		do_prepare "$set_dir"
	fi
	[[ "$mode" == prepare ]] && { _l_msg "Sources are ready in $PL_SRC"; return; }

	do_build "$engine"
	[[ "$mode" == all ]] && _l_true "$_install" && do_install
	_l_msg "Done"
}

main "$@"
