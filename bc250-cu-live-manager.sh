#!/usr/bin/env bash
# BC-250 live CU/WGP manager for CachyOS.
#
# This is a self-contained runtime manager. It uses UMR to read/write the
# BC-250 gfx1013 registers that control CU enumeration and WGP dispatch.
#
# Hardware granularity is WGP pairs:
#   WGP0 = CU0,CU1   WGP1 = CU2,CU3   WGP2 = CU4,CU5
#   WGP3 = CU6,CU7   WGP4 = CU8,CU9

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
BC250_PCI_ID="13fe"
ASIC="${UMR_ASIC:-cyan_skillfish.gfx1013}"
REG_CC="mmCC_GC_SHADER_ARRAY_CONFIG"
REG_SPI="mmSPI_PG_ENABLE_STATIC_WGP_MASK"
REG_RLC="mmRLC_PG_ALWAYS_ON_WGP_MASK"
SERVICE_NAME="bc250-cu-live-manager.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
SERVICE_BIN="/usr/local/bin/bc250-cu-live-manager"
SERVICE_CONF="/etc/bc250-cu-live-manager.conf"
OLD_UDEV_RULE="/etc/udev/rules.d/99-bc250-cu-live-manager.rules"
LAST_REG_PATH=""
WGP_FULL_MASK=0x1f
UMR="${UMR:-}"
UMR_INSTANCE="${UMR_INSTANCE:-}"
UMR_INSTANCE_SOURCE="${UMR_INSTANCE:+env}"
YES=0
DRY_RUN=0
FORCE=0
SERVICE_TABLE_PENDING=0
DISCLAIMER_ACCEPTED=0
DISCLAIMER_NONINTERACTIVE_SHOWN=0
UMR_INSTALL_OFFERED=0
UMR_INSTANCE_ARGS=()

if [ -t 1 ]; then
	BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
	RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
	CYAN=$'\033[36m'; REV=$'\033[7m'
else
	BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""
	CYAN=""; REV=""
fi

info() { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '%s[ERR ]%s %s\n' "$RED" "$RESET" "$*" >&2; }
die()  { err "$@"; exit 1; }

hr() {
	printf '%s+------------------------------------------------------------------------------+%s\n' "$DIM" "$RESET"
}

panel_title() {
	local title="$1"
	hr
	printf '%s|%s %-76s %s|%s\n' "$DIM" "$RESET$BOLD" "$title" "$DIM" "$RESET"
	hr
}

prompt_line() {
	printf '%s>%s %s' "$CYAN" "$RESET" "$1"
}

usage() {
	cat <<EOF
BC-250 live CU/WGP manager

Usage:
  sudo ./$SCRIPT_NAME status
  sudo ./$SCRIPT_NAME enable all
  sudo ./$SCRIPT_NAME stock-dispatch
  sudo ./$SCRIPT_NAME table
  sudo ./$SCRIPT_NAME enable-wgp SE.SH.WGP [...]
  sudo ./$SCRIPT_NAME disable-wgp SE.SH.WGP [...]
  sudo ./$SCRIPT_NAME enable-cu SE.SH.CU [...]
  sudo ./$SCRIPT_NAME disable-cu SE.SH.CU [...]
  sudo ./$SCRIPT_NAME install-service
  sudo ./$SCRIPT_NAME write-service-table
  sudo ./$SCRIPT_NAME apply-service
  sudo ./$SCRIPT_NAME uninstall-service
  sudo ./$SCRIPT_NAME menu

Commands:
  status                  Show the main dashboard.
  table                   Edit WGP routing with cursor keys and Space.
  enable all              Route all WGPs/CUs on all shader arrays.
  disable all             Disable all dispatch WGPs on all shader arrays.
  enable-wgp LIST         Enable specific WGP pairs, e.g. 1.0.4.
  disable-wgp LIST        Disable specific WGP pairs, e.g. 1.0.4.
  enable-cu LIST          Enable CU pairs by CU id; 1.0.8 enables WGP4.
  disable-cu LIST         Disable CU pairs by CU id; 1.0.8 disables WGP4.
  stock-dispatch          Restore SPI/RLC dispatch to the boot driver topology.
  install-service         Install/update the boot service.
  write-service-table     Save the current WGP table as the boot profile.
  apply-service           Apply the table saved for the boot service.
  uninstall-service       Remove the boot service.
  install-umr             Install umr via pacman/paru/rpm-ostree/dnf.
  menu                    Interactive mode.

Options:
  -y, --yes               Do not prompt for risky register writes.
  -n, --dry-run           Print UMR writes without executing them.
  -i, --umr-instance N    Force umr DRI instance number.
  --force                 Allow writes when BC-250 PCI ID is not detected.
  -h, --help              Show this help.

Notes:
  - One WGP is two CUs; single CUs cannot be controlled independently.
  - Stock BC-250 layout is 6 active CUs per row: WGP0-2/CU0-5 on,
    WGP3-4/CU6-9 factory disabled across all 4 SE/SH rows.
  - Apply operations clear the BC-250 CC harvest mask before writing SPI,
    matching the known-working CachyOS unlock sequence.
  - write-service-table snapshots the current WGP table. Re-run it after
    table changes if status says the boot service is out of date.
  - Live disable operations refuse to turn off WGPs that are active in the
    driver topology; reboot with a driver mask instead if those CUs must change.
  - Write actions require a safety acknowledgment unless --yes is used.
EOF
}

find_umr() {
	local p
	if [ -n "$UMR" ] && [ -x "$UMR" ]; then
		return 0
	fi
	for p in /usr/bin/umr /usr/local/bin/umr /opt/umr/build/src/app/umr; do
		if [ -x "$p" ]; then
			UMR="$p"
			return 0
		fi
	done
	return 1
}

need_umr() {
	find_umr || die "umr not found. Run: sudo ./$SCRIPT_NAME install-umr"
	select_umr_instance
}

validate_umr_instance() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

init_umr_instance_args() {
	UMR_INSTANCE_ARGS=()
	if [ -n "$UMR_INSTANCE" ]; then
		UMR_INSTANCE_ARGS=(-i "$UMR_INSTANCE")
	fi
}

umr_cmd_string() {
	printf '%s' "$UMR"
	if [ -n "$UMR_INSTANCE" ]; then
		printf ' -i %s' "$UMR_INSTANCE"
	fi
}

