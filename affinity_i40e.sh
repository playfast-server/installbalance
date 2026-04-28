#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2015 - 2023 Intel Corporation
#
# Affinitize interrupts to cores
#
# typical usage is (as root):
# set_irq_affinity -x local eth1 <eth2> <eth3>
# set_irq_affinity -s eth1
#
# to get help:
# set_irq_affinity
#
# MODIFIED: Reads /etc/default/grub (and /proc/cmdline) and automatically
# restricts ALL affinity operations (smp_affinity, XPS) to housekeeping CPUs.
# Isolated CPUs (isolcpus / nohz_full / rcu_nocbs) are NEVER touched and
# NEVER receive IRQs/XPS.
#
# Housekeeping set is determined as:
#   1) irqaffinity= from cmdline if present, else
#   2) online CPUs MINUS isolated CPUs.

usage()
{
	echo
	echo "Usage: option -s <interface> to show current settings only"
	echo "Usage: $0 [-x|-X] [all|local|remote [<node>]|one <core>|custom|<cores>] <interface> ..."
	echo "	Options: "
	echo "	  -s		Shows current affinity settings"
	echo "	  -x		Configure XPS as well as smp_affinity"
	echo "	  -X		Disable XPS but set smp_affinity"
	echo "	  [all] is the default value"
	echo "	  [remote [<node>]] can be followed by a specific node number"
	echo "	Examples:"
	echo "	  $0 -s eth1            # Show settings on eth1"
	echo "	  $0 all eth1 eth2      # eth1 and eth2 to all IRQ-pool cores"
	echo "	  $0 one 2 eth1         # eth1 to core 2 only (must be in IRQ pool)"
	echo "	  $0 local eth1         # eth1 to local IRQ-pool cores only"
	echo "	  $0 remote eth1        # eth1 to remote IRQ-pool cores only"
	echo "	  $0 custom eth1        # prompt for eth1 interface"
	echo "	  $0 0-7,16-23 eth0     # eth0 to (0-7,16-23) ∩ IRQ-pool"
	echo
	echo "  Operating modes (auto-detected from /etc/default/grub):"
	echo "    SPLIT       (housekeeping >=2): IRQ -> housekeeping, XPS -> isolated"
	echo "    RESERVE_ONE (housekeeping ==1): IRQ + XPS -> online minus reserved CPU"
	echo "    NORMAL      (housekeeping ==0): IRQ + XPS -> all online cores"
	echo
	exit 1
}

usageX()
{
	echo "options -x and -X cannot both be specified, pick one"
	exit 1
}

if [ "$1" == "-x" ]; then
	XPS_ENA=1
	shift
fi

if [ "$1" == "-s" ]; then
	SHOW=1
	echo Show affinity settings
	shift
fi

if [ "$1" == "-X" ]; then
	if [ -n "$XPS_ENA" ]; then
		usageX
	fi
	XPS_DIS=2
	shift
fi

if [ "$1" == -x ]; then
	usageX
fi

if [ -n "$XPS_ENA" ] && [ -n "$XPS_DIS" ]; then
	usageX
fi

if [ -z "$XPS_ENA" ]; then
	XPS_ENA=$XPS_DIS
fi

SED=`which sed`
if [[ ! -x $SED ]]; then
	echo " $0: ERROR: sed not found in path, this script requires sed"
	exit 1
fi

num='^[0-9]+$'

# search helpers
NOZEROCOMMA="s/^[0,]*//"

# ============================================================
# GRUB / housekeeping CPU detection
# ============================================================

