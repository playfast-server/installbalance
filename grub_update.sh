#!/bin/bash
###############################################################################
#  CPU GRUB Tuner v1.0 (lite)
#  Auto-detect CPU + Configurar GRUB (apenas)
#  Foco: Streaming / Máximo throughput / Mínima latência de tráfego
#  Compatível com: Intel Xeon, AMD Ryzen, AMD EPYC, AMD Threadripper
#  Requer: root / sudo
#
#  Sem isolation NUMA, sem cpufrequtils, sem ulimits, sem systemd.
#  Apenas edita GRUB_CMDLINE_LINUX_DEFAULT e roda update-grub.
###############################################################################

set -euo pipefail

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
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1" >&2; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $1" >&2; }
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
echo -e "${BOLD}║         CPU GRUB Tuner v1.0 (lite) - GRUB only              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
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

log_section "1/3 - DETECÇÃO DE HARDWARE"

# ─────────────────────────────────────────────────────────────────────────────
# Detectar CPU
# ─────────────────────────────────────────────────────────────────────────────
VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
MODEL_NAME=$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')
CPU_FAMILY=$(grep -m1 'cpu family' /proc/cpuinfo | awk '{print $4}')
THREADS=$(grep -c '^processor' /proc/cpuinfo || echo 0)
SOCKETS=$(grep 'physical id' /proc/cpuinfo | sort -u | wc -l || true)
[[ "$SOCKETS" -eq 0 ]] && SOCKETS=1
# Defesa: CPU_FAMILY pode estar vazio em containers minimal ou /proc não-padrão.
# Comparações [[ "$CPU_FAMILY" -eq N ]] quebram com set -u se não-numérico.
[[ "$CPU_FAMILY" =~ ^[0-9]+$ ]] || CPU_FAMILY=0
[[ "$THREADS" =~ ^[0-9]+$ ]] || THREADS=1
KERNEL_VER=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_VER" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VER" | cut -d. -f2)
# Defesa contra kernels custom com formato estranho — comparações usam -lt/-eq
# e quebram em set -u se valor não for numérico. Default 0 quando não-numérico.
[[ "$KERNEL_MAJOR" =~ ^[0-9]+$ ]] || KERNEL_MAJOR=0
[[ "$KERNEL_MINOR" =~ ^[0-9]+$ ]] || KERNEL_MINOR=0

log_info "CPU:               ${BOLD}${MODEL_NAME}${NC}"
log_info "Vendor:            ${VENDOR}"
log_info "Family:            ${CPU_FAMILY}"
log_info "Threads totais:    ${THREADS}"
log_info "Sockets:           ${SOCKETS}"
log_info "Kernel:            ${KERNEL_VER}"

# ─────────────────────────────────────────────────────────────────────────────
# Classificar CPU e montar GRUB line
# ─────────────────────────────────────────────────────────────────────────────
log_section "2/3 - MONTAGEM DA LINHA GRUB"

CPU_TYPE="unknown"
PSTATE_DRIVER=""
INTEL_IDLE_FLAG=""
IOMMU_FLAGS=""
EXTRA_NOTES=()

