#!/usr/bin/env bash
# Build and flash the Baochip-1x Linux bring-up pieces
#
#   ./flash.sh all           sbi-linux + dtb + kernel
#   ./flash.sh sbi-linux     REPL + M-mode SBI stub;   -> 0x60060000
#   ./flash.sh kernel        XIP Linux                 -> 0x600A0000
#   ./flash.sh dtb           device tree               -> 0x60390000
#   ./flash.sh busybox       build bin/busybox-rv32-min
#   ./flash.sh demo          build bin/demo-rv32 from initramfs/demo.c

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
XOUS=$HERE/workspace/xous-core
LINUX=$HERE/workspace/linux

# Where the BAOCHIP volume shows up depends on who mounted it: udisks uses
# /run/media/<user> on most distros and /media/<user> on Debian and Ubuntu.
# Take the first that exists, and fall back to the common one so the error
# message names a real path. VOL overrides all of it
me=${USER:-$(id -un)}
if [ -z "${VOL:-}" ]; then
	for d in "/run/media/$me/BAOCHIP" "/media/$me/BAOCHIP" "/Volumes/BAOCHIP"; do
		[ -d "$d" ] && VOL=$d && break
	done
	VOL=${VOL:-/run/media/$me/BAOCHIP}
fi
MKUF2=$HERE/tools/mkuf2.py

KERNEL_ADDR=0x600A0000
DTB_ADDR=0x60390000

die() { echo "error: $*" >&2; exit 1; }

need_volume() {
	[ -d "$VOL" ] || die "$VOL not mounted - hold BOOT while plugging USB. Override with: VOL=/path/to/volume $0 $*"
}

send() {
	local f=$1
	local sz
	sz=$(stat -c%s "$f")
	need_volume
	echo ">> $(basename "$f") -> $VOL  ($((sz / 1024)) KiB)"
	cp "$f" "$VOL/"
	sync
	echo "   done"
}

build_sbi_linux() {
	echo "== building SBI+Linux image (REPL; type \`linux\` to boot) =="
	# grep must not decide the exit status: it returns 1 when it prints nothing,
	# which under pipefail would look like a build failure. cargo's own status
	# still propagates through the pipe
	( cd "$XOUS" && cargo +1.97.1 xtask bao1x-sbi-linux-dabao ) 2>&1 | { grep -v '^warning: locales@' || true; }

	send "$XOUS/target/riscv32imac-unknown-none-elf/release/baremetal.uf2"
}

BB_VER=1.37.0
CC_RV32="zig cc -target riscv32-linux-musl -mcpu=generic_rv32+m+a+c \
         -Wno-ignored-optimization-argument"

build_busybox() {
	echo "== building busybox $BB_VER =="
	local work=${WORK:-/tmp/baochip-linux-build}
	mkdir -p "$work" "$HERE/bin"
	cd "$work"

	[ -f busybox.tar.bz2 ] || curl -sSL -o busybox.tar.bz2 "https://busybox.net/downloads/busybox-$BB_VER.tar.bz2"
	rm -rf "busybox-$BB_VER"; tar xf busybox.tar.bz2
	cd "busybox-$BB_VER"
	cp "$HERE/configs/busybox-min.config" .config

	# XXX: Zig's linker rejects these three flags; busybox passes them unconditionally
	sed -i '323s/-Wl,--warn-common \\/\\/' scripts/trylink
	sed -i '99s|.*|\techo ""|' scripts/trylink

	make oldconfig > /dev/null
	make -j"$(nproc)" CC="$CC_RV32" HOSTCC=cc AR="zig ar" SKIP_STRIP=y busybox

	llvm-strip -s -o "$HERE/bin/busybox-rv32-min" busybox
	file "$HERE/bin/busybox-rv32-min" | grep -q soft-float || die "busybox is not soft-float - check -mcpu"

	echo "$(stat -c%s "$HERE/bin/busybox-rv32-min") bytes"
}

build_demo() {
	echo "== building /bin/demo (static rv32 ELF) =="
	mkdir -p "$HERE/bin"

	( cd "$HERE/initramfs" && $CC_RV32 -static -Os -o "$HERE/bin/demo-rv32" demo.c )

	llvm-strip "$HERE/bin/demo-rv32"
	file "$HERE/bin/demo-rv32" | grep -q soft-float || die "demo-rv32 is not soft-float -- check -mcpu"

	echo "$(stat -c%s "$HERE/bin/demo-rv32") bytes"
}

build_userspace() {
	if [ ! -f "$HERE/bin/busybox-rv32-min" ] || [ "$HERE/configs/busybox-min.config" -nt "$HERE/bin/busybox-rv32-min" ]; then
		build_busybox
	else
		echo "== busybox up to date, (./flash.sh busybox to force) =="
	fi
	build_demo
}

build_kernel() {
	echo "== building kernel =="
	# The initramfs is compiled into the image, so these have to exist first
	# Without the check the failure is a gen_init_cpio error from deep inside
	# the kernel build, which does not point back here
	[ -f "$HERE/bin/busybox-rv32-min" ] || die "bin/busybox-rv32-min missing - run: $0 busybox"
	[ -f "$HERE/bin/demo-rv32" ]        || die "bin/demo-rv32 missing - run: $0 demo"

	if [ "$HERE/configs/kernel-xip-bao1x.config" -nt "$LINUX/.config" ]; then
		echo "config changed, reapplying"
		cp "$HERE/configs/kernel-xip-bao1x.config" "$LINUX/.config"
		( cd "$LINUX" && make ARCH=riscv LLVM=1 olddefconfig > /dev/null )
	fi

	( cd "$LINUX" && make ARCH=riscv LLVM=1 -j"$(nproc)" xipImage )
	local img=$LINUX/arch/riscv/boot/xipImage

	# XXX: the payload must not run into the DTB
	python3 - "$img" <<-EOF
		import os, sys
		end = 0x600A0000 + os.path.getsize(sys.argv[1])
		if end >= $DTB_ADDR:
		    sys.exit(f"kernel ends 0x{end:08x}, collides with DTB at $DTB_ADDR")
		print(f"   kernel 0x600a0000..0x{end:08x}, DTB clear")
	EOF

	python3 "$MKUF2" pack "$img" /tmp/kernel.uf2 $KERNEL_ADDR
	send /tmp/kernel.uf2
}

build_dtb() {
	echo "== building device tree =="
	dtc -I dts -O dtb -o /tmp/bao1x-dabao.dtb "$HERE/dts/bao1x-dabao.dts"

	python3 "$MKUF2" pack /tmp/bao1x-dabao.dtb /tmp/dtb.uf2 $DTB_ADDR
	send /tmp/dtb.uf2
}

case "${1:-}" in
sbi-linux)  build_sbi_linux ;;
busybox)    build_busybox; exit 0 ;;
demo)       build_demo; exit 0 ;;
kernel)     build_kernel ;;
dtb)        build_dtb ;;
all)        build_sbi_linux; build_dtb; build_userspace; build_kernel ;;
*)          sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'; exit 1 ;;
esac

echo
echo "Done!"