# Expand "0-3,8,10-11" (possibly with non-numeric prefix tokens like
# "managed_irq,domain,2-15,34-47") into a space-separated list of CPUs.
parse_range_to_list()
{
	local input="$1"
	local cleaned="" tok
	local OLDIFS="$IFS"
	IFS=','
	for tok in $input; do
		if [[ $tok =~ ^[0-9]+(-[0-9]+)?$ ]]; then
			cleaned+="${tok},"
		fi
	done
	IFS="$OLDIFS"
	cleaned="${cleaned%,}"
	[ -z "$cleaned" ] && return

	local RANGE LIST r
	RANGE=${cleaned//,/ }
	RANGE=${RANGE//-/..}
	LIST=""
	for r in $RANGE; do
		# If $r contains "..", expand the brace range; else use as-is.
		if [[ "$r" == *..* ]]; then
			r="$(eval echo {$r})"
		fi
		LIST+=" $r"
	done
	echo $LIST
}

# Extract value of param=VALUE from a cmdline string.
extract_param()
{
	local cmdline="$1"
	local param="$2"
	local val
	val=$(echo "$cmdline" | grep -oE "(^|[[:space:]\"])${param}=[^[:space:]\"]+" | head -n1 | sed -E "s/.*${param}=//")
	echo "$val"
}

# Strip a single layer of matching outer quotes (single OR double) from a
# string. Used for parsing GRUB_CMDLINE_* values which may be quoted either way.
strip_outer_quotes()
{
	local s="$1"
	# Double-quoted
	if [[ "$s" =~ ^\".*\"$ ]]; then
		s="${s#\"}"
		s="${s%\"}"
	# Single-quoted
	elif [[ "$s" =~ ^\'.*\'$ ]]; then
		s="${s#\'}"
		s="${s%\'}"
	fi
	echo "$s"
}

# Read kernel cmdline. Prefers /etc/default/grub (the file the user pointed us
# to), falls back to /proc/cmdline if the file is missing or unparseable.
# Warns if both exist and disagree on isolation parameters.
read_kernel_cmdline()
{
	local grub_cmdline="" raw_def raw_lin def lin
	if [ -r /etc/default/grub ]; then
		raw_def=$(grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | tail -n1 | sed -E 's/^[^=]*=//')
		raw_lin=$(grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX=' /etc/default/grub | tail -n1 | sed -E 's/^[^=]*=//')
		def=$(strip_outer_quotes "$raw_def")
		lin=$(strip_outer_quotes "$raw_lin")
		grub_cmdline="$def $lin"
	fi

	# Trim
	grub_cmdline="$(echo "$grub_cmdline" | tr -s ' ' | sed -E 's/^ +| +$//g')"

	if [ -n "$grub_cmdline" ]; then
		echo "$grub_cmdline"
	elif [ -r /proc/cmdline ]; then
		cat /proc/cmdline
	fi
}

# If both /etc/default/grub and /proc/cmdline are readable, compare the
# isolation-related parameters and print a warning to stderr on mismatch.
# This catches the case where the user edited grub but did not yet
# update-grub + reboot.
warn_on_grub_proc_divergence()
{
	[ -r /etc/default/grub ] || return 0
	[ -r /proc/cmdline ]     || return 0

	local grub_cl proc_cl
	local raw_def raw_lin def lin
	raw_def=$(grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | tail -n1 | sed -E 's/^[^=]*=//')
	raw_lin=$(grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX=' /etc/default/grub | tail -n1 | sed -E 's/^[^=]*=//')
	def=$(strip_outer_quotes "$raw_def")
	lin=$(strip_outer_quotes "$raw_lin")
	grub_cl="$def $lin"
	proc_cl=$(cat /proc/cmdline)

	local p
	local mismatch=0
	for p in isolcpus nohz_full rcu_nocbs irqaffinity; do
		local g_v r_v
		g_v=$(extract_param "$grub_cl" "$p")
		r_v=$(extract_param "$proc_cl" "$p")
		if [ "$g_v" != "$r_v" ]; then
			if [ $mismatch -eq 0 ]; then
				echo "WARNING: /etc/default/grub and /proc/cmdline disagree on isolation params." >&2
				echo "         You may have edited grub but not yet run update-grub + reboot." >&2
				mismatch=1
			fi
			echo "         $p: grub='$g_v' running='$r_v'" >&2
		fi
	done
	if [ $mismatch -eq 1 ]; then
		echo "         This script will use the values from /etc/default/grub." >&2
		echo "" >&2
	fi
}

# Compute housekeeping CPUs and isolated CPUs.
# Sets globals: HOUSEKEEPING_CORES, ISOLATED_CORES (both space-separated)
#               MANAGED_IRQ_FLAG (1 if isolcpus contains "managed_irq")
detect_housekeeping_cpus()
{
	# Warn if grub file and running kernel disagree.
	warn_on_grub_proc_divergence

	local cmdline
	cmdline=$(read_kernel_cmdline)

	if [ -z "$cmdline" ]; then
		echo "ERROR: Could not read kernel cmdline from /etc/default/grub or /proc/cmdline."
		exit 3
	fi

	local online online_list
	online=$(</sys/devices/system/cpu/online 2>/dev/null)
	if [ -z "$online" ]; then
		# Fallback: build "0,1,2,..,N-1" from cpuinfo
		online=$(grep ^processor /proc/cpuinfo | awk '{print $NF}' | paste -sd,)
	fi
	online_list=$(parse_range_to_list "$online")

	if [ -z "$online_list" ]; then
		echo "ERROR: Could not determine online CPUs."
		exit 3
	fi

	local p_isolcpus p_nohz p_rcunocbs p_irqaff
	p_isolcpus=$(extract_param "$cmdline" "isolcpus")
	p_nohz=$(extract_param "$cmdline" "nohz_full")
	p_rcunocbs=$(extract_param "$cmdline" "rcu_nocbs")
	p_irqaff=$(extract_param "$cmdline" "irqaffinity")

	# Detect "managed_irq" flag in isolcpus — relevant because for IRQs
	# marked managed by the kernel (modern mlx5/i40e/ice MSI-X), writes
	# to /proc/irq/*/smp_affinity are silently ignored by the kernel.
	MANAGED_IRQ_FLAG=0
	if [[ ",$p_isolcpus," == *",managed_irq,"* ]]; then
		MANAGED_IRQ_FLAG=1
	fi

	local isolated_list=""
	isolated_list+=" $(parse_range_to_list "$p_isolcpus")"
	isolated_list+=" $(parse_range_to_list "$p_nohz")"
	isolated_list+=" $(parse_range_to_list "$p_rcunocbs")"
	# Intersect isolated set with online (a CPU offlined by hotplug isn't
	# really "isolated" for our purposes — and writing to its mask fails).
	local isolated_clean="" x o
	for x in $(echo $isolated_list | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un); do
		for o in $online_list; do
			if [ "$x" = "$o" ]; then
				isolated_clean+=" $x"
				break
			fi
		done
	done
	ISOLATED_CORES=$(echo $isolated_clean | tr ' ' '\n' | sort -un | tr '\n' ' ')
	# Normalize trailing whitespace so [ -n "$ISOLATED_CORES" ] works correctly.
	ISOLATED_CORES="$(echo $ISOLATED_CORES)"

	local hk_list=""
	if [ -n "$p_irqaff" ]; then
		# irqaffinity= explicitly given: that's the housekeeping set.
		local irqaff_list c
		irqaff_list=$(parse_range_to_list "$p_irqaff")
		for c in $irqaff_list; do
			for o in $online_list; do
				if [ "$c" = "$o" ]; then
					hk_list+=" $c"
					break
				fi
			done
		done
	elif [ -n "$ISOLATED_CORES" ]; then
		# No irqaffinity= but some isolation params (isolcpus/nohz_full/rcu_nocbs)
		# are set: derive housekeeping = online MINUS isolated.
		local skip
		for o in $online_list; do
			skip=0
			for x in $ISOLATED_CORES; do
				if [ "$o" = "$x" ]; then
					skip=1
					break
				fi
			done
			[ $skip -eq 0 ] && hk_list+=" $o"
		done
	fi
	# else: neither irqaffinity= nor any isolation params -> hk_list stays empty,
	#       which triggers NORMAL mode (use all online, original Intel behaviour).

	HOUSEKEEPING_CORES=$(echo $hk_list | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')
	# Normalize trailing whitespace.
	HOUSEKEEPING_CORES="$(echo $HOUSEKEEPING_CORES)"

	# Empty housekeeping is OK — it triggers NORMAL mode below
	# (matches the original Intel script behaviour).

	# Sanity check: HOUSEKEEPING and ISOLATED must be disjoint.
	local hk i_cpu bad=""
	for hk in $HOUSEKEEPING_CORES; do
		for i_cpu in $ISOLATED_CORES; do
			if [ "$hk" = "$i_cpu" ]; then
				bad+=" $hk"
				break
			fi
		done
	done
	if [ -n "$bad" ]; then
		echo "ERROR: housekeeping and isolated sets overlap on CPUs: [$(echo $bad | tr ' ' ',')]"
		echo "       This usually means irqaffinity= and isolcpus= contradict each other in GRUB."
		exit 3
	fi

	# Trim trailing whitespace for clean display
	HOUSEKEEPING_CORES="$(echo $HOUSEKEEPING_CORES)"
	ISOLATED_CORES="$(echo $ISOLATED_CORES)"
	ONLINE_CORES="$(echo $online_list)"

	# ============================================================
	# Determine operating MODE based on the housekeeping CPU count.
	# This drives how IRQ_POOL and XPS_POOL are populated below.
	#
	#   SPLIT       : 2+ housekeeping CPUs.
	#                 IRQ -> housekeeping
	#                 XPS -> isolated (excluding housekeeping)
	#
	#   RESERVE_ONE : exactly 1 housekeeping CPU.
	#                 The single housekeeping CPU is reserved for the kernel.
	#                 IRQ -> all online MINUS the reserved CPU
	#                 XPS -> all online MINUS the reserved CPU (same set as IRQ)
	#
	#   NORMAL      : 0 housekeeping CPUs (no irqaffinity= set, or
	#                 online minus isolcpus = empty).
	#                 IRQ -> all online cores
	#                 XPS -> all online cores
	#                 This matches the original Intel script behaviour.
	# ============================================================
	local hk_count
	hk_count=$(echo $HOUSEKEEPING_CORES | wc -w)

	if [ "$hk_count" -ge 2 ]; then
		MODE="SPLIT"
		IRQ_POOL="$HOUSEKEEPING_CORES"
		XPS_POOL="$ISOLATED_CORES"
	elif [ "$hk_count" -eq 1 ]; then
		MODE="RESERVE_ONE"
		# Build (online - housekeeping) — note housekeeping has 1 CPU here.
		local reserved="$HOUSEKEEPING_CORES" pool="" o is_reserved r
		for o in $ONLINE_CORES; do
			is_reserved=0
			for r in $reserved; do
				[ "$o" = "$r" ] && is_reserved=1 && break
			done
			[ $is_reserved -eq 0 ] && pool+=" $o"
		done
		IRQ_POOL="$(echo $pool)"
		XPS_POOL="$IRQ_POOL"
	else
		MODE="NORMAL"
		IRQ_POOL="$ONLINE_CORES"
		XPS_POOL="$ONLINE_CORES"
	fi

	echo "GRUB-aware mode active"
	case "$MODE" in
	SPLIT)
		echo "  MODE: SPLIT (housekeeping has $hk_count CPUs)"
		echo "    IRQ smp_affinity -> housekeeping CPUs : [$(echo $IRQ_POOL | tr ' ' ',')]"
		echo "    XPS xps_cpus     -> isolated    CPUs : [$(echo $XPS_POOL | tr ' ' ',')]"
	;;
	RESERVE_ONE)
		echo "  MODE: RESERVE_ONE (housekeeping has 1 CPU; reserving it)"
		echo "    Reserved CPU (no IRQ, no XPS): [$HOUSEKEEPING_CORES]"
		echo "    IRQ smp_affinity -> [$(echo $IRQ_POOL | tr ' ' ',')]"
		echo "    XPS xps_cpus     -> [$(echo $XPS_POOL | tr ' ' ',')]"
	;;
	NORMAL)
		echo "  MODE: NORMAL (no housekeeping CPUs detected)"
		echo "    IRQ smp_affinity -> all online: [$(echo $IRQ_POOL | tr ' ' ',')]"
		echo "    XPS xps_cpus     -> all online: [$(echo $XPS_POOL | tr ' ' ',')]"
	;;
	esac
	if [ "$MANAGED_IRQ_FLAG" = "1" ]; then
		echo "  NOTE: isolcpus contains 'managed_irq'. For managed MSI-X IRQs"
		echo "        (modern mlx5/i40e/ice), writes to smp_affinity are ignored"
		echo "        by the kernel — affinity is auto-managed. This script will"
		echo "        still try to write the mask; failures are expected and the"
		echo "        existing 'SMP_AFFINITY setting failed' warning will fire."
	fi
	echo
}

# Filter a space-separated CPU list, keeping only CPUs that are in
# the given pool (space-separated CPU list). Used as a defense-in-depth
# check before applying any IRQ/XPS settings.
filter_to_pool()
{
	local in="$1" pool="$2"
	local out="" c p ok
	for c in $in; do
		ok=0
		for p in $pool; do
			if [ "$c" = "$p" ]; then
				ok=1
				break
			fi
		done
		[ $ok -eq 1 ] && out+=" $c"
	done
	echo $out
}

# Test if a given CPU number is in an arbitrary space-separated pool.
_in_pool()
{
	local c="$1" pool="$2" p
	for p in $pool; do
		[ "$c" = "$p" ] && return 0
	done
	return 1
}

# Intersect: returns CPUs that appear in BOTH lists.
#   $1 = space-separated list (e.g. "0 1 32 33")
#   $2 = either cpulist-style range ("0-15,32-47") OR space-separated
#        ("0 1 32 33"). Both work.
intersect()
{
	local L1="$1" L2="$2" out=""
	# Normalize L2: convert spaces to commas, then expand via parse_range_to_list.
	# This handles both "0-15,32-47" and "0 1 32 33" inputs.
	local L2_normalized
	L2_normalized=$(echo $L2 | tr ' ' ',')
	local L2_expanded
	L2_expanded=$(parse_range_to_list "$L2_normalized")
	local a b
	for a in $L1; do
		for b in $L2_expanded; do
			if [ "$a" = "$b" ]; then
				out+=" $a"
				break
			fi
		done
	done
	echo $out
}

detect_housekeeping_cpus
# ============================================================
# end housekeeping detection
# ============================================================

# Vars
AFF=$1
shift

case "$AFF" in
    remote)	[[ $1 =~ $num ]] && rnode=$1 && shift ;;
    one)	[[ $1 =~ $num ]] && cnt=$1 && shift || { echo "ERROR: 'one' mode requires a numeric core argument"; exit 1; } ;;
    all)	;;
    local)	;;
    custom)	;;
    [0-9]*)	;;
    -h|--help)	usage ;;
    "")		usage ;;
    *)		IFACES=$AFF && AFF=all ;;	# Backwards compat mode