# ══════════════════════════════════════════════════════════════════════════════
# BLOCO 1: Parâmetros comuns — aplicados em Intel E AMD
# ══════════════════════════════════════════════════════════════════════════════
#
# ── Performance / segurança vs. velocidade ──
#   mitigations=off                       → Desabilita TODAS as mitigações de CPU (Spectre, Meltdown, MDS,
#                                           L1TF, Retbleed, Downfall, etc.) — MÁXIMO desempenho.
#                                           Ganho típico: 8-15% PPS em workloads com muito syscall.
#                                           Risco: servidor multi-tenant com código não confiável.
#
# ── Clocksource ──
#   tsc=reliable                          → Marca TSC como confiável (desliga watchdog que pode marcar TSC
#                                           como instável e fazer fallback para HPET — regressão até 90% em rede).
#   clocksource=tsc                       → Força TSC como clocksource (menor overhead em gettimeofday/clock_gettime).
#   hpet=disable                          → Desabilita HPET (evita interrupções do timer legado, libera IRQ).
#
# ── Watchdogs / detection ──
#   nowatchdog                            → Desabilita watchdog do kernel (remove NMIs periódicos em todos os cores).
#   nmi_watchdog=0                        → Desabilita NMI watchdog especificamente (complementa nowatchdog).
#   nosoftlockup                          → Desabilita softlockup detection (kthread watchdog/N).
#   skew_tick=1                           → Desalinha timer ticks entre cores (reduz contenção de cache lines
#                                           e locks de scheduler/timer em sistemas com 32+ threads).
#
# ── Subsistemas dispensáveis ──
#   audit=0                               → Desabilita subsistema de auditoria (remove overhead de syscall logging).
#   noresume                              → Desabilita resume de hibernação (boot rápido, sem busca de imagem).
#   selinux=0                             → Desabilita SELinux (RHEL/CentOS). Inócuo em Ubuntu/Debian.
#   apparmor=0                            → Desabilita AppArmor (Ubuntu/Debian). Inócuo em RHEL/CentOS.
#
# ── Workqueue / PCIe ──
#   workqueue.power_efficient=0           → Force workqueues per-CPU (cache locality), em vez de unbound (power saving).
#                                           Importante para netfilter, conntrack, e workqueues de rede em geral.
#   pcie_aspm=off                         → Desabilita PCIe Active State Power Management (latência zero em
#                                           NICs 25G+/100G — wake-up de L1 mata throughput consistente).
#
# ── Frequência / C-states ──
#   cpufreq.default_governor=performance  → Define governor performance no boot do kernel (kernel 5.9+).
#   processor.max_cstate=1                → Driver acpi_idle: permite só C0+C1. Bloqueia C2/C3/C6/C7 (latência 100μs+).
#                                           Em Intel com intel_idle ativo, este flag é ignorado — por isso
#                                           adicionamos intel_idle.max_cstate=1 no bloco Intel.
#
# ── Misc ──
#   random.trust_cpu=on                   → Usa RDRAND/RDSEED como fonte de entropia (boot rápido + SSL handshakes).
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
COMMON_FLAGS+=" random.trust_cpu=on"

# ══════════════════════════════════════════════════════════════════════════════
# BLOCO 2: THP (permite hugepages opt-in)
# ══════════════════════════════════════════════════════════════════════════════
#
#   transparent_hugepage=madvise     → THP opt-in (apps que pedem via madvise() ganham hugepages,
#                                      apps de streaming com muitas alocações pequenas ficam em 4KB,
#                                      evita latency spikes por compaction/defrag do khugepaged)
#
PERF_BOOT_FLAGS=""
PERF_BOOT_FLAGS+=" transparent_hugepage=madvise"

