#!/usr/bin/env bash
# Check the toolchain and bring the submodules up. Safe to re-run
#
#   ./setup.sh          check tools, init submodules, write the kernel config
#   ./setup.sh check    check tools only, touch nothing
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WS=$HERE/workspace

ok()   { printf '  \033[32mok\033[0m   %s\n' "$*" >&2; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

missing=0
need() { warn "$*"; missing=$((missing + 1)); }

check_tools() {
	echo "== toolchain =="
	# The LLVM names are exactly what the kernel Makefile invokes under LLVM=1;
	# note ld.lld and not lld, which is a different binary that some distros
	# ship and some do not
	for t in git make dtc python3 cpio gzip curl file zig \
	         clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump \
	         llvm-readelf llvm-strip; do
		command -v "$t" >/dev/null && ok "$t" || need "$t MISSING"
	done
	if command -v rustup >/dev/null; then
		rustup toolchain list | grep -q '1\.97\.1' \
			&& ok "rust 1.97.1" \
			|| need "rust 1.97.1 missing: rustup toolchain install 1.97.1"
		rustup target list --toolchain 1.97.1 --installed 2>/dev/null \
			| grep -q riscv32imac-unknown-none-elf \
			&& ok "riscv32imac target" \
			|| need "add it: rustup target add riscv32imac-unknown-none-elf --toolchain 1.97.1"
	else
		need "rustup MISSING"
	fi
	[ "$missing" -eq 0 ] || die "$missing tool(s) missing"
}

submodules() {
	echo "== submodules =="
	echo "  fetching (the kernel tree is large, this takes a while on first run)"
	git -C "$HERE" submodule update --init --recursive

	# xous-core's xtask stamps its build from `git describe --tags`, and GitHub
	# forks do not inherit tags from the parent repo. Without them the build
	# stops at "SemVer::from_git: no major version", which does not obviously
	# point at a missing tag. Pull them from upstream if the fork has none
	if ! git -C "$WS/xous-core" describe --tags >/dev/null 2>&1; then
		git -C "$WS/xous-core" remote get-url upstream >/dev/null 2>&1 \
			|| git -C "$WS/xous-core" remote add upstream \
				https://github.com/betrusted-io/xous-core.git
		git -C "$WS/xous-core" fetch -q --tags upstream
		ok "fetched xous-core tags from upstream"
	fi

	for m in xous-core linux; do
		[ -d "$WS/$m/.git" ] || [ -f "$WS/$m/.git" ] \
			|| die "$m did not check out -- try: git submodule update --init $WS/$m"
		ok "$m at $(git -C "$WS/$m" rev-parse --short HEAD)"
	done
}

xous_toolchain() {
	echo "== xous toolchain =="
	local sysroot
	sysroot=$(rustc +1.97.1 --print sysroot)
	if [ -d "$sysroot/lib/rustlib/riscv32imac-unknown-xous-elf" ]; then
		ok "riscv32imac-unknown-xous-elf present"
		return
	fi
	echo "  downloading (not a rustup target, so this comes from GitHub releases)"
	( cd "$WS/xous-core" && cargo +1.97.1 xtask install-toolkit ) || die "install-toolkit failed"

	ok "riscv32imac-unknown-xous-elf installed"
}

kernel_config() {
	echo "== kernel config =="
	cp "$HERE/configs/kernel-xip-bao1x.config" "$WS/linux/.config"
	( cd "$WS/linux" && make ARCH=riscv LLVM=1 olddefconfig >/dev/null )
	grep -q '^CONFIG_32BIT=y' "$WS/linux/.config" && ok "32-bit config in place" || die "config is not 32-bit"
}

check_tools
[ "${1:-}" = "check" ] && exit 0

submodules
xous_toolchain
kernel_config

echo "== Ready =="