esac

# append the interfaces listed to the string with spaces
while [ "$#" -ne "0" ] ; do
	IFACES+=" $1"
	shift
done

# for now the user must specify interfaces
if [ -z "$IFACES" ]; then
	usage
	exit 2
fi

notfound()
{
	echo $MYIFACE: not found
	exit 15
}

# check the interfaces exist (use sysfs, avoids substring matches like
# 'eth0' matching 'veth0' or 'eth00' in /proc/net/dev)
for MYIFACE in $IFACES; do
	if [ ! -d "/sys/class/net/$MYIFACE" ]; then
		notfound
	fi
done

# support functions

build_mask()
{
	# Defensive: refuse non-numeric or negative core
	if ! [[ "$core" =~ ^[0-9]+$ ]]; then
		echo "ERROR: build_mask called with non-numeric core='$core'" >&2
		MASK=0
		return
	fi

	VEC=$core
	if [ $VEC -ge 32 ]
	then
		MASK_FILL=""
		MASK_ZERO="00000000"
		let "IDX = $VEC / 32"
		for ((i=1; i<=$IDX;i++))
		do
			MASK_FILL="${MASK_FILL},${MASK_ZERO}"
		done

		let "VEC -= 32 * $IDX"
		MASK_TMP=$((1<<$VEC))
		MASK=$(printf "%X%s" $MASK_TMP $MASK_FILL)
	else
		MASK_TMP=$((1<<$VEC))
		MASK=$(printf "%X" $MASK_TMP)
	fi
}