# ══════════════════════════════════════════════════════════════════════════════
# BLOCO 3: Parâmetros específicos por vendor/modelo
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$VENDOR" == "GenuineIntel" ]]; then
    # ── INTEL ──────────────────────────────────────────────────────────────
    #   intel_pstate=active          → Driver Intel P-state em modo active (HWP direto)
    #   intel_idle.max_cstate=1      → Limita o driver intel_idle a C0+C1 (defesa em profundidade
    #                                  sobre processor.max_cstate=1, que é ignorado quando intel_idle
    #                                  está ativo). Wake-up via MWAIT ~1μs.
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

    elif echo "$MODEL_NAME" | grep -qiE "xeon.*d-?[0-9]"; then
        CPU_TYPE="intel_xeon_d"
        log_ok "Tipo: Intel Xeon-D (Embedded — Skylake-D / Ice Lake-D)"

    elif echo "$MODEL_NAME" | grep -qiE "xeon.*(e5|e7|e3)"; then
        CPU_TYPE="intel_xeon_legacy"
        log_ok "Tipo: Intel Xeon E-series (Broadwell / Haswell / Ivy Bridge)"

        # Broadwell/Haswell com kernel antigo: intel_pstate pode falhar
        if [[ "$KERNEL_MAJOR" -lt 4 ]] || { [[ "$KERNEL_MAJOR" -eq 4 ]] && [[ "$KERNEL_MINOR" -lt 10 ]]; }; then
            log_warn "Kernel < 4.10: usando intel_pstate=disable (fallback acpi-cpufreq)"
            PSTATE_DRIVER="intel_pstate=disable"
            EXTRA_NOTES+=("Xeon E-series com kernel antigo: governor virá do cpufreq.default_governor=performance")
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
    # Cores ociosos podem entrar em C-states profundos liberando PPT budget
    # para cores ativos boostarem ao máximo via Precision Boost.

    if echo "$MODEL_NAME" | grep -qiE "EPYC"; then
        # ── AMD EPYC (Server) ──
        #   amd_pstate=active   → Driver AMD P-state com CPPC ativo (requer kernel + BIOS suportar)
        #   amd_iommu=on        → Ativa AMD-Vi IOMMU
        #   iommu=pt            → Passthrough
        #
        # NOTA: NPS (Nodes Per Socket) é configuração de BIOS (Advanced > AMD CBS >
        # DF Common Options > Memory Addressing > NUMA Nodes per Socket).
        # Configurar nps=1 NO BIOS para EPYC multi-CCD em workloads de rede.
        #
        CPU_TYPE="amd_epyc"
        PSTATE_DRIVER="amd_pstate=active"
        IOMMU_FLAGS="amd_iommu=on iommu=pt"
        log_ok "Tipo: AMD EPYC Server"

        # Ajustes por geração (mapeamento family→Zen do kernel Linux):
        # family 23 (0x17) = Zen 1/Zen+/Zen 2 — Naples (7001), Rome (7002)
        # family 25 (0x19) = Zen 3/Zen 4    — Milan (7003), Genoa (9004), Bergamo (97x4), Siena (8004)
        # family 26 (0x1A) = Zen 5/Zen 5c   — Turin (9005)
        if [[ "$CPU_FAMILY" -eq 23 ]]; then
            log_info "Geração: Naples/Rome (Zen 1/Zen+/Zen 2) — family 23"
            PSTATE_DRIVER=""
            EXTRA_NOTES+=("EPYC Naples/Rome (Zen 1/2): amd_pstate não forçado — acpi-cpufreq usado")

        elif [[ "$CPU_FAMILY" -eq 25 ]]; then
            log_info "Geração: Milan/Genoa/Bergamo/Siena (Zen 3/Zen 4) — family 25"
            if [[ "$KERNEL_MAJOR" -lt 5 ]] || { [[ "$KERNEL_MAJOR" -eq 5 ]] && [[ "$KERNEL_MINOR" -lt 17 ]]; }; then
                log_warn "Kernel < 5.17: amd_pstate não disponível. Fallback para acpi-cpufreq."
                PSTATE_DRIVER=""
                EXTRA_NOTES+=("EPYC Zen 3/4 com kernel < 5.17: acpi-cpufreq usado como fallback")
            elif [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 3 ]]; then
                PSTATE_DRIVER="amd_pstate=guided"
                log_warn "Kernel < 6.3 com Zen 4: usando amd_pstate=guided como fallback."
                EXTRA_NOTES+=("EPYC Zen 4 com kernel < 6.3: amd_pstate=guided (limitado)")
            fi
            if echo "$MODEL_NAME" | grep -qiE "EPYC 8[0-9][0-9][0-9]"; then
                log_info "Sub-tipo: Siena (EPYC 8000 series, Zen 4c)"
                if [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 5 ]]; then
                    log_warn "Kernel < 6.5 para Siena: amd_pstate=guided recomendado."
                    PSTATE_DRIVER="amd_pstate=guided"
                fi
            fi

        elif [[ "$CPU_FAMILY" -eq 26 ]]; then
            log_info "Geração: Turin (Zen 5/Zen 5c) — family 26"
            if [[ "$KERNEL_MAJOR" -lt 6 ]] || { [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 4 ]]; }; then
                log_warn "Kernel < 6.4: amd_pstate pode ser instável em Turin. Fallback para acpi-cpufreq."
                PSTATE_DRIVER=""
                EXTRA_NOTES+=("EPYC Turin com kernel < 6.4: acpi-cpufreq usado como fallback")
            elif [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 13 ]]; then
                EXTRA_NOTES+=("EPYC Turin com kernel < 6.13: amd_pstate=active forçado (default só em 6.13+)")
            fi
        else
            log_warn "EPYC com family ${CPU_FAMILY} desconhecida — usando configuração genérica"
        fi

        # Avisos para EPYC
        EXTRA_NOTES+=("EPYC: configure nps=1 NO BIOS (Advanced > AMD CBS > DF Common Options) para multi-CCD")
        if [[ "$SOCKETS" -ge 2 ]]; then
            log_warn "Dual-socket EPYC (${SOCKETS} sockets) — NUMA pinning recomendado!"
            EXTRA_NOTES+=("DUAL-SOCKET: Use 'numactl --cpunodebind=X --membind=X' para pinning ao socket local")
        fi

    elif echo "$MODEL_NAME" | grep -qiE "Threadripper"; then
        # ── AMD Threadripper / Threadripper PRO ──
        CPU_TYPE="amd_threadripper"
        PSTATE_DRIVER="amd_pstate=active"
        IOMMU_FLAGS="amd_iommu=on iommu=pt"

        if echo "$MODEL_NAME" | grep -qiE "Threadripper.*PRO|PRO.*[0-9]{4}WX"; then
            log_ok "Tipo: AMD Threadripper PRO (workstation/server)"
            EXTRA_NOTES+=("Threadripper PRO: configure nps=1 NO BIOS para NUMA flat com múltiplos CCDs")
        else
            log_ok "Tipo: AMD Threadripper (HEDT consumer)"
        fi

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
        CPU_TYPE="amd_ryzen"
        PSTATE_DRIVER="amd_pstate=active"
        IOMMU_FLAGS="amd_iommu=on iommu=pt"
        log_ok "Tipo: AMD Ryzen (Desktop/Mobile/APU)"

        if [[ "$CPU_FAMILY" -eq 23 ]]; then
            log_info "Geração: Ryzen 1000/2000/3000 (Zen/Zen+/Zen 2) — family 23"
            PSTATE_DRIVER=""
            EXTRA_NOTES+=("Ryzen Zen/Zen+/Zen 2: sem amd_pstate, usando acpi-cpufreq")
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
# MONTAGEM FINAL DA LINHA GRUB
# ══════════════════════════════════════════════════════════════════════════════
GRUB_LINE="${PSTATE_DRIVER}"
GRUB_LINE+="${COMMON_FLAGS}"
GRUB_LINE+="${PERF_BOOT_FLAGS}"
[[ -n "${INTEL_IDLE_FLAG}" ]] && GRUB_LINE+=" ${INTEL_IDLE_FLAG}"
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
log_section "3/3 - APLICAR GRUB"

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
        # Remove quiet/splash, depois colapsa espaços múltiplos e limpa aspas com só espaço
        sed -i '
            /^GRUB_CMDLINE_LINUX=/ {
                s/\bquiet\b//g
                s/\bsplash\b//g
                s/  */ /g
                s/="\s*/="/
                s/\s*"$/"/
            }' "$GRUB_FILE"
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
echo -e "  ${BOLD}Kernel${NC}           ${KERNEL_VER}"
echo ""

echo -e "  ${BOLD}Arquivos modificados:${NC}"
echo "    ✓ ${GRUB_FILE} (backup: ${BACKUP_DIR}/grub.backup.${TIMESTAMP})"

if [[ ${#EXTRA_NOTES[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}Notas:${NC}"
    for note in "${EXTRA_NOTES[@]+"${EXTRA_NOTES[@]}"}"; do
        echo -e "    ${YELLOW}⚠ ${note}${NC}"
    done
fi

echo ""
echo -e "  ${BOLD}${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${YELLOW}║  REBOOT NECESSÁRIO para aplicar alterações do GRUB.            ║${NC}"
echo -e "  ${BOLD}${YELLOW}║                                                                ║${NC}"
echo -e "  ${BOLD}${YELLOW}║  Após reboot, verifique com:                                   ║${NC}"
echo -e "  ${BOLD}${YELLOW}║    cat /proc/cmdline                                           ║${NC}"
echo -e "  ${BOLD}${YELLOW}║    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   ║${NC}"
echo -e "  ${BOLD}${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
