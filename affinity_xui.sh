#!/bin/bash
###############################################################################
#  XUI.One CPU Affinity Setter
#  Lê isolcpus= do /proc/cmdline, remove qualquer CPUAffinity= existente do
#  /etc/systemd/system/xuione.service e adiciona a nova logo após [Service].
###############################################################################

set -euo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $1"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $1"; }

SERVICE_FILE="/etc/systemd/system/xuione.service"

# Verificar root
if [[ $EUID -ne 0 ]]; then
    log_error "Este script precisa ser executado como root."
    exit 1
fi

# Validar service file
if [[ ! -f "$SERVICE_FILE" ]]; then
    log_error "Service file não encontrado: ${SERVICE_FILE}"
    exit 1
fi

# Validar que existe seção [Service]
if ! grep -q '^\[Service\]' "$SERVICE_FILE"; then
    log_error "Service file não contém seção [Service]: ${SERVICE_FILE}"
    exit 1
fi

# Ler isolcpus= do /proc/cmdline
CMDLINE=$(cat /proc/cmdline)
ISOLCPUS_RAW=$(echo "$CMDLINE" | grep -oE 'isolcpus=[^ ]+' || echo "")

if [[ -z "$ISOLCPUS_RAW" ]]; then
    log_error "isolcpus= não encontrado em /proc/cmdline"
    log_info "Rode o tuner com isolation primeiro: sudo bash cpu_performance_tuner_v2.sh --nic <interface>"
    exit 1
fi

# Limpar prefixos: isolcpus=managed_irq,domain,1-15,17-31 → 1-15,17-31
ISOLATED_RANGE="${ISOLCPUS_RAW#isolcpus=}"
for flag in managed_irq domain nohz; do
    ISOLATED_RANGE="${ISOLATED_RANGE#"${flag}",}"
    ISOLATED_RANGE="${ISOLATED_RANGE//,"${flag}",/,}"
done

# Validar formato
if [[ -z "$ISOLATED_RANGE" ]] || ! [[ "$ISOLATED_RANGE" =~ ^[0-9,-]+$ ]]; then
    log_error "Range inválido após parse: '${ISOLATED_RANGE}'"
    exit 1
fi

# Validar contra CPUs disponíveis
MAX_CPU=$(( $(nproc) - 1 ))
HIGHEST_CPU=$(echo "$ISOLATED_RANGE" | tr ',' '\n' | tr '-' '\n' | sort -n | tail -1)
if [[ -n "$HIGHEST_CPU" ]] && [[ "$HIGHEST_CPU" -gt "$MAX_CPU" ]]; then
    log_error "Range referencia CPU ${HIGHEST_CPU}, mas sistema só tem CPUs 0-${MAX_CPU}"
    exit 1
fi

log_ok "Range isolado detectado: ${ISOLATED_RANGE}"

# Editar o service file:
# 1. Remover qualquer linha CPUAffinity= existente
# 2. Adicionar a nova logo após [Service]
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT INT TERM HUP

awk -v new_line="CPUAffinity=${ISOLATED_RANGE}" '
    # Pular linhas CPUAffinity= existentes (remoção)
    /^[[:space:]]*CPUAffinity[[:space:]]*=/ { next }
    # Imprimir todas as outras linhas
    { print }
    # Logo após [Service], inserir a nova linha
    /^\[Service\][[:space:]]*$/ { print new_line }
' "$SERVICE_FILE" > "$TMP_FILE"

# Validar que a linha nova está presente
if ! grep -q "^CPUAffinity=${ISOLATED_RANGE}$" "$TMP_FILE"; then
    log_error "Falha ao inserir CPUAffinity no service file"
    exit 1
fi

# Idempotência: se conteúdo é idêntico ao atual, não fazer nada
if cmp -s "$TMP_FILE" "$SERVICE_FILE"; then
    log_ok "Service file já está correto (CPUAffinity=${ISOLATED_RANGE}) — nenhuma alteração necessária"
    exit 0
fi

# Aplicar a edição preservando permissões e dono originais via mv (atômico)
chown --reference="$SERVICE_FILE" "$TMP_FILE"
chmod --reference="$SERVICE_FILE" "$TMP_FILE"
mv "$TMP_FILE" "$SERVICE_FILE"
log_ok "Service file atualizado: CPUAffinity=${ISOLATED_RANGE}"

# Reload + restart condicional
systemctl daemon-reload
log_ok "daemon-reload executado"

# Só reinicia se serviço estava ativo (preserva manutenção planejada)
if systemctl is-active --quiet xuione.service; then
    systemctl restart xuione.service
    log_ok "xuione.service reiniciado"

    # Verificar status
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
    log_info "Para iniciar manualmente: sudo systemctl start xuione.service"
fi
