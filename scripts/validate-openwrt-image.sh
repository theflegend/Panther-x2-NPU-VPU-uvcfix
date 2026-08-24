#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
	cat <<'EOF'
Usage:
  validate-openwrt-image.sh \
    --image IMAGE.img.gz \
    --kernel-release RELEASE \
    --uboot-dir DIR \
    --report FILE
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_file() {
	local path="$1"
	local label="$2"
	[[ -s "${path}" ]] || die "missing ${label}: ${path}"
	printf 'OK file: %s\n' "${label}"
}

require_line() {
	local path="$1"
	local expression="$2"
	local label="$3"
	grep -Eq "${expression}" "${path}" || die "${label}"
	printf 'OK value: %s\n' "${label}"
}

require_text() {
	local path="$1"
	local text="$2"
	local label="$3"
	grep -Fq -- "${text}" "${path}" || die "${label}"
	printf 'OK value: %s\n' "${label}"
}

expect_fdt_status() {
	local dtb="$1"
	local node="$2"
	local expected="$3"
	local actual

	actual="$(fdtget -t s "${dtb}" "${node}" status 2>/dev/null || true)"
	[[ "${actual}" == "${expected}" ]] || \
		die "DTB ${node}/status: expected ${expected}, got ${actual:-<missing>}"
	printf 'OK DTB status: %s=%s\n' "${node}" "${actual}"
}

expect_fdt_string() {
	local dtb="$1"
	local node="$2"
	local property="$3"
	local expected="$4"
	local actual

	actual="$(fdtget -t s "${dtb}" "${node}" "${property}" 2>/dev/null || true)"
	[[ "${actual}" == "${expected}" ]] || \
		die "DTB ${node}/${property}: expected ${expected}, got ${actual:-<missing>}"
	printf 'OK DTB property: %s/%s=%s\n' "${node}" "${property}" "${actual}"
}

expect_fdt_hex() {
	local dtb="$1"
	local node="$2"
	local property="$3"
	local expected="$4"
	local actual

	actual="$(fdtget -t x "${dtb}" "${node}" "${property}" 2>/dev/null || true)"
	[[ "${actual}" == "${expected}" ]] || \
		die "DTB ${node}/${property}: expected ${expected}, got ${actual:-<missing>}"
	printf 'OK DTB property: %s/%s=%s\n' "${node}" "${property}" "${actual}"
}

image=""
kernel_release=""
uboot_dir=""
report=""

while [[ "$#" -gt 0 ]]; do
	case "$1" in
		--image)
			image="${2:-}"
			shift 2
			;;
		--kernel-release)
			kernel_release="${2:-}"
			shift 2
			;;
		--uboot-dir)
			uboot_dir="${2:-}"
			shift 2
			;;
		--report)
			report="${2:-}"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

require_file "${image}" 'compressed OpenWrt image'
[[ -n "${kernel_release}" ]] || die '--kernel-release is required'
require_file "${uboot_dir}/idbloader.img" 'source idbloader.img'
require_file "${uboot_dir}/u-boot.itb" 'source u-boot.itb'
[[ -n "${report}" ]] || die '--report is required'

for command_name in cmp fdtget findmnt gzip losetup mount mountpoint umount; do
	command -v "${command_name}" >/dev/null 2>&1 || die "required command not found: ${command_name}"
done

mkdir -p "$(dirname "${report}")"
exec > >(tee "${report}") 2>&1

work_dir="$(mktemp -d)"
raw_image="${work_dir}/panther-x2-openwrt.img"
mount_dir="${work_dir}/root"
boot_dir="${work_dir}/boot"
loopdev=""
mkdir -p "${mount_dir}" "${boot_dir}"

cleanup() {
	if mountpoint -q "${boot_dir}"; then
		sudo umount "${boot_dir}" || true
	fi
	if mountpoint -q "${mount_dir}"; then
		sudo umount "${mount_dir}" || true
	fi
	if [[ -n "${loopdev}" ]]; then
		sudo losetup --detach "${loopdev}" || true
	fi
	rm -rf -- "${work_dir}"
}
trap cleanup EXIT