detect_umr_instance() {
	local debug_root="/sys/kernel/debug/dri" line bdf dir inst
	local -a seen=()
	[ -d "$debug_root" ] || return 1

	while IFS= read -r line; do
		bdf="${line%% *}"
		[ -n "$bdf" ] || continue
		for dir in "$debug_root"/[0-9]*; do
			[ -e "$dir/name" ] || continue
			inst="${dir##*/}"
			[[ "$inst" =~ ^[0-9]+$ ]] || continue
			[ "$inst" -lt 128 ] || continue
			if grep -Fqi "$bdf" "$dir/name" 2>/dev/null; then
				printf '%s\n' "$inst"
				return 0
			fi
		done
	done < <(lspci -Dnn 2>/dev/null | grep -i '\[1002:13fe\]' || true)

	for dir in "$debug_root"/[0-9]*; do
		[ -e "$dir/name" ] || continue
		inst="${dir##*/}"
		[[ "$inst" =~ ^[0-9]+$ ]] || continue
		[ "$inst" -lt 128 ] || continue
		seen+=("$inst")
	done
	[ "${#seen[@]}" -eq 1 ] || return 1
	printf '%s\n' "${seen[0]}"
	return 0
}

select_umr_instance() {
	local detected
	if [ -n "$UMR_INSTANCE" ]; then
		validate_umr_instance "$UMR_INSTANCE" || die "invalid --umr-instance '$UMR_INSTANCE' (expected non-negative integer)"
		UMR_INSTANCE_SOURCE="${UMR_INSTANCE_SOURCE:-env}"
		init_umr_instance_args
		return 0
	fi
	detected="$(detect_umr_instance || true)"
	if [ -n "$detected" ]; then
		UMR_INSTANCE="$detected"
		UMR_INSTANCE_SOURCE="auto"
	else
		UMR_INSTANCE_SOURCE="default"
	fi
	init_umr_instance_args
}

need_root() {
	[ "$(id -u)" = "0" ] || die "register writes require root"
}

need_umr_root() {
	[ "$(id -u)" = "0" ] || die "umr register access requires root. Run: sudo ./$SCRIPT_NAME ${1:-status}"
}

print_disclaimer() {
	panel_title "Safety Disclaimer"
	printf '| %-76s |\n' "This tool writes low-level AMDGPU registers on BC-250 hardware."
	printf '| %-76s |\n' "Incorrect values can freeze the GPU, crash the system, or force a reboot."
	printf '| %-76s |\n' "You may lose unsaved work and can increase power draw and thermals."
	printf '| %-76s |\n' "No warranty is provided by the authors or contributors of this script."
	printf '| %-76s |\n' "You are fully responsible for validation, monitoring, and any outcomes."
	printf '| %-76s |\n' "Recommended: stable PSU, active cooling, and a remote shell fallback."
	hr
}

confirm_disclaimer() {
	local ans
	[ "$DISCLAIMER_ACCEPTED" -eq 1 ] && return 0
	if [ "$YES" -eq 1 ]; then
		if [ "$DISCLAIMER_NONINTERACTIVE_SHOWN" -eq 0 ]; then
			printf '\n'
			print_disclaimer
			warn "--yes is set; continuing without interactive acknowledgment"
			DISCLAIMER_NONINTERACTIVE_SHOWN=1
		fi
		DISCLAIMER_ACCEPTED=1
		return 0
	fi
	while true; do
		printf '\n'
		print_disclaimer
		prompt_line "Type 'accept' to continue or 'no' to cancel: "
		read -r ans
		case "$ans" in
			accept|ACCEPT|Accept)
				DISCLAIMER_ACCEPTED=1
				return 0
				;;
			n|N|no|NO|No|cancel|CANCEL|Cancel)
				warn "cancelled"
				return 1
				;;
			*)
				warn "type accept or no"
				;;
		esac
	done
}

confirm_service_install() {
	confirm_disclaimer || return 1
	[ "$YES" -eq 1 ] && return 0
	local ans
	while true; do
		printf '\n'
		panel_title "Confirm Service Install"
		printf '| %-76s |\n' "This will install and enable the boot service."
		printf '| %-76s |\n' "Use write-service-table when you want to change the saved WGP table."
		hr
		prompt_line "Install/update service? [y/n]: "
		read -r ans
		case "$ans" in
			y|Y|yes|YES) return 0 ;;
			n|N|no|NO) warn "cancelled"; return 1 ;;
			*) warn "type y or n" ;;
		esac
	done
}

confirm_write_service_table() {
	[ "$YES" -eq 1 ] && return 0
	local ans
	while true; do
		printf '\n'
		panel_title "Confirm Boot Table Save"
		printf '| %-76s |\n' "This will save the current live WGP table as the boot profile."
		printf '| %-76s |\n' "The installed service will use this table on the next start/boot."
		hr
		prompt_line "Write current table to service config? [y/n]: "
		read -r ans
		case "$ans" in
			y|Y|yes|YES) return 0 ;;
			n|N|no|NO) warn "cancelled"; return 1 ;;
			*) warn "type y or n" ;;
		esac
	done
}

mask_tokens() {
	local mask="$1" driver_mask="${2:-0}" wgp bit token out=""
	for wgp in 0 1 2 3 4; do
		bit=$((1 << wgp))
		if [ $((driver_mask & bit)) -ne 0 ] && [ $((mask & bit)) -ne 0 ]; then
			token="D+"
		elif [ $((driver_mask & bit)) -ne 0 ]; then
			token="D!"
		elif [ $((mask & bit)) -ne 0 ]; then
			token="S+"
		else
			token="--"
		fi
		out="${out}${out:+ }$token"
	done
	printf '%s\n' "$out"
}

mask_change_label() {
	local old="$1" new="$2" wgp bit out=""
	for wgp in 0 1 2 3 4; do
		bit=$((1 << wgp))
		if [ $((old & bit)) -eq 0 ] && [ $((new & bit)) -ne 0 ]; then
			out="${out}${out:+,}W${wgp}+"
		elif [ $((old & bit)) -ne 0 ] && [ $((new & bit)) -eq 0 ]; then
			out="${out}${out:+,}W${wgp}-"
		fi
	done
	printf '%s\n' "${out:-none}"
}

dispatch_total() {
	local idx total=0
	for idx in 0 1 2 3; do
		total=$((total + $(wgp_mask_cu_count "${target_masks[$idx]}")))
	done
	printf '%s\n' "$total"
}

