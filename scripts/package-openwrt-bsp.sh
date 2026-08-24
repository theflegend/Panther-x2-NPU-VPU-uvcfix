#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
	cat <<'EOF'
Usage:
  package-openwrt-bsp.sh \
    --debs DIR \
    --kernel-output DIR \
    --uboot-output DIR \
    [--expected-base VERSION] \
    [--manifest FILE]

Convert the Panther X2 Armbian kernel/DTB/U-Boot DEBs into the layout used by
ophub/amlogic-s9xxx-openwrt.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

find_one() {
	local root="$1"
	local pattern="$2"
	local label="$3"
	local -a matches=()

	mapfile -t matches < <(find "${root}" -type f -name "${pattern}" -print | LC_ALL=C sort)
	if [[ "${#matches[@]}" -ne 1 ]]; then
		printf 'Expected exactly one %s matching %s; found %s:\n' \
			"${label}" "${pattern}" "${#matches[@]}" >&2
		printf '  %s\n' "${matches[@]:-<none>}" >&2
		exit 1
	fi

	printf '%s\n' "${matches[0]}"
}

require_config_y() {
	local config="$1"
	local symbol="$2"
	grep -q "^CONFIG_${symbol}=y$" "${config}" || die "CONFIG_${symbol}=y is required"
}

require_config_enabled() {
	local config="$1"
	local symbol="$2"
	grep -Eq "^CONFIG_${symbol}=(y|m)$" "${config}" || die "CONFIG_${symbol}=y/m is required"
}

expect_fdt_status() {
	local dtb="$1"
	local node="$2"
	local expected="$3"
	local actual

	actual="$(fdtget -t s "${dtb}" "${node}" status 2>/dev/null || true)"
	[[ "${actual}" == "${expected}" ]] || \
		die "DTB ${node}/status: expected ${expected}, got ${actual:-<missing>}"
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
}

debs_dir=""
kernel_output=""
uboot_output=""
expected_base="6.1.115"
manifest=""

while [[ "$#" -gt 0 ]]; do
	case "$1" in
		--debs)
			debs_dir="${2:-}"
			shift 2
			;;
		--kernel-output)
			kernel_output="${2:-}"
			shift 2
			;;
		--uboot-output)
			uboot_output="${2:-}"
			shift 2
			;;
		--expected-base)
			expected_base="${2:-}"
			shift 2
			;;
		--manifest)
			manifest="${2:-}"
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

[[ -d "${debs_dir}" ]] || die "DEB directory does not exist: ${debs_dir:-<empty>}"
[[ -n "${kernel_output}" ]] || die "--kernel-output is required"
[[ -n "${uboot_output}" ]] || die "--uboot-output is required"
[[ ! -e "${kernel_output}" ]] || die "kernel output already exists: ${kernel_output}"

for command_name in cpio dpkg-deb fdtget find gzip mkimage sha256sum tar; do
	require_command "${command_name}"
done

image_deb="$(find_one "${debs_dir}" 'linux-image-vendor-rk35xx*.deb' 'kernel image DEB')"
dtb_deb="$(find_one "${debs_dir}" 'linux-dtb-vendor-rk35xx*.deb' 'kernel DTB DEB')"
uboot_deb="$(find_one "${debs_dir}" 'linux-u-boot-panther-x2-vendor-vendor*.deb' 'Panther X2 U-Boot DEB')"

work_dir="$(mktemp -d)"
cleanup() {
	rm -rf -- "${work_dir}"
}
trap cleanup EXIT

image_root="${work_dir}/image"
dtb_root="${work_dir}/dtb"
uboot_root="${work_dir}/uboot"
mkdir -p "${image_root}" "${dtb_root}" "${uboot_root}"

dpkg-deb -x "${image_deb}" "${image_root}"
dpkg-deb -x "${dtb_deb}" "${dtb_root}"
dpkg-deb -x "${uboot_deb}" "${uboot_root}"

module_parent=""
for candidate in "${image_root}/lib/modules" "${image_root}/usr/lib/modules"; do
	if [[ -d "${candidate}" ]]; then
		module_parent="${candidate}"
		break
	fi
done
[[ -n "${module_parent}" ]] || die 'kernel image DEB does not contain lib/modules'

mapfile -t module_dirs < <(find "${module_parent}" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort)
[[ "${#module_dirs[@]}" -eq 1 ]] || die "expected one kernel module directory, found ${#module_dirs[@]}"
module_dir="${module_dirs[0]}"
kernel_release="$(basename "${module_dir}")"
kernel_base="${kernel_release%%-*}"
[[ "${kernel_base}" == "${expected_base}" ]] || \
	die "expected kernel base ${expected_base}, got ${kernel_release}"

kernel_image="${image_root}/boot/vmlinuz-${kernel_release}"
kernel_config="${image_root}/boot/config-${kernel_release}"
system_map="${image_root}/boot/System.map-${kernel_release}"
[[ -s "${kernel_image}" ]] || die "missing ${kernel_image}"
[[ -s "${kernel_config}" ]] || die "missing ${kernel_config}"

for symbol in \
	ROCKCHIP_RKNPU \
	ROCKCHIP_MPP_SERVICE \
	ROCKCHIP_MULTI_RGA \
	IEP \
	MEDIA_USB_SUPPORT \
	USB_VIDEO_CLASS \
	USB_XHCI_HCD \
	USB_DWC3 \
	BTRFS_FS \
	EXT4_FS \
	NETFILTER \
	BLK_DEV_INITRD; do
	require_config_y "${kernel_config}" "${symbol}"
