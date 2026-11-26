# shellcheck shell=bash
# proton-lunar shared functions, sourced by proton-lunar.sh.

GE_URL="https://github.com/GloriousEggroll/proton-ge-custom"
GE_PREP="patches/protonprep-valve-staging.sh"

# ---------------------------------------------------------------- messages --

_l_msg()  { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
_l_msg2() { printf '  \033[1;34m->\033[0m %s\n' "$*"; }
_l_warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
_l_die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

_l_true() { [[ "${1,,}" == "true" || "${1,,}" == "yes" || "$1" == "1" ]]; }

# ------------------------------------------------------------- the options --

# Load customization.cfg, then the personal override file.
pl_load_options() {
	local where="$1"
	_user_settings=()
	# shellcheck disable=SC1091
	source "$where/customization.cfg"
	local user_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/proton-lunar.cfg"
	if [[ -f "$user_cfg" ]]; then
		_l_msg2 "Reading overrides from $user_cfg"
		# shellcheck disable=SC1090
		source "$user_cfg"
	fi
}

_pl_bool() {
	local name="$1" val="${!1}"
	[[ "${val,,}" =~ ^(true|false|yes|no|1|0)$ ]] || _l_die "$name must be true or false (is \"$val\")"
}

# Check every option and derive the paths; die on the first invalid one.
pl_validate_options() {
	local where="$1" o kv
	[[ "$_ge_tag" =~ ^[A-Za-z0-9._-]+$ ]] || _l_die "_ge_tag \"$_ge_tag\" is not a valid tag name"
	[[ "$_patch_set" == auto || "$_patch_set" == fallback ]] \
		|| _l_die "_patch_set must be auto or fallback (is \"$_patch_set\")"
	for o in _patch_sud_upcall _patch_fast_xsave _patch_fix_rebuild _user_patches _ccache _install _keep_tarball; do
		_pl_bool "$o"
	done
	[[ -z "$_container_engine" || "$_container_engine" == podman || "$_container_engine" == docker ]] \
		|| _l_die "_container_engine must be podman, docker or empty (is \"$_container_engine\")"
	[[ -z "$_jobs" || "$_jobs" =~ ^[1-9][0-9]*$ ]] || _l_die "_jobs must be a number (is \"$_jobs\")"
	[[ "$_march" =~ ^[A-Za-z0-9._-]*$ ]] || _l_die "_march \"$_march\" is not a valid -march value"
	for kv in "${_user_settings[@]}"; do
		[[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || _l_die "_user_settings entry \"$kv\" is not NAME=value"
	done

	PL_BUILD_NAME="${_build_name:-${_ge_tag}-lunar}"
	[[ "$PL_BUILD_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || _l_die "_build_name \"$PL_BUILD_NAME\" may only contain letters, digits, . _ -"
	PL_SRC="${_src_dir:-$where/src}"
	PL_BUILD="${_build_dir:-$where/build}"
	PL_LOGS="${_log_dir:-$where/logs}"
	PL_JOBS="${_jobs:-$(nproc)}"
	PL_PATCHES="$where/patches"
	PL_USERPATCHES="$where/userpatches"
	case "$PL_BUILD/" in "$PL_SRC"/*) _l_die "_build_dir must not be inside _src_dir" ;; esac
}

# ------------------------------------------------------------ patch sets ----

# Directory of the patch set for _ge_tag, following _patch_set.
pl_patch_set_dir() {
	if [[ -d "$PL_PATCHES/$_ge_tag" ]]; then
		echo "$PL_PATCHES/$_ge_tag"
		return
	fi
	[[ "$_patch_set" == fallback ]] \
		|| _l_die "No patch set for $_ge_tag in patches/ (set _patch_set=\"fallback\" to try the newest older one)"
	local best="" d
	for d in $(find "$PL_PATCHES" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V); do
		[[ "$(printf '%s\n%s\n' "$d" "$_ge_tag" | sort -V | tail -n1)" == "$_ge_tag" ]] && best="$d"
	done
	[[ -n "$best" ]] || _l_die "No patch set older than $_ge_tag in patches/"
	_l_warn "No patch set for $_ge_tag, trying $best (patches must apply exactly)"
	echo "$PL_PATCHES/$best"
}

# Print "toggle component patchfile" for every series entry.
pl_series() {
	local dir="$1"
	[[ -f "$dir/series" ]] || _l_die "$dir/series is missing"
	grep -v '^[[:space:]]*\(#\|$\)' "$dir/series"
}

# Apply one patch to a directory, all or nothing.
pl_apply() {
	local dir="$1" patch="$2" out
	[[ -d "$dir" ]] || _l_die "$(basename "$patch"): $dir does not exist"
	if ! out=$(patch -d "$dir" -Np1 --fuzz=0 --dry-run -i "$patch" 2>&1); then
		printf '%s\n' "$out" >&2
		_l_die "$(basename "$patch") does not apply to ${dir#"$PL_SRC"/}"
	fi
	patch -d "$dir" -Np1 --fuzz=0 --no-backup-if-mismatch -s -i "$patch" \
		|| _l_die "$(basename "$patch") failed to apply"
}

# ----------------------------------------------------------- environment ----

pl_container_engine() {
	if [[ -n "$_container_engine" ]]; then
		command -v "$_container_engine" >/dev/null || _l_die "$_container_engine is not installed"
		echo "$_container_engine"
	elif command -v podman >/dev/null; then echo podman
	elif command -v docker >/dev/null; then echo docker
	else _l_die "GE-Proton builds in a container: install podman (or docker)"
	fi
}

pl_check_tools() {
	local t missing=() tools=(git make patch python3 perl wget tar autoreconf)
	[[ "$1" == prepare ]] || tools+=(rsync sha512sum)
	for t in "${tools[@]}"; do
		command -v "$t" >/dev/null || missing+=("$t")
	done
	(( ${#missing[@]} == 0 )) || _l_die "Missing tools: ${missing[*]} (Arch: sudo pacman -S --needed git make patch python perl wget rsync tar autoconf automake)"
}

# Warn when the file system holding $1 has less than $2 GB free.
pl_check_space() {
	local dir="$1" need="$2" free
	mkdir -p "$dir"
	free=$(df -Pk "$dir" | awk 'NR==2 {print int($4 / 1048576)}')
	(( free >= need )) || _l_warn "Only ${free} GB free for $dir, a full build needs about ${need} GB"
}

# Steam's compatibilitytools.d, from _install_dir or found automatically.
pl_install_dir() {
	if [[ -n "$_install_dir" ]]; then
		echo "$_install_dir"
		return
	fi
	local root
	for root in "$HOME/.steam/root" "$HOME/.local/share/Steam" \
		"$HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
		if [[ -d "$root" ]]; then
			echo "$(readlink -f "$root")/compatibilitytools.d"
			return
		fi
	done
	_l_die "Steam not found; set _install_dir to its compatibilitytools.d"
}

# A fingerprint of everything that decides what prepare produces.
pl_fingerprint() {
	local set_dir="$1"
	{
		echo "tag=$_ge_tag set=${set_dir##*/} march=$_march"
		local toggle comp file
		while read -r toggle comp file; do
			_l_true "${!toggle:-false}" && echo "$comp $(sha256sum < "$set_dir/$file")"
		done < <(pl_series "$set_dir")
		if _l_true "$_user_patches" && [[ -d "$PL_USERPATCHES" ]]; then
			find "$PL_USERPATCHES" -name '*.patch' -type f | sort | xargs -r sha256sum
		fi
		cat "$PL_PATCHES/../proton-lunar-config/lib.sh" "$PL_PATCHES/../proton-lunar.sh" | sha256sum
	} | sha256sum | cut -d' ' -f1
}