# Build a cpumask string (Linux smp_affinity / xps_cpus format) from a
# space-separated list of CPU numbers. Outputs to stdout.
# Format: 32-bit hex groups separated by commas, MSB first.
# E.g. cpus "0 1 32"  -> "1,00000003"
#      cpus "2-15"    -> "0000fffc"
build_mask_list()
{
	local cpus="$1"
	[ -z "$cpus" ] && { echo "0"; return; }

	# Find highest CPU to size the bitmap
	local max=0 c
	for c in $cpus; do
		[[ "$c" =~ ^[0-9]+$ ]] || continue
		[ "$c" -gt "$max" ] && max=$c
	done

	# Number of 32-bit groups needed
	local ngroups=$(( max / 32 + 1 ))

	# Initialize bitmap as array of 32-bit unsigned ints
	local -a bits
	local g
	for ((g=0; g<ngroups; g++)); do
		bits[g]=0
	done

	# Set bits
	for c in $cpus; do
		[[ "$c" =~ ^[0-9]+$ ]] || continue
		local grp=$(( c / 32 ))
		local off=$(( c % 32 ))
		bits[grp]=$(( bits[grp] | (1 << off) ))
	done

	# Print MSB first, comma-separated, no leading zeros except within group.
	# To match the kernel's expected format (e.g. "1,00000003"), each group
	# is 8 hex digits, but leading groups can drop leading zeros.
	local out=""
	local first=1
	for ((g=ngroups-1; g>=0; g--)); do
		if [ $first -eq 1 ]; then
			out=$(printf "%X" "${bits[g]}")
			first=0
		else
			out=$(printf "%s,%08X" "$out" "${bits[g]}")
		fi
	done
	echo "$out"
}