done

for symbol in NF_CONNTRACK NF_TABLES NFT_NAT NFT_MASQ BRIDGE VLAN_8021Q VETH; do
	require_config_enabled "${kernel_config}" "${symbol}"
done

panther_dtb="$(find_one "${dtb_root}" 'rk3566-panther-x2.dtb' 'Panther X2 DTB')"
rockchip_dtb_dir="$(dirname "${panther_dtb}")"
dtb_count="$(find "${rockchip_dtb_dir}" -maxdepth 1 -type f -name '*.dtb' | wc -l | tr -d ' ')"
[[ "${dtb_count}" -ge 2 ]] || die "ophub requires at least two Rockchip DTBs; found ${dtb_count}"

while IFS= read -r node; do
	expect_fdt_status "${panther_dtb}" "${node}" okay
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

expect_fdt_status "${panther_dtb}" /video-codec@fdea0400 disabled
expect_fdt_string "${panther_dtb}" /usbdrd/usb@fcc00000 dr_mode host
expect_fdt_string "${panther_dtb}" /usbdrd/usb@fcc00000 maximum-speed high-speed
expect_fdt_hex "${panther_dtb}" /npu@fde40000 rknpu-supply 149
expect_fdt_string "${panther_dtb}" /npu@fde40000 interrupt-names npu_irq
expect_fdt_hex "${panther_dtb}" /bus-npu bus-supply 6b
expect_fdt_hex "${panther_dtb}" /bus-npu pvtm-supply 5

boot_stage="${work_dir}/boot-stage"
dtb_stage="${work_dir}/dtb-stage"
modules_stage="${work_dir}/modules-stage"
initrd_stage="${work_dir}/initrd-stage"
mkdir -p "${boot_stage}" "${dtb_stage}" "${modules_stage}" "${initrd_stage}"

cp -L "${kernel_image}" "${boot_stage}/vmlinuz-${kernel_release}"
cp -L "${kernel_config}" "${boot_stage}/config-${kernel_release}"
if [[ -s "${system_map}" ]]; then
	cp -L "${system_map}" "${boot_stage}/System.map-${kernel_release}"
fi

(
	cd "${initrd_stage}"
	find . -print0 | cpio --null --create --format=newc 2>/dev/null | \
		gzip -9n >"${boot_stage}/initrd.img-${kernel_release}"
)
mkimage \
	-A arm64 \
	-O linux \
	-T ramdisk \
	-C none \
	-n "Panther X2 OpenWrt initrd" \
	-d "${boot_stage}/initrd.img-${kernel_release}" \
	"${boot_stage}/uInitrd-${kernel_release}" >/dev/null

cp -a "${rockchip_dtb_dir}/." "${dtb_stage}/"
cp -a "${module_dir}" "${modules_stage}/"

mkdir -p "${kernel_output}" "${uboot_output}"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
	-C "${boot_stage}" -czf "${kernel_output}/boot-${kernel_release}.tar.gz" .
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
	-C "${dtb_stage}" -czf "${kernel_output}/dtb-rockchip-${kernel_release}.tar.gz" .
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
	-C "${modules_stage}" -czf "${kernel_output}/modules-${kernel_release}.tar.gz" .

idbloader="$(find_one "${uboot_root}" 'idbloader.img' 'idbloader.img')"
uboot_itb="$(find_one "${uboot_root}" 'u-boot.itb' 'u-boot.itb')"
cp -L "${idbloader}" "${uboot_output}/idbloader.img"
cp -L "${uboot_itb}" "${uboot_output}/u-boot.itb"

[[ "$(wc -c <"${uboot_output}/idbloader.img")" -gt 32768 ]] || die 'idbloader.img is unexpectedly small'
[[ "$(wc -c <"${uboot_output}/u-boot.itb")" -gt 262144 ]] || die 'u-boot.itb is unexpectedly small'

(
	cd "${kernel_output}"
	sha256sum ./*.tar.gz | sed 's#  \./#  #' >sha256sums
)

if [[ -n "${manifest}" ]]; then
	mkdir -p "$(dirname "${manifest}")"
	{
		printf 'KERNEL_RELEASE=%s\n' "${kernel_release}"
		printf 'KERNEL_BASE=%s\n' "${kernel_base}"
		printf 'KERNEL_IMAGE_DEB=%s\n' "$(basename "${image_deb}")"
		printf 'KERNEL_DTB_DEB=%s\n' "$(basename "${dtb_deb}")"
		printf 'UBOOT_DEB=%s\n' "$(basename "${uboot_deb}")"
		printf 'PANTHER_DTB_SHA256=%s\n' "$(sha256sum "${panther_dtb}" | awk '{print $1}')"
		printf 'IDBLOADER_SHA256=%s\n' "$(sha256sum "${uboot_output}/idbloader.img" | awk '{print $1}')"
		printf 'UBOOT_ITB_SHA256=%s\n' "$(sha256sum "${uboot_output}/u-boot.itb" | awk '{print $1}')"
	} >"${manifest}"
fi

printf 'Prepared ophub BSP bundle for %s\n' "${kernel_release}"
printf 'Kernel archives: %s\n' "${kernel_output}"
printf 'U-Boot files: %s\n' "${uboot_output}"