mask_csv() {
	local -n ref="$1"
	printf '%s,%s,%s,%s\n' \
		"$(hex_mask "${ref[0]}")" \
		"$(hex_mask "${ref[1]}")" \
		"$(hex_mask "${ref[2]}")" \
		"$(hex_mask "${ref[3]}")"
}

mask_summary() {
	local -n ref="$1"
	printf '%s=%s %s=%s %s=%s %s=%s\n' \
		"$(row_label 0)" "$(hex_mask "${ref[0]}")" \
		"$(row_label 1)" "$(hex_mask "${ref[1]}")" \
		"$(row_label 2)" "$(hex_mask "${ref[2]}")" \
		"$(row_label 3)" "$(hex_mask "${ref[3]}")"
}

load_service_masks() {
	local line csv item idx value
	local -a _service_items
	service_masks=()
	[ -f "$SERVICE_CONF" ] || return 1
	while IFS= read -r line; do
		case "$line" in
			BC250_WGP_MASKS=*)
				csv="${line#BC250_WGP_MASKS=}"
				break
				;;
		esac
	done <"$SERVICE_CONF"
	[ -n "${csv:-}" ] || return 1
	IFS=',' read -ra _service_items <<<"$csv"
	[ "${#_service_items[@]}" -eq 4 ] || return 1
	for idx in 0 1 2 3; do
		item="${_service_items[$idx]}"
		[[ "$item" =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]] || return 1
		value=$((item))
		[ "$value" -ge 0 ] && [ "$value" -le 31 ] || return 1
		service_masks[$idx]="$value"
	done
	return 0
}

service_masks_match_current() {
	local idx
	[ "${#service_masks[@]}" -eq 4 ] || return 1
	[ "${#current_masks[@]}" -eq 4 ] || return 1
	for idx in 0 1 2 3; do
		[ "$((service_masks[idx] & 31))" -eq "$((current_masks[idx] & 31))" ] || return 1
	done
	return 0
}

confirm_dispatch_plan() {
	local title="$1" idx ans current target driver
	confirm_disclaimer || return 1
	[ "$YES" -eq 1 ] && return 0
	while true; do
		printf '\n'
		panel_title "$title"
		printf '  Legend: D+ driver+routed, S+ SPI only, -- off, D! unsafe blocked\n\n'
		printf '  +---------+----------------+----------------+-----------------------+\n'
		printf '  | Row     | Current        | Target         | Change                |\n'
		printf '  +---------+----------------+----------------+-----------------------+\n'
		for idx in 0 1 2 3; do
			current="${current_masks[$idx]}"
			target="${target_masks[$idx]}"
			driver="${driver_masks[$idx]:-0}"
			printf '  | %-7s | %-14s | %-14s | %-21s |\n' \
				"$(row_label "$idx")" \
				"$(mask_tokens "$current" "$driver")" \
				"$(mask_tokens "$target" "$driver")" \
				"$(mask_change_label "$current" "$target")"
		done
		printf '  +---------+----------------+----------------+-----------------------+\n'
		printf '\n  Target total: %s%s/40 CUs%s\n' "$BOLD" "$(dispatch_total)" "$RESET"
		prompt_line "Apply changes? [y/n]: "
		read -r ans
		case "$ans" in
			y|Y|yes|YES) return 0 ;;
			n|N|no|NO) warn "cancelled"; return 1 ;;
			*) warn "type y or n" ;;
		esac
	done
}

check_bc250() {
	if command -v lspci >/dev/null 2>&1 && lspci -nn 2>/dev/null | grep -qi "$BC250_PCI_ID"; then
		return 0
	fi
	warn "BC-250 PCI ID 13fe was not detected by lspci."
	return 1
}

require_bc250_for_write() {
	if check_bc250; then
		return 0
	fi
	[ "$FORCE" -eq 1 ] || die "refusing register writes on unknown hardware. Use --force only if this is a BC-250 and lspci detection is wrong."
	warn "forcing register writes despite failed BC-250 PCI detection"
}

install_umr() {
	need_root
	if command -v pacman >/dev/null 2>&1 && pacman -Qi umr >/dev/null 2>&1; then
		info "umr is already installed."
		return 0
	fi
	if command -v pacman >/dev/null 2>&1; then
		if pacman -Si umr >/dev/null 2>&1; then
			info "Installing umr with pacman..."
			pacman -S --needed umr
			return 0
		fi
	fi
	if command -v paru >/dev/null 2>&1; then
		local user_name="${SUDO_USER:-}"
		[ -n "$user_name" ] || die "paru install needs SUDO_USER set; run through sudo from your normal user"
		info "Installing umr with paru as $user_name..."
		sudo -u "$user_name" paru -S --needed umr
		return 0
	fi
	if command -v rpm-ostree >/dev/null 2>&1; then
		warn "rpm-ostree layering is host-level and may affect upgrade workflows on immutable systems."
		info "Installing umr with rpm-ostree (reboot required)..."
		if rpm-ostree install umr; then
			info "umr was staged successfully. Reboot, then run this script again."
			return 0
		fi
		die "rpm-ostree could not install umr; try layering it manually and check rpm-ostree output."
	fi
	if command -v dnf >/dev/null 2>&1; then
		info "Installing umr with dnf..."
		dnf install -y umr && return 0
		die "dnf could not install umr; check repository availability for package 'umr'."
	fi
	die "could not install umr automatically; install it with pacman/paru/rpm-ostree/dnf first"
}

install_service() {
	need_root
	need_umr
	confirm_service_install || return 0
	local source_path
	source_path="$(readlink -f "$0")"
	if ! install -m 0755 "$source_path" "$SERVICE_BIN"; then
		if [ -d /var/usrlocal/bin ]; then
			SERVICE_BIN="/var/usrlocal/bin/bc250-cu-live-manager"
			install -m 0755 "$source_path" "$SERVICE_BIN"
		else
			die "failed to install service binary at $SERVICE_BIN"
		fi
	fi
	cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=BC-250 CU saved enumeration and dispatch
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
EnvironmentFile=-$SERVICE_CONF
ExecStartPre=/usr/bin/bash -c 'for _ in {1..30}; do compgen -G "/dev/dri/renderD*" >/dev/null && exit 0; sleep 1; done; exit 1'
ExecStart=$SERVICE_BIN --yes apply-service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
	rm -f "$OLD_UDEV_RULE"
	systemctl daemon-reload
	systemctl enable "$SERVICE_NAME"
	if [ -f "$SERVICE_CONF" ]; then
		info "installed and enabled $SERVICE_NAME"
		info "saved boot table will be applied on next boot; use apply-service to apply it now"
	else
		info "installed and enabled $SERVICE_NAME"
		warn "no boot table is saved yet; use write-service-table before rebooting"
	fi
}