show_affinity()
{
	# returns the MASK variable
	build_mask

	SMP_I=`sed -E "${NOZEROCOMMA}" /proc/irq/$IRQ/smp_affinity`
	HINT=`sed -E "${NOZEROCOMMA}" /proc/irq/$IRQ/affinity_hint`
	printf "ACTUAL	%s %d %s <- /proc/irq/$IRQ/smp_affinity\n" $IFACE $core $SMP_I
	printf "HINT 	%s %d %s <- /proc/irq/$IRQ/affinity_hint\n" $IFACE $core $HINT
	IRQ_CHECK=`grep '[-,]' /proc/irq/$IRQ/smp_affinity_list`
	if [ ! -z $IRQ_CHECK ]; then
		printf " WARNING -- SMP_AFFINITY is assigned to multiple cores $IRQ_CHECK\n"
	fi
	if [ "$SMP_I" != "$HINT" ]; then
		printf " WARNING -- SMP_AFFINITY VALUE does not match AFFINITY_HINT \n"
	fi
	printf "NODE 	%s %d %s <- /proc/irq/$IRQ/node\n" $IFACE $core `cat /proc/irq/$IRQ/node`
	printf "LIST	%s %d [%s] <- /proc/irq/$IRQ/smp_affinity_list\n" $IFACE $core `cat /proc/irq/$IRQ/smp_affinity_list`

	# Skip per-queue sysfs reads if we're past the actual queue count.
	if [ "$qidx" -ge "$num_tx_queues" ]; then
		printf "SKIP	%s qidx=%d (no tx-%d queue; %d TX queues exist)\n" $IFACE $qidx $qidx $num_tx_queues
		echo
		return
	fi

	printf "XPS	%s %d %s <- /sys/class/net/%s/queues/tx-%d/xps_cpus\n" $IFACE $core `cat /sys/class/net/$IFACE/queues/tx-$qidx/xps_cpus` $IFACE $qidx
	if [ -z `ls /sys/class/net/$IFACE/queues/tx-$qidx/xps_rxqs 2>/dev/null` ]; then
		echo "WARNING: xps rxqs not supported on $IFACE"
	else
		printf "XPSRXQs	%s %d %s <- /sys/class/net/%s/queues/tx-%d/xps_rxqs\n" $IFACE $core `cat /sys/class/net/$IFACE/queues/tx-$qidx/xps_rxqs` $IFACE $qidx
	fi
	printf "TX_MAX	%s %d %s <- /sys/class/net/%s/queues/tx-%d/tx_maxrate\n" $IFACE $core `cat /sys/class/net/$IFACE/queues/tx-$qidx/tx_maxrate` $IFACE $qidx
	printf "BQLIMIT	%s %d %s <- /sys/class/net/%s/queues/tx-%d/byte_queue_limits/limit\n" $IFACE $core `cat /sys/class/net/$IFACE/queues/tx-$qidx/byte_queue_limits/limit` $IFACE $qidx
	printf "BQL_MAX	%s %d %s <- /sys/class/net/%s/queues/tx-%d/byte_queue_limits/limit_max\n" $IFACE $core `cat /sys/class/net/$IFACE/queues/tx-$qidx/byte_queue_limits/limit_max` $IFACE $qidx
	printf "BQL_MIN	%s %d %s <- /sys/class/net/%s/queues/tx-%d/byte_queue_limits/limit_min\n" $IFACE $core `cat /sys/class/net/$IFACE/queues/tx-$qidx/byte_queue_limits/limit_min` $IFACE $qidx

	# RX side — bounds-check against num_rx_queues separately.
	if [ "$qidx" -ge "$num_rx_queues" ]; then
		echo
		return
	fi
	if [ -z `ls /sys/class/net/$IFACE/queues/rx-$qidx/rps_flow_cnt 2>/dev/null` ]; then
		echo "WARNING: aRFS is not supported on $IFACE"
	else
		printf "RPSFCNT	%s %d %s <- /sys/class/net/%s/queues/rx-%d/rps_flow_cnt\n" $IFACE $core `cat /sys/class/net/$IFACE/queues/rx-$qidx/rps_flow_cnt` $IFACE $qidx
	fi
	if [ -z `ls /sys/class/net/$IFACE/queues/rx-$qidx/rps_cpus 2>/dev/null` ]; then
		echo "WARNING: rps_cpus is not available on $IFACE"
	else
		printf "RPSCPU	%s %d %s <- /sys/class/net/%s/queues/rx-%d/rps_cpus\n" $IFACE $core `cat /sys/class/net/$IFACE/queues/rx-$qidx/rps_cpus` $IFACE $qidx
	fi
	echo
}

