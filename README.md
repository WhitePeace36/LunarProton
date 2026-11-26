# proton-lunar

[GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) with the
[linux-lunar](https://github.com/WhitePeace36/linux-lunar) Wine patches on top,
built and installed into Steam with one command. Each patch can be switched on
or off in `customization.cfg`, the same way linux-lunar's kernel patches are.

    git clone <this repo> && cd proton-lunar
    ./proton-lunar.sh

The script fetches the GE-Proton release named in `customization.cfg`, runs
GE's own patch script, applies the enabled lunar patches and your own patches,
builds with GE's build system (inside Valve's Steam Runtime SDK container) and
puts the result into Steam's `compatibilitytools.d`. Restart Steam and pick
**GE-Proton11-14-lunar** under *Properties > Compatibility*.

## The patches

| Option | What it does | Needs |
|---|---|---|
| `_patch_sud_upcall` | Games that make raw Windows syscalls (anti-cheat, e.g. THE FINALS: 100–200k per second) are caught by Syscall User Dispatch. Instead of a SIGSYS signal for each one (~0.8–0.9 µs), the kernel jumps straight to Wine's dispatcher and returns with SYSRET. | linux-lunar patch 0014 (or CachyOS/linux#15) in the running kernel. Other kernels: Wine notices and keeps using SIGSYS, so the build works everywhere. |
| `_patch_fast_xsave` | Every Windows syscall saves the vector registers. When AVX is not in use (XINUSE), Wine stores the same bytes with plain moves instead of `xsavec64` (GE dispatcher benchmark: ~103 → ~76 ns per syscall). Falls back to `xsavec64` whenever the AVX state or the x87 register stack is live. | Any kernel. `WINE_DISABLE_FAST_XSAVE=1` turns it off for one game. |
| `_patch_fix_rebuild` | Build fix for GE's Makefile: its source sync deleted the generated autotools files of sbc and xz, so every build after the first in the same `build/` failed (`build-aux/missing: No such file or directory`). No effect on the built Proton. | Nothing. |

All three are on by default. GE's game-specific syscall hacks (EOS, NASCAR 25)
take precedence over the upcall, as they did over SIGSYS.

To check that the upcall is in use, start a game with
`WINEDEBUG=+seh %command%` and look for `SUD direct-upcall mode 2 available`
in the log (1 = the CachyOS RCX variant, no line = SIGSYS).

To see the effect, compare the game thread's system time with stock GE-Proton
in the same scene: `sudo tools/threadtime.sh <game.exe> 30` prints the user
and system time of the busiest threads over 30 seconds. With the upcall the
system share of the thread making the raw syscalls should drop clearly.

## Requirements

* git, make, patch, python, perl, wget, rsync, tar, autoconf, automake
  (Arch/CachyOS: `sudo pacman -S --needed git make patch python perl wget rsync tar autoconf automake`)
* podman (recommended, rootless, no service) or docker
* about 40 GB of free space and, the first time, a few GB of downloads; the
  first build takes one to several hours, later ones much less with ccache

Do not run it as root: Steam's folders and the rootless container belong to
your user.

## Usage

    ./proton-lunar.sh               fetch, prepare, build and install
    ./proton-lunar.sh --build-only  fetch, prepare and build, do not install
    ./proton-lunar.sh --prepare     only fetch and patch the sources (inspect src/)
    ./proton-lunar.sh --install     install the last finished build
    ./proton-lunar.sh --test        run the patch tests on the prepared sources
    ./proton-lunar.sh --list        show the patch sets and the newest GE tags
    ./proton-lunar.sh --uninstall   remove the installed build from Steam
    ./proton-lunar.sh --clean       remove build/ and logs/ (--clean-all: also src/)

Sources that are already prepared for the same release, patches and options
are not fetched or patched again. Logs go to `logs/` (`fetch.log`,
`protonprep.log`, `configure.log`, `build.log`).

## Configuration

`customization.cfg` documents every option. Put your own changes into
`~/.config/proton-lunar.cfg` (same syntax) so that pulling updates never
conflicts with them, for example:

    _patch_fast_xsave="false"
    _user_settings=( "PROTON_ENABLE_WAYLAND=1" )
    _container_engine="podman"

Besides the patch toggles:

* `_ge_tag`: the GE-Proton release. `patches/<tag>/` holds the patch set
  tested against it; `_patch_set="fallback"` tries the newest older set on a
  newer release (every patch must still apply exactly, or the run stops before
  compiling).
* `_user_settings`: environment variables for every game run with this build,
  written to the build's `user_settings.py`. Launch options still win.
* `_user_patches`: your own patches from `userpatches/<component>/`, see
  [userpatches/README.md](userpatches/README.md).
* `_march`: compile for a specific CPU (`native`, `znver3`, ...) instead of
  GE's `-march=nocona -mtune=core-avx2`. Measurable gains are small for most
  games; the build then only runs on CPUs like yours and is not supported by GE.
* `_build_name`, `_jobs`, `_ccache`, `_src_dir`/`_build_dir`/`_log_dir`,
  `_install`, `_install_dir`, `_keep_tarball`.

## A new GE-Proton release

1. Set `_ge_tag` to the new tag and run `./proton-lunar.sh --prepare`.
2. If a lunar patch no longer applies, the run stops and names it. Copy
   `patches/<old tag>` to `patches/<new tag>` and refresh the patch against
   `src/wine` (or set `_patch_set="fallback"` if the old set still applies).
3. `./proton-lunar.sh --test` checks the patched dispatcher before you spend
   the time on a build.

## Tests

`tests/` extracts the patched `__wine_syscall_dispatcher` handlers from
`src/wine/dlls/ntdll/unix/signal_x86_64.c`, assembles them into a test
program and runs them against a simulated kernel upcall and against the
original `xsavec64` path, byte for byte. `make -C tests bench` times the
dispatcher with and without the patches.

## Credits

GE-Proton by GloriousEggroll and contributors, Proton by Valve, Wine by the
Wine project. The SUD upcall idea comes from CachyOS/linux#15 by FurryMileon.
