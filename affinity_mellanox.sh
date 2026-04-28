#! /bin/bash
#
# set_irq_affinity_bynode.sh — Mellanox IRQ affinity, NUMA-node bound,
#                              with GRUB-aware housekeeping/isolated CPU filtering.
#
# Reads /etc/default/grub (and /proc/cmdline) to detect:
#   - isolcpus / nohz_full / rcu_nocbs    (isolated CPUs)
#   - irqaffinity                         (housekeeping CPUs)
# and chooses an operating MODE:
#
#   SPLIT       (housekeeping >= 2 CPUs):
#     IRQs go ONLY to the housekeeping subset of the chosen NUMA node.
#     Isolated CPUs of that node are skipped.
#
#   RESERVE_ONE (housekeeping == 1 CPU):
#     The single housekeeping CPU is treated as reserved (no IRQ).
#     IRQs go to (node CPUs MINUS that reserved CPU).
#
#   NORMAL      (housekeeping == 0):
#     Original behaviour — IRQs go to all CPUs of the chosen NUMA node.
#
# Usage: ./set_irq_affinity_bynode.sh <node_id> <interface> [<2nd interface>]

if [ -z "$2" ]; then
	echo "usage: $0 <node id> <interface> [2nd interface]"
	exit 1
fi

node=$1
interface=$2
interface2=$3

# Validate node is numeric (avoids constructing invalid sysfs paths).
if ! [[ "$node" =~ ^[0-9]+$ ]]; then
	echo "ERROR: <node id> must be a non-negative integer, got '$node'"
	exit 1
fi

# Source the common library AFTER arg validation so usage errors don't
# require the library to exist.
source common_irq_affinity.sh

# ============================================================
# GRUB / housekeeping CPU detection
# ============================================================

# Expand "0-3,8,10-11" (with possible non-numeric prefix tokens like
# "managed_irq,domain,2-15,34-47") into a space-separated CPU list.
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
		if [[ "$r" == *..* ]]; then
			r="$(eval echo {$r})"
		fi
		LIST+=" $r"
	done
	echo $LIST
}

# Extract param=VALUE from a cmdline string.
extract_param()
{
	local cmdline="$1"
	local param="$2"
	local val
	val=$(echo "$cmdline" | grep -oE "(^|[[:space:]\"])${param}=[^[:space:]\"]+" | head -n1 | sed -E "s/.*${param}=//")
	echo "$val"
}