printf 'Image: %s\n' "$(basename "${image}")"
gzip -dc "${image}" >"${raw_image}"

sudo fdisk -l "${raw_image}"
loopdev="$(sudo losetup --find --partscan --show "${raw_image}")"
for _ in {1..20}; do
	[[ -b "${loopdev}p1" && -b "${loopdev}p2" ]] && break
	sleep 1
done
[[ -b "${loopdev}p1" && -b "${loopdev}p2" ]] || \
	die "expected ${loopdev}p1 and ${loopdev}p2"

sudo mount -o ro "${loopdev}p1" "${boot_dir}"
sudo mount -o ro "${loopdev}p2" "${mount_dir}"

boot_fs="$(findmnt -n -o FSTYPE "${boot_dir}")"
root_fs="$(findmnt -n -o FSTYPE "${mount_dir}")"
[[ "${boot_fs}" == "ext4" ]] || die "expected ext4 boot filesystem, got ${boot_fs}"
[[ "${root_fs}" == "btrfs" ]] || die "expected btrfs root filesystem, got ${root_fs}"
printf 'OK filesystem: boot=%s root=%s\n' "${boot_fs}" "${root_fs}"

kernel_config="${boot_dir}/config-${kernel_release}"
dtb="${boot_dir}/dtb/rockchip/rk3566-panther-x2.dtb"
openwrt_release="${mount_dir}/etc/openwrt_release"
ophub_release="${mount_dir}/etc/flippy-openwrt-release"
single_lan_defaults="${mount_dir}/etc/uci-defaults/99-pantherx2-single-lan"

require_file "${boot_dir}/vmlinuz-${kernel_release}" 'vendor kernel image'
require_file "${boot_dir}/uInitrd-${kernel_release}" 'OpenWrt uInitrd'
require_file "${kernel_config}" 'vendor kernel configuration'
require_file "${dtb}" 'Panther X2 DTB'
require_file "${openwrt_release}" '/etc/openwrt_release'
require_file "${ophub_release}" '/etc/flippy-openwrt-release'
require_file "${single_lan_defaults}" 'single-port LAN DHCP preset'
[[ -d "${mount_dir}/lib/modules/${kernel_release}" ]] || \
	die "missing /lib/modules/${kernel_release}"
printf 'OK directory: /lib/modules/%s\n' "${kernel_release}"

[[ "$(readlink "${boot_dir}/Image")" == "vmlinuz-${kernel_release}" ]] || \
	die '/boot/Image does not select the vendor kernel'
[[ "$(readlink "${boot_dir}/uInitrd")" == "uInitrd-${kernel_release}" ]] || \
	die '/boot/uInitrd does not select the matching initrd'
printf 'OK links: Image and uInitrd select %s\n' "${kernel_release}"

require_line "${boot_dir}/armbianEnv.txt" \
	'^fdtfile=rockchip/rk3566-panther-x2\.dtb$' \
	'boot configuration selects the Panther X2 DTB'
require_line "${boot_dir}/armbianEnv.txt" \
	'^extraboardargs=.*net\.ifnames=0' \
	'boot configuration keeps the Ethernet device name eth0'
require_line "${ophub_release}" "^BOARD='panther-x2'$" 'ophub board is Panther X2'
require_line "${ophub_release}" "^KERNEL_TAGS='rk35xx'$" 'ophub kernel tag is rk35xx'
require_line "${ophub_release}" "^KERNEL_VERSION='6\.1\.115'$" 'ophub package kernel is 6.1.115'

require_text "${single_lan_defaults}" \
	"uci -q delete network.wan" \
	'first boot removes the WAN interface'
require_text "${single_lan_defaults}" \
	"uci set network.lan.device='eth0'" \
	'first boot assigns eth0 to LAN'