set_affinity()
{
	# Safety net: never apply IRQ to a CPU outside the IRQ pool for this MODE.
	if ! _in_pool "$core" "$IRQ_POOL"; then
		printf " SKIP\t%s IRQ=%s core=%d (not in IRQ pool: %s)\n" $IFACE $IRQ $core "$MODE"
		return
	fi

	# returns the MASK variable (mask for the IRQ core)
	build_mask

	printf "%s" $MASK > /proc/irq/$IRQ/smp_affinity
	printf "%s %d %s -> /proc/irq/$IRQ/smp_affinity\n" $IFACE $core $MASK
	SMP_I=`sed -E "${NOZEROCOMMA}" /proc/irq/$IRQ/smp_affinity`
	if [ "$SMP_I" != "$MASK" ]; then
		printf " ACTUAL\t%s %d %s <- /proc/irq/$IRQ/smp_affinity\n" $IFACE $core $SMP_I
		printf " WARNING -- SMP_AFFINITY setting failed\n"
	fi

	# XPS: only write if a corresponding tx queue exists in sysfs.
	if [ "$qidx" -ge "$num_tx_queues" ]; then
		case "$XPS_ENA" in
		1|2)
			printf " SKIP\t%s IRQ=%s qidx=%d (no tx-%d queue; only %d TX queues exist)\n" \
				$IFACE $IRQ $qidx $qidx $num_tx_queues
		;;
		esac
		return
	fi

	# Pick the XPS CPU(s) for this TX queue.
	# Round-robin across XPS_CORES, indexed by qidx so each queue gets a
	# distinct XPS-pool CPU (wrapping when nxps < num_tx_queues).
	local XPS_MASK XPS_CORE_PICKED
	if [ -z "$(echo $XPS_CORES)" ]; then
		# No XPS pool available for this iface/flag combination.
		case "$MODE" in
		NORMAL)
			# Match the original Intel script's behaviour: XPS to the IRQ core.
			XPS_CORE_PICKED="$core"
			XPS_MASK="$MASK"
		;;
		SPLIT|RESERVE_ONE)
			# Refuse to put XPS on a housekeeping/reserved CPU.
			# Skip XPS for this queue entirely.
			case "$XPS_ENA" in
			1|2)
				printf " SKIP\t%s qidx=%d (no XPS pool available in %s mode; refusing to write XPS to non-XPS CPU)\n" \
					$IFACE $qidx "$MODE"
			;;
			esac
			return
		;;
		esac
	else
		# Convert XPS_CORES to an array; pick by qidx mod count.
		local -a xps_arr
		local i_arr=0 c
		for c in $XPS_CORES; do
			xps_arr[i_arr]="$c"
			((i_arr++))
		done
		local nxps=${#xps_arr[@]}
		local pick=$(( qidx % nxps ))
		XPS_CORE_PICKED="${xps_arr[pick]}"
		XPS_MASK=$(build_mask_list "$XPS_CORE_PICKED")
	fi

	case "$XPS_ENA" in
	1)
		printf "%s %d %s -> /sys/class/net/%s/queues/tx-%d/xps_cpus\n" \
			$IFACE $XPS_CORE_PICKED $XPS_MASK $IFACE $qidx
		printf "%s" $XPS_MASK > /sys/class/net/$IFACE/queues/tx-$qidx/xps_cpus
	;;
	2)
		XPS_MASK=0
		printf "%s %d %s -> /sys/class/net/%s/queues/tx-%d/xps_cpus\n" \
			$IFACE $XPS_CORE_PICKED $XPS_MASK $IFACE $qidx
		printf "%s" $XPS_MASK > /sys/class/net/$IFACE/queues/tx-$qidx/xps_cpus
	;;
	*)
	esac
}

