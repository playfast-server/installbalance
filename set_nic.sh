#!/bin/bash
#
# nic_tune_all.sh - Tuning automatico de todas as NICs fisicas
#
# Configuracoes aplicadas em cada NIC fisica detectada:
#   - Filas (channels): maximo suportado (combined preferencialmente, rx/tx em fallback)
#   - Ring buffer RX/TX: maximo suportado
#   - Coalescing: adaptive-rx on, adaptive-tx off, rx-usecs=16, tx-frames=32
#
# Uso:
#   sudo ./nic_tune_all.sh              # aplica em todas
#   sudo ./nic_tune_all.sh --dry-run    # mostra o que faria
#   sudo ./nic_tune_all.sh --help       # ajuda
#   sudo ./nic_tune_all.sh -i eth0      # aplica apenas na NIC indicada
#

set -uo pipefail

# ---------- defaults ----------
DRY_RUN=0
TARGET_NIC=""
INCLUDE_WIRELESS=0

# ---------- parse args ----------
usage() {
    cat <<EOF
Uso: $0 [opcoes]

Opcoes:
  --dry-run            Mostra o que seria feito, sem aplicar nada
  -i, --interface NIC  Aplica apenas na interface especificada
  --include-wireless   Inclui interfaces wireless (padrao: ignora)
  -h, --help           Mostra esta ajuda

Sem argumentos, aplica em todas as NICs fisicas cabeadas detectadas.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)          DRY_RUN=1; shift ;;
        -i|--interface)     TARGET_NIC="${2:-}"; shift 2 ;;
        --include-wireless) INCLUDE_WIRELESS=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "Opcao desconhecida: $1"; usage; exit 1 ;;
    esac
done

# ---------- cores (so se TTY) ----------
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log()   { printf "%s[INFO]%s  %s\n"  "$BLUE"   "$NC" "$*"; }
ok()    { printf "%s[OK]%s    %s\n"  "$GREEN"  "$NC" "$*"; }
warn()  { printf "%s[WARN]%s  %s\n"  "$YELLOW" "$NC" "$*"; }
err()   { printf "%s[ERRO]%s  %s\n"  "$RED"    "$NC" "$*" >&2; }

# ---------- contadores p/ resumo ----------
TOTAL_NICS=0
declare -A NIC_RESULT  # ok | partial | fail | unsupported

# ---------- pre-checks ----------
if [[ $EUID -ne 0 && $DRY_RUN -eq 0 ]]; then
    err "Este script precisa ser executado como root (use sudo)"
    exit 1
fi

if ! command -v ethtool >/dev/null 2>&1; then
    err "ethtool nao encontrado. Instale com: apt install ethtool  (ou yum/dnf)"
    exit 1
fi

# ---------- helpers ----------

# Executa comando ou apenas mostra (dry-run). Captura saida em $RUN_OUT.
RUN_OUT=""
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [DRY-RUN] $*"
        RUN_OUT=""
        return 0
    fi
    RUN_OUT=$("$@" 2>&1)
    return $?
}

# Extrai valor numerico de uma chave dentro de um BLOCO de texto delimitado.
# Retorna string vazia se nao encontrar ou se valor for "n/a".
extract_value() {
    local input="$1"
    local key="$2"
    local val
    val=$(printf '%s\n' "$input" \
          | grep -E "^[[:space:]]*${key}:[[:space:]]" \
          | head -n1 \
          | awk '{print $NF}' \
          | tr -d '[:space:]')
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
    else
        echo ""
    fi
}

# Detecta se interface eh wireless
is_wireless() {
    local nic="$1"
    [[ -d "/sys/class/net/${nic}/wireless" ]] || \
    [[ -L "/sys/class/net/${nic}/phy80211" ]]
}

# Detecta se interface eh fisica/real (NIC ou virtio)
is_physical() {
    local nic="$1"
    local sys="/sys/class/net/${nic}"

    [[ "$nic" == "lo" ]]              && return 1
    [[ -d "${sys}/bridge" ]]          && return 1
    [[ -d "${sys}/bonding" ]]         && return 1
    [[ -e "${sys}/tun_flags" ]]       && return 1   # tun/tap

    # Tem que ter device real
    [[ -e "${sys}/device" ]]          || return 1

    # Exclui interfaces filhas (vlan/macvlan tem 'lower_*')
    local lower
    lower=$(find "$sys" -maxdepth 1 -name 'lower_*' 2>/dev/null | head -n1)
    [[ -n "$lower" ]] && return 1

    # Exclui dummy
    if [[ -L "${sys}/device/driver" ]]; then
        local drv
        drv=$(basename "$(readlink "${sys}/device/driver" 2>/dev/null)" 2>/dev/null)
        [[ "$drv" == "dummy" ]] && return 1
    fi

    return 0
}

