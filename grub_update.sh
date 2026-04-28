#!/bin/bash
###############################################################################
#  CPU Performance Tuner v2.0
#  Auto-detect CPU + Configurar GRUB + cpufrequtils + Ulimits
#  Foco: Streaming / Máximo throughput / Mínima latência de tráfego
#  Compatível com: Intel Xeon, AMD Ryzen, AMD EPYC
#  Requer: root / sudo
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Parser de argumentos
# ─────────────────────────────────────────────────────────────────────────────
NIC=""
HOUSEKEEPING_OVERRIDE=""

show_usage() {
    cat <<USAGE
Uso: $0 [OPÇÕES]

OPÇÕES:
  --nic <interface>          Indica a NIC primária para isolation NUMA-aware.
                             O script detecta o NUMA da NIC e isola apenas
                             os cores desse NUMA, deixando NUMAs remotos livres
                             para o sistema. Exemplo: --nic enp1s0f0
  --housekeeping <N>         (Opcional) Override do número de threads para
                             housekeeping. Default: 1/2/2/4/8 conforme escala
                             do NUMA (≤8/9-16/17-32/33-64/>64 threads).
  --help                     Mostra esta mensagem.

EXEMPLOS:
  # Modo padrão (sem isolation):
  $0

  # Com isolation NUMA-aware (recomendado para streaming):
  $0 --nic enp1s0f0

  # Override do count de housekeeping:
  $0 --nic enp1s0f0 --housekeeping 4

USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nic)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
                echo "Erro: --nic requer um valor (ex: --nic enp1s0)" >&2
                exit 1
            fi
            NIC="$2"
            shift 2
            ;;
        --housekeeping)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
                echo "Erro: --housekeeping requer um valor numérico (ex: --housekeeping 4)" >&2
                exit 1
            fi
            HOUSEKEEPING_OVERRIDE="$2"
            shift 2
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            echo "Argumento desconhecido: $1" >&2
            show_usage
            exit 1
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Cores e formatação
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok()      { echo -e "${GREEN}[ OK ]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $1"; }
log_section() { echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}  $1${NC}"; echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# Verificação de root
# ─────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    log_error "Este script precisa ser executado como root."
    echo "  Use: sudo $0"
    exit 1
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   CPU Performance Tuner v2.0 - Maximum Streaming Throughput ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# FUNÇÕES DE DETECÇÃO E CÁLCULO PARA ISOLATION NUMA-AWARE
# ═════════════════════════════════════════════════════════════════════════════