write_service_table() {
	need_root
	need_umr
	select_asic
	require_bc250_for_write
	local -a current_masks
	read_current_masks
	confirm_write_service_table || return 0
	cat > "$SERVICE_CONF" <<EOF
# BC-250 live manager boot profile.
# Generated by $SCRIPT_NAME on $(date -Iseconds).
# Format: SE0.SH0,SE0.SH1,SE1.SH0,SE1.SH1 SPI WGP masks.
BC250_WGP_MASKS=$(mask_csv current_masks)
UMR_ASIC=$ASIC
UMR_INSTANCE=$UMR_INSTANCE
UMR=$UMR
EOF
	chmod 0644 "$SERVICE_CONF"
	info "saved boot table: $(mask_summary current_masks)"
}

uninstall_service() {
	need_root
	systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
	rm -f "$SERVICE_PATH" "$SERVICE_BIN" "/var/usrlocal/bin/bc250-cu-live-manager" "$SERVICE_CONF" "$OLD_UDEV_RULE"
	systemctl daemon-reload
	info "removed $SERVICE_NAME"
}

select_asic() {
	local out value
	out="$("$UMR" "${UMR_INSTANCE_ARGS[@]}" -r "$ASIC.$REG_SPI" 2>&1 || true)"
	value="$(printf '%s\n' "$out" | parse_hex)"
	[ -n "$value" ] && return 0
	die "failed to read $ASIC.$REG_SPI with umr. Set UMR_ASIC to the exact selector if your board differs."
}

reg_candidates() {
	printf '%s\n' "$1"
}

parse_hex() {
	awk '
		{
			for (i = NF; i >= 1; i--) {
				if ($i ~ /^0x[0-9a-fA-F]+$/) {
					print $i
					exit
				}
			}
		}
	'
}

umr_output_failed() {
	local out="$1"
	printf '%s\n' "$out" | grep -Eqi '(\[ERROR\]|error|failed|invalid|unknown|cannot|no such)'
}

read_reg_bank() {
	local reg="$1" se="$2" sh="$3" candidate out value
	if value="$(try_read_reg_bank "$reg" "$se" "$sh")"; then
		printf '%s\n' "$value"
		return 0
	fi
	die "failed to read $reg for SE$se SH$sh with umr"
}

try_read_reg_bank() {
	local reg="$1" se="$2" sh="$3" candidate out value
	LAST_REG_PATH=""
	while IFS= read -r candidate; do
		out="$("$UMR" "${UMR_INSTANCE_ARGS[@]}" -r "$ASIC.$candidate" -b "$se" "$sh" 0xffffffff 2>&1 || true)"
		value="$(printf '%s\n' "$out" | parse_hex)"
		if [ -z "$value" ]; then
			out="$("$UMR" "${UMR_INSTANCE_ARGS[@]}" -r "$ASIC.$candidate" -b "$se" "$sh" 2>&1 || true)"
			value="$(printf '%s\n' "$out" | parse_hex)"
		fi
		if [ -n "$value" ]; then
			LAST_REG_PATH="$ASIC.$candidate"
			printf '%s\n' "$value"
			return 0
		fi
	done < <(reg_candidates "$reg")
	return 1
}

try_write_reg_global() {
	local reg="$1" value="$2" candidate out
	LAST_REG_PATH=""
	while IFS= read -r candidate; do
		LAST_REG_PATH="$ASIC.$candidate"
		if [ "$DRY_RUN" -eq 1 ]; then
			printf 'dry-run: %s -w %s %s\n' "$(umr_cmd_string)" "$LAST_REG_PATH" "$value"
			return 0
		fi
		out="$("$UMR" "${UMR_INSTANCE_ARGS[@]}" -w "$LAST_REG_PATH" "$value" 2>&1 || true)"
		if ! umr_output_failed "$out"; then
			return 0
		fi
	done < <(reg_candidates "$reg")
	return 1
}

write_reg_bank() {
	local reg="$1" value="$2" se="$3" sh="$4" candidate out
	LAST_REG_PATH=""
	while IFS= read -r candidate; do
		LAST_REG_PATH="$ASIC.$candidate"
		if [ "$DRY_RUN" -eq 1 ]; then
			printf 'dry-run: %s -w %s %s -b %s %s 0xffffffff\n' \
				"$(umr_cmd_string)" "$LAST_REG_PATH" "$value" "$se" "$sh"
			return 0
		fi
		out="$("$UMR" "${UMR_INSTANCE_ARGS[@]}" -w "$LAST_REG_PATH" "$value" -b "$se" "$sh" 0xffffffff 2>&1 || true)"
		if ! umr_output_failed "$out"; then
			return 0
		fi
	done < <(reg_candidates "$reg")
	die "failed to write $reg=$value for SE$se SH$sh with umr"
}

hex_to_dec() {
	printf '%d' "$(( $1 ))"
}

hex_mask() {
	printf '0x%02x' "$(( $1 & 31 ))"
}

wgp_mask_cu_count() {
	local mask="$1" wgp count=0
	for wgp in 0 1 2 3 4; do
		if [ $((mask & (1 << wgp))) -ne 0 ]; then
			count=$((count + 2))
		fi
	done
	printf '%s\n' "$count"
}

module_status() {
	local mode enum
	mode="$(cat /sys/module/amdgpu/parameters/bc250_cc_write_mode 2>/dev/null || true)"
	enum="$(dmesg 2>/dev/null | grep -o 'active_cu_number [0-9]*' | tail -1 | awk '{print $2}' || true)"
	printf '  amdgpu     : bc250_cc_write_mode=%s, active_cu_number=%s\n' \
		"${mode:-not exposed}" "${enum:-unknown}"
}

live_table_rule() {
	printf '  +---------+------+------+------+------+------+------+------------+--------+\n'
}

live_table_header() {
	live_table_rule
	printf '  | Row     | WGP0 | WGP1 | WGP2 | WGP3 | WGP4 | SPI  | CC         | CUs    |\n'
	printf '  |         | 0-1  | 2-3  | 4-5  | 6-7  | 8-9  |      |            |        |\n'
	live_table_rule
}