# Strip a single layer of matching outer quotes (single or double).
strip_outer_quotes()
{
	local s="$1"
	if [[ "$s" =~ ^\".*\"$ ]]; then
		s="${s#\"}"; s="${s%\"}"
	elif [[ "$s" =~ ^\'.*\'$ ]]; then
		s="${s#\'}"; s="${s%\'}"
	fi
	echo "$s"
}

# Read kernel cmdline. Prefers /etc/default/grub, falls back to /proc/cmdline.
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
	grub_cmdline="$(echo "$grub_cmdline" | tr -s ' ' | sed -E 's/^ +| +$//g')"
	if [ -n "$grub_cmdline" ]; then
		echo "$grub_cmdline"
	elif [ -r /proc/cmdline ]; then
		cat /proc/cmdline
	fi
}

# Warn if /etc/default/grub and /proc/cmdline disagree.
warn_on_grub_proc_divergence()
{
	[ -r /etc/default/grub ] || return 0
	[ -r /proc/cmdline ]     || return 0

	local grub_cl proc_cl raw_def raw_lin def lin
	raw_def=$(grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | tail -n1 | sed -E 's/^[^=]*=//')
	raw_lin=$(grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX=' /etc/default/grub | tail -n1 | sed -E 's/^[^=]*=//')
	def=$(strip_outer_quotes "$raw_def")
	lin=$(strip_outer_quotes "$raw_lin")
	grub_cl="$def $lin"
	proc_cl=$(cat /proc/cmdline)

	local p mismatch=0
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
	[ $mismatch -eq 1 ] && {
		echo "         This script will use the values from /etc/default/grub." >&2
		echo "" >&2
	}
}

# Detect housekeeping/isolated/online sets and choose MODE.
# Sets globals: HOUSEKEEPING_CORES, ISOLATED_CORES, ONLINE_CORES,
#               MODE, MANAGED_IRQ_FLAG
detect_housekeeping_cpus()
{
	warn_on_grub_proc_divergence

	local cmdline
	cmdline=$(read_kernel_cmdline)
	if [ -z "$cmdline" ]; then
		echo "ERROR: Could not read kernel cmdline." >&2
		exit 3
	fi

	local online online_list
	online=$(</sys/devices/system/cpu/online 2>/dev/null)
	if [ -z "$online" ]; then
		online=$(grep ^processor /proc/cpuinfo | awk '{print $NF}' | paste -sd,)
	fi
	online_list=$(parse_range_to_list "$online")
	if [ -z "$online_list" ]; then
		echo "ERROR: Could not determine online CPUs." >&2
		exit 3
	fi

	local p_isolcpus p_nohz p_rcunocbs p_irqaff
	p_isolcpus=$(extract_param "$cmdline" "isolcpus")
	p_nohz=$(extract_param "$cmdline" "nohz_full")
	p_rcunocbs=$(extract_param "$cmdline" "rcu_nocbs")
	p_irqaff=$(extract_param "$cmdline" "irqaffinity")

	MANAGED_IRQ_FLAG=0
	if [[ ",$p_isolcpus," == *",managed_irq,"* ]]; then
		MANAGED_IRQ_FLAG=1
	fi

	# Build isolated set (intersected with online)
	local isolated_list=""
	isolated_list+=" $(parse_range_to_list "$p_isolcpus")"
	isolated_list+=" $(parse_range_to_list "$p_nohz")"
	isolated_list+=" $(parse_range_to_list "$p_rcunocbs")"
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
	ISOLATED_CORES="$(echo $ISOLATED_CORES)"

	# Build housekeeping set
	local hk_list=""
	if [ -n "$p_irqaff" ]; then
		# irqaffinity= is the authoritative housekeeping set.
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
		# Derive housekeeping = online MINUS isolated.
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
	HOUSEKEEPING_CORES=$(echo $hk_list | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')
	HOUSEKEEPING_CORES="$(echo $HOUSEKEEPING_CORES)"

	# Sanity: housekeeping and isolated must be disjoint.
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
		echo "ERROR: housekeeping and isolated sets overlap on CPUs: [$(echo $bad | tr ' ' ',')]" >&2
		echo "       This usually means irqaffinity= and isolcpus= contradict each other." >&2
		exit 3
	fi

	# Determine MODE based on housekeeping count.
	local hk_count
	hk_count=$(echo $HOUSEKEEPING_CORES | wc -w)
	if [ "$hk_count" -ge 2 ]; then
		MODE="SPLIT"
	elif [ "$hk_count" -eq 1 ]; then
		MODE="RESERVE_ONE"
	else
		MODE="NORMAL"
	fi

	echo "GRUB-aware mode active"
	case "$MODE" in
	SPLIT)
		echo "  MODE: SPLIT (housekeeping has $hk_count CPUs)"
		echo "    housekeeping: [$(echo $HOUSEKEEPING_CORES | tr ' ' ',')]"
		echo "    isolated    : [$(echo $ISOLATED_CORES | tr ' ' ',')] (will be EXCLUDED from IRQs)"
	;;
	RESERVE_ONE)
		echo "  MODE: RESERVE_ONE (1 housekeeping CPU; reserving it)"
		echo "    Reserved CPU (no IRQ): [$HOUSEKEEPING_CORES]"
	;;
	NORMAL)
		echo "  MODE: NORMAL (no housekeeping CPUs detected; using all node CPUs)"
	;;
	esac
	if [ "$MANAGED_IRQ_FLAG" = "1" ]; then
		echo "  NOTE: isolcpus contains 'managed_irq'. For managed MSI-X IRQs"
		echo "        (modern mlx5/mlx4), writes to smp_affinity may be ignored"
		echo "        by the kernel — affinity is auto-managed."
	fi
	echo
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

# Filter a space-separated CPU list, removing CPUs that are NOT in the
# target pool. Used to drop isolated/reserved CPUs from the node's CPU list.
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

# Run detection up front
detect_housekeeping_cpus
# ============================================================
# end housekeeping detection
# ============================================================

IRQS=$( get_irq_list "$interface" )

if [ -n "$interface2" ]; then
	IRQS_2=$( get_irq_list "$interface2" )
	echo "---------------------------------------"
	echo "Optimizing IRQs for Dual port traffic"
	echo "---------------------------------------"
else
	echo "-------------------------------------"
	echo "Optimizing IRQs for Single port traffic"
	echo "-------------------------------------"
fi

# Read the chosen NUMA node's cpulist and validate.
cpulist=$(cat "/sys/devices/system/node/node$node/cpulist" 2>/dev/null)
cat_status=$?
if [ $cat_status -ne 0 ] || [ -z "$cpulist" ]; then
	echo "ERROR: Node id '$node' does not exist."
	exit 1
fi

# Expand the cpulist (can contain ranges like "0-11,24-35") into a flat
# comma-separated list of individual CPUs.
NGROUPS=$( echo "$cpulist" | sed 's/,/ /g' | wc -w )
CPULIST=""
for word in $(seq 1 "$NGROUPS")
do
	SEQ=$(echo "$cpulist" | cut -d "," -f "$word" | sed 's/-/ /')
	if [ "$(echo "$SEQ" | wc -w)" != "1" ]; then
		CPULIST="$CPULIST $( echo $(seq $SEQ) | sed 's/ /,/g' )"
	else
		CPULIST="$CPULIST $SEQ"
	fi
done
cpulist=$(echo $CPULIST | sed 's/ /,/g' | sed 's/^,//;s/,$//')

# ============================================================
# Apply MODE-aware filtering to the node's CPU list.
# After this point, $cpulist contains ONLY the CPUs that should
# receive IRQs for this NUMA node (i.e. excluding isolated/reserved).
# ============================================================
node_cpus_space=$(echo "$cpulist" | tr ',' ' ')
case "$MODE" in
SPLIT)
	# Keep only housekeeping CPUs that belong to this node.
	filtered=$(filter_to_pool "$node_cpus_space" "$HOUSEKEEPING_CORES")
	;;
RESERVE_ONE)
	# Drop the single reserved housekeeping CPU from the node's list.
	# (Effectively: node_cpus_space MINUS HOUSEKEEPING_CORES)
	reserved="$HOUSEKEEPING_CORES"
	filtered=""
	for c in $node_cpus_space; do
		if ! _in_pool "$c" "$reserved"; then
			filtered+=" $c"
		fi
	done
	filtered=$(echo $filtered)
	;;
NORMAL)
	# No filtering — original behaviour.
	filtered="$node_cpus_space"
	;;