# Validar a NIC indicada e retornar seu NUMA node
validate_nic_and_get_numa() {
    local nic="$1"
    if [[ ! -e "/sys/class/net/${nic}" ]]; then
        log_error "NIC '${nic}' não existe em /sys/class/net/"
        echo "  NICs disponíveis:" >&2
        for n in /sys/class/net/*/; do
            n=$(basename "$n")
            [[ "$n" == "lo" ]] && continue
            echo "    - $n" >&2
        done
        exit 1
    fi
    if [[ ! -e "/sys/class/net/${nic}/device" ]]; then
        log_error "NIC '${nic}' é virtual (sem device PCIe) — isolation NUMA não aplicável"
        exit 1
    fi
    if [[ ! -r "/sys/class/net/${nic}/device/numa_node" ]]; then
        log_error "NIC '${nic}' não expõe informação NUMA"
        exit 1
    fi
    local numa
    numa=$(cat "/sys/class/net/${nic}/device/numa_node")
    # numa_node = -1 em sistemas single-NUMA; tratar como NUMA 0
    [[ "$numa" == "-1" ]] && numa=0
    echo "$numa"
}

# Listar threads de um NUMA node (formato: "0-15,32-47" ou "0-31")
get_numa_cpus() {
    local node="$1"
    local cpulist_file="/sys/devices/system/node/node${node}/cpulist"
    if [[ -r "$cpulist_file" ]]; then
        cat "$cpulist_file"
    else
        # Fallback para sistemas single-NUMA sem /sys/devices/system/node/
        echo "0-$(( $(nproc) - 1 ))"
    fi
}

# Contar threads em uma string de range "0-15,32-47" → 32
count_threads_in_range() {
    local range="$1"
    [[ -z "$range" ]] && { echo 0; return; }
    local total=0
    local part start end
    local parts
    IFS=',' read -ra parts <<< "$range"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            start="${part%-*}"
            end="${part#*-}"
            total=$(( total + end - start + 1 ))
        else
            total=$(( total + 1 ))
        fi
    done
    echo "$total"
}

# Expandir range "0-3,16-19" para lista "0 1 2 3 16 17 18 19"
expand_range() {
    local range="$1"
    [[ -z "$range" ]] && { echo ""; return; }
    local part start end i
    local out=()
    local parts
    IFS=',' read -ra parts <<< "$range"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            start="${part%-*}"
            end="${part#*-}"
            for ((i=start; i<=end; i++)); do
                out+=("$i")
            done
        else
            out+=("$part")
        fi
    done
    # Proteção contra array vazio em set -u
    [[ ${#out[@]} -eq 0 ]] && { echo ""; return; }
    echo "${out[@]}"
}

# Compactar lista "0 1 2 3 16 17 18 19" para range "0-3,16-19"
compact_range() {
    local input="$1"
    local cpus
    # Split intencional (input vem com espaços controlados, não há globbing)
    read -ra cpus <<< "$input"
    [[ ${#cpus[@]} -eq 0 ]] && { echo ""; return; }

    # Ordenar numericamente
    local sorted
    sorted=$(printf "%s\n" "${cpus[@]}" | sort -n -u)
    readarray -t cpus <<< "$sorted"

    local result=""
    local start="${cpus[0]}"
    local prev="${cpus[0]}"
    local i

    for ((i=1; i<${#cpus[@]}; i++)); do
        if [[ "${cpus[$i]}" -eq $((prev + 1)) ]]; then
            prev="${cpus[$i]}"
        else
            if [[ "$start" == "$prev" ]]; then
                result+="${start},"
            else
                result+="${start}-${prev},"
            fi
            start="${cpus[$i]}"
            prev="${cpus[$i]}"
        fi
    done

    if [[ "$start" == "$prev" ]]; then
        result+="${start}"
    else
        result+="${start}-${prev}"
    fi

    echo "$result"
}

# Decidir housekeeping count baseado no número de threads do NUMA
calc_housekeeping_count() {
    local numa_threads="$1"
    if [[ "$numa_threads" -le 8 ]]; then
        echo 1
    elif [[ "$numa_threads" -le 16 ]]; then
        echo 2
    elif [[ "$numa_threads" -le 32 ]]; then
        echo 2
    elif [[ "$numa_threads" -le 64 ]]; then
        echo 4
    else
        echo 8
    fi
}

# Selecionar N threads housekeeping = SMT siblings dos N primeiros cores físicos
# do NUMA. Retorna lista compactada (ex: "0,16" ou "0-3,32-35")
select_housekeeping_threads() {
    local numa_cpus="$1"
    local hk_count="$2"

    # Expandir lista de CPUs do NUMA
    local numa_list
    numa_list=$(expand_range "$numa_cpus")
    local numa_arr
    read -ra numa_arr <<< "$numa_list"

    # Mapear cores físicos únicos com seus SMT siblings
    declare -A core_to_threads
    local cpu siblings core_id
    for cpu in "${numa_arr[@]}"; do
        local sib_file="/sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list"
        local core_file="/sys/devices/system/cpu/cpu${cpu}/topology/core_id"
        [[ -r "$sib_file" ]] || continue
        [[ -r "$core_file" ]] || continue

        siblings=$(cat "$sib_file")
        core_id=$(cat "$core_file")

        # Usar core_id como chave (cores físicos únicos)
        if [[ -z "${core_to_threads[$core_id]:-}" ]]; then
            core_to_threads[$core_id]="$siblings"
        fi
    done

    # Validar que conseguimos ler topology de pelo menos 1 core
    if [[ ${#core_to_threads[@]} -eq 0 ]]; then
        # Fallback: topology indisponível, usar primeiros hk_count threads diretos
        # (não ideal mas evita travar — rara em hardware real, comum em containers/VMs minimal)
        local fallback_threads=()
        local i=0
        for cpu in "${numa_arr[@]}"; do
            [[ $i -ge $hk_count ]] && break
            fallback_threads+=("$cpu")
            i=$((i + 1))
        done
        compact_range "${fallback_threads[*]}"
        return
    fi

    # Pegar os N primeiros cores físicos (ordenados por core_id numericamente)
    local sorted_core_ids
    sorted_core_ids=$(printf "%s\n" "${!core_to_threads[@]}" | sort -n)

    local hk_threads=()
    local count=0
    while IFS= read -r cid; do
        [[ "$count" -ge "$hk_count" ]] && break
        # Adicionar todos os SMT siblings deste core físico
        local thr_list
        thr_list=$(expand_range "${core_to_threads[$cid]}")
        for t in $thr_list; do
            hk_threads+=("$t")
        done
        count=$((count + 1))
    done <<< "$sorted_core_ids"

    compact_range "${hk_threads[*]}"
}

# Calcular threads isolated = todos do NUMA menos os housekeeping
calc_isolated_threads() {
    local numa_cpus="$1"
    local hk_range="$2"

    local numa_list hk_list
    numa_list=$(expand_range "$numa_cpus")
    hk_list=$(expand_range "$hk_range")

    declare -A hk_set
    for t in $hk_list; do
        hk_set[$t]=1
    done

    local isolated=()
    for t in $numa_list; do
        [[ -z "${hk_set[$t]:-}" ]] && isolated+=("$t")
    done

    compact_range "${isolated[*]}"
}

# ═════════════════════════════════════════════════════════════════════════════
# Backup do GRUB
# ─────────────────────────────────────────────────────────────────────────────
GRUB_FILE="/etc/default/grub"
BACKUP_DIR="/etc/default/grub-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"
if [[ -f "$GRUB_FILE" ]]; then
    cp "$GRUB_FILE" "${BACKUP_DIR}/grub.backup.${TIMESTAMP}"
else
    log_error "${GRUB_FILE} não encontrado!"
    exit 1
fi

log_section "1/8 - LIMPEZA DE CONFIGURAÇÕES ANTERIORES"

# ─────────────────────────────────────────────────────────────────────────────
# Remover persistências de execuções anteriores deste script (v1 e v2)
# ─────────────────────────────────────────────────────────────────────────────
OLD_FOUND=0

# Serviço systemd
if systemctl is-active cpu-performance.service &>/dev/null; then
    systemctl stop cpu-performance.service &>/dev/null
    log_info "Serviço cpu-performance.service parado"
    OLD_FOUND=1
fi
if systemctl is-enabled cpu-performance.service &>/dev/null; then
    systemctl disable cpu-performance.service &>/dev/null
    log_info "Serviço cpu-performance.service desabilitado"
    OLD_FOUND=1
fi
if [[ -f /etc/systemd/system/cpu-performance.service ]]; then
    rm -f /etc/systemd/system/cpu-performance.service
    systemctl daemon-reload &>/dev/null
    log_info "Removido: /etc/systemd/system/cpu-performance.service"
    OLD_FOUND=1
fi

# Boot script
if [[ -f /usr/local/bin/cpu-performance-tuner.sh ]]; then
    rm -f /usr/local/bin/cpu-performance-tuner.sh
    log_info "Removido: /usr/local/bin/cpu-performance-tuner.sh"
    OLD_FOUND=1
fi

# cpufrequtils config
if [[ -f /etc/default/cpufrequtils ]]; then
    rm -f /etc/default/cpufrequtils
    log_info "Removido: /etc/default/cpufrequtils"
    OLD_FOUND=1
fi

# Ulimits
if [[ -f /etc/security/limits.d/99-streaming.conf ]]; then
    rm -f /etc/security/limits.d/99-streaming.conf
    log_info "Removido: /etc/security/limits.d/99-streaming.conf"
    OLD_FOUND=1
fi

# Sysctl de versões anteriores (v1)
if [[ -f /etc/sysctl.d/99-streaming-performance.conf ]]; then
    rm -f /etc/sysctl.d/99-streaming-performance.conf
    log_info "Removido: /etc/sysctl.d/99-streaming-performance.conf (v1)"
    OLD_FOUND=1
fi

# Módulo bbr de versões anteriores (v1)
if [[ -f /etc/modules-load.d/bbr.conf ]]; then
    rm -f /etc/modules-load.d/bbr.conf
    log_info "Removido: /etc/modules-load.d/bbr.conf (v1)"
    OLD_FOUND=1
fi

if [[ $OLD_FOUND -eq 1 ]]; then
    log_ok "Configurações anteriores removidas com sucesso"
else
    log_info "Nenhuma configuração anterior encontrada — instalação limpa"
fi

log_section "2/8 - DETECÇÃO DE HARDWARE"

# ─────────────────────────────────────────────────────────────────────────────
# Detectar CPU
# ─────────────────────────────────────────────────────────────────────────────
VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
MODEL_NAME=$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')
CPU_FAMILY=$(grep -m1 'cpu family' /proc/cpuinfo | awk '{print $4}')
CPU_MODEL=$(awk -F: '/^model\t/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
[[ -z "$CPU_MODEL" ]] && CPU_MODEL=0
THREADS=$(grep -c '^processor' /proc/cpuinfo)
SOCKETS=$(grep 'physical id' /proc/cpuinfo | sort -u | wc -l || true)
[[ "$SOCKETS" -eq 0 ]] && SOCKETS=1
CORES_PER_SOCKET=$(grep -m1 'cpu cores' /proc/cpuinfo | awk '{print $4}')
[[ -z "$CORES_PER_SOCKET" ]] && CORES_PER_SOCKET="N/A"
KERNEL_VER=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_VER" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VER" | cut -d. -f2)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))

log_info "CPU:               ${BOLD}${MODEL_NAME}${NC}"
log_info "Vendor:            ${VENDOR}"
log_info "Family/Model:      ${CPU_FAMILY}/${CPU_MODEL}"
log_info "Threads totais:    ${THREADS}"
log_info "Sockets:           ${SOCKETS}"
log_info "Cores por socket:  ${CORES_PER_SOCKET}"
log_info "RAM total:         ${TOTAL_RAM_GB} GB"
log_info "Kernel:            ${KERNEL_VER}"

# ─────────────────────────────────────────────────────────────────────────────
# Classificar CPU e montar GRUB line
# ─────────────────────────────────────────────────────────────────────────────
log_section "3/8 - MONTAGEM DA LINHA GRUB"

CPU_TYPE="unknown"
PSTATE_DRIVER=""
INTEL_IDLE_FLAG=""
IOMMU_FLAGS=""
NUMA_FLAGS=""
EXTRA_NOTES=()

# ══════════════════════════════════════════════════════════════════════════════
# BLOCO 1: Parâmetros comuns — aplicados em Intel E AMD
# ══════════════════════════════════════════════════════════════════════════════
#
#   mitigations=off               → Desabilita TODAS as mitigações de CPU (Spectre, Meltdown, MDS, etc.) — MÁXIMO desempenho
#   tsc=reliable                  → Marca o TSC como confiável (evita fallback para clocksources mais lentos)
#   clocksource=tsc               → Força TSC como clocksource (menor overhead em gettimeofday/clock_gettime)
#   hpet=disable                  → Desabilita HPET (evita interrupções lentas do timer legado)
#   nowatchdog                    → Desabilita watchdog do kernel (remove interrupções NMI periódicas)
#   nmi_watchdog=0                → Desabilita NMI watchdog especificamente (complementa nowatchdog)
#   nosoftlockup                  → Desabilita detecção de softlockup (evita falsos alarmes)
#   skew_tick=1                   → Desalinha ticks entre cores (reduz contenção de lock no timer tick)
#   audit=0                       → Desabilita subsistema de auditoria (remove overhead de syscall logging)
#   noresume                      → Desabilita resume de hibernação (boot mais rápido, sem busca de imagem)
#   selinux=0                     → Desabilita SELinux (remove overhead de contexto de segurança em cada syscall)
#   apparmor=0                    → Desabilita AppArmor (remove overhead de MAC)
#   workqueue.power_efficient=0   → Desabilita mode power-efficient em workqueues (usa CPU local, não migra para economizar)
#   pcie_aspm=off                 → Desabilita PCIe Active State Power Management (latência zero em dispositivos PCIe/NIC 25G+)
#   cpufreq.default_governor=performance → Define governor performance no boot do kernel (kernel 5.9+), antes de qualquer userspace
#   processor.max_cstate=1        → Permite apenas C0 e C1 (HLT raso). Proíbe C3/C6/C7 que têm latência alta (~100μs).
#                                   Wake-up de C1 é ~1μs — ideal para streaming. Cores ociosos ainda podem dormir
#                                   em C1 para liberar power budget, sem o overhead dos C-states profundos.
#   init_on_alloc=0               → Não zerar páginas em alloc (kernel 5.3+ default é 1, ganho mensurável em apps
#                                   com muito malloc/free como FFmpeg)
#   init_on_free=0                → Não zerar páginas em free (mesmo princípio)
#   vsyscall=none                 → Desabilita emulação de vsyscall legacy (segurança + performance)
#   random.trust_cpu=on           → Usa RDRAND/RDSEED como fonte de entropia (boot rápido + SSL handshakes rápidos)
#
COMMON_FLAGS=""
COMMON_FLAGS+=" mitigations=off"
COMMON_FLAGS+=" tsc=reliable"
COMMON_FLAGS+=" clocksource=tsc"
COMMON_FLAGS+=" hpet=disable"
COMMON_FLAGS+=" nowatchdog"
COMMON_FLAGS+=" nmi_watchdog=0"
COMMON_FLAGS+=" nosoftlockup"
COMMON_FLAGS+=" skew_tick=1"
COMMON_FLAGS+=" audit=0"
COMMON_FLAGS+=" noresume"
COMMON_FLAGS+=" selinux=0"
COMMON_FLAGS+=" apparmor=0"
COMMON_FLAGS+=" workqueue.power_efficient=0"
COMMON_FLAGS+=" pcie_aspm=off"
COMMON_FLAGS+=" cpufreq.default_governor=performance"
COMMON_FLAGS+=" processor.max_cstate=1"
COMMON_FLAGS+=" init_on_alloc=0"
COMMON_FLAGS+=" init_on_free=0"
COMMON_FLAGS+=" vsyscall=none"
COMMON_FLAGS+=" random.trust_cpu=on"

# ══════════════════════════════════════════════════════════════════════════════
# NOTA SOBRE C-STATE POLICY
# ══════════════════════════════════════════════════════════════════════════════
# processor.max_cstate=1 é o meio termo universal para streaming:
# permite C0+C1 (HLT, wake-up ~1μs) mas proíbe C3/C6/C7 (latência 100μs+).
# Cores ociosos dormem em C1 liberando power budget sem o overhead dos
# C-states profundos. Funciona em Intel e AMD.

# ══════════════════════════════════════════════════════════════════════════════
# BLOCO 2: RCU + THP (reduz jitter e permite hugepages opt-in)
# ══════════════════════════════════════════════════════════════════════════════
#
#   rcupdate.rcu_expedited=1         → Grace periods expeditos (callbacks mais rápido)
#   rcu_nocbs=<range>                → Cores isolados offloadam RCU callbacks (gerado dinamicamente com --nic)
#   transparent_hugepage=madvise     → THP opt-in (apps que pedem via madvise() ganham hugepages,
#                                      apps de streaming com muitas alocações pequenas ficam em 4KB,
#                                      evita latency spikes por compaction/defrag do khugepaged)
#
PERF_BOOT_FLAGS=""
PERF_BOOT_FLAGS+=" rcupdate.rcu_expedited=1"
# rcu_nocbs será adicionado dinamicamente APENAS com isolation NUMA-aware (--nic).
# Sem isolation, rcu_nocbs=all não traz benefício real (kthreads correm em qualquer core).
PERF_BOOT_FLAGS+=" transparent_hugepage=madvise"

# ══════════════════════════════════════════════════════════════════════════════
# BLOCO 3: Parâmetros específicos por vendor/modelo
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$VENDOR" == "GenuineIntel" ]]; then
    # ── INTEL ──────────────────────────────────────────────────────────────
    #   intel_pstate=active          → Driver Intel P-state em modo active (HWP direto)
    #   intel_idle.max_cstate=1      → Limita o driver intel_idle a C0+C1 (complementa processor.max_cstate=1).
    #                                  Mantém o driver carregado (com observabilidade via sysfs) mas restringe
    #                                  aos estados rasos. Wake-up via MWAIT ~1μs.
    #   intel_iommu=on               → Ativa Intel VT-d IOMMU
    #   iommu=pt                     → IOMMU em passthrough (zero overhead de tradução para DMA)
    #
    PSTATE_DRIVER="intel_pstate=active"
    INTEL_IDLE_FLAG="intel_idle.max_cstate=1"
    IOMMU_FLAGS="intel_iommu=on iommu=pt"

    if echo "$MODEL_NAME" | grep -qiE "xeon.*(gold|platinum|silver|bronze)"; then
        CPU_TYPE="intel_xeon_scalable"
        log_ok "Tipo: Intel Xeon Scalable (Skylake-SP / Cascade Lake / Ice Lake / Sapphire Rapids / Emerald Rapids)"

    elif echo "$MODEL_NAME" | grep -qiE "xeon.*w-?[0-9]"; then
        CPU_TYPE="intel_xeon_w"
        log_ok "Tipo: Intel Xeon-W (Workstation — Sapphire Rapids-W / Ice Lake-W)"
        EXTRA_NOTES+=("Xeon-W (workstation): sem dependência multi-socket, NUMA single-node")

    elif echo "$MODEL_NAME" | grep -qiE "xeon.*d-?[0-9]"; then
        CPU_TYPE="intel_xeon_d"
        log_ok "Tipo: Intel Xeon-D (Embedded — Skylake-D / Ice Lake-D)"
        EXTRA_NOTES+=("Xeon-D (embedded): integrado, geralmente single-socket")

    elif echo "$MODEL_NAME" | grep -qiE "xeon.*(e5|e7|e3)"; then
        CPU_TYPE="intel_xeon_legacy"
        log_ok "Tipo: Intel Xeon E-series (Broadwell / Haswell / Ivy Bridge)"

        # Broadwell/Haswell com kernel antigo: intel_pstate pode falhar
        if [[ "$KERNEL_MAJOR" -lt 4 ]] || { [[ "$KERNEL_MAJOR" -eq 4 ]] && [[ "$KERNEL_MINOR" -lt 10 ]]; }; then
            log_warn "Kernel < 4.10: usando intel_pstate=disable (fallback acpi-cpufreq)"
            PSTATE_DRIVER="intel_pstate=disable"
            EXTRA_NOTES+=("Xeon E-series com kernel antigo: governor será setado via cpufrequtils")
        fi

    elif echo "$MODEL_NAME" | grep -qiE "core.*(i[3579]|ultra)"; then
        CPU_TYPE="intel_desktop"
        log_ok "Tipo: Intel Core Desktop / Mobile"

    elif echo "$MODEL_NAME" | grep -qiE "(pentium|celeron|atom|N[0-9]+|J[0-9]+)"; then
        CPU_TYPE="intel_lowend"
        log_ok "Tipo: Intel Low-end (Pentium / Celeron / Atom)"
        EXTRA_NOTES+=("CPU low-end: alguns recursos como HWP podem não estar disponíveis")

    else
        CPU_TYPE="intel_generic"
        log_warn "Tipo: Intel Genérico (modelo não identificado especificamente)"
    fi

elif [[ "$VENDOR" == "AuthenticAMD" ]]; then
    # ── AMD ────────────────────────────────────────────────────────────────
    # Política C-state unificada via processor.max_cstate=1 (em COMMON_FLAGS).
    # Cores ociosos entram em C1 (HLT, wake-up ~1μs) liberando PPT budget
    # para cores ativos boostarem ao máximo via Precision Boost.

    if echo "$MODEL_NAME" | grep -qiE "EPYC"; then
        # ── AMD EPYC (Server) ──
        #   amd_pstate=active   → Driver AMD P-state com CPPC ativo (requer kernel + BIOS suportar)
        #   amd_iommu=on        → Ativa AMD-Vi IOMMU
        #   iommu=pt            → Passthrough
        #   nps=1               → Nodes Per Socket = 1 (NUMA flat, sem fragmentação inter-CCD)
        #
        CPU_TYPE="amd_epyc"
        PSTATE_DRIVER="amd_pstate=active"
        IOMMU_FLAGS="amd_iommu=on iommu=pt"
        NUMA_FLAGS="nps=1"
        log_ok "Tipo: AMD EPYC Server"

        # Ajustes por geração (mapeamento family→Zen do kernel Linux):
        # family 23 (0x17) = Zen 1/Zen+/Zen 2 — Naples (7001), Rome (7002)
        # family 25 (0x19) = Zen 3/Zen 4    — Milan (7003), Genoa (9004), Bergamo (97x4), Siena (8004)
        # family 26 (0x1A) = Zen 5/Zen 5c   — Turin (9005)
        if [[ "$CPU_FAMILY" -eq 23 ]]; then
            log_info "Geração: Naples/Rome (Zen 1/Zen+/Zen 2) — family 23"
            # Zen 1/2 EPYC: amd_pstate requer kernel 5.17+ E CPPC habilitado no BIOS.
            # Em servidores antigos o BIOS frequentemente não expõe CPPC.
            # Por segurança, deixamos acpi-cpufreq assumir.
            PSTATE_DRIVER=""
            EXTRA_NOTES+=("EPYC Naples/Rome (Zen 1/2): amd_pstate não forçado — acpi-cpufreq usado (governor via GRUB)")

        elif [[ "$CPU_FAMILY" -eq 25 ]]; then
            log_info "Geração: Milan/Genoa/Bergamo/Siena (Zen 3/Zen 4) — family 25"
            # Zen 3 (Milan): amd_pstate em kernel 5.17+
            # Zen 4 (Genoa/Bergamo/Siena): amd_pstate em kernel 6.3+ (guided), 6.5+ ideal
            if [[ "$KERNEL_MAJOR" -lt 5 ]] || { [[ "$KERNEL_MAJOR" -eq 5 ]] && [[ "$KERNEL_MINOR" -lt 17 ]]; }; then
                log_warn "Kernel < 5.17: amd_pstate não disponível. Fallback para acpi-cpufreq."
                PSTATE_DRIVER=""
                EXTRA_NOTES+=("EPYC Zen 3/4 com kernel < 5.17: acpi-cpufreq usado como fallback")
            elif [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 3 ]]; then
                # Zen 4 em kernel 5.17-6.2 funciona limitadamente — usar guided
                PSTATE_DRIVER="amd_pstate=guided"
                log_warn "Kernel < 6.3 com Zen 4: usando amd_pstate=guided como fallback."
                EXTRA_NOTES+=("EPYC Zen 4 com kernel < 6.3: amd_pstate=guided (limitado)")
            fi
            # Siena (EPYC 8000 series, Zen 4c) prefere kernel 6.5+
            if echo "$MODEL_NAME" | grep -qiE "EPYC 8[0-9][0-9][0-9]"; then
                log_info "Sub-tipo: Siena (EPYC 8000 series, Zen 4c)"
                if [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 5 ]]; then
                    log_warn "Kernel < 6.5 para Siena: amd_pstate=guided recomendado."
                    PSTATE_DRIVER="amd_pstate=guided"
                fi
            fi

        elif [[ "$CPU_FAMILY" -eq 26 ]]; then
            log_info "Geração: Turin (Zen 5/Zen 5c) — family 26"
            # Turin (EPYC 9005): amd_pstate funcional em kernel 6.4+, default em 6.13+
            if [[ "$KERNEL_MAJOR" -lt 6 ]] || { [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 4 ]]; }; then
                log_warn "Kernel < 6.4: amd_pstate pode ser instável em Turin. Fallback para acpi-cpufreq."
                PSTATE_DRIVER=""
                EXTRA_NOTES+=("EPYC Turin com kernel < 6.4: acpi-cpufreq usado como fallback")
            elif [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 13 ]]; then
                EXTRA_NOTES+=("EPYC Turin com kernel < 6.13: amd_pstate=active forçado (default só em 6.13+)")
            fi
        else
            log_warn "EPYC com family ${CPU_FAMILY} desconhecida — usando configuração genérica"
            EXTRA_NOTES+=("EPYC family ${CPU_FAMILY} não mapeada explicitamente — verifique kernel docs")
        fi

        # Dual-socket EPYC
        if [[ "$SOCKETS" -ge 2 ]]; then
            log_warn "Dual-socket EPYC (${SOCKETS} sockets) — NUMA pinning recomendado!"
            EXTRA_NOTES+=("DUAL-SOCKET: Use 'numactl --cpunodebind=X --membind=X' para pinning do streaming ao socket local")
        fi

    elif echo "$MODEL_NAME" | grep -qiE "Threadripper"; then
        # ── AMD Threadripper / Threadripper PRO ──
        #   amd_pstate=active   → CPPC ativo (requer BIOS com CPPC habilitado)
        #   amd_iommu=on        → Ativa AMD-Vi IOMMU
        #   iommu=pt            → IOMMU em passthrough
        #   nps=1               → NUMA flat (essencial em multi-CCD, especialmente PRO)
        #
        CPU_TYPE="amd_threadripper"
        PSTATE_DRIVER="amd_pstate=active"
        IOMMU_FLAGS="amd_iommu=on iommu=pt"
        NUMA_FLAGS="nps=1"

        # Detectar PRO (workstation com mais memory channels e PCIe lanes)
        if echo "$MODEL_NAME" | grep -qiE "Threadripper.*PRO|PRO.*[0-9]{4}WX"; then
            log_ok "Tipo: AMD Threadripper PRO (workstation/server)"
            EXTRA_NOTES+=("Threadripper PRO: nps=1 essencial para NUMA flat com múltiplos CCDs")
        else
            log_ok "Tipo: AMD Threadripper (HEDT consumer)"
            EXTRA_NOTES+=("Threadripper: nps=1 adicionado para NUMA flat")
        fi

        # Ajustes por geração
        if [[ "$CPU_FAMILY" -eq 23 ]]; then
            log_info "Geração: Threadripper 1000/2000/3000 (Zen/Zen+/Zen 2) — family 23"
            PSTATE_DRIVER=""
            EXTRA_NOTES+=("Threadripper Zen/Zen+/Zen 2: sem amd_pstate, usando acpi-cpufreq")
        elif [[ "$CPU_FAMILY" -eq 25 ]]; then
            log_info "Geração: Threadripper 5000/7000 (Zen 3/Zen 4) — family 25"
            if [[ "$KERNEL_MAJOR" -lt 5 ]] || { [[ "$KERNEL_MAJOR" -eq 5 ]] && [[ "$KERNEL_MINOR" -lt 17 ]]; }; then
                log_warn "Kernel < 5.17: amd_pstate não disponível. Fallback para acpi-cpufreq."
                PSTATE_DRIVER=""
            fi
        elif [[ "$CPU_FAMILY" -eq 26 ]]; then
            log_info "Geração: Threadripper 9000 (Zen 5) — family 26"
            if [[ "$KERNEL_MAJOR" -lt 6 ]] || { [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 4 ]]; }; then
                log_warn "Kernel < 6.4 com Zen 5: amd_pstate=guided como fallback."
                PSTATE_DRIVER="amd_pstate=guided"
            fi
        fi

    elif echo "$MODEL_NAME" | grep -qiE "Ryzen"; then
        # ── AMD Ryzen (Desktop / Mobile / APU) ──
        #   amd_pstate=active   → CPPC ativo (requer BIOS com CPPC habilitado)
        #   amd_iommu=on        → Ativa AMD-Vi IOMMU
        #   iommu=pt            → IOMMU em passthrough (zero overhead de tradução para DMA)
        #
        CPU_TYPE="amd_ryzen"
        PSTATE_DRIVER="amd_pstate=active"
        IOMMU_FLAGS="amd_iommu=on iommu=pt"
        log_ok "Tipo: AMD Ryzen (Desktop/Mobile/APU)"

        # Ajustes por geração
        if [[ "$CPU_FAMILY" -eq 23 ]]; then
            log_info "Geração: Ryzen 1000/2000/3000 (Zen/Zen+/Zen 2) — family 23"
            PSTATE_DRIVER=""
            EXTRA_NOTES+=("Ryzen Zen/Zen+/Zen 2: sem amd_pstate, usando acpi-cpufreq (governor via GRUB)")
        elif [[ "$CPU_FAMILY" -eq 25 ]]; then
            log_info "Geração: Ryzen 5000/7000 (Zen 3/Zen 4) — family 25"
            if [[ "$KERNEL_MAJOR" -lt 5 ]] || { [[ "$KERNEL_MAJOR" -eq 5 ]] && [[ "$KERNEL_MINOR" -lt 17 ]]; }; then
                log_warn "Kernel < 5.17: amd_pstate não disponível. Fallback para acpi-cpufreq."
                PSTATE_DRIVER=""
            fi
        elif [[ "$CPU_FAMILY" -eq 26 ]]; then
            log_info "Geração: Ryzen 9000 / Strix Point / Strix Halo (Zen 5) — family 26"
            if [[ "$KERNEL_MAJOR" -lt 6 ]] || { [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 4 ]]; }; then
                log_warn "Kernel < 6.4 com Zen 5: amd_pstate pode estar limitado."
                PSTATE_DRIVER="amd_pstate=guided"
            fi
        fi

    else
        # ── AMD Genérico (Athlon, A-series, FX, Opteron antigo, etc.) ──
        CPU_TYPE="amd_generic"
        PSTATE_DRIVER="amd_pstate=active"
        IOMMU_FLAGS="amd_iommu=on iommu=pt"
        log_ok "Tipo: AMD Genérico"

        # CPUs AMD pre-Zen (family < 23): sem amd_pstate
        if [[ "$CPU_FAMILY" -lt 23 ]]; then
            log_warn "AMD pre-Zen detectado (family ${CPU_FAMILY}): sem amd_pstate"
            PSTATE_DRIVER=""
            EXTRA_NOTES+=("AMD pre-Zen: usando acpi-cpufreq")
        fi
    fi
else
    log_error "Vendor não suportado: ${VENDOR}"
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# CÁLCULO DE ISOLATION FLAGS (NUMA-aware, ativado por --nic)
# ══════════════════════════════════════════════════════════════════════════════
ISOLATION_FLAGS=""
HK_THREADS=""
ISOLATED_THREADS=""
NIC_NUMA=""
NUMA_CPULIST=""
NUMA_THREAD_COUNT=""
HK_COUNT=""
REMOTE_NUMAS=""

if [[ -n "$NIC" ]]; then
    log_section "ISOLATION NUMA-AWARE — análise da topologia"

    # Validar NIC e descobrir NUMA
    NIC_NUMA=$(validate_nic_and_get_numa "$NIC")
    log_ok "NIC '${NIC}' está no NUMA node ${NIC_NUMA}"

    # Listar threads do NUMA da NIC
    NUMA_CPULIST=$(get_numa_cpus "$NIC_NUMA")
    NUMA_THREAD_COUNT=$(count_threads_in_range "$NUMA_CPULIST")
    log_info "Threads no NUMA ${NIC_NUMA}: ${NUMA_CPULIST} (total: ${NUMA_THREAD_COUNT})"

    # Determinar housekeeping count (override ou heurística)
    if [[ -n "$HOUSEKEEPING_OVERRIDE" ]]; then
        if ! [[ "$HOUSEKEEPING_OVERRIDE" =~ ^[0-9]+$ ]] || [[ "$HOUSEKEEPING_OVERRIDE" -lt 1 ]]; then
            log_error "--housekeeping deve ser um inteiro positivo (recebido: '$HOUSEKEEPING_OVERRIDE')"
            exit 1
        fi
        HK_COUNT="$HOUSEKEEPING_OVERRIDE"
        log_info "Housekeeping count: ${HK_COUNT} (override via --housekeeping)"
    else
        HK_COUNT=$(calc_housekeeping_count "$NUMA_THREAD_COUNT")
        log_info "Housekeeping count: ${HK_COUNT} threads (heurística automática)"
    fi

    # Validar que sobram threads para isolation após reservar housekeeping
    if [[ "$HK_COUNT" -ge "$NUMA_THREAD_COUNT" ]]; then
        log_error "Housekeeping (${HK_COUNT}) >= threads do NUMA (${NUMA_THREAD_COUNT}). Não há threads para isolar."
        exit 1
    fi

    # Calcular conjuntos
    HK_THREADS=$(select_housekeeping_threads "$NUMA_CPULIST" "$HK_COUNT")
    ISOLATED_THREADS=$(calc_isolated_threads "$NUMA_CPULIST" "$HK_THREADS")

    # Validar: ambos os conjuntos devem ser não-vazios para produzir GRUB válido
    if [[ -z "$HK_THREADS" ]]; then
        log_error "Não foi possível determinar threads housekeeping (topology ausente?)"
        exit 1
    fi
    if [[ -z "$ISOLATED_THREADS" ]]; then
        log_error "Não há threads para isolar após reservar housekeeping"
        log_error "  NUMA cpus: ${NUMA_CPULIST}, Housekeeping: ${HK_THREADS}"
        exit 1
    fi

    log_ok "Housekeeping threads: ${HK_THREADS}"
    log_ok "Isolated threads:     ${ISOLATED_THREADS}"

    # Calcular NUMAs remotos (informativo)
    for node_dir in /sys/devices/system/node/node[0-9]*; do
        n=$(basename "$node_dir" | sed 's/node//')
        [[ "$n" == "$NIC_NUMA" ]] && continue
        remote_cpus=$(cat "${node_dir}/cpulist" 2>/dev/null)
        [[ -n "$remote_cpus" ]] && REMOTE_NUMAS+="NUMA ${n}: ${remote_cpus} | "
    done
    if [[ -n "$REMOTE_NUMAS" ]]; then
        log_info "NUMAs remotos (livres para scheduler default): ${REMOTE_NUMAS%| }"
    fi

    # Montar ISOLATION_FLAGS
    ISOLATION_FLAGS=" isolcpus=managed_irq,domain,${ISOLATED_THREADS}"
    ISOLATION_FLAGS+=" nohz_full=${ISOLATED_THREADS}"
    ISOLATION_FLAGS+=" rcu_nocbs=${ISOLATED_THREADS}"
    ISOLATION_FLAGS+=" irqaffinity=${HK_THREADS}"

    EXTRA_NOTES+=("Isolation: cores ${ISOLATED_THREADS} do NUMA ${NIC_NUMA} dedicados à aplicação")
    EXTRA_NOTES+=("Housekeeping: cores ${HK_THREADS} (NUMA ${NIC_NUMA}) absorvem IRQs residuais e kernel work")
    [[ -n "$REMOTE_NUMAS" ]] && EXTRA_NOTES+=("NUMAs remotos livres para serviços não-críticos (PHP-FPM, MySQL, etc)")
fi

# ══════════════════════════════════════════════════════════════════════════════
# MONTAGEM FINAL DA LINHA GRUB
# ══════════════════════════════════════════════════════════════════════════════
GRUB_LINE="${PSTATE_DRIVER}"
GRUB_LINE+="${COMMON_FLAGS}"
GRUB_LINE+="${PERF_BOOT_FLAGS}"
[[ -n "${INTEL_IDLE_FLAG}" ]] && GRUB_LINE+=" ${INTEL_IDLE_FLAG}"
[[ -n "$NUMA_FLAGS" ]]       && GRUB_LINE+=" ${NUMA_FLAGS}"
[[ -n "$ISOLATION_FLAGS" ]]  && GRUB_LINE+="${ISOLATION_FLAGS}"
GRUB_LINE+=" ${IOMMU_FLAGS}"

# Limpar espaços duplos e leading/trailing
GRUB_LINE=$(echo "$GRUB_LINE" | tr -s ' ' | sed 's/^ //;s/ $//')

echo ""
log_info "Linha GRUB completa gerada:"
echo ""
echo -e "  ${GREEN}GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_LINE}\"${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Aplicar no GRUB
# ─────────────────────────────────────────────────────────────────────────────
log_section "4/8 - APLICAR GRUB"

log_info "Backup: ${BACKUP_DIR}/grub.backup.${TIMESTAMP}"

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_LINE}\"|" "$GRUB_FILE"
    log_ok "GRUB_CMDLINE_LINUX_DEFAULT atualizado."
else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_LINE}\"" >> "$GRUB_FILE"
    log_ok "GRUB_CMDLINE_LINUX_DEFAULT adicionado."
fi

# Também garantir que GRUB_CMDLINE_LINUX não conflite
if grep -q '^GRUB_CMDLINE_LINUX=' "$GRUB_FILE"; then
    EXISTING_GRUB_LINUX=$(grep '^GRUB_CMDLINE_LINUX=' "$GRUB_FILE" | sed 's/GRUB_CMDLINE_LINUX=//' | tr -d '"')
    if echo "$EXISTING_GRUB_LINUX" | grep -qE "quiet|splash"; then
        log_info "Removendo 'quiet splash' de GRUB_CMDLINE_LINUX..."
        sed -i '/^GRUB_CMDLINE_LINUX=/s/\bquiet\b//g; /^GRUB_CMDLINE_LINUX=/s/\bsplash\b//g' "$GRUB_FILE"
    fi
fi

# Update GRUB
log_info "Atualizando GRUB..."
GRUB_UPDATED=0
if command -v update-grub &>/dev/null; then
    if update-grub 2>&1 | sed 's/^/    /'; then
        GRUB_UPDATED=1
    fi
elif command -v grub2-mkconfig &>/dev/null; then
    GRUB_CFG=""
    for candidate in /boot/grub2/grub.cfg /boot/efi/EFI/centos/grub.cfg /boot/efi/EFI/redhat/grub.cfg /boot/efi/EFI/fedora/grub.cfg /boot/efi/EFI/rocky/grub.cfg /boot/efi/EFI/almalinux/grub.cfg /boot/efi/EFI/debian/grub.cfg /boot/efi/EFI/ubuntu/grub.cfg; do
        [[ -f "$candidate" ]] && { GRUB_CFG="$candidate"; break; }
    done
    if [[ -n "$GRUB_CFG" ]]; then
        if grub2-mkconfig -o "$GRUB_CFG" 2>&1 | sed 's/^/    /'; then
            GRUB_UPDATED=1
        fi
    else
        log_warn "grub.cfg não encontrado. Execute manualmente."
    fi
else
    log_warn "Nenhum update-grub encontrado. Atualize o GRUB manualmente."
fi

if [[ $GRUB_UPDATED -eq 1 ]]; then
    log_ok "GRUB atualizado."
else
    log_warn "GRUB NÃO foi atualizado automaticamente — atualize manualmente antes de reiniciar!"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Instalar pacotes
# ─────────────────────────────────────────────────────────────────────────────
log_section "5/8 - INSTALAR PACOTES"

install_packages() {
    # Estratégia: suprimir TODA saída do gerenciador de pacotes (inclusive de pacotes
    # quebrados pré-existentes como mlnx-ofed-dkms, drivers DKMS falhando, etc),
    # tentar instalar os 3 pacotes que precisamos, e verificar pós-install.
    # Erros em outros pacotes não-relacionados NÃO devem afetar este script.

    local pkg
    local pkgs_needed=()
    local pkgs_missing=()

    if command -v apt-get &>/dev/null; then
        log_info "Gerenciador: apt (Debian/Ubuntu)"
        export DEBIAN_FRONTEND=noninteractive

        # Update silencioso — não aborta mesmo se algum repo quebrar
        apt-get update -qq >/dev/null 2>&1 || true

        # Tentar instalar — todo output (stdout+stderr) suprimido
        apt-get install -y -qq cpufrequtils net-tools bc >/dev/null 2>&1 || true

        # linux-tools: tentar versão específica do kernel atual
        KVER=$(uname -r)
        if apt-get install -y -qq "linux-tools-${KVER}" >/dev/null 2>&1; then
            log_ok "linux-tools instalado para kernel ${KVER}"
        else
            # Fallback para pacote genérico (kernels custom tipo XanMod não têm linux-tools específico)
            apt-get install -y -qq linux-tools-common linux-tools-generic >/dev/null 2>&1 || true
            log_info "linux-tools específico indisponível para kernel ${KVER} — script usará sysfs direto"
        fi
        pkgs_needed=(cpufrequtils net-tools bc)

    elif command -v dnf &>/dev/null; then
        log_info "Gerenciador: dnf (RHEL/Fedora)"
        dnf install -y -q kernel-tools net-tools bc >/dev/null 2>&1 || true
        pkgs_needed=(kernel-tools net-tools bc)

    elif command -v yum &>/dev/null; then
        log_info "Gerenciador: yum (CentOS)"
        yum install -y -q kernel-tools net-tools bc >/dev/null 2>&1 || true
        pkgs_needed=(kernel-tools net-tools bc)

    elif command -v pacman &>/dev/null; then
        log_info "Gerenciador: pacman (Arch)"
        pacman -S --noconfirm --needed cpupower net-tools bc >/dev/null 2>&1 || true
        pkgs_needed=(cpupower net-tools bc)

    else
        log_warn "Nenhum gerenciador de pacotes reconhecido (apt/dnf/yum/pacman)"
        log_info "Prosseguindo sem instalar pacotes — script usará métodos sysfs direto"
        return
    fi

    # Verificar pós-install: quais dos pacotes pedidos ficaram de fato instalados?
    for pkg in "${pkgs_needed[@]}"; do
        if command -v dpkg &>/dev/null; then
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && continue
        elif command -v rpm &>/dev/null; then
            rpm -q "$pkg" &>/dev/null && continue
        elif command -v pacman &>/dev/null; then
            pacman -Qi "$pkg" &>/dev/null && continue
        fi
        pkgs_missing+=("$pkg")
    done

    if [[ ${#pkgs_missing[@]} -eq 0 ]]; then
        log_ok "Pacotes verificados: ${pkgs_needed[*]}"
    else
        log_warn "Pacotes não instalados: ${pkgs_missing[*]}"
        log_info "O script usará sysfs direto — funciona sem estes pacotes"
    fi
}

install_packages

# ─────────────────────────────────────────────────────────────────────────────
# Governor performance + turbo (imediato)
# ─────────────────────────────────────────────────────────────────────────────
log_section "6/8 - GOVERNOR PERFORMANCE + TURBO BOOST"

set_governor_now() {
    local ok=0
    local method=""
    local avail_govs=""

    # Verificar se cpufreq está disponível no kernel atual
    if [[ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        log_warn "cpufreq não disponível no kernel atual (driver não carregado)"
        log_warn "Após reboot com o novo GRUB, o governor será aplicado automaticamente pelo serviço systemd"
        return
    fi

    # Verificar se 'performance' está nos governors disponíveis
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]]; then
        avail_govs=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
        log_info "Governors disponíveis: ${avail_govs}"

        if ! echo "$avail_govs" | grep -qw "performance"; then
            # Tentar carregar o módulo do governor performance
            modprobe cpufreq_performance 2>/dev/null || true

            # Verificar novamente
            avail_govs=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
            if ! echo "$avail_govs" | grep -qw "performance"; then
                log_warn "Governor 'performance' não disponível neste kernel/driver"
                log_info "Driver atual: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo 'N/A')"
                log_warn "Será aplicado após reboot com o novo GRUB"
                return
            fi
        fi
    fi

    # Mostrar driver atual
    local current_driver
    current_driver=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "N/A")
    log_info "Driver de frequência: ${current_driver}"

    # ── Método 1: sysfs direto (mais confiável, funciona com qualquer kernel) ──
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if [[ -f "$gov" ]]; then
            echo "performance" > "$gov" 2>/dev/null && ok=1
        fi
    done
    if [[ $ok -eq 1 ]]; then
        method="sysfs"
    fi

    # ── Método 2: cpupower (se sysfs falhou e cpupower funciona com este kernel) ──
    if [[ $ok -eq 0 ]] && command -v cpupower &>/dev/null; then
        if cpupower frequency-set -g performance &>/dev/null; then
            ok=1
            method="cpupower"
        fi
    fi

    # ── Método 3: cpufreq-set (fallback) ──
    if [[ $ok -eq 0 ]] && command -v cpufreq-set &>/dev/null; then
        local any_set=0
        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            n=$(basename "$cpu" | sed 's/cpu//')
            cpufreq-set -c "$n" -g performance &>/dev/null && any_set=1
        done
        if [[ $any_set -eq 1 ]]; then
            ok=1
            method="cpufreq-set"
        fi
    fi

    # Resultado
    if [[ $ok -eq 1 ]]; then
        # Confirmar contando quantos cores ficaram em performance
        local perf_count
        perf_count=0
        perf_count=$(grep -rl "performance" /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | wc -l) || perf_count=0
        log_ok "Governor 'performance' aplicado via ${method} (${perf_count}/${THREADS} cores)"
    else
        log_warn "Não foi possível definir governor agora"
        log_warn "Será aplicado automaticamente após reboot pelo serviço systemd"
    fi
}

set_governor_now

# Turbo/Boost
if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null
    log_ok "Intel Turbo Boost: HABILITADO"
fi
if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
    echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null
    log_ok "AMD Boost: HABILITADO"
fi

# Energy Performance Preference → performance
EPP_SET=0
for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    [[ -f "$epp" ]] && echo "performance" > "$epp" 2>/dev/null && EPP_SET=1
done
if [[ $EPP_SET -eq 1 ]]; then
    log_ok "Energy Performance Preference → performance"
else
    log_info "EPP não disponível neste driver (normal para acpi-cpufreq)"
fi

# Política C-state via GRUB (processor.max_cstate=1) é suficiente.
# Não fazemos lock de scaling_min_freq = max (prejudica Precision Boost em AMD
# e não traz benefício real em Intel com HWP/EPP em performance).
# Não forçamos C-states off via sysfs — max_cstate=1 no boot já limita a C1.
log_info "Política C-state: processor.max_cstate=1 via GRUB (permite C1 para liberar power budget)"

# cpufrequtils persistente (Debian/Ubuntu)
CPUFREQ_DEFAULT="/etc/default/cpufrequtils"
cat > "$CPUFREQ_DEFAULT" <<'EOF'
ENABLE="true"
GOVERNOR="performance"
MAX_SPEED="0"
MIN_SPEED="0"
EOF
chmod 0644 "$CPUFREQ_DEFAULT"
log_ok "Persistência: /etc/default/cpufrequtils → performance"

# ─────────────────────────────────────────────────────────────────────────────
# Ulimits para processos de streaming
# ─────────────────────────────────────────────────────────────────────────────
log_section "7/8 - ULIMITS"

# ── Limits (ulimits) para processos de streaming ──
LIMITS_FILE="/etc/security/limits.d/99-streaming.conf"
cat > "$LIMITS_FILE" <<'EOF'
# Streaming Performance - File descriptors e prioridade
*    soft    nofile    1048576
*    hard    nofile    1048576
*    soft    nproc     unlimited
*    hard    nproc     unlimited
*    soft    memlock   unlimited
*    hard    memlock   unlimited
root soft    nofile    1048576
root hard    nofile    1048576
EOF
chmod 0644 "$LIMITS_FILE"
log_ok "Ulimits configurados: ${LIMITS_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# Serviço systemd para persistência de TUDO no boot
# ─────────────────────────────────────────────────────────────────────────────
log_section "8/8 - SERVIÇO SYSTEMD PERSISTENTE"

SYSTEMD_SERVICE="/etc/systemd/system/cpu-performance.service"
TUNING_SCRIPT="/usr/local/bin/cpu-performance-tuner.sh"

cat > "$TUNING_SCRIPT" <<'BOOTSCRIPT'
#!/bin/bash
###############################################################################
# CPU Performance Tuner - Boot Script (executa a cada boot)
# Reaplica: governor performance, turbo/boost, EPP performance
# Nota: C-state policy vem do GRUB (processor.max_cstate=1), não do sysfs
###############################################################################

LOG_TAG="cpu-perf-tuner"

# ── 1. Carregar módulo governor performance (caso não esteja built-in) ──
modprobe cpufreq_performance 2>/dev/null || true

# ── 2. Aguardar cpufreq inicializar (pode demorar em boot) ──
for i in 1 2 3 4 5; do
    [ -d /sys/devices/system/cpu/cpu0/cpufreq ] && break
    sleep 1
done

# ── 3. Governor performance em todos os cores ──
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$gov" ] && echo "performance" > "$gov" 2>/dev/null
done

# ── 4. Turbo/Boost habilitado ──
[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null
[ -f /sys/devices/system/cpu/cpufreq/boost ] && echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null

# ── 5. Energy Performance Preference → performance ──
for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    [ -f "$epp" ] && echo "performance" > "$epp" 2>/dev/null
done

# Nota: C-state policy vem do GRUB (processor.max_cstate=1).
# Não tocamos em scaling_min_freq nem em cpuidle/state*/disable.

logger "$LOG_TAG: Boot tuning applied"
BOOTSCRIPT

chmod 0755 "$TUNING_SCRIPT"
log_ok "Boot script: ${TUNING_SCRIPT}"

cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=CPU Performance Tuner for Streaming (v2.0)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${TUNING_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$SYSTEMD_SERVICE"

systemctl daemon-reload
systemctl enable cpu-performance.service 2>/dev/null
log_ok "Serviço cpu-performance.service habilitado no boot."

# Executar agora
bash "$TUNING_SCRIPT" 2>/dev/null || true
log_ok "Tuning completo aplicado imediatamente."

# ─────────────────────────────────────────────────────────────────────────────
# Relatório final
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    RELATÓRIO FINAL                          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "  ${BOLD}CPU${NC}              ${MODEL_NAME}"
echo -e "  ${BOLD}Tipo${NC}             ${CPU_TYPE}"
echo -e "  ${BOLD}Sockets${NC}          ${SOCKETS}"
echo -e "  ${BOLD}Threads${NC}          ${THREADS}"
echo -e "  ${BOLD}RAM${NC}              ${TOTAL_RAM_GB} GB"
echo -e "  ${BOLD}Kernel${NC}           ${KERNEL_VER}"
echo ""

# Governor
echo -e "  ${BOLD}Governor:${NC}"
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    PERF_COUNT=0
    PERF_COUNT=$(grep -rl "performance" /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | wc -l) || PERF_COUNT=0
    echo -e "    CPU0: ${GREEN}${GOV}${NC}  |  Total em performance: ${GREEN}${PERF_COUNT}/${THREADS}${NC}"
else
    echo -e "    ${YELLOW}Disponível após reboot${NC}"
fi

# Frequência
echo -e "  ${BOLD}Frequência:${NC}"
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]]; then
    CUR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
    MAX=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
    [[ -n "$CUR" ]] && echo -e "    Atual: ${GREEN}$(( CUR / 1000 )) MHz${NC}"
    [[ -n "$MAX" ]] && echo -e "    Max:   ${GREEN}$(( MAX / 1000 )) MHz${NC}"