live_wgp_dispatch_cell() {
	local spi_on="$1" driver_on="${2:-0}"
	if [ "$driver_on" -ne 0 ] && [ "$spi_on" -ne 0 ]; then
		printf '  %sD+%s  |' "$GREEN$BOLD" "$RESET"
	elif [ "$driver_on" -ne 0 ]; then
		printf '  %sD!%s  |' "$RED$BOLD" "$RESET"
	elif [ "$spi_on" -ne 0 ]; then
		printf '  %sS+%s  |' "$CYAN" "$RESET"
	else
		printf '  %s--%s  |' "$DIM" "$RESET"
	fi
}

read_driver_wgp_masks() {
	local line idx mask
	local -a out=()
	while IFS= read -r line; do
		out+=("$line")
	done < <(python3 <<'PYEOF'
import ctypes
import os
import struct
import sys

def open_render_node():
    candidates = ["/dev/dri/renderD128"]
    dri = "/dev/dri"
    if os.path.isdir(dri):
        for name in sorted(os.listdir(dri)):
            if name.startswith("renderD"):
                path = os.path.join(dri, name)
                if path not in candidates:
                    candidates.append(path)
    last = None
    for path in candidates:
        try:
            return os.open(path, os.O_RDWR)
        except OSError as exc:
            last = exc
    raise RuntimeError(f"no DRM render node could be opened: {last}")

try:
    libdrm = ctypes.CDLL("libdrm_amdgpu.so.1")
    fd = open_render_node()
    dev = ctypes.c_void_p()
    maj, min_ = ctypes.c_uint32(), ctypes.c_uint32()
    rc = libdrm.amdgpu_device_initialize(fd, ctypes.byref(maj), ctypes.byref(min_), ctypes.byref(dev))
    if rc != 0:
        raise RuntimeError(f"amdgpu_device_initialize failed: {rc}")
    buf = (ctypes.c_uint8 * 1024)()
    rc = libdrm.amdgpu_query_info(dev, 0x16, 1024, ctypes.byref(buf))
    if rc != 0:
        raise RuntimeError(f"amdgpu_query_info(CU_INFO) failed: {rc}")
    raw = bytes(buf)
    num_se = struct.unpack_from("<I", raw, 20)[0]
    num_sh = struct.unpack_from("<I", raw, 24)[0]
    rows = []
    for se in range(min(num_se, 2)):
        for sh in range(min(num_sh, 2)):
            bm = struct.unpack_from("<I", raw, 56 + (se * 4 + sh) * 4)[0]
            wgp_mask = 0
            for wgp in range(5):
                if bm & (0x3 << (wgp * 2)):
                    wgp_mask |= 1 << wgp
            rows.append((se * 2 + sh, wgp_mask))
    for idx, mask in rows:
        print(f"{idx} {mask}")
except Exception:
    sys.exit(1)
finally:
    try:
        if 'dev' in locals() and dev:
            libdrm.amdgpu_device_deinitialize(dev)
    except Exception:
        pass
    try:
        if 'fd' in locals() and fd >= 0:
            os.close(fd)
    except Exception:
        pass
PYEOF
	)
	[ "${#out[@]}" -gt 0 ] || return 1
	for idx in 0 1 2 3; do
		driver_masks[$idx]=0
	done
	for line in "${out[@]}"; do
		read -r idx mask <<<"$line"
		[[ "$idx" =~ ^[0-3]$ ]] || continue
		driver_masks[$idx]="$mask"
	done
	return 0
}

register_status() {
	need_umr_root status
	need_umr
	select_asic
	check_bc250 || true
	local total=0 driver_total=0 blocked_total=0 se sh spi cc_hex count idx wgp bit driver_mask spi_on driver_on
	local -a driver_masks current_masks service_masks
	local driver_ok=0 service_has_config=0
	if read_driver_wgp_masks; then
		driver_ok=1
	fi
	read_current_masks
	SERVICE_TABLE_PENDING=0
	if load_service_masks; then
		service_has_config=1
		if ! service_masks_match_current; then
			SERVICE_TABLE_PENDING=1
		fi
	elif [ -f "$SERVICE_PATH" ]; then
		SERVICE_TABLE_PENDING=1
	fi
	panel_title "BC-250 CU Dashboard / Live Dispatch"
	printf '  UMR        : %s\n' "$UMR"
	if [ -n "$UMR_INSTANCE" ]; then
		printf '  UMR inst   : %s (%s)\n' "$UMR_INSTANCE" "$UMR_INSTANCE_SOURCE"
	else
		printf '  UMR inst   : default (0)\n'
	fi
	printf '  ASIC       : %s\n' "$ASIC"
	module_status
	if command -v systemctl >/dev/null 2>&1 && [ -f "$SERVICE_PATH" ]; then
		printf '  Service    : %s\n' "$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || printf 'installed')"
		if [ "$SERVICE_TABLE_PENDING" -eq 1 ]; then
			printf '  %sBoot sync  : pending changes; press [w] Write table%s\n' "$YELLOW$BOLD" "$RESET"
		elif [ "$service_has_config" -eq 1 ]; then
			printf '  Boot sync  : current table saved\n'
		else
			printf '  %sBoot sync  : no saved table; press [w] Write table%s\n' "$YELLOW$BOLD" "$RESET"
		fi
	fi
	printf '  Source     : SPI dispatch masks'
	if [ "$driver_ok" -eq 1 ]; then
		printf ' + driver CU topology\n'
		printf '  Legend     : %sD+%s driver+routed locked, %sS+%s SPI only, %s--%s off\n\n' \
			"$GREEN$BOLD" "$RESET" "$CYAN" "$RESET" "$DIM" "$RESET"
	else
		printf '\n'
		printf '  Legend     : %sS+%s routed, %s--%s off. Driver lock state unavailable.\n\n' \
			"$CYAN" "$RESET" "$DIM" "$RESET"
	fi
	live_table_header
	for se in 0 1; do
		for sh in 0 1; do
			idx=$((se * 2 + sh))
			cc_hex="$(read_reg_bank "$REG_CC" "$se" "$sh")"
			spi="${current_masks[$idx]}"
			driver_mask="${driver_masks[$idx]:-0}"
			count=0
			printf '  | SE%s.SH%s |' "$se" "$sh"
			for wgp in 0 1 2 3 4; do
				bit=$((1 << wgp))
				spi_on=0
				driver_on=0
				if [ $((spi & bit)) -ne 0 ]; then
					spi_on=1
					count=$((count + 2))
				fi
				if [ "$driver_ok" -eq 1 ] && [ $((driver_mask & bit)) -ne 0 ]; then
					driver_on=1
					driver_total=$((driver_total + 2))
				fi
				if [ "$driver_on" -ne 0 ] && [ "$spi_on" -eq 0 ]; then
					blocked_total=$((blocked_total + 2))
				fi
				live_wgp_dispatch_cell "$spi_on" "$driver_on"
			done
			total=$((total + count))
			printf ' %s%s%s | %s | %3s/10 |\n' "$DIM" "$(hex_mask "$spi")" "$RESET" "$cc_hex" "$count"
		done
	done
	live_table_rule
	printf '\n  SPI total  : %s%s/40 CUs%s\n' "$BOLD" "$total" "$RESET"
	if [ "$service_has_config" -eq 1 ]; then
		printf '  Boot table : %s\n' "$(mask_summary service_masks)"
	fi
	if [ "$driver_ok" -eq 1 ]; then
		printf '  Driver lock: %s%s/40 CUs%s active; active WGPs cannot be disabled live\n' "$BOLD" "$driver_total" "$RESET"
		if [ "$blocked_total" -gt 0 ]; then
			warn "driver-active CUs are not routed by SPI (${blocked_total} CUs shown as D!)"
		fi
	else
		warn "driver topology lock state unavailable; disabling dispatch will be refused"
	fi
}