esac

if [ -z "$filtered" ]; then
	echo "ERROR: After applying $MODE filter, no usable CPUs remain on node $node."
	echo "       node $node CPUs : [$cpulist]"
	echo "       housekeeping    : [$(echo $HOUSEKEEPING_CORES | tr ' ' ',')]"
	echo "       isolated        : [$(echo $ISOLATED_CORES | tr ' ' ',')]"
	exit 4
fi

# Replace cpulist with the filtered list (comma-separated, as the rest
# of this script expects when using `cut -d "," -f $word`).
cpulist=$(echo "$filtered" | tr ' ' ',')
CORES=$( echo "$cpulist" | sed 's/,/ /g' | wc -w )

echo "Node $node usable CPUs after $MODE filter: [$cpulist] (count: $CORES)"
echo

# Sanity: we need at least 1 CPU. Dual-port mode needs at least 2.
if [ "$CORES" -lt 1 ]; then
	echo "ERROR: no usable CPUs on node $node after filtering."
	exit 4
fi
if [ -n "$interface2" ] && [ "$CORES" -lt 2 ]; then
	echo "ERROR: dual-port mode requires at least 2 usable CPUs on node $node, got $CORES."
	echo "       Re-run with a single interface, or pick a node with more housekeeping CPUs."
	exit 4
fi

# Compute per-interface stride.
#   single-port: stride = CORES   (use all of them, round-robin)
#   dual-port  : stride = CORES/2 for the first half, second half for iface2
#                If CORES is odd, iface1 gets the extra CPU (ceil), iface2 gets floor.
if [ -n "$interface2" ]; then
	HALF1=$(( (CORES + 1) / 2 ))   # ceil
	HALF2=$(( CORES / 2 ))         # floor
	# Defensive: HALF2 must be at least 1, guaranteed by CORES >= 2 above.
fi

if [ -z "$IRQS" ] ; then
	echo "No IRQs found for $interface."
else
	echo
	echo "Discovered irqs for $interface: $IRQS"
fi

# ---- First interface ----
I=1
for IRQ in $IRQS
do
	core_id=$(echo "$cpulist" | cut -d "," -f $I)
	echo "Assign irq $IRQ core_id $core_id"
	affinity=$( core_to_affinity "$core_id" )
	set_irq_affinity "$IRQ" "$affinity"
	if [ -z "$interface2" ]; then
		# Round-robin across all CORES
		I=$(( (I % CORES) + 1 ))
	else
		# Round-robin only across the first HALF1 CPUs
		I=$(( (I % HALF1) + 1 ))
	fi
done

# ---- Second interface (dual-port only) ----
if [ -n "$interface2" ]; then
	if [ -z "$IRQS_2" ] ; then
		echo "No IRQs found for $interface2."
	else
		echo
		echo "Discovered irqs for $interface2: $IRQS_2"
	fi

	# Start at the first CPU of the second half.
	I=$(( HALF1 + 1 ))
	for IRQ in $IRQS_2
	do
		core_id=$(echo "$cpulist" | cut -d "," -f $I)
		echo "Assign irq $IRQ core_id $core_id"
		affinity=$( core_to_affinity "$core_id" )
		set_irq_affinity "$IRQ" "$affinity"
		# Round-robin within the second half (CPUs HALF1+1 .. CORES)
		I=$(( ((I - HALF1) % HALF2) + 1 + HALF1 ))
	done
fi

echo
echo done.