else
    echo -e "    ${YELLOW}Disponível após reboot (cpufreq não carregado)${NC}"
fi

# Turbo
echo -e "  ${BOLD}Turbo/Boost:${NC}"
if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    NT=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
    if [[ "$NT" -eq 0 ]]; then
        echo -e "    ${GREEN}Intel Turbo: ON${NC}"
    else
        echo -e "    ${RED}Intel Turbo: OFF${NC}"
    fi
elif [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
    B=$(cat /sys/devices/system/cpu/cpufreq/boost)
    if [[ "$B" -eq 1 ]]; then
        echo -e "    ${GREEN}AMD Boost: ON${NC}"
    else
        echo -e "    ${RED}AMD Boost: OFF${NC}"
    fi
else
    echo -e "    ${YELLOW}Status não disponível via sysfs (verificar após reboot)${NC}"
fi

echo ""
echo -e "  ${BOLD}Arquivos modificados/criados:${NC}"
echo "    ✓ ${GRUB_FILE} (backup: ${BACKUP_DIR}/grub.backup.${TIMESTAMP})"
echo "    ✓ ${CPUFREQ_DEFAULT}"
echo "    ✓ ${LIMITS_FILE}"
echo "    ✓ ${TUNING_SCRIPT}"
echo "    ✓ ${SYSTEMD_SERVICE}"

if [[ ${#EXTRA_NOTES[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}Notas:${NC}"
    for note in "${EXTRA_NOTES[@]+"${EXTRA_NOTES[@]}"}"; do
        echo -e "    ${YELLOW}⚠ ${note}${NC}"
    done
fi

# Sugestão de pinning para systemd services se isolation foi aplicada
if [[ -n "$ISOLATED_THREADS" ]]; then
    echo ""
    echo -e "  ${BOLD}${CYAN}Sugestão de pinning para seus systemd services:${NC}"
    echo ""
    echo -e "  ${CYAN}# Aplicação de streaming (XUI.One, nginx workers, FFmpeg):${NC}"
    echo -e "  ${GREEN}# /etc/systemd/system/xuione.service.d/cpuaffinity.conf${NC}"
    echo -e "  ${GREEN}[Service]${NC}"
    echo -e "  ${GREEN}CPUAffinity=${ISOLATED_THREADS}${NC}"
    echo ""
    echo -e "  ${CYAN}# Mesmo CPUAffinity para nginx.service e qualquer outro serviço hot-path${NC}"
    if [[ -n "$REMOTE_NUMAS" ]]; then
        echo ""
        echo -e "  ${CYAN}# Serviços não-críticos (PHP-FPM, MySQL) podem usar NUMA remoto:${NC}"
        # Pegar o primeiro NUMA remoto como sugestão
        first_remote=$(echo "$REMOTE_NUMAS" | awk -F'|' '{print $1}' | sed 's/.*: //')
        echo -e "  ${GREEN}# /etc/systemd/system/php-fpm.service.d/cpuaffinity.conf${NC}"
        echo -e "  ${GREEN}[Service]${NC}"
        echo -e "  ${GREEN}CPUAffinity=${first_remote}${NC}"
    fi
    echo ""
    echo -e "  ${CYAN}# Após criar os arquivos:${NC}"
    echo -e "  ${GREEN}sudo systemctl daemon-reload${NC}"
    echo -e "  ${GREEN}sudo systemctl restart xuione nginx${NC}"
fi

echo ""
echo -e "  ${BOLD}${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${YELLOW}║  REBOOT NECESSÁRIO para aplicar alterações do GRUB.       ║${NC}"
echo -e "  ${BOLD}${YELLOW}║                                                            ║${NC}"
echo -e "  ${BOLD}${YELLOW}║  Após reboot, verifique com:                               ║${NC}"
echo -e "  ${BOLD}${YELLOW}║    cat /proc/cmdline                                       ║${NC}"
echo -e "  ${BOLD}${YELLOW}║    cpupower frequency-info                                 ║${NC}"
echo -e "  ${BOLD}${YELLOW}║    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor║${NC}"
echo -e "  ${BOLD}${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