status() {
	if [ "$(id -u)" != "0" ]; then
		panel_title "BC-250 CU Dashboard"
		warn "UMR register view skipped; run with sudo for register access."
		return 0
	fi
	if ! find_umr; then
		panel_title "BC-250 CU Dashboard"
		warn "UMR register view skipped; umr was not found."
		return 0
	fi
	register_status
}

clear_screen() {
	if [ -t 1 ]; then
		printf '\033[2J\033[H'
	fi
}

pause_screen() {
	printf '\nPress Enter to continue... '
	read -r _
}

print_menu() {
	clear_screen
	status
	printf '\n'
	hr
	printf '%s|%s %s%-76s%s %s|%s\n' "$DIM" "$RESET" "$BOLD" "Actions" "$RESET" "$DIM" "$RESET"
	hr
	printf '%s|%s  %-22s  %-22s  %-27s %s|%s\n' "$DIM" "$RESET" "[e] Edit WGP table" "[f] Full dispatch" "[t] Driver dispatch" "$DIM" "$RESET"
	printf '%s|%s  %-22s  ' "$DIM" "$RESET" "[i] Install service"
	if [ "$SERVICE_TABLE_PENDING" -eq 1 ]; then
		printf '%s%-22s%s  ' "$YELLOW$BOLD" "[w] Write table *" "$RESET"
	else
		printf '%-22s  ' "[w] Write table"
	fi
	printf '%-27s %s|%s\n' "[u] Uninstall service" "$DIM" "$RESET"
	printf '%s|%s  %-75s %s|%s\n' "$DIM" "$RESET" "[q] Quit" "$DIM" "$RESET"
	hr
	printf '\n'
}

offer_umr_install_from_menu() {
	local ans
	find_umr && return 0
	[ "$UMR_INSTALL_OFFERED" -eq 1 ] && return 0
	UMR_INSTALL_OFFERED=1
	printf '\n'
	prompt_line "UMR is not installed. Install it now? [y/n]: "
	read -r ans
	case "$ans" in
		y|Y|yes|YES)
			clear_screen
			if [ "$(id -u)" != "0" ]; then
				warn "install-umr requires root. Re-run with sudo."
			else
				install_umr
			fi
			pause_screen
			return 1
			;;
		*)
			return 0
			;;
	esac
}

row_label() {
	case "$1" in
		0) printf 'SE0.SH0' ;;
		1) printf 'SE0.SH1' ;;
		2) printf 'SE1.SH0' ;;
		3) printf 'SE1.SH1' ;;
	esac
}

row_coords() {
	case "$1" in
		0) printf '0 0' ;;
		1) printf '0 1' ;;
		2) printf '1 0' ;;
		3) printf '1 1' ;;
	esac
}

read_spi_masks() {
	local idx se sh spi_hex
	for idx in 0 1 2 3; do
		read -r se sh <<<"$(row_coords "$idx")"
		spi_hex="$(read_reg_bank "$REG_SPI" "$se" "$sh")"
		masks[$idx]=$(( $(hex_to_dec "$spi_hex") & 31 ))
	done
}

read_current_masks() {
	local -a masks
	read_spi_masks
	current_masks=("${masks[@]}")
}

draw_wgp_table() {
	local cursor_row="$1" cursor_wgp="$2" idx wgp bit cell style endstyle driver_on blocked_total=0
	clear_screen
	panel_title "BC-250 WGP Routing"
	printf '  %sArrows/hjkl%s move    %sSpace%s toggle unlocked    %sEnter/a%s apply    %sq%s cancel\n' \
		"$CYAN" "$RESET" "$CYAN" "$RESET" "$CYAN" "$RESET" "$CYAN" "$RESET"
	printf '  Legend: %sD+%s locked+routed, %sS+%s routed, %s--%s off\n\n' \
		"$GREEN$BOLD" "$RESET" "$CYAN" "$RESET" "$DIM" "$RESET"
	printf '  +---------+------+------+------+------+------+\n'
	printf '  | Row     | WGP0 | WGP1 | WGP2 | WGP3 | WGP4 |\n'
	printf '  |         | 0-1  | 2-3  | 4-5  | 6-7  | 8-9  |\n'
	printf '  +---------+------+------+------+------+------+\n'
	for idx in 0 1 2 3; do
		printf '  | %-7s |' "$(row_label "$idx")"
		for wgp in 0 1 2 3 4; do
			bit=$((1 << wgp))
			driver_on=0
			if [ "${driver_lock_ok:-0}" -eq 1 ] && [ $((driver_masks[idx] & bit)) -ne 0 ]; then
				driver_on=1
			fi
			if [ $((masks[idx] & bit)) -ne 0 ]; then
				if [ "$driver_on" -eq 1 ]; then
					cell="  D+  "
					style="$GREEN$BOLD"
				else
					cell="  S+  "
					style="$CYAN"
				fi
			else
				if [ "$driver_on" -eq 1 ]; then
					cell="  D!  "
					style="$RED$BOLD"
					blocked_total=$((blocked_total + 2))
				else
					cell="  --  "
					style="$DIM"
				fi
			fi
			if [ "$idx" -eq "$cursor_row" ] && [ "$wgp" -eq "$cursor_wgp" ]; then
				style="${REV}${style}"
			fi
			endstyle="$RESET"
			printf '%s%s%s|' "$style" "$cell" "$endstyle"
		done
		printf '\n'
	done
	printf '  +---------+------+------+------+------+------+\n\n'
	if [ "${driver_lock_ok:-0}" -ne 1 ]; then
		warn "driver topology is unavailable; apply is disabled to avoid unsafe live disables"
	elif [ "$blocked_total" -gt 0 ]; then
		warn "driver-active CUs are not routed by SPI (${blocked_total} CUs shown as D!)"
	fi
}