require_text "${single_lan_defaults}" \
	"uci set network.lan.proto='dhcp'" \
	'LAN uses a DHCP client'
require_text "${single_lan_defaults}" \
	"uci set dhcp.lan.ignore='1'" \
	'LAN DHCP server is disabled'
require_text "${single_lan_defaults}" \
	"uci set dhcp.lan.ra='disabled'" \
	'LAN IPv6 router advertisements are disabled'

for expression in \
	'^CONFIG_ROCKCHIP_RKNPU=y$' \
	'^CONFIG_ROCKCHIP_MPP_SERVICE=y$' \
	'^CONFIG_ROCKCHIP_MULTI_RGA=y$' \
	'^CONFIG_IEP=y$' \
	'^CONFIG_USB_VIDEO_CLASS=y$' \
	'^CONFIG_USB_XHCI_HCD=y$' \
	'^CONFIG_USB_DWC3=y$' \
	'^CONFIG_BTRFS_FS=y$' \
	'^CONFIG_NETFILTER=y$'; do
	require_line "${kernel_config}" "${expression}" "kernel option ${expression}"
done

while IFS= read -r node; do
	expect_fdt_status "${dtb}" "${node}" okay
done <<'NODES'
/mpp-srv
/npu@fde40000
/bus-npu
/iommu@fde4b000
/vdpu@fdea0400
/iommu@fdea0800
/rk_rga@fdeb0000
/jpegd@fded0000
/iommu@fded0480
/vepu@fdee0000
/iommu@fdee0800
/iep@fdef0000
/iommu@fdef0800
/rkvenc@fdf40000
/iommu@fdf40f00
/rkvdec@fdf80200
/iommu@fdf80800
/usbdrd
/usbdrd/usb@fcc00000
/usb2-phy@fe8a0000
/usb2-phy@fe8a0000/otg-port
NODES

expect_fdt_status "${dtb}" /video-codec@fdea0400 disabled
expect_fdt_string "${dtb}" /usbdrd/usb@fcc00000 dr_mode host
expect_fdt_string "${dtb}" /usbdrd/usb@fcc00000 maximum-speed high-speed
expect_fdt_hex "${dtb}" /npu@fde40000 rknpu-supply 149
expect_fdt_string "${dtb}" /npu@fde40000 interrupt-names npu_irq
expect_fdt_hex "${dtb}" /bus-npu bus-supply 6b
expect_fdt_hex "${dtb}" /bus-npu pvtm-supply 5

require_file "${mount_dir}/lib/u-boot/idbloader.img" 'packaged idbloader.img'
require_file "${mount_dir}/lib/u-boot/u-boot.itb" 'packaged u-boot.itb'
cmp "${uboot_dir}/idbloader.img" "${mount_dir}/lib/u-boot/idbloader.img"
cmp "${uboot_dir}/u-boot.itb" "${mount_dir}/lib/u-boot/u-boot.itb"
printf 'OK U-Boot: rootfs copies match the current Armbian build\n'

idbloader_size="$(wc -c <"${uboot_dir}/idbloader.img")"
uboot_size="$(wc -c <"${uboot_dir}/u-boot.itb")"
cmp --bytes="${idbloader_size}" --ignore-initial=32768:0 \
	"${raw_image}" "${uboot_dir}/idbloader.img"
cmp --bytes="${uboot_size}" --ignore-initial=8388608:0 \
	"${raw_image}" "${uboot_dir}/u-boot.itb"
printf 'OK U-Boot: idbloader and u-boot.itb are present at Rockchip offsets\n'

grep -E '^(DISTRIB_ID|DISTRIB_RELEASE|DISTRIB_ARCH|DISTRIB_DESCRIPTION)=' "${openwrt_release}" || true
grep -E "^(MODEL_NAME|SOC|FDTFILE|BOARD|KERNEL_TAGS|KERNEL_VERSION)='" "${ophub_release}"
printf 'Panther X2 OpenWrt BSP 6.1 image validation: passed (single LAN uses DHCP client)\n'
