#!/bin/bash
###############################################################################
#  XUI.One CPU Affinity Setter
#  Lê isolcpus= e irqaffinity= de /etc/default/grub, subtrai os cores de
#  housekeeping do range isolado, e seta CPUAffinity= no service do XUI.One.
###############################################################################

set -euo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $1"; }

GRUB_FILE="/etc/default/grub"
SERVICE_FILE="/etc/systemd/system/xuione.service"

# ─────────────────────────────────────────────────────────────────────────────
# Funções de manipulação de range
# ─────────────────────────────────────────────────────────────────────────────

# Expandir "0-3,16-19" em lista "0 1 2 3 16 17 18 19"
expand_range() {
    local range="$1"
    [[ -z "$range" ]] && return
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
    [[ ${#out[@]} -eq 0 ]] && return
    echo "${out[@]}"
}

# Compactar "0 1 2 3 16 17 18 19" em "0-3,16-19"
compact_range() {
    local input="$1"
    [[ -z "$input" ]] && return
    local cpus
    read -ra cpus <<< "$input"
    [[ ${#cpus[@]} -eq 0 ]] && return

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

# subtract_range "0-31" "0,16" → "1-15,17-31"
subtract_range() {
    local minuend="$1"
    local subtrahend="$2"

    local minuend_list subtrahend_list
    minuend_list=$(expand_range "$minuend")
    subtrahend_list=$(expand_range "$subtrahend")

    declare -A sub_set
    for c in $subtrahend_list; do
        sub_set[$c]=1
    done

    local result=()
    for c in $minuend_list; do
        [[ -z "${sub_set[$c]:-}" ]] && result+=("$c")
    done

    [[ ${#result[@]} -eq 0 ]] && return
    compact_range "${result[*]}"
}

# Limpar prefixos de flags como "managed_irq,domain," do início do range
strip_isolcpus_flags() {
    local range="$1"
    range="${range#isolcpus=}"
    for flag in managed_irq domain nohz; do
        range="${range#"${flag}",}"
        range="${range//,"${flag}",/,}"
    done
    echo "$range"
}

# ─────────────────────────────────────────────────────────────────────────────
# Verificações iniciais
# ─────────────────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    log_error "Este script precisa ser executado como root."
    exit 1
fi

if [[ ! -r "$GRUB_FILE" ]]; then
    log_error "Arquivo GRUB não encontrado: ${GRUB_FILE}"
    exit 1
fi

if [[ ! -f "$SERVICE_FILE" ]]; then
    log_error "Service file não encontrado: ${SERVICE_FILE}"
    exit 1
fi

if ! grep -q '^\[Service\]' "$SERVICE_FILE"; then
    log_error "Service file não contém seção [Service]: ${SERVICE_FILE}"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Ler isolcpus= e irqaffinity= de /etc/default/grub
# ─────────────────────────────────────────────────────────────────────────────
CMDLINE=""
for var in GRUB_CMDLINE_LINUX_DEFAULT GRUB_CMDLINE_LINUX; do
    line=$(grep -E "^[[:space:]]*${var}=" "$GRUB_FILE" || true)
    if [[ -n "$line" ]]; then
        # Extrair conteúdo entre aspas (suporta " e ')
        value=$(echo "$line" | sed -E "s/^[[:space:]]*${var}=//; s/^['\"]//; s/['\"][[:space:]]*$//")
        CMDLINE="${CMDLINE} ${value}"
    fi
done

if [[ -z "$CMDLINE" ]]; then
    log_error "GRUB_CMDLINE_LINUX_DEFAULT/GRUB_CMDLINE_LINUX não encontrados em ${GRUB_FILE}"
    exit 1
fi

ISOLCPUS_RAW=$(echo "$CMDLINE" | grep -oE 'isolcpus=[^ ]+' || true)
IRQAFF_RAW=$(echo "$CMDLINE" | grep -oE 'irqaffinity=[^ ]+' || true)

if [[ -z "$ISOLCPUS_RAW" ]]; then
    log_error "isolcpus= não encontrado em ${GRUB_FILE}"
    exit 1
fi

# Limpar prefixos: isolcpus=managed_irq,domain,2-15,34-47 → 2-15,34-47
ISOLATED_RANGE=$(strip_isolcpus_flags "$ISOLCPUS_RAW")

if [[ -z "$ISOLATED_RANGE" ]] || ! [[ "$ISOLATED_RANGE" =~ ^[0-9,-]+$ ]]; then
    log_error "Range isolcpus inválido após parse: '${ISOLATED_RANGE}'"
    exit 1
fi

log_info "Range isolcpus: ${ISOLATED_RANGE}"

# ─────────────────────────────────────────────────────────────────────────────
# Subtrair housekeeping (irqaffinity=) do range
# ─────────────────────────────────────────────────────────────────────────────
HK_RANGE=""
if [[ -n "$IRQAFF_RAW" ]]; then
    HK_RANGE="${IRQAFF_RAW#irqaffinity=}"
    if [[ -n "$HK_RANGE" ]] && [[ "$HK_RANGE" =~ ^[0-9,-]+$ ]]; then
        log_info "Range housekeeping: ${HK_RANGE}"

        FILTERED_RANGE=$(subtract_range "$ISOLATED_RANGE" "$HK_RANGE")

        if [[ "$FILTERED_RANGE" != "$ISOLATED_RANGE" ]]; then
            log_warn "Cores housekeeping detectados em isolcpus — filtrando"
            ISOLATED_RANGE="$FILTERED_RANGE"
        fi
    fi
fi

if [[ -z "$ISOLATED_RANGE" ]]; then
    log_error "Range vazio após filtrar housekeeping"
    exit 1
fi

# Validar contra CPUs disponíveis
MAX_CPU=$(( $(nproc) - 1 ))
HIGHEST_CPU=$(echo "$ISOLATED_RANGE" | tr ',' '\n' | tr '-' '\n' | sort -n | tail -1)
if [[ -n "$HIGHEST_CPU" ]] && [[ "$HIGHEST_CPU" -gt "$MAX_CPU" ]]; then
    log_error "Range referencia CPU ${HIGHEST_CPU}, mas sistema só tem CPUs 0-${MAX_CPU}"
    exit 1
fi

log_ok "CPUAffinity final: ${ISOLATED_RANGE}"

# ─────────────────────────────────────────────────────────────────────────────
# Editar o service file
# ─────────────────────────────────────────────────────────────────────────────
SERVICE_DIR=$(dirname "$SERVICE_FILE")
TMP_FILE=$(mktemp -p "$SERVICE_DIR" .xuione.service.tmp.XXXXXX)
trap 'rm -f "$TMP_FILE"' EXIT INT TERM HUP

awk -v new_line="CPUAffinity=${ISOLATED_RANGE}" '
    /^[[:space:]]*CPUAffinity[[:space:]]*=/ { next }
    { print }
    /^\[Service\][[:space:]]*$/ { print new_line }
' "$SERVICE_FILE" > "$TMP_FILE"

if ! grep -q "^CPUAffinity=${ISOLATED_RANGE}$" "$TMP_FILE"; then
    log_error "Falha ao inserir CPUAffinity no service file"
    exit 1
fi

# Idempotência
if cmp -s "$TMP_FILE" "$SERVICE_FILE"; then
    log_ok "Service file já está correto — nenhuma alteração necessária"
    exit 0
fi

# Aplicar (atômico via mv no mesmo filesystem)
chown --reference="$SERVICE_FILE" "$TMP_FILE"
chmod --reference="$SERVICE_FILE" "$TMP_FILE"
mv "$TMP_FILE" "$SERVICE_FILE"
log_ok "Service file atualizado: CPUAffinity=${ISOLATED_RANGE}"

# ─────────────────────────────────────────────────────────────────────────────
# Reload + restart
# ─────────────────────────────────────────────────────────────────────────────
systemctl daemon-reload
log_ok "daemon-reload executado"

if systemctl is-active --quiet xuione.service; then
    systemctl restart xuione.service
    log_ok "xuione.service reiniciado"

    sleep 1
    if systemctl is-active --quiet xuione.service; then
        log_ok "xuione.service está rodando"
    else
        log_error "xuione.service NÃO está rodando após restart"
        journalctl -u xuione.service -n 20 --no-pager 2>/dev/null || true
        exit 1
    fi
else
    log_info "xuione.service não estava ativo — não reiniciado"
    log_info "Para iniciar: sudo systemctl start xuione.service"
fi