ensure_target_mask_preserves_driver() {
	local target_mask="$1" idx disabled
	local -a driver_masks
	read_driver_wgp_masks || die "driver topology unavailable; refusing to disable live dispatch"
	for idx in 0 1 2 3; do
		disabled=$((driver_masks[idx] & ~target_mask & 31))
		if [ "$disabled" -ne 0 ]; then
			die "refusing preset because it would disable driver-active WGPs on $(row_label "$idx") (mask $(hex_mask "$disabled"))"
		fi
	done
}

ensure_driver_active_wgps_remain_enabled() {
	local idx new_mask locked disabled
	[ "${driver_lock_ok:-0}" -eq 1 ] || die "driver topology unavailable; refusing to disable live dispatch"
	for idx in 0 1 2 3; do
		new_mask=$((masks[idx] & 31))
		locked=$((driver_masks[idx] & 31))
		disabled=$((locked & ~new_mask & 31))
		if [ "$disabled" -ne 0 ]; then
			die "refusing to disable driver-active WGPs on $(row_label "$idx") (mask $(hex_mask "$disabled"))"
		fi
	done
}

apply_spi_masks() {
	require_bc250_for_write
	ensure_driver_active_wgps_remain_enabled
	local -a current_masks target_masks
	read_current_masks
	target_masks=("${masks[@]}")
	confirm_dispatch_plan "Apply WGP Routing" || return 0
	apply_target_masks
}

apply_target_masks() {
	local idx se sh union=0
	if ! try_write_reg_global "$REG_CC" 0x0; then
		warn "could not write global $REG_CC; trying per-row CC clears"
	fi
	for idx in 0 1 2 3; do
		read -r se sh <<<"$(row_coords "$idx")"
		write_reg_bank "$REG_CC" 0x0 "$se" "$sh"
		write_reg_bank "$REG_SPI" "$(hex_mask "${target_masks[$idx]}")" "$se" "$sh"
		union=$((union | target_masks[idx]))
	done
	if ! try_write_reg_global "$REG_RLC" "$(hex_mask "$union")"; then
		warn "could not write $REG_RLC; continuing with SPI masks applied"
	fi
	info "dispatch registers updated ($(dispatch_total)/40 CUs target)"
}

table_editor() {
	need_umr_root table
	need_umr
	select_asic
	local -a masks driver_masks
	local driver_lock_ok=0
	local row=0 wgp=0 key rest bit
	read_spi_masks
	if read_driver_wgp_masks; then
		driver_lock_ok=1
	fi
	while true; do
		draw_wgp_table "$row" "$wgp"
		IFS= read -rsn1 key || return 0
		case "$key" in
			$'\x1b')
				IFS= read -rsn2 -t 0.1 rest || rest=""
				case "$rest" in
					'[A') row=$((row > 0 ? row - 1 : 3)) ;;
					'[B') row=$((row < 3 ? row + 1 : 0)) ;;
					'[C') wgp=$((wgp < 4 ? wgp + 1 : 0)) ;;
					'[D') wgp=$((wgp > 0 ? wgp - 1 : 4)) ;;
				esac
				;;
			h|H) wgp=$((wgp > 0 ? wgp - 1 : 4)) ;;
			l|L) wgp=$((wgp < 4 ? wgp + 1 : 0)) ;;
			k|K) row=$((row > 0 ? row - 1 : 3)) ;;
			j|J) row=$((row < 3 ? row + 1 : 0)) ;;
			' ')
				bit=$((1 << wgp))
				if [ "$driver_lock_ok" -ne 1 ]; then
					warn "driver topology is unavailable; toggles are locked"
					sleep 1
				elif [ $((driver_masks[row] & bit)) -ne 0 ] && [ $((masks[row] & bit)) -ne 0 ]; then
					warn "$(row_label "$row") WGP$wgp is active in driver topology and cannot be disabled live"
					sleep 1
				else
					masks[$row]=$((masks[row] ^ bit))
				fi
				;;
			''|$'\n'|$'\r'|a|A)
				apply_spi_masks
				pause_screen
				return 0
				;;
			q|Q)
				return 0
				;;
		esac
	done
}

parse_wgp_item() {
	local item="$1" se sh wgp extra
	IFS='.' read -r se sh wgp extra <<<"$item"
	[ -z "${extra:-}" ] || die "invalid WGP entry '$item' (expected SE.SH.WGP)"
	[[ "$se" =~ ^[0-1]$ ]] || die "invalid SE in '$item' (expected 0 or 1)"
	[[ "$sh" =~ ^[0-1]$ ]] || die "invalid SH in '$item' (expected 0 or 1)"
	[[ "$wgp" =~ ^[0-4]$ ]] || die "invalid WGP in '$item' (expected 0..4)"
	printf '%s %s %s\n' "$se" "$sh" "$wgp"
}

parse_cu_item() {
	local item="$1" se sh cu extra wgp
	IFS='.' read -r se sh cu extra <<<"$item"
	[ -z "${extra:-}" ] || die "invalid CU entry '$item' (expected SE.SH.CU)"
	[[ "$se" =~ ^[0-1]$ ]] || die "invalid SE in '$item' (expected 0 or 1)"
	[[ "$sh" =~ ^[0-1]$ ]] || die "invalid SH in '$item' (expected 0 or 1)"
	[[ "$cu" =~ ^[0-9]$ ]] || die "invalid CU in '$item' (expected 0..9)"
	wgp=$((cu / 2))
	printf '%s %s %s\n' "$se" "$sh" "$wgp"
}