# Detecta NICs fisicas (uma por linha, seguro p/ mapfile)
get_physical_nics() {
    local nic name
    for nic in /sys/class/net/*; do
        [[ -d "$nic" ]] || continue
        name=$(basename "$nic")

        is_physical "$name" || continue

        if is_wireless "$name" && [[ $INCLUDE_WIRELESS -eq 0 ]]; then
            continue
        fi

        printf '%s\n' "$name"
    done
}

# ---------- tuning de uma NIC ----------
tune_nic() {
    local nic="$1"
    local status_channels="skip" status_ring="skip" status_coal="skip"

    echo
    echo "============================================================"
    log "Configurando NIC: ${YELLOW}${nic}${NC}"
    echo "============================================================"

    # Estado e driver
    local state driver
    state=$(cat "/sys/class/net/${nic}/operstate" 2>/dev/null || echo "unknown")
    if [[ -L "/sys/class/net/${nic}/device/driver" ]]; then
        driver=$(basename "$(readlink "/sys/class/net/${nic}/device/driver")")
    else
        driver="unknown"
    fi
    log "Estado: $state | Driver: $driver"

    if [[ "$state" == "up" ]]; then
        warn "Interface esta UP - pode haver pequena interrupcao de trafego ao reconfigurar"
    fi

    # ---------- 1. FILAS (CHANNELS) ----------
    log "[1/3] Lendo capacidade de filas (channels)..."
    local ch_out ch_rc
    ch_out=$(ethtool -l "$nic" 2>&1)
    ch_rc=$?

    if [[ $ch_rc -ne 0 ]] || echo "$ch_out" | grep -qiE "Operation not supported|no channel parameters"; then
        warn "$nic nao suporta configuracao de filas"
        status_channels="unsupported"
    else
        # Isola APENAS as duas secoes (com awk, sem incluir linhas separadoras)
        local max_section preset_section
        max_section=$(echo "$ch_out"   | awk '/Pre-set maximums:/{f=1; next} /Current hardware settings:/{f=0} f')
        preset_section=$(echo "$ch_out" | awk '/Current hardware settings:/{f=1; next} f')

        local max_combined max_rx max_tx
        max_combined=$(extract_value "$max_section" "Combined")
        max_rx=$(extract_value "$max_section" "RX")
        max_tx=$(extract_value "$max_section" "TX")

        local cur_combined cur_rx cur_tx
        cur_combined=$(extract_value "$preset_section" "Combined")
        cur_rx=$(extract_value "$preset_section" "RX")
        cur_tx=$(extract_value "$preset_section" "TX")

        log "  Atuais  -> Combined:${cur_combined:-N/A}  RX:${cur_rx:-N/A}  TX:${cur_tx:-N/A}"
        log "  Maximos -> Combined:${max_combined:-N/A}  RX:${max_rx:-N/A}  TX:${max_tx:-N/A}"

        # Estrategia: tenta combined primeiro; se >0, usa combined.
        # Caso contrario, usa rx/tx separados.
        local applied=0
        if [[ -n "$max_combined" && "$max_combined" -gt 0 ]]; then
            if [[ "$cur_combined" == "$max_combined" ]]; then
                ok "Combined ja esta no maximo ($max_combined) - sem alteracao"
                applied=1
                status_channels="ok"
            else
                log "  Aplicando combined=$max_combined"
                if run ethtool -L "$nic" combined "$max_combined"; then
                    ok "Filas combined ajustadas para $max_combined"
                    applied=1
                    status_channels="ok"
                else
                    warn "Falha em combined: ${RUN_OUT:-(sem msg)}"
                fi
            fi
        fi

        if [[ $applied -eq 0 && -n "$max_rx" && "$max_rx" -gt 0 \
              && -n "$max_tx" && "$max_tx" -gt 0 ]]; then
            if [[ "$cur_rx" == "$max_rx" && "$cur_tx" == "$max_tx" ]]; then
                ok "RX/TX ja estao no maximo (RX=$max_rx TX=$max_tx)"
                status_channels="ok"
            else
                log "  Aplicando rx=$max_rx tx=$max_tx"
                if run ethtool -L "$nic" rx "$max_rx" tx "$max_tx"; then
                    ok "Filas RX=$max_rx TX=$max_tx aplicadas"
                    status_channels="ok"
                else
                    warn "Falha em rx/tx: ${RUN_OUT:-(sem msg)}"
                    status_channels="fail"
                fi
            fi
        elif [[ $applied -eq 0 ]]; then
            warn "Sem valores validos de filas para aplicar"
            status_channels="unsupported"
        fi
    fi

    # ---------- 2. RING BUFFER ----------
    log "[2/3] Lendo capacidade de ring buffer..."
    local rg_out rg_rc
    rg_out=$(ethtool -g "$nic" 2>&1)
    rg_rc=$?

    if [[ $rg_rc -ne 0 ]] || echo "$rg_out" | grep -qiE "Operation not supported|ring parameters not supported"; then
        warn "$nic nao suporta configuracao de ring buffer"
        status_ring="unsupported"
    else
        local max_section_rg cur_section_rg
        max_section_rg=$(echo "$rg_out"  | awk '/Pre-set maximums:/{f=1; next} /Current hardware settings:/{f=0} f')
        cur_section_rg=$(echo "$rg_out"  | awk '/Current hardware settings:/{f=1; next} f')

        local max_ring_rx max_ring_tx cur_ring_rx cur_ring_tx
        max_ring_rx=$(extract_value "$max_section_rg" "RX")
        max_ring_tx=$(extract_value "$max_section_rg" "TX")
        cur_ring_rx=$(extract_value "$cur_section_rg" "RX")
        cur_ring_tx=$(extract_value "$cur_section_rg" "TX")

        log "  Atual   -> RX:${cur_ring_rx:-N/A}  TX:${cur_ring_tx:-N/A}"
        log "  Maximo  -> RX:${max_ring_rx:-N/A}  TX:${max_ring_tx:-N/A}"

        if [[ -n "$max_ring_rx" && "$max_ring_rx" -gt 0 \
              && -n "$max_ring_tx" && "$max_ring_tx" -gt 0 ]]; then
            if [[ "$cur_ring_rx" == "$max_ring_rx" && "$cur_ring_tx" == "$max_ring_tx" ]]; then
                ok "Ring ja esta no maximo (RX=$max_ring_rx TX=$max_ring_tx)"
                status_ring="ok"
            else
                log "  Aplicando rx=$max_ring_rx tx=$max_ring_tx"
                if run ethtool -G "$nic" rx "$max_ring_rx" tx "$max_ring_tx"; then
                    ok "Ring buffer ajustado: RX=$max_ring_rx TX=$max_ring_tx"
                    status_ring="ok"
                else
                    warn "Falha no ring: ${RUN_OUT:-(sem msg)}"
                    status_ring="fail"
                fi
            fi
        else
            warn "Sem valores validos de ring buffer"
            status_ring="unsupported"
        fi
    fi

    # ---------- 3. COALESCING ----------
    log "[3/3] Configurando interrupt coalescing..."
    local co_out co_rc
    co_out=$(ethtool -c "$nic" 2>&1)
    co_rc=$?

    if [[ $co_rc -ne 0 ]] || echo "$co_out" | grep -qiE "Operation not supported|Coalesce parameters not supported"; then
        warn "$nic nao suporta interrupt coalescing"
        status_coal="unsupported"
    else
        log "  Aplicando: adaptive-rx on, adaptive-tx off, rx-usecs=16, tx-frames=32"

        # Tenta tudo de uma vez primeiro (caminho feliz)
        if run ethtool -C "$nic" adaptive-rx on adaptive-tx off rx-usecs 16 tx-frames 32; then
            ok "Coalescing aplicado integralmente"
            status_coal="ok"
        else
            warn "Falha em batch: ${RUN_OUT:-(sem msg)}"
            warn "Tentando parametros individualmente..."

            local fails=0 successes=0

            # Tenta os adaptives juntos (alguns drivers exigem)
            if run ethtool -C "$nic" adaptive-rx on adaptive-tx off; then
                ok "  adaptive-rx on, adaptive-tx off"
                successes=$((successes+1))
            else
                if run ethtool -C "$nic" adaptive-rx on; then
                    ok "  adaptive-rx on"; successes=$((successes+1))
                else
                    warn "  adaptive-rx on falhou: ${RUN_OUT}"; fails=$((fails+1))
                fi
                if run ethtool -C "$nic" adaptive-tx off; then
                    ok "  adaptive-tx off"; successes=$((successes+1))
                else
                    warn "  adaptive-tx off falhou: ${RUN_OUT}"; fails=$((fails+1))
                fi
            fi

            if run ethtool -C "$nic" rx-usecs 16; then
                ok "  rx-usecs=16"; successes=$((successes+1))
            else
                warn "  rx-usecs 16 falhou: ${RUN_OUT}"; fails=$((fails+1))
            fi

            if run ethtool -C "$nic" tx-frames 32; then
                ok "  tx-frames=32"; successes=$((successes+1))
            else
                warn "  tx-frames 32 falhou: ${RUN_OUT}"; fails=$((fails+1))
            fi

            if [[ $fails -eq 0 ]]; then
                status_coal="ok"
            elif [[ $successes -gt 0 ]]; then
                status_coal="partial"
            else
                status_coal="fail"
            fi
        fi
    fi

    # ---------- resultado da NIC ----------
    if [[ "$status_channels" == "fail" || "$status_ring" == "fail" || "$status_coal" == "fail" ]]; then
        NIC_RESULT[$nic]="fail"
    elif [[ "$status_coal" == "partial" ]]; then
        NIC_RESULT[$nic]="partial"
    elif [[ "$status_channels" == "ok" || "$status_ring" == "ok" || "$status_coal" == "ok" ]]; then
        NIC_RESULT[$nic]="ok"
    else
        NIC_RESULT[$nic]="unsupported"
    fi

    log "Resultado: channels=$status_channels ring=$status_ring coalesce=$status_coal"
}

# ---------- MAIN ----------
echo
echo "############################################################"
echo "#  NIC Tuning - All Interfaces                             #"
echo "#  Filas:MAX | Ring:MAX | Coalesce: arx=on atx=off         #"
echo "#                        rx-usecs=16 tx-frames=32          #"
echo "############################################################"

[[ $DRY_RUN -eq 1 ]] && warn "MODO DRY-RUN: nenhuma alteracao sera aplicada"

# Determina lista de NICs
NICS=()
if [[ -n "$TARGET_NIC" ]]; then
    if [[ ! -d "/sys/class/net/${TARGET_NIC}" ]]; then
        err "Interface '$TARGET_NIC' nao existe"
        exit 1
    fi
    NICS=("$TARGET_NIC")
else
    mapfile -t NICS < <(get_physical_nics)
fi

if [[ ${#NICS[@]} -eq 0 ]]; then
    err "Nenhuma NIC fisica detectada"
    [[ $INCLUDE_WIRELESS -eq 0 ]] && log "Use --include-wireless para incluir interfaces wireless"
    exit 1
fi

TOTAL_NICS=${#NICS[@]}
log "NICs alvo ($TOTAL_NICS): ${NICS[*]}"

for nic in "${NICS[@]}"; do
    tune_nic "$nic"
done

# ---------- resumo final ----------
echo
echo "============================================================"
echo "                        RESUMO"
echo "============================================================"
ok_count=0; fail_count=0; partial_count=0; unsup_count=0
for nic in "${NICS[@]}"; do
    case "${NIC_RESULT[$nic]:-unknown}" in
        ok)          ok    "$nic - tudo OK"               ; ok_count=$((ok_count+1)) ;;
        partial)     warn  "$nic - parcialmente aplicado" ; partial_count=$((partial_count+1)) ;;
        fail)        err   "$nic - falhou"                ; fail_count=$((fail_count+1)) ;;
        unsupported) warn  "$nic - nao suportado"         ; unsup_count=$((unsup_count+1)) ;;
        *)           warn  "$nic - estado desconhecido" ;;
    esac
done

echo
echo "Total: $TOTAL_NICS | OK: $ok_count | Parcial: $partial_count | Falha: $fail_count | NaoSuportado: $unsup_count"
echo "============================================================"
echo
log "Para verificar: ethtool -l <nic> ; ethtool -g <nic> ; ethtool -c <nic>"
echo

# Exit codes:
#   0 = nada falhou
#   1 = todas falharam
#   2 = falha parcial em alguma NIC
if [[ $fail_count -gt 0 && $ok_count -eq 0 ]]; then
    exit 1
elif [[ $fail_count -gt 0 || $partial_count -gt 0 ]]; then
    exit 2
fi
exit 0