# Allow usage of , or -
#
parse_range () {
        RANGE=${@//,/ }
        RANGE=${RANGE//-/..}
        LIST=""
        for r in $RANGE; do
		# eval lets us use vars in {#..#} range
                [[ $r =~ '..' ]] && r="$(eval echo {$r})"
		LIST+=" $r"
        done
	echo $LIST
}

# Affinitize interrupts
#
doaff()
{
	CORES=$(parse_range $CORES)

	# Hard filter: drop any CPU not in the IRQ pool for this MODE.
	local CORES_BEFORE="$CORES"
	CORES=$(filter_to_pool "$CORES" "$IRQ_POOL")

	if [ -z "$CORES" ]; then
		echo "ERROR: After filtering against IRQ pool, no usable cores remain for $IFACE"
		echo "       requested cores : [$CORES_BEFORE]"
		echo "       IRQ pool ($MODE): [$(echo $IRQ_POOL | tr ' ' ',')]"
		return
	fi

	# Report any drops
	local dropped="" c k kept
	for c in $CORES_BEFORE; do
		kept=0
		for k in $CORES; do
			[ "$c" = "$k" ] && kept=1 && break
		done
		[ $kept -eq 0 ] && dropped+=" $c"
	done
	if [ -n "$dropped" ]; then
		echo "  $IFACE: dropped cores [$(echo $dropped | tr ' ' ',')] (not in IRQ pool)"
	fi

	# Report which cores will receive IRQ and XPS for this iface
	if [ "$XPS_ENA" = "1" ]; then
		echo "  $IFACE: IRQ -> [$(echo $CORES | tr ' ' ',')]"
		if [ -n "$XPS_CORES" ]; then
			echo "  $IFACE: XPS -> [$(echo $XPS_CORES | tr ' ' ',')]"
		else
			echo "  $IFACE: XPS -> (using IRQ core; no separate XPS pool available)"
		fi
	elif [ "$XPS_ENA" = "2" ]; then
		echo "  $IFACE: XPS will be DISABLED (mask=0) on all queues"
		echo "  $IFACE: IRQ -> [$(echo $CORES | tr ' ' ',')]"
	else
		echo "  $IFACE: IRQ -> [$(echo $CORES | tr ' ' ',')]"
	fi

	ncores=$(echo $CORES | wc -w)

	# Determine number of TX/RX queues actually present in sysfs.
	# The IRQ list may have more entries than queues (e.g. async/misc/ctrl
	# IRQs), and the queue list may have a different count than IRQs.
	# We pair each IRQ with queue index = position in IRQ list (qidx),
	# capped at the number of real sysfs queues.
	num_tx_queues=$(ls -d /sys/class/net/${IFACE}/queues/tx-* 2>/dev/null | wc -l)
	num_rx_queues=$(ls -d /sys/class/net/${IFACE}/queues/rx-* 2>/dev/null | wc -l)

	# n  = round-robin index over $CORES (1..ncores), wraps.
	# qidx = monotonic queue index for tx-K/rx-K (0..num_queues-1), does NOT wrap.
	n=1
	qidx=0

	# this script only supports interrupt vectors in pairs,
	# modification would be required to support a single Tx or Rx queue
	# per interrupt vector

	queues="${IFACE}-.*TxRx"

	irqs=$(grep "$queues" /proc/interrupts | cut -f1 -d:)
	# Use word-boundary grep to avoid matching e.g. "eth00" when looking for "eth0"
	[ -z "$irqs" ] && irqs=$(grep -E "(^|[[:space:]])${IFACE}([[:space:]\-]|$)" /proc/interrupts | cut -f1 -d:)
	[ -z "$irqs" ] && [ -d "/sys/class/net/${IFACE}/device/msi_irqs" ] && irqs=$(for i in `ls -1 /sys/class/net/${IFACE}/device/msi_irqs | sort -n` ;do grep -w $i: /proc/interrupts | egrep -v 'fdir|async|misc|ctrl' | cut -f 1 -d :; done)
	if [ -z "$irqs" ]; then
		echo "Error: Could not find interrupts for $IFACE"
		return
	fi

	if [ "$SHOW" == "1" ] ; then
		echo "TYPE IFACE CORE MASK -> FILE"
		echo "============================"
	else
		echo "IFACE CORE MASK -> FILE"
		echo "======================="
	fi

	for IRQ in $irqs; do
		[ "$n" -gt "$ncores" ] && n=1
		j=1
		# much faster than calling cut for each
		for i in $CORES; do
			[ $((j++)) -ge $n ] && break
		done
		core=$i
		if [ "$SHOW" == "1" ] ; then
			show_affinity
		else
			set_affinity
		fi
		((n++))
		((qidx++))
	done
}

# these next 2 lines would allow script to auto-determine interfaces
#[ -z "$IFACES" ] && IFACES=$(ls /sys/class/net)
#[ -z "$IFACES" ] && echo "Error: No interfaces up" && exit 1

# echo IFACES is $IFACES

CORES=$(</sys/devices/system/cpu/online)
[ "$CORES" ] || CORES=$(grep ^proc /proc/cpuinfo | cut -f2 -d:)

# Core list for each node from sysfs
node_dir=/sys/devices/system/node
for i in $(ls -d $node_dir/node*); do
	i=${i/*node/}
	corelist[$i]=$(<$node_dir/node${i}/cpulist)
done

# Given a list of CPU numbers (space-sep), return the set of NUMA node
# IDs that own at least one of those CPUs.
nodes_for_cores()
{
	local cpus="$1" out="" nd c found
	for nd in "${!corelist[@]}"; do
		found=0
		for c in $(parse_range_to_list "${corelist[$nd]}"); do
			# is c in cpus?
			for x in $cpus; do
				if [ "$x" = "$c" ]; then
					found=1
					break 2
				fi
			done
		done
		[ $found -eq 1 ] && out+=" $nd"
	done
	echo $out
}

# Given a CPU list and a list of NUMA node IDs, return the subset of
# the CPU list that belongs to any of those nodes.
pool_for_nodes()
{
	local pool="$1" nodes="$2" out="" nd
	for nd in $nodes; do
		out+=" $(intersect "$pool" "${corelist[$nd]}")"
	done
	# dedup
	echo $(echo $out | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un)
}

for IFACE in $IFACES; do
	# echo $IFACE being modified

	dev_dir=/sys/class/net/$IFACE/device
	[ -e $dev_dir/numa_node ] && node=$(<$dev_dir/numa_node)
	[ "$node" ] && [ "$node" -gt 0 ] || node=0

	# Resolve which NUMA nodes the user's flag selects, then intersect
	# IRQ_POOL and XPS_POOL with those nodes. This is mode-agnostic:
	# whatever the MODE put into IRQ_POOL/XPS_POOL gets filtered the same
	# way for every flag.
	case "$AFF" in
	all)
		CORES="$IRQ_POOL"
		XPS_CORES="$XPS_POOL"
	;;
	local)
		CORES=$(intersect     "$IRQ_POOL" "${corelist[$node]}")
		XPS_CORES=$(intersect "$XPS_POOL" "${corelist[$node]}")
	;;
	remote)
		[ "$rnode" ] || { [ $node -eq 0 ] && rnode=1 || rnode=0; }
		CORES=$(intersect     "$IRQ_POOL" "${corelist[$rnode]}")
		XPS_CORES=$(intersect "$XPS_POOL" "${corelist[$rnode]}")
	;;
	one)
		if [ -z "$cnt" ]; then
			echo "ERROR: 'one' mode requires a numeric core argument."
			exit 1
		fi
		# In SPLIT mode, 'one' must target a housekeeping CPU (= IRQ_POOL).
		# In RESERVE_ONE / NORMAL mode, the IRQ_POOL is the full usable set,
		# so any CPU in IRQ_POOL is acceptable.
		if ! _in_pool "$cnt" "$IRQ_POOL"; then
			echo "ERROR: requested core $cnt is not in the IRQ pool."
			echo "       IRQ pool ($MODE): [$(echo $IRQ_POOL | tr ' ' ',')]"
			exit 4
		fi
		CORES=$cnt
		# XPS for 'one' goes to XPS_POOL on the same NUMA node as the IRQ core.
		cnt_node=0
		for nd in "${!corelist[@]}"; do
			for c in $(parse_range_to_list "${corelist[$nd]}"); do
				[ "$c" = "$cnt" ] && cnt_node=$nd && break 2
			done
		done
		XPS_CORES=$(intersect "$XPS_POOL" "${corelist[$cnt_node]}")
	;;
	custom)
		echo -n "Input cores for $IFACE (ex. 0-7,15-23): "
		read CORES
		custom_expanded=$(parse_range "$CORES")
		custom_nodes=$(nodes_for_cores "$custom_expanded")
		if [ -n "$custom_nodes" ]; then
			XPS_CORES=$(pool_for_nodes "$XPS_POOL" "$custom_nodes")
		else
			XPS_CORES="$XPS_POOL"
		fi
	;;
	[0-9]*)
		CORES=$AFF
		num_expanded=$(parse_range "$CORES")
		num_nodes=$(nodes_for_cores "$num_expanded")
		if [ -n "$num_nodes" ]; then
			XPS_CORES=$(pool_for_nodes "$XPS_POOL" "$num_nodes")
		else
			XPS_CORES="$XPS_POOL"
		fi
	;;
	*)
		usage
		exit 1
	;;
	esac

	# Fallback: if the requested flag produced an empty CORES intersection
	# (e.g. no IRQ-pool CPUs on the NIC's NUMA node), use the full IRQ pool
	# rather than failing.
	if [ -z "$(echo $CORES)" ] && [ -n "$IRQ_POOL" ]; then
		case "$AFF" in
		local|remote)
			echo "  $IFACE: no IRQ-pool cores on requested NUMA node; using full IRQ pool"
			CORES=$(echo $IRQ_POOL | tr ' ' ',')
		;;
		esac
	fi

	# Fallback: if the requested flag produced no XPS cores on the target
	# NUMA node, use the full XPS pool so XPS still gets written.
	if [ -z "$(echo $XPS_CORES)" ]; then
		if [ -n "$XPS_POOL" ]; then
			echo "  $IFACE: no XPS-pool cores on NUMA node $node; XPS will use full XPS pool"
			XPS_CORES="$XPS_POOL"
		fi
	fi

	# call the worker function
	doaff
done

# check for irqbalance running
IRQBALANCE_ON=`ps ax | grep -v grep | grep -q irqbalance; echo $?`
if [ "$IRQBALANCE_ON" == "0" ] ; then
	echo " WARNING: irqbalance is running and will"
	echo "          likely override this script's affinitization."
	echo "          Please stop the irqbalance service and/or execute"
	echo "          'killall irqbalance'"
	exit 2
fi