modify_wgps() {
	local op="$1" mode="$2"
	shift 2
	need_root
	need_umr
	select_asic
	require_bc250_for_write
	local -a current_masks target_masks driver_masks
	read_current_masks
	target_masks=("${current_masks[@]}")
	read_driver_wgp_masks || [ "$op" = "enable" ] || die "driver topology unavailable; refusing to disable live dispatch"
	local item se sh wgp parsed idx=0
	local -a target_se target_sh target_wgp
	for item in "$@"; do
		if [ "$mode" = "cu" ]; then
			parsed="$(parse_cu_item "$item")"
		else
			parsed="$(parse_wgp_item "$item")"
		fi
		read -r se sh wgp <<<"$parsed"
		if [ "$op" = "disable" ] && [ $((driver_masks[se * 2 + sh] & (1 << wgp))) -ne 0 ]; then
			die "refusing to disable SE$se SH$sh WGP$wgp; it is active in driver topology"
		fi
		if [ "$op" = "enable" ]; then
			target_masks[$((se * 2 + sh))]=$((target_masks[se * 2 + sh] | (1 << wgp)))
		else
			target_masks[$((se * 2 + sh))]=$((target_masks[se * 2 + sh] & ~(1 << wgp)))
		fi
		target_se[$idx]="$se"
		target_sh[$idx]="$sh"
		target_wgp[$idx]="$wgp"
		idx=$((idx + 1))
	done
	confirm_dispatch_plan "Apply WGP Changes" || return 0
	for idx in "${!target_wgp[@]}"; do
		se="${target_se[$idx]}"
		sh="${target_sh[$idx]}"
		wgp="${target_wgp[$idx]}"
		info "${op}d SE$se SH$sh WGP$wgp (CU$((wgp * 2))-CU$((wgp * 2 + 1)))"
	done
	apply_target_masks
}

enable_all() {
	need_root
	need_umr
	select_asic
	require_bc250_for_write
	local -a current_masks target_masks driver_masks
	read_current_masks
	read_driver_wgp_masks || true
	target_masks=("$WGP_FULL_MASK" "$WGP_FULL_MASK" "$WGP_FULL_MASK" "$WGP_FULL_MASK")
	confirm_dispatch_plan "Enable Full Dispatch" || return 0
	apply_target_masks
}

disable_all() {
	need_root
	need_umr
	select_asic
	require_bc250_for_write
	ensure_target_mask_preserves_driver 0
	local -a current_masks target_masks driver_masks
	read_current_masks
	read_driver_wgp_masks || die "driver topology unavailable; refusing to disable live dispatch"
	target_masks=(0 0 0 0)
	confirm_dispatch_plan "Disable Dispatch" || return 0
	apply_target_masks
}

stock_dispatch() {
	need_root
	need_umr
	select_asic
	require_bc250_for_write
	local -a current_masks target_masks driver_masks
	read_driver_wgp_masks || die "driver topology unavailable; cannot restore boot dispatch mask"
	read_current_masks
	target_masks=("${driver_masks[@]}")
	confirm_dispatch_plan "Restore Driver Dispatch" || return 0
	apply_target_masks
}

apply_service() {
	need_root
	need_umr
	select_asic
	require_bc250_for_write
	local -a current_masks target_masks service_masks
	load_service_masks || die "service profile not found or invalid at $SERVICE_CONF; run write-service-table to save the current table"
	read_current_masks
	target_masks=("${service_masks[@]}")
	confirm_dispatch_plan "Apply Saved Service Table" || return 0
	apply_target_masks
}

interactive_menu() {
	while true; do
		print_menu
		if ! offer_umr_install_from_menu; then
			continue
		fi
		prompt_line "Select action: "
		read -r opt
		case "$opt" in
			e|E) table_editor ;;
			f|F) clear_screen; enable_all; pause_screen ;;
			t|T) clear_screen; stock_dispatch; pause_screen ;;
			i|I) clear_screen; install_service; pause_screen ;;
			w|W) clear_screen; write_service_table; pause_screen ;;
			u|U) clear_screen; uninstall_service; pause_screen ;;
			q|Q) exit 0 ;;
			*) warn "unknown option: $opt" ;;
		esac
	done
}

main() {
	local args=()
	while [ "$#" -gt 0 ]; do
		case "$1" in
			-y|--yes) YES=1; shift ;;
			-n|--dry-run) DRY_RUN=1; YES=1; shift ;;
			-i|--umr-instance)
				[ "${2:-}" != "" ] || die "$1 requires an argument"
				validate_umr_instance "$2" || die "invalid --umr-instance '$2' (expected non-negative integer)"
				UMR_INSTANCE="$2"
				UMR_INSTANCE_SOURCE="cli"
				shift 2
				;;
			--umr-instance=*)
				UMR_INSTANCE="${1#*=}"
				validate_umr_instance "$UMR_INSTANCE" || die "invalid --umr-instance '$UMR_INSTANCE' (expected non-negative integer)"
				UMR_INSTANCE_SOURCE="cli"
				shift
				;;
			--force) FORCE=1; shift ;;
			-h|--help) usage; exit 0 ;;
			*) args+=("$1"); shift ;;
		esac
	done
	set -- "${args[@]}"

	local cmd="${1:-menu}"
	shift || true
	case "$cmd" in
		status) status ;;
		table) table_editor ;;
		install-umr) install_umr ;;
		install-service) install_service ;;
		write-service-table) write_service_table ;;
		apply-service) apply_service ;;
		uninstall-service) uninstall_service ;;
		menu) interactive_menu ;;
		enable)
			case "${1:-}" in
				all) enable_all ;;
				"") die "enable requires 'all' or WGP entries; see --help" ;;
				*) modify_wgps enable wgp "$@" ;;
			esac
			;;
		disable)
			case "${1:-}" in
				all) disable_all ;;
				"") die "disable requires 'all' or WGP entries; see --help" ;;
				*) modify_wgps disable wgp "$@" ;;
			esac
			;;
		enable-wgp) [ "$#" -gt 0 ] || die "enable-wgp requires SE.SH.WGP entries"; modify_wgps enable wgp "$@" ;;
		disable-wgp) [ "$#" -gt 0 ] || die "disable-wgp requires SE.SH.WGP entries"; modify_wgps disable wgp "$@" ;;
		enable-cu) [ "$#" -gt 0 ] || die "enable-cu requires SE.SH.CU entries"; modify_wgps enable cu "$@" ;;
		disable-cu) [ "$#" -gt 0 ] || die "disable-cu requires SE.SH.CU entries"; modify_wgps disable cu "$@" ;;
		stock-dispatch) stock_dispatch ;;
		*) usage; die "unknown command: $cmd" ;;
	esac
}

main "$@"
