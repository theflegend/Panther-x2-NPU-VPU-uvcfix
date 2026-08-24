#!/usr/bin/env bash

# ophub's Rockchip OpenWrt image builder uses Btrfs for the root partition.
# Btrfs therefore has to be available before the root filesystem is mounted.
function custom_kernel_config__pantherx2_openwrt_rootfs() {
	local option
	local -a kept_opts_m=()

	if [[ -f .config ]]; then
		display_alert "Panther X2 OpenWrt kernel" "Building Btrfs into the kernel" "info"
	fi

	# Armbian's core filesystem hook adds BTRFS_FS to opts_m. The framework
	# applies opts_y before opts_m, so leaving both entries would make the final
	# setting a module even though this extension requested a built-in driver.
	for option in "${opts_m[@]}"; do
		[[ "${option}" == "BTRFS_FS" ]] || kept_opts_m+=("${option}")
	done
	opts_m=("${kept_opts_m[@]}")
	opts_y+=("BTRFS_FS")
}
