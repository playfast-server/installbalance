#!/usr/bin/env bash
# xuione-ccd-net.sh
#
# Aplica topologia CCD-aware em servidores AMD EPYC + NIC multi-queue:
#   - N CCDs dedicados a rede (IRQ + nginx workers nos SMT siblings)
#   - Resto dos CCDs para app (PHP-FPM, ffmpeg)
#   - XPS, RPS e ARFS ZERADOS por default em TODAS as queues. XPS pode ser
#     reativado seletivamente via UMA das flags (mutuamente exclusivas):
#       --xps-irq      : mask = CPU fisica do IRQ daquela queue
#       --xps-smt      : mask = SMT sibling do IRQ daquela queue
#       --xps-irq-smt  : mask = {CPU fisica, SMT sibling}  (smt-irq classico)
#       --xps-spread   : mask = TODOS os threads (cpumask cheio)
#     IRQs sao SEMPRE re-pinados; queues fora do plano sempre zeradas.
#   - NIC combined queues = numero de CPUs (FISICAS) da rede
#   - nginx worker_processes = mesmo numero (1 worker por SMT sibling)
#   - worker_cpu_affinity no nginx.conf alinhado aos SMTs
#   - CPUAffinity em xuione.service + cron.service drop-in para cores app
#   - Tuning NIC: RDMA desativado (+blacklist persistente), ring buffer no max
#     da NIC, coalesce adaptive RX/TX = on
#
# TERMINOLOGIA (importante):
#   - "CPU" neste script SEMPRE significa "core fisico" (1 dos 2 threads SMT,
#     o de menor numero do par). Para EPYC 7702P: 64 CPUs fisicas (cores 0-63),
#     128 threads totais (cores fisicos + SMT siblings 64-127).
#   - "thread" (ou "SMT sibling") refere-se ao segundo thread do par SMT.
#   - "queues NIC" = numero de CPUs fisicas alocadas para rede.
#   - "nginx workers" = mesma quantidade, mas pinados nos SMT siblings.
#   - Para um CCD com 8 cores fisicos (16 threads em SMT2):
#       --ccds 1  =>  8 queues NIC + 8 nginx workers + 16 threads pinados rede
#       --ccds 4  =>  32 queues NIC + 32 nginx workers + 64 threads pinados
#
# Topologia detectada via /sys/devices/system/cpu/*/cache/index3/id (L3 = CCX),
# 2 CCXes consecutivos = 1 CCD (numeracao padrao EPYC Rome/Milan).
#
# Default: DRY-RUN. Use --apply para executar.
# NIC: passar via --nic IFACE (obrigatorio). Sem flag, lista candidatas.
#
# Idempotente: pode ser executado N vezes; estado final converge.

set -uo pipefail

# Locale C: evita que comandos como ethtool/awk/grep retornem strings
# traduzidas que quebram parsing (ex "Adaptive RX:" em pt_BR).
export LC_ALL=C
export LANG=C

VERSION="1.0.0"
SCRIPT_NAME="${0##*/}"

# === Defaults / paths ===
DEFAULT_NGINX_CONF="/home/xui/bin/nginx/conf/nginx.conf"
DEFAULT_XUI_UNIT="/etc/systemd/system/xuione.service"
DEFAULT_CRON_DROPIN_DIR="/etc/systemd/system/cron.service.d"
DEFAULT_CRON_DROPIN_FILE="${DEFAULT_CRON_DROPIN_DIR}/xuione-ccdnet.conf"
NGINX_BLOCK_BEGIN="# === BEGIN xuione-ccd-net ==="
NGINX_BLOCK_END="# === END xuione-ccd-net ==="
RDMA_BLACKLIST_FILE="/etc/modprobe.d/xuione-ccdnet-blacklist-irdma.conf"
RDMA_MODULE="irdma"  # modulo RDMA do driver Intel ice/E810

# Persistencia (instalada por default; opt-out via --no-systemd)
PERSIST_BIN_PATH="/usr/local/sbin/xuione-ccd-net.sh"
PERSIST_UNIT_SERVICE="/etc/systemd/system/xuione-ccd-net.service"
PERSIST_UNIT_PATH="/etc/systemd/system/xuione-ccd-net.path"

# === Constantes estruturais (NAO derivadas em runtime) ===
# Linux cpumask format: cada palavra tem 32 bits (estrutural do kernel).
readonly CPUMASK_BITS_PER_WORD=32
readonly CPUMASK_HEX_PER_WORD=8   # 32 bits / 4 bits por char hex

# AMD CCD vs CCX ratio (detectado dinamicamente em detect_topology):
#   Zen2 (Rome)  : 4 cores/CCX, 2 CCXes/CCD  → CCXES_PER_CCD = 2
#   Zen3 (Milan) : 8 cores/CCX, 1 CCX/CCD    → CCXES_PER_CCD = 1
#   Zen4 (Genoa) : 8 cores/CCX, 1 CCX/CCD    → CCXES_PER_CCD = 1
# Detectamos via (TOTAL_PHYSICAL_CORES / NUM_CCXES) -> cores_per_ccx,
# depois aplicamos heuristica: 4 cores/CCX = Zen2; 8 cores/CCX = Zen3+.
# Variavel global, NAO readonly (atribuida em detect_topology).
CCXES_PER_CCD=0

# Delays de operacao (segundos). Justificativa:
# - SLEEP_AFTER_QUEUE_RESIZE: ethtool -L pode levar 1-3s para o driver
#   reorganizar os IRQ vectors e reiniciar o ring buffer.
# - SLEEP_IRQ_RETRY: se IRQs ainda nao apareceram em /proc/interrupts apos
#   queue resize, aguarda mais um pouco.
readonly SLEEP_AFTER_QUEUE_RESIZE=2
readonly SLEEP_IRQ_RETRY=3

# === Args ===
# DRY_RUN=1 e o default; --apply muda para 0 (variavel canonica de modo)
# Nao ha confirmacao interativa: --apply ja executa direto. Operador
# escolhe a janela. Persistencia systemd nao tem stdin de qualquer forma.
CCDS_NET=0
# CCDS_MODE: "numeric" (default, usa CCDS_NET como int)
#          | "core"   (todos os cores fisicos para IRQ + todos os SMTs para nginx)
#          | "spread" (todos os ${TOTAL_THREADS} threads para IRQ, 1 worker nginx por thread)
# Em "core" e "spread" nao sobra app threads -> NO_AFFINITY e auto-ativado.
CCDS_MODE="numeric"
NIC=""
# XPS_MODE: off (default) | irq | smt | irq-smt | spread
# - off    : TODAS as tx-* queues recebem xps_cpus=0
# - irq    : queues do plano recebem mask = CPU fisica do IRQ daquela queue
# - smt    : queues do plano recebem mask = SMT sibling do IRQ daquela queue
# - irq-smt: queues do plano recebem mask = {CPU fisica, SMT sibling}
# - spread : queues do plano recebem mask = TODOS os threads (cpumask cheio)
# Em QUALQUER modo, queues fora do plano (extras) recebem xps_cpus=0.
XPS_MODE="off"
NO_AFFINITY=0     # --no-affinity: pula CPUAffinity e REMOVE de TODOS arquivos
                  # de xuione.service/cron.service (overrides + drop-ins).
                  # CPUAffinity ausente = systemd sem restricao = todos os cores
                  # permitidos (semantica padrao systemd, equivalente a 0-N-1).
# NGINX_MODE: auto | irq | smt (default) | irq-smt
# - auto    : worker_processes auto + SEM worker_cpu_affinity (nginx decide)
# - irq     : worker[i] pinado em NET_IRQ_CPUS[i] (mesmo thread que IRQ da queue i)
# - smt     : worker[i] pinado em SMT sibling do IRQ thread (CLASSICO - default)
# - irq-smt : worker[i] mask = {NET_IRQ_CPUS[i], SMT_SIBLING[...]} (2 bits, mesmo par fisico)
NGINX_MODE="smt"
NGINX_MODE_SET=0  # 1 se usuario passou --nginx-* explicitamente (controla auto-implicacao)
NO_SYSTEMD=0      # --no-systemd: nao instala persistencia (xuione-ccd-net.service/.path)
ALLOW_NIC_RESET=0 # --allow-nic-reset: autoriza ethtool -G (ring) mesmo com trafego
                  # passando na NIC. Sem a flag, o ring resize e PULADO quando ha
                  # trafego (ethtool -G faz ice_down()/ice_up() = ~5-10s de pausa).
RESTART_SERVICES=0 # --restart: faz systemctl restart de xuione + cron.service quando
                   # os respectivos arquivos mudaram (XUI_UNIT_CHANGED / CRON_DROPIN_CHANGED).
                   # Sem essa flag, o script apenas informa que o usuario deve restartar
                   # manualmente. NAO eh propagada para a persistencia systemd.
DRY_RUN=1
VERBOSE=0
REVERT=0
SHOW_PLAN_ONLY=0
ANALYZE_ONLY=0

# === Topologia detectada ===
NUM_CCDS=0
NUM_CCXES=0
TOTAL_PHYSICAL_CORES=0
TOTAL_THREADS=0
declare -A CCD_PHYSCORES=()  # CCD_PHYSCORES[ccd_id] = "c1 c2 c3 ..."
declare -A SMT_SIBLING=()    # SMT_SIBLING[cpu] = sibling

# === Plano calculado ===
NET_CCD_LIST=""        # "0 1 2 3"
APP_CCD_LIST=""        # "4 5 6 7"
NET_IRQ_CPUS=""        # space-separated, ex: "0 1 2 ... 31"
NET_NGINX_CPUS=""      # space-separated, ex: "64 65 ... 95"
APP_CPUS_RANGE=""      # range, ex: "32-63,96-127"
NUM_QUEUES=0
NUM_NGINX_WORKERS=0
MAX_NIC_QUEUES=0       # Pre-set Maximum Combined da NIC (detectado no preflight)

# === Flags de mudancas (centralizam reloads no fim) ===
# Cada apply_* marca sua flag quando muda algo. apply_reloads() consolida.
XUI_UNIT_CHANGED=0       # marcada por apply_xuione_service
CRON_DROPIN_CHANGED=0    # marcada por apply_cron_dropin
NGINX_CONF_CHANGED=0     # marcada por apply_nginx_conf
# PERSISTENCE_CHANGED:
#   0 = sem mudanca
#   1 = INSTALADA  (precisa daemon-reload + start path-trigger)
#   2 = REMOVIDA   (precisa daemon-reload apenas, NAO start)
PERSISTENCE_CHANGED=0

# ============================================================================
# COLORS / LOGGING
# ============================================================================
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
  C_CYA=$'\033[0;36m'; C_BLD=$'\033[1m';    C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""; C_BLD=""; C_DIM=""; C_RST=""
fi

c_red() { printf '%s%s%s' "$C_RED" "$*" "$C_RST"; }
c_grn() { printf '%s%s%s' "$C_GRN" "$*" "$C_RST"; }
c_yel() { printf '%s%s%s' "$C_YEL" "$*" "$C_RST"; }
c_cya() { printf '%s%s%s' "$C_CYA" "$*" "$C_RST"; }
c_bld() { printf '%s%s%s' "$C_BLD" "$*" "$C_RST"; }
c_dim() { printf '%s%s%s' "$C_DIM" "$*" "$C_RST"; }

log()     { printf '%s %s\n' "$(c_cya '[*]')" "$*"; }
# vlog: usa if explicito (evita SC2015: && || nao e if-then-else)
vlog()    { if [ "${VERBOSE}" -eq 1 ]; then printf '%s %s\n' "$(c_dim '[v]')" "$*"; fi; }
ok()      { printf '%s %s\n' "$(c_grn '[OK]')" "$*"; }
nok()     { printf '%s %s\n' "$(c_red '[NOK]')" "$*"; }
warn()    { printf '%s %s\n' "$(c_yel '[WARN]')" "$*" >&2; }
die()     { printf '%s %s\n' "$(c_red '[FATAL]')" "$*" >&2; exit 1; }
section() { echo; printf '%s\n' "$(c_bld "=== $* ===")"; }

# ============================================================================
# CLEANUP: todos os temporarios vivem sob UM diretorio, removido no EXIT
# ============================================================================
# Nao usar array acumulador: mktemp_tracked e SEMPRE chamada como
# "tmp=$(mktemp_tracked)", logo o corpo roda na subshell de $( ) e o append
# mutaria apenas a copia da subshell -- o trap do pai via array vazio e os
# temporarios vazavam em /tmp a cada boot/re-run (inclusive copias do
# nginx.conf). Com um diretorio unico criado no PAI, o trap limpa tudo.
_TMPROOT=""
cleanup_on_exit() {
  if [ -n "${_TMPROOT:-}" ]; then
    rm -rf "$_TMPROOT" 2>/dev/null || true
  fi
  return 0
}
trap cleanup_on_exit EXIT

# Atribuicao no escopo PRINCIPAL (nunca dentro de $( )), senao o pai nao
# enxerga o valor e o trap nao limpa nada.
_TMPROOT=$(mktemp -d -t xuione-ccdnet.XXXXXX) || die "mktemp -d falhou"

mktemp_tracked() {
  [ -n "${_TMPROOT:-}" ] || return 1
  mktemp "${_TMPROOT}/f.XXXXXX"
}

# ============================================================================
# HELP
# ============================================================================
usage() {
  cat <<EOF
${C_BLD}${SCRIPT_NAME} v${VERSION}${C_RST}  -  Tuning CCD-aware para NIC multi-queue + nginx + XUI

${C_BLD}O QUE FAZ${C_RST}
  Em servidores AMD EPYC com NIC multi-queue (E810, mlx5, etc) e XUI 1.5.13,
  organiza recursos de CPU para que cada componente fique no melhor lugar:

    ${C_CYA}rede${C_RST}  =>  IRQs da NIC em N CCDs (=> 1 IRQ por CPU fisica)
              nginx workers nos SMT siblings dessas CPUs
    ${C_CYA}app${C_RST}   =>  PHP-FPM + ffmpeg pinados nos CCDs restantes (via systemd)
    ${C_CYA}NIC${C_RST}   =>  combined queues = #CPUs rede, ring max, coalesce adaptive,
              RDMA desativado, XPS/RPS/ARFS gerenciados
    ${C_CYA}sysctl${C_RST} =>  ${SYSCTL_FILE} ${C_YEL}REESCRITO INTEIRO${C_RST} com o template
              embedded (buffers, backlogs, portas, BBR+fq, RFS off)

  Tudo idempotente, com backup automatico e persistencia systemd (re-aplica
  no boot e em mudancas de operstate da NIC).

${C_BLD}FLUXO RECOMENDADO${C_RST}
  ${C_GRN}1.${C_RST}  sudo ${SCRIPT_NAME} --nic IFACE --analyze        ${C_DIM}# ve topologia + sugestoes${C_RST}
  ${C_GRN}2.${C_RST}  sudo ${SCRIPT_NAME} --nic IFACE --ccds N          ${C_DIM}# revisa o plano (dry-run)${C_RST}
  ${C_GRN}3.${C_RST}  sudo ${SCRIPT_NAME} --nic IFACE --ccds N --apply  ${C_DIM}# aplica (fora de pico)${C_RST}
  ${C_YEL}!${C_RST}   O passo 3 REESCREVE ${SYSCTL_FILE} por completo (com backup)
      e mexe na NIC ao vivo -- leia EFEITOS COLATERAIS antes.

${C_BLD}USO${C_RST}
  ${SCRIPT_NAME} [--nic IFACE] [opcoes]

  Sem --nic, o script lista as interfaces UP candidatas e sai.

${C_BLD}=============================================================================${C_RST}
${C_BLD}FLAGS OBRIGATORIAS${C_RST}
${C_BLD}=============================================================================${C_RST}
  ${C_BLD}--nic IFACE${C_RST}            Nome da interface (ex: enp197s0f0np0).
                         Alias: --iface

${C_BLD}=============================================================================${C_RST}
${C_BLD}MODOS DE EXECUCAO  ${C_DIM}(escolha 1)${C_RST}
${C_BLD}=============================================================================${C_RST}
  ${C_BLD}(sem flag)${C_RST}             DRY-RUN: mostra o plano + diff esperado, sem aplicar.
                         Use sempre antes de --apply.

  ${C_BLD}--analyze${C_RST}              Imprime relatorio rico da maquina:
                           - CPU model, CCDs detectados, mapa de cores por CCD
                           - NIC: driver, firmware, queues, ring, coalesce
                           - estado ATUAL: XPS/RPS/ARFS/nginx.conf/CPUAffinity
                           - tabela de recomendacoes (--ccds 1..N, core, spread)
                           - carga (loadavg, trafego pps, RAM)
                         Aliases: --analyse, --topology

  ${C_BLD}--plan${C_RST}                 So calcula e imprime o plano; nao tenta aplicar.
                         Util para reviewar threads alocados sem dry-run completo.

  ${C_BLD}--apply${C_RST}                Executa o plano (sem confirmacao interativa).
                         ${C_YEL}Aviso: ethtool -L combined N causa breve interrupcao
                         (~5-10s). Aplicar fora de pico.${C_RST}

  ${C_BLD}--revert --apply${C_RST}       Reverte tudo: zera XPS/RPS, restaura nginx.conf
                         do backup, remove CPUAffinity, REMOVE persistencia.
                         ${C_DIM}NIC queues e ring NAO sao revertidos (tuning generico
                         seguro de manter).${C_RST}

${C_BLD}=============================================================================${C_RST}
${C_BLD}ALOCACAO DE CPUS  ${C_DIM}(--ccds VAL)${C_RST}
${C_BLD}=============================================================================${C_RST}
  ${C_BLD}--ccds N${C_RST}               ${C_BLD}N inteiro >= 1.${C_RST}  Primeiros N CCDs para rede,
                         restantes para app. Use ${C_GRN}--analyze${C_RST} para ver a
                         tabela de recomendacoes por carga.

  ${C_BLD}--ccds core${C_RST}            ${C_BLD}TODOS${C_RST} os cores fisicos para IRQ + TODOS os SMT
                         siblings para nginx. Nada sobra para app.
                         ${C_DIM}Auto-ativa: --no-affinity${C_RST}

  ${C_BLD}--ccds spread${C_RST}          ${C_BLD}TODOS${C_RST} os threads (fisicos + SMT) recebem IRQ
                         da NIC -- max paralelismo, sem isolamento app.
                         ${C_DIM}Auto-ativa: --no-affinity + --nginx-auto${C_RST}
                         ${C_YEL}Nao combina com --xps-irq-smt nem --nginx-irq-smt${C_RST}
                         (em spread workers em pares teriam mask identica;
                         use --xps-irq / --nginx-irq / --nginx-auto).

${C_BLD}=============================================================================${C_RST}
${C_BLD}XPS  ${C_DIM}(Transmit Packet Steering -- mutuamente exclusivas)${C_RST}
${C_BLD}=============================================================================${C_RST}
  Default (sem flag): ${C_BLD}XPS desativado${C_RST} -- TODAS as tx-* queues recebem
  xps_cpus=0 (kernel usa skb hash para escolher queue).

  ${C_BLD}--xps-irq${C_RST}              Cada queue Q recebe mask = bit do IRQ thread de Q.
                         => TX do CPU N vai pela queue N (afinidade estrita).

  ${C_BLD}--xps-smt${C_RST}              Mask = bit do SMT sibling do IRQ thread.
                         => TX do SMT sibling vai pela queue cujo IRQ ta no
                         core fisico irmao (anti-afinidade -- raro mas valido).

  ${C_BLD}--xps-irq-smt${C_RST}          Mask = {IRQ thread, SMT sibling}.
                         => TX de qualquer dos 2 threads do par fisico vai pela
                         mesma queue. Cache locality preservada (L1d/L2 do par).
                         ${C_DIM}Classico para servidores SMT2 com poucas queues.${C_RST}

  ${C_BLD}--xps-spread${C_RST}           Mask = TODOS os threads (cpumask cheio).
                         => Kernel usa hash interno; nenhuma afinidade CPU.

  ${C_DIM}>> Queues fora do plano sao SEMPRE zeradas em qualquer modo. <<${C_RST}

${C_BLD}=============================================================================${C_RST}
${C_BLD}NGINX WORKER PINNING  ${C_DIM}(mutuamente exclusivas; default = --nginx-smt)${C_RST}
${C_BLD}=============================================================================${C_RST}
  ${C_BLD}--nginx-auto${C_RST}           ${C_DIM}worker_processes auto;${C_RST} sem worker_cpu_affinity.
                         => Nginx detecta CPUs, kernel scheduler decide tudo.

  ${C_BLD}--nginx-irq${C_RST}            worker[i] pinado no ${C_BLD}IRQ thread${C_RST} da queue i.
                         => Worker e IRQ handler no mesmo thread; cache L1d
                         quente, mas disputam CPU.

  ${C_BLD}--nginx-smt${C_RST}            ${C_GRN}(DEFAULT)${C_RST}  worker[i] pinado no ${C_BLD}SMT sibling${C_RST}
                         do IRQ thread.
                         => IRQ no thread fisico, nginx no SMT irmao --
                         compartilham L1d/L2 sem disputar o mesmo thread.

  ${C_BLD}--nginx-irq-smt${C_RST}        worker[i] mask = ${C_BLD}{IRQ thread, SMT sibling}${C_RST}.
                         => Scheduler migra worker entre os 2 threads do
                         par fisico baseado em load. Mais flexivel.

${C_BLD}=============================================================================${C_RST}
${C_BLD}OUTRAS FLAGS${C_RST}
${C_BLD}=============================================================================${C_RST}
  ${C_BLD}--no-affinity${C_RST}          NAO aplica CPUAffinity em xuione.service nem
                         cron.service, e ${C_BLD}REMOVE${C_RST} qualquer CPUAffinity= existente:
                           - /etc/systemd/system/xuione.service (principal)
                           - /etc/systemd/system/xuione.service.d/*.conf
                           - /run/systemd/system/xuione.service.d/*.conf
                           - /etc/systemd/system/cron.service (override)
                           - /etc/systemd/system/cron.service.d/*.conf
                           - /run/systemd/system/cron.service.d/*.conf
                         CPUAffinity ausente = todos os cores permitidos.

  ${C_BLD}--no-systemd${C_RST}           NAO instala persistencia systemd NOVA (se ja existe, e sincronizada).
                         ${C_DIM}Sem essa flag, sao instalados${C_RST}
                           ${PERSIST_BIN_PATH}
                           ${PERSIST_UNIT_SERVICE}
                           ${PERSIST_UNIT_PATH}
                         ${C_DIM}para re-aplicar no boot + em operstate change.${C_RST}

  ${C_BLD}--allow-nic-reset${C_RST}      Autoriza ${C_BLD}ethtool -G${C_RST} (ring buffer) mesmo com trafego
                         passando na NIC. Sem a flag, o ring resize e PULADO
                         quando ha trafego (o driver faz ice_down()/ice_up(),
                         ~5-10s de pausa). Use em janela controlada.

  ${C_BLD}--restart${C_RST}              ${C_YEL}OPT-IN${C_RST} para ${C_BLD}systemctl restart${C_RST} ao final, APENAS quando o
                         arquivo correspondente mudou:
                           ${C_BLD}xuione.service${C_RST}  se CPUAffinity em xuione.service mudou
                           ${C_BLD}cron.service${C_RST}    se drop-in CPUAffinity do cron mudou
                         ${C_DIM}Sem essa flag, o script apenas informa que o usuario
                         deve restartar manualmente. Recomendado em janela
                         controlada (xuione mata PHP-FPM + ffmpegs durante restart).${C_RST}
                         ${C_DIM}NAO eh propagada para a persistencia systemd.${C_RST}

  ${C_BLD}-v, --verbose${C_RST}          Output detalhado (mostra cada step + mask + diff).
  ${C_BLD}-h, --help${C_RST}             Esta ajuda.
  ${C_BLD}--version${C_RST}              Versao.

${C_BLD}=============================================================================${C_RST}
${C_BLD}CONCEITOS BASICOS${C_RST}
${C_BLD}=============================================================================${C_RST}
  ${C_BLD}CPU (fisica)${C_RST}      = 1 core fisico. 1 par SMT conta como 1 CPU.
  ${C_BLD}thread${C_RST}            = 1 dos 2 threads de um par SMT. SMT2: 2 threads/core.
  ${C_BLD}SMT sibling${C_RST}       = o "outro" thread do mesmo par fisico.
  ${C_BLD}CCD${C_RST}               = Core Complex Die. EPYC Rome: 4cores/CCX, 2 CCXes/CCD,
                       8 cores fisicos por CCD. Cada CCD tem L3 separado.
  ${C_BLD}NIC queue${C_RST}         = par TX/RX da NIC. 1 IRQ por queue.
  ${C_BLD}nginx worker${C_RST}      = 1 processo nginx que aceita conexoes.

  ${C_BLD}EPYC 7702P${C_RST} (8 CCDs / 64 cores fisicos / 128 threads):

  ${C_BLD}--ccds   queues   nginx wkrs       app threads     uso tipico${C_RST}
   1            8             8           56 cpu / 112 t   teste / minimo
   2           16            16           48 cpu /  96 t   conservador (RX leve)
   3           24            24           40 cpu /  80 t   medio (~10-15 Gbps)
   ${C_GRN}4           32            32           32 cpu /  64 t   sweet spot 50/50${C_RST}
   5           40            40           24 cpu /  48 t   rede pesada (>40 Gbps)
   6           48            48           16 cpu /  32 t   rede extrema
   7           56            56            8 cpu /  16 t   rede extrema, app limitado
   core       64            64            0 cpu /   0 t   tudo na rede, sem app pin
   spread    128         (auto)            0 cpu /   0 t   IRQ em todo thread

${C_BLD}=============================================================================${C_RST}
${C_BLD}COMO ESCOLHER  ${C_DIM}(arvore de decisao rapida)${C_RST}
${C_BLD}=============================================================================${C_RST}
  ${C_BLD}- Quanto trafego TX/RX espera?${C_RST}
      < 10 Gbps               => --ccds 2 ou 3
      10-30 Gbps              => --ccds 3 ou 4   ${C_GRN}<- sweet spot 4${C_RST}
      30-60 Gbps              => --ccds 5 ou 6
      > 60 Gbps               => --ccds 6 ou 7
      max latencia / max rede => --ccds core
      max queues, sem app pin => --ccds spread

  ${C_BLD}- Precisa que app rode em cores especificos?${C_RST}
      Sim, isolar app          => --ccds N (sem --no-affinity)
      Nao, app pode ir junto   => --no-affinity (ou --ccds core/spread auto)

  ${C_BLD}- XPS?${C_RST}
      Cargas balanceadas + SMT classico => --xps-irq-smt
      1 conexao por CPU                 => --xps-irq
      Nao quer XPS                      => omitir (default = off)
      Maximo paralelismo                => --xps-spread

  ${C_BLD}- nginx pinning?${C_RST}
      Default (SMT siblings)            => omitir (= --nginx-smt)
      Quer nginx no IRQ thread          => --nginx-irq
      Deixar scheduler decidir          => --nginx-auto

${C_BLD}=============================================================================${C_RST}
${C_BLD}EXEMPLOS${C_RST}
${C_BLD}=============================================================================${C_RST}
  ${C_DIM}# 1. Descobrir interfaces candidatas${C_RST}
  sudo ${SCRIPT_NAME}

  ${C_DIM}# 2. Analisar topologia + recomendacoes (NAO mexe em nada)${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --analyze

  ${C_DIM}# 3. Ver plano para 4 CCDs (dry-run -- nada e aplicado)${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --ccds 4

  ${C_DIM}# 4. Aplicar 4 CCDs (sweet spot na maioria dos servidores)${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --ccds 4 --apply

  ${C_DIM}# 5. Aplicar com XPS smt-irq classico (cache locality maxima)${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --ccds 4 --xps-irq-smt --apply

  ${C_DIM}# 6. Maximizar rede usando TODOS cores fisicos${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --ccds core --apply

  ${C_DIM}# 7. IRQ em TODOS os 128 threads (--no-affinity + --nginx-auto auto)${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --ccds spread --apply

  ${C_DIM}# 8. Rede tunada mas APP livre (sem pinar xuione/cron)${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --ccds 4 --no-affinity --apply

  ${C_DIM}# 9. nginx no IRQ thread (em vez do SMT sibling)${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --ccds 4 --nginx-irq --apply

  ${C_DIM}# 10. nginx com mask {IRQ, SMT} (scheduler decide entre par)${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --ccds 4 --nginx-irq-smt --apply

  ${C_DIM}# 11. Aplicar sem instalar persistencia systemd${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --ccds 4 --no-systemd --apply

  ${C_DIM}# 12. Reverter TUDO (XPS, nginx, CPUAffinity, persistencia)${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --revert --apply

  ${C_DIM}# 13. Aplicar E reiniciar xuione + cron automaticamente (janela controlada)${C_RST}
  sudo ${SCRIPT_NAME} --nic enp197s0f0np0 --ccds 4 --apply --restart

${C_BLD}=============================================================================${C_RST}
${C_BLD}ARQUIVOS MODIFICADOS  ${C_DIM}(todos com backup automatico)${C_RST}
${C_BLD}=============================================================================${C_RST}
  ${C_BLD}/etc/modprobe.d/xuione-ccdnet-blacklist-irdma.conf${C_RST}
                         Blacklist do modulo RDMA (irdma). Garante que NAO
                         recarrega em reboot.

  ${C_BLD}${SYSCTL_FILE}${C_RST}
                         ${C_YEL}REESCRITO INTEIRO${C_RST} com o template embedded do script
                         (buffers, backlogs, portas, BBR+fq, RFS off).
                         Customizacoes suas no arquivo sao PERDIDAS.
                         Se estava com ${C_BLD}chattr +i${C_RST}: o script faz -i, reescreve
                         e reaplica +i (edicao manual depois falha com EPERM).
                         Backup: ${SYSCTL_FILE}.bak.ccdnet.<ts>
                         ${C_DIM}--revert NAO restaura este arquivo.${C_RST}

  ${C_BLD}${DEFAULT_NGINX_CONF}${C_RST}
                         Inserido bloco delimitado por
                         ${C_DIM}# === BEGIN xuione-ccd-net ===${C_RST}
                         ${C_DIM}# === END xuione-ccd-net ===${C_RST}
                         contendo worker_processes + worker_cpu_affinity.
                         Backup: ${DEFAULT_NGINX_CONF}.bak.ccdnet.<ts>

  ${C_BLD}${DEFAULT_XUI_UNIT}${C_RST}
                         Adiciona/atualiza linha CPUAffinity=<app cores>.
                         Backup: ${DEFAULT_XUI_UNIT}.bak.ccdnet.<ts>

  ${C_BLD}${DEFAULT_CRON_DROPIN_FILE}${C_RST}
                         Drop-in unico com CPUAffinity para os crons do XUI.

  ${C_BLD}${PERSIST_BIN_PATH}${C_RST}
                         Copia canonica deste script, atualizada em todo apply.

  ${C_BLD}${PERSIST_UNIT_SERVICE}${C_RST}
  ${C_BLD}${PERSIST_UNIT_PATH}${C_RST}
                         Unit + path-trigger que re-aplica o tuning no boot
                         e em mudancas de operstate da NIC.

${C_BLD}=============================================================================${C_RST}
${C_BLD}EFEITOS COLATERAIS${C_RST}
${C_BLD}=============================================================================${C_RST}
  - ${C_YEL}ethtool -L combined N${C_RST}    BREVE interrupcao (~5-10s). Aplicar fora de pico.
  - ${C_YEL}ethtool -G rx/tx (ring)${C_RST}  ice_down()/ice_up() = mesma pausa do -L. So roda se
                             o ring nao estiver no maximo, e e ${C_BLD}PULADO com trafego${C_RST}
                             (use ${C_BLD}--allow-nic-reset${C_RST} em janela controlada).
  - ${C_YEL}ethtool -K feature${C_RST}       So emitido para features atualmente OFF (idempotente).
  - ${C_YEL}${SYSCTL_FILE}${C_RST}       ${C_BLD}REESCRITO POR COMPLETO${C_RST} com o template embedded;
                             customizacoes suas sao perdidas. Se estava com
                             ${C_BLD}chattr +i${C_RST}, volta imutavel (edicao manual falha com
                             EPERM ate ${C_BLD}chattr -i${C_RST}). ${C_BLD}--revert NAO desfaz.${C_RST}
  - nginx -s reload          ${C_BLD}SEMPRE${C_RST} executado se nginx.conf mudou. Zero-downtime.
  - xuione.service           ${C_BLD}NAO${C_RST} reiniciado por default (apenas daemon-reload).
                             Use ${C_BLD}--restart${C_RST} para reiniciar quando CPUAffinity mudou.
                             Sem a flag, o script avisa para reiniciar manualmente.
  - cron.service             ${C_BLD}NAO${C_RST} reiniciado por default (apenas daemon-reload).
                             Use ${C_BLD}--restart${C_RST} para reiniciar quando drop-in mudou.
                             Sem a flag, o script avisa para reiniciar manualmente.
                             ${C_DIM}(Jobs <1min: impacto baixo quando reiniciar.)${C_RST}
  - Idempotente              Pode rodar N vezes; estado final converge.

${C_BLD}=============================================================================${C_RST}
${C_BLD}TROUBLESHOOTING${C_RST}
${C_BLD}=============================================================================${C_RST}
  ${C_BLD}"NIC suporta no maximo X queues"${C_RST}
    Plano pede mais queues que o hardware. Use --ccds menor, ou --ccds core
    (= TOTAL_PHYSICAL_CORES queues), ou faca downgrade do firmware.

  ${C_BLD}"--xps-* mutuamente exclusivas"${C_RST}
    Passou mais de uma flag --xps-*. Escolha exatamente uma (ou nenhuma = off).

  ${C_BLD}"--nginx-* mutuamente exclusivas"${C_RST}
    Mesma logica. Default = --nginx-smt.

  ${C_BLD}"combinacao degenerada"${C_RST}
    --ccds spread + --xps-irq-smt OU --ccds spread + --nginx-irq-smt.
    Em spread cada thread ja tem queue/worker propria; o irq-smt geraria
    pares com masks identicas. Use --xps-irq / --nginx-irq / --nginx-auto.

  ${C_BLD}nginx -t falha apos apply${C_RST}
    Script restaura backup automaticamente e morre. Inspecione com
      cat ${DEFAULT_NGINX_CONF}
      cat ${DEFAULT_NGINX_CONF}.bak.ccdnet.*

  ${C_BLD}xuione nao restartou apos --apply${C_RST}
    Por default o script NAO reinicia xuione. Duas opcoes para que o
    CPUAffinity surta efeito:
      sudo systemctl restart xuione                      ${C_DIM}# manual${C_RST}
      sudo ${SCRIPT_NAME} --nic IFACE --ccds N --apply --restart   ${C_DIM}# auto${C_RST}

  ${C_BLD}Verificar estado depois de aplicar${C_RST}
    sudo ${SCRIPT_NAME} --nic IFACE --analyze
    cat /proc/irq/<IRQ>/smp_affinity_list
    cat /sys/class/net/<IFACE>/queues/tx-0/xps_cpus
    grep CPUAffinity ${DEFAULT_XUI_UNIT}

${C_BLD}=============================================================================${C_RST}
${C_BLD}TOPOLOGIA SUPORTADA${C_RST}
${C_BLD}=============================================================================${C_RST}
  AMD EPYC Rome (Zen2), Milan (Zen3), Genoa (Zen4) com numeracao padrao.
  Deteccao automatica de CCDs via /sys/devices/system/cpu/*/cache/index3/id.
  SMT2 obrigatorio (cada core fisico com 2 threads).

EOF
  exit 0
}

# ============================================================================
# ARG PARSING
# ============================================================================
parse_args() {
  # Rastreia qual flag --xps-* foi usada (para mensagem de mutua exclusao)
  local xps_flag_seen=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ccds)
        local _val="${2:-}"
        [ -z "$_val" ] && die "--ccds requer valor (N | core | spread)"
        case "$_val" in
          core)
            CCDS_MODE="core"; CCDS_NET=0 ;;
          spread)
            CCDS_MODE="spread"; CCDS_NET=0 ;;
          *)
            CCDS_MODE="numeric"; CCDS_NET="$_val" ;;
        esac
        shift 2 ;;
      --nic|--iface)
        # --nic e o nome canonico; --iface mantido como alias retrocompativel
        NIC="${2:-}"
        [ -z "$NIC" ] && die "$1 requer nome da interface (ex: --nic enp197s0f0np0)"
        shift 2 ;;
      --xps-irq)
        [ -n "$xps_flag_seen" ] && die "--xps-* mutuamente exclusivas (ja vi ${xps_flag_seen}, agora $1)"
        XPS_MODE="irq"; xps_flag_seen="$1"; shift ;;
      --xps-smt)
        [ -n "$xps_flag_seen" ] && die "--xps-* mutuamente exclusivas (ja vi ${xps_flag_seen}, agora $1)"
        XPS_MODE="smt"; xps_flag_seen="$1"; shift ;;
      --xps-irq-smt)
        [ -n "$xps_flag_seen" ] && die "--xps-* mutuamente exclusivas (ja vi ${xps_flag_seen}, agora $1)"
        XPS_MODE="irq-smt"; xps_flag_seen="$1"; shift ;;
      --xps-spread)
        [ -n "$xps_flag_seen" ] && die "--xps-* mutuamente exclusivas (ja vi ${xps_flag_seen}, agora $1)"
        XPS_MODE="spread"; xps_flag_seen="$1"; shift ;;
      --no-affinity)
        NO_AFFINITY=1; shift ;;
      --nginx-auto)
        [ "$NGINX_MODE_SET" -eq 1 ] && die "--nginx-* mutuamente exclusivas (ja vi modo='${NGINX_MODE}', agora $1)"
        NGINX_MODE="auto"; NGINX_MODE_SET=1; shift ;;
      --nginx-irq)
        [ "$NGINX_MODE_SET" -eq 1 ] && die "--nginx-* mutuamente exclusivas (ja vi modo='${NGINX_MODE}', agora $1)"
        NGINX_MODE="irq"; NGINX_MODE_SET=1; shift ;;
      --nginx-smt)
        [ "$NGINX_MODE_SET" -eq 1 ] && die "--nginx-* mutuamente exclusivas (ja vi modo='${NGINX_MODE}', agora $1)"
        NGINX_MODE="smt"; NGINX_MODE_SET=1; shift ;;
      --nginx-irq-smt)
        [ "$NGINX_MODE_SET" -eq 1 ] && die "--nginx-* mutuamente exclusivas (ja vi modo='${NGINX_MODE}', agora $1)"
        NGINX_MODE="irq-smt"; NGINX_MODE_SET=1; shift ;;
      --no-systemd)
        NO_SYSTEMD=1; shift ;;
      --allow-nic-reset)
        ALLOW_NIC_RESET=1; shift ;;
      --restart)
        RESTART_SERVICES=1; shift ;;
      --apply)
        DRY_RUN=0; shift ;;
      --plan)
        SHOW_PLAN_ONLY=1; shift ;;
      --analyze|--analyse|--topology)
        ANALYZE_ONLY=1; shift ;;
      --revert)
        REVERT=1; shift ;;
      -v|--verbose)
        VERBOSE=1; shift ;;
      -h|--help)
        usage ;;
      --version)
        echo "${SCRIPT_NAME} v${VERSION}"; exit 0 ;;
      *)
        die "Argumento desconhecido: $1 (use --help)" ;;
    esac
  done

  # Validacoes
  if [ "$REVERT" -eq 1 ] || [ "$ANALYZE_ONLY" -eq 1 ]; then
    return 0  # Revert e analyze nao precisam --ccds
  fi

  case "$CCDS_MODE" in
    core|spread)
      # core/spread consomem TODOS os CPUs/threads para rede. Nao sobra app
      # threads -> ativa NO_AFFINITY automaticamente (CPUAffinity= ficaria vazia).
      if [ "$NO_AFFINITY" -eq 0 ]; then
        warn "--ccds ${CCDS_MODE}: nenhum thread sobra para app; auto-ativando --no-affinity"
        NO_AFFINITY=1
      fi
      # spread: IRQ em TODOS os 128 threads -> qualquer pinning de worker compete
      # com um IRQ; auto-ativa --nginx-auto (se usuario nao escolheu outro)
      if [ "$CCDS_MODE" = "spread" ] && [ "$NGINX_MODE_SET" -eq 0 ]; then
        warn "--ccds spread: nginx pinning compete com IRQs em cada thread; auto-ativando --nginx-auto"
        NGINX_MODE="auto"
      fi
      ;;
    numeric)
      if [ "$CCDS_NET" -lt 1 ] 2>/dev/null || ! [[ "$CCDS_NET" =~ ^[0-9]+$ ]]; then
        die "--ccds deve ser inteiro >= 1 ou 'core' ou 'spread' (recebido: '$CCDS_NET'). Use --help."
      fi
      ;;
    *)
      die "CCDS_MODE inesperado: '$CCDS_MODE' (bug interno)" ;;
  esac

  # --- Rejeita combinacoes degeneradas em --ccds spread ---
  # Em spread cada thread ja tem sua propria queue/worker, entao masks
  # {core, sib} produzem PARES com mascaras identicas (worker N e sibling(N)
  # acabam com a mesma mask) -- redundante e nao tras ganho.
  if [ "$CCDS_MODE" = "spread" ] && [ "$XPS_MODE" = "irq-smt" ]; then
    echo "${C_RED}[FATAL]${C_RST} --ccds spread + --xps-irq-smt: combinacao degenerada." >&2
    echo "        Em spread cada thread ja tem sua propria queue." >&2
    echo "        Use --xps-irq      (1 CPU -> 1 queue) ou" >&2
    echo "            --xps-spread   (kernel hash em mask cheio) ou" >&2
    echo "            --ccds core/N --xps-irq-smt (semantica original)." >&2
    exit 1
  fi
  if [ "$CCDS_MODE" = "spread" ] && [ "$NGINX_MODE" = "irq-smt" ]; then
    echo "${C_RED}[FATAL]${C_RST} --ccds spread + --nginx-irq-smt: combinacao degenerada." >&2
    echo "        Em spread 2 workers competiriam pela mesma mask {N, sib(N)}." >&2
    echo "        Use --nginx-auto   (nginx decide) ou" >&2
    echo "            --nginx-irq    (1 worker por thread, self-pin) ou" >&2
    echo "            --nginx-smt    (worker no SMT do IRQ thread) ou" >&2
    echo "            --ccds core/N --nginx-irq-smt (semantica original)." >&2
    exit 1
  fi
}

# ============================================================================
# REQUIRE ROOT
# ============================================================================
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Este script precisa rodar como root."
  fi
}

# ============================================================================
# LOCK: previne execucao concorrente.
#
# Por que: o path-trigger (xuione-ccd-net.path) dispara o service quando
# /sys/class/net/<iface>/operstate muda. Durante o apply manual, o
# `ethtool -L combined N` derruba a NIC momentaneamente (DOWN -> UP), o que
# pode disparar o trigger e rodar o script em PARALELO consigo mesmo,
# causando duas execucoes concorrentes que mexem nos mesmos arquivos.
#
# flock garante exclusao mutua: apenas 1 instancia roda por vez. Outras
# instancias falham rapidamente com `die` (nao acumulam pendentes).
# ============================================================================
readonly LOCK_FILE="/var/lock/xuione-ccd-net.lock"
acquire_lock() {
  # Modo somente-leitura (analyze, plan, dry-run sem apply) nao precisa lock
  if [ "$DRY_RUN" -eq 1 ] && [ "$REVERT" -eq 0 ]; then
    return 0
  fi
  exec 9>"$LOCK_FILE" || die "Nao consegui abrir lock file ${LOCK_FILE}"
  if ! flock -n 9; then
    # --revert precisa falhar alto: o operador espera que tenha revertido.
    [ "$REVERT" -eq 1 ] && \
      die "Outra instancia do script ja esta rodando (lock=${LOCK_FILE}). Aguarde ou kill PID."
    # Apply concorrente e redundante por definicao (mesmo plano, idempotente).
    # Sair 0 evita que o path-trigger -- disparado pelo PROPRIO apply quando a
    # NIC faz DOWN->UP -- deixe a unit em "failed" sem motivo.
    warn "Outra instancia ja esta aplicando (lock=${LOCK_FILE}); saindo sem fazer nada."
    exit 0
  fi
  # Grava PID no lock para diagnostico
  printf '%s\n' "$$" >&9
  vlog "Lock adquirido (PID=$$): ${LOCK_FILE}"
}

# ============================================================================
# TOPOLOGIA: detecta CCDs via L3 cache groups
# ============================================================================
detect_topology() {
  section "Detectando topologia"

  TOTAL_THREADS=$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo)
  [ "$TOTAL_THREADS" -lt 4 ] && die "Topologia muito pequena (<4 threads): $TOTAL_THREADS"

  # Detecta SMT siblings: para cada thread, o sibling > self e' o "outro" thread
  local cpu sib
  for cpu in $(seq 0 $((TOTAL_THREADS - 1))); do
    local sl_file="/sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list"
    [ ! -f "$sl_file" ] && die "Topologia incompleta: $sl_file ausente"
    # Lista pode ser "N,M" ou "N-M". Pegamos os 2 numeros.
    local nums; nums=$(tr ',-' '\n' < "$sl_file" | head -2 | xargs)
    local a b; a=$(echo "$nums" | awk '{print $1}'); b=$(echo "$nums" | awk '{print $2}')
    if [ -n "$b" ] && [ "$a" != "$b" ]; then
      SMT_SIBLING[$cpu]=$([ "$cpu" = "$a" ] && echo "$b" || echo "$a")
    else
      SMT_SIBLING[$cpu]=""
    fi
  done

  # Verifica SMT2 esperado: cada core fisico tem 2 threads
  local n_no_sib=0
  for cpu in "${!SMT_SIBLING[@]}"; do
    [ -z "${SMT_SIBLING[$cpu]}" ] && n_no_sib=$((n_no_sib + 1))
  done
  [ "$n_no_sib" -gt 0 ] && warn "${n_no_sib} CPUs sem SMT sibling (SMT desabilitado?)"

  # Conta cores fisicos: para cada par SMT, conta uma vez (o de menor numero)
  TOTAL_PHYSICAL_CORES=0
  for cpu in $(seq 0 $((TOTAL_THREADS - 1))); do
    local sib="${SMT_SIBLING[$cpu]}"
    if [ -z "$sib" ] || [ "$cpu" -lt "$sib" ]; then
      TOTAL_PHYSICAL_CORES=$((TOTAL_PHYSICAL_CORES + 1))
    fi
  done

  # Detecta CCXes via L3 cache id
  declare -A l3_cores=()  # l3_id -> "c1 c2 ..."
  for cpu in $(seq 0 $((TOTAL_THREADS - 1))); do
    local l3_file="/sys/devices/system/cpu/cpu${cpu}/cache/index3/id"
    if [ -f "$l3_file" ]; then
      local lid; lid=$(cat "$l3_file" 2>/dev/null)
      if [ -n "$lid" ]; then
        l3_cores[$lid]="${l3_cores[$lid]:-} $cpu"
      fi
    fi
  done

  NUM_CCXES="${#l3_cores[@]}"
  [ "$NUM_CCXES" -lt 2 ] && die "Nao detectei CCXes via L3 (kernel velho? maquina nao-EPYC?)"

  # Detecta CCXES_PER_CCD dinamicamente baseado em cores fisicos por CCX:
  #   - 4 cores/CCX => Zen2 (Rome): 2 CCXes por CCD
  #   - 8 cores/CCX => Zen3/Zen4 (Milan/Genoa): 1 CCX por CCD
  local cores_per_ccx=$(( TOTAL_PHYSICAL_CORES / NUM_CCXES ))
  if [ "$cores_per_ccx" -eq 4 ]; then
    CCXES_PER_CCD=2
  elif [ "$cores_per_ccx" -eq 8 ]; then
    CCXES_PER_CCD=1
  else
    warn "Topologia atipica: ${cores_per_ccx} cores/CCX. Assumindo 1 CCX/CCD."
    CCXES_PER_CCD=1
  fi

  # Cada CCD = CCXES_PER_CCD CCXes consecutivos (numeracao L3 padrao AMD).
  declare -A ccd_threads=()
  local l3id
  for l3id in "${!l3_cores[@]}"; do
    local ccd_id=$((l3id / CCXES_PER_CCD))
    ccd_threads[$ccd_id]="${ccd_threads[$ccd_id]:-} ${l3_cores[$l3id]}"
  done

  NUM_CCDS="${#ccd_threads[@]}"
  [ "$NUM_CCDS" -lt 2 ] && die "Detectei apenas ${NUM_CCDS} CCD(s); precisa ao menos 2"

  # Para cada CCD, lista cores fisicos (1 por par SMT)
  local ccd_id
  for ccd_id in $(seq 0 $((NUM_CCDS - 1))); do
    local cores="${ccd_threads[$ccd_id]:-}"
    local phys_list=""
    for cpu in $cores; do
      local sib="${SMT_SIBLING[$cpu]:-}"
      if [ -z "$sib" ] || [ "$cpu" -lt "$sib" ]; then
        phys_list="$phys_list $cpu"
      fi
    done
    # shellcheck disable=SC2086  # word splitting intencional sobre phys_list
    CCD_PHYSCORES[$ccd_id]="$(echo $phys_list | tr ' ' '\n' | sort -n | xargs)"
  done

  # Resumo
  log "Threads totais: ${TOTAL_THREADS}"
  log "Cores fisicos: ${TOTAL_PHYSICAL_CORES}"
  log "CCXes detectados: ${NUM_CCXES}"
  log "CCDs detectados: ${NUM_CCDS}  (assumindo ${CCXES_PER_CCD} CCXes/CCD - padrao EPYC)"

  if [ "$VERBOSE" -eq 1 ]; then
    for ccd_id in $(seq 0 $((NUM_CCDS - 1))); do
      vlog "  CCD${ccd_id}: cores fisicos = ${CCD_PHYSCORES[$ccd_id]}"
    done
  fi
}

# ============================================================================
# REQUIRE NIC: flag --nic e obrigatoria. Valida existencia e estado.
# Se NIC omitido, lista candidatas (UP, fisicas) para ajudar o usuario.
# ============================================================================
require_nic() {
  if [ -z "$NIC" ]; then
    # Lista candidatas para sugerir
    echo "${C_RED}[FATAL]${C_RST} Flag ${C_BLD}--nic NAME${C_RST} e obrigatoria." >&2
    echo "" >&2
    echo "Interfaces candidatas (UP, nao-virtuais) neste host:" >&2
    local iface_path iface state tx_bytes
    local found=0
    for iface_path in /sys/class/net/*; do
      iface=${iface_path##*/}
      case "$iface" in
        lo|docker*|veth*|br-*|tun*|virbr*|enx*) continue ;;
      esac
      state=$(cat "${iface_path}/operstate" 2>/dev/null || echo down)
      [ "$state" != "up" ] && continue
      tx_bytes=$(cat "${iface_path}/statistics/tx_bytes" 2>/dev/null || echo 0)
      local driver speed
      driver=$(ethtool -i "$iface" 2>/dev/null | awk '/^driver:/ {print $2}')
      speed=$(cat "${iface_path}/speed" 2>/dev/null)
      printf '  %-20s  driver=%-10s  speed=%s Mbps  tx_bytes=%s\n' \
        "$iface" "${driver:-?}" "${speed:-?}" "$tx_bytes" >&2
      found=1
    done
    [ "$found" -eq 0 ] && echo "  (nenhuma interface UP detectada)" >&2
    echo "" >&2
    echo "Uso: ${SCRIPT_NAME} --nic <NAME> ..." >&2
    exit 1
  fi
  if [ ! -d "/sys/class/net/${NIC}" ]; then
    die "Interface '${NIC}' nao existe em /sys/class/net/"
  fi
  local state
  state=$(cat "/sys/class/net/${NIC}/operstate" 2>/dev/null || echo unknown)
  if [ "$state" != "up" ]; then
    warn "Interface ${NIC} state='${state}' (esperado 'up'). Continuando mesmo assim."
  fi
  log "NIC: ${C_BLD}${NIC}${C_RST}  (state=${state})"
}

# ============================================================================
# PLAN: calcula listas conforme CCDS_MODE.
#
# Modos:
#   numeric : NET = primeiros CCDS_NET CCDs (cores fisicos); nginx em SMTs
#   core    : NET = TODOS cores fisicos; nginx em TODOS SMT siblings; app=vazio
#   spread  : NET = TODOS os ${TOTAL_THREADS} threads; nginx 1 por thread
#             (self-pinned); app=vazio
#
# Em qualquer modo, ao final temos:
#   NET_IRQ_CPUS   = lista de threads que recebem IRQ NIC (1 por elemento)
#   NET_NGINX_CPUS = lista de threads que recebem nginx worker (1 por elemento)
#   NUM_QUEUES        = count(NET_IRQ_CPUS)
#   NUM_NGINX_WORKERS = count(NET_NGINX_CPUS)
#
# Invariante: NUM_QUEUES == NUM_NGINX_WORKERS (1 worker por queue).
# ============================================================================
build_plan() {
  local i cpu sib

  case "$CCDS_MODE" in
    core)
      section "Construindo plano (modo CORE: TODOS ${TOTAL_PHYSICAL_CORES} cores fisicos)"
      NET_CCD_LIST=""; APP_CCD_LIST=""
      for i in $(seq 0 $((NUM_CCDS - 1))); do NET_CCD_LIST="$NET_CCD_LIST $i"; done
      # shellcheck disable=SC2086
      NET_CCD_LIST=$(echo $NET_CCD_LIST | xargs)

      # IRQ em TODOS cores fisicos do sistema
      NET_IRQ_CPUS=""
      for i in $NET_CCD_LIST; do NET_IRQ_CPUS="$NET_IRQ_CPUS ${CCD_PHYSCORES[$i]}"; done
      # shellcheck disable=SC2086
      NET_IRQ_CPUS=$(echo $NET_IRQ_CPUS | tr ' ' '\n' | sort -n | xargs)

      # nginx em TODOS SMT siblings (mesmo comportamento que numeric)
      NET_NGINX_CPUS=""
      local count_cpus_sem_sib=0
      for cpu in $NET_IRQ_CPUS; do
        sib="${SMT_SIBLING[$cpu]:-}"
        if [ -z "$sib" ]; then
          count_cpus_sem_sib=$((count_cpus_sem_sib + 1))
          warn "CPU fisica ${cpu} nao tem SMT sibling"
          continue
        fi
        NET_NGINX_CPUS="$NET_NGINX_CPUS $sib"
      done
      [ "$count_cpus_sem_sib" -gt 0 ] && die "${count_cpus_sem_sib} CPU(s) rede sem SMT sibling."
      # shellcheck disable=SC2086
      NET_NGINX_CPUS=$(echo $NET_NGINX_CPUS | tr ' ' '\n' | sort -n | xargs)
      ;;

    spread)
      section "Construindo plano (modo SPREAD: TODOS ${TOTAL_THREADS} threads)"
      NET_CCD_LIST=""; APP_CCD_LIST=""
      for i in $(seq 0 $((NUM_CCDS - 1))); do NET_CCD_LIST="$NET_CCD_LIST $i"; done
      # shellcheck disable=SC2086
      NET_CCD_LIST=$(echo $NET_CCD_LIST | xargs)

      # IRQ em TODOS os threads (fisicos + SMT) -> NUM_QUEUES = TOTAL_THREADS
      NET_IRQ_CPUS=$(seq 0 $((TOTAL_THREADS - 1)) | xargs)
      # nginx tambem em TODOS os threads, 1 worker por thread (self-pinned).
      # Mask binario gerado por apply_nginx_conf sera 1-bit em cada thread.
      NET_NGINX_CPUS="$NET_IRQ_CPUS"
      ;;

    numeric)
      section "Construindo plano (CCDs rede = ${CCDS_NET})"

      if [ "$CCDS_NET" -ge "$NUM_CCDS" ]; then
        die "--ccds=${CCDS_NET} >= total CCDs (${NUM_CCDS}); precisa sobrar para app (ou use 'core'/'spread')"
      fi

      # CCDs para rede: 0..CCDS_NET-1 ; CCDs para app: CCDS_NET..NUM_CCDS-1
      NET_CCD_LIST=""; APP_CCD_LIST=""
      for i in $(seq 0 $((CCDS_NET - 1))); do NET_CCD_LIST="$NET_CCD_LIST $i"; done
      for i in $(seq "$CCDS_NET" $((NUM_CCDS - 1))); do APP_CCD_LIST="$APP_CCD_LIST $i"; done
      # shellcheck disable=SC2086
      NET_CCD_LIST=$(echo $NET_CCD_LIST | xargs)
      # shellcheck disable=SC2086
      APP_CCD_LIST=$(echo $APP_CCD_LIST | xargs)

      # CPUs fisicas dos CCDs rede (CCD_PHYSCORES ja contem so fisicos)
      NET_IRQ_CPUS=""
      for i in $NET_CCD_LIST; do NET_IRQ_CPUS="$NET_IRQ_CPUS ${CCD_PHYSCORES[$i]}"; done
      # shellcheck disable=SC2086
      NET_IRQ_CPUS=$(echo $NET_IRQ_CPUS | tr ' ' '\n' | sort -n | xargs)

      # SMT siblings dessas CPUs fisicas (1 worker nginx por sibling)
      NET_NGINX_CPUS=""
      local count_cpus_sem_sib=0
      for cpu in $NET_IRQ_CPUS; do
        sib="${SMT_SIBLING[$cpu]:-}"
        if [ -z "$sib" ]; then
          count_cpus_sem_sib=$((count_cpus_sem_sib + 1))
          warn "CPU fisica ${cpu} nao tem SMT sibling"
          continue
        fi
        NET_NGINX_CPUS="$NET_NGINX_CPUS $sib"
      done
      [ "$count_cpus_sem_sib" -gt 0 ] && die "${count_cpus_sem_sib} CPU(s) rede sem SMT sibling. Verifique SMT: lscpu | grep 'Thread(s)'."
      # shellcheck disable=SC2086
      NET_NGINX_CPUS=$(echo $NET_NGINX_CPUS | tr ' ' '\n' | sort -n | xargs)
      ;;

    *)
      die "CCDS_MODE invalido em build_plan: '${CCDS_MODE}'" ;;
  esac

  # APP_CPUS_RANGE = todos os outros threads (CPUs fisicas + SMTs dos CCDs app)
  declare -A used=()
  for cpu in $NET_IRQ_CPUS; do used[$cpu]=1; done
  for cpu in $NET_NGINX_CPUS; do used[$cpu]=1; done

  local app_list=""
  for cpu in $(seq 0 $((TOTAL_THREADS - 1))); do
    [ -z "${used[$cpu]:-}" ] && app_list="$app_list $cpu"
  done
  # shellcheck disable=SC2086
  APP_CPUS_RANGE=$(compact_range $app_list)

  # shellcheck disable=SC2086
  NUM_QUEUES=$(echo $NET_IRQ_CPUS | wc -w)
  # shellcheck disable=SC2086
  NUM_NGINX_WORKERS=$(echo $NET_NGINX_CPUS | wc -w)

  # === ASSERTIONS de invariantes ===
  # Inv 1: NUM_QUEUES > 0
  # Inv 2 (so numeric/core): NUM_NGINX_WORKERS == #SMT siblings das CPUs rede
  # Inv 3: queues NIC == workers nginx (1 worker por queue)
  # Em spread, NET_NGINX_CPUS == NET_IRQ_CPUS (self-pin) -> Inv 2 nao se aplica.

  if [ "$NUM_QUEUES" -le 0 ]; then
    die "Invariante 1 violada: plano resultou em 0 queues. Verifique topologia."
  fi

  if [ "$CCDS_MODE" != "spread" ]; then
    local independent_smt_count=0
    for cpu in $NET_IRQ_CPUS; do
      sib="${SMT_SIBLING[$cpu]:-}"
      if [ -n "$sib" ]; then independent_smt_count=$((independent_smt_count + 1)); fi
    done
    if [ "$NUM_NGINX_WORKERS" -ne "$independent_smt_count" ]; then
      die "Invariante 2 violada: workers (${NUM_NGINX_WORKERS}) != #SMTs das CPUs rede (${independent_smt_count}). Bug."
    fi
  fi

  if [ "$NUM_QUEUES" -ne "$NUM_NGINX_WORKERS" ]; then
    die "Invariante 3 violada: NUM_QUEUES (${NUM_QUEUES}) != NUM_NGINX_WORKERS (${NUM_NGINX_WORKERS})."
  fi

  # Header descritivo do plano (varia por modo)
  local ccd_label
  case "$CCDS_MODE" in
    core)    ccd_label="${C_BLD}TODOS${C_RST} (modo core)" ;;
    spread)  ccd_label="${C_BLD}TODOS${C_RST} (modo spread = ${TOTAL_THREADS} threads)" ;;
    *)       ccd_label="${C_BLD}${NET_CCD_LIST}${C_RST}  (${CCDS_NET} CCDs)" ;;
  esac
  log "CCDs rede:                  ${ccd_label}"
  if [ "$CCDS_MODE" = "numeric" ]; then
    log "CCDs app:                   ${C_BLD}${APP_CCD_LIST}${C_RST}  ($((NUM_CCDS - CCDS_NET)) CCDs)"
  else
    log "CCDs app:                   ${C_DIM}<nenhum -- modo ${CCDS_MODE}>${C_RST}"
  fi
  log "Threads IRQ NIC:            ${C_BLD}${NUM_QUEUES}${C_RST}  (1 IRQ NIC por thread)"
  log "Threads nginx workers:      ${C_BLD}${NUM_NGINX_WORKERS}${C_RST}  (1 worker por thread)"
  log "APP threads:                ${APP_CPUS_RANGE:-${C_DIM}<vazio>${C_RST}}"
  log "XPS mode:                   ${C_BLD}${XPS_MODE}${C_RST}  -- $(xps_mode_desc)"
  log "nginx mode:                 ${C_BLD}${NGINX_MODE}${C_RST}  -- $(nginx_mode_desc)"
  log ""
  log "${C_BLD}Garantias:${C_RST}"
  log "  NIC queues       = ${C_BLD}${NUM_QUEUES}${C_RST}"
  log "  nginx workers    = ${C_BLD}${NUM_NGINX_WORKERS}${C_RST}"
  log "  queues == workers ${C_GRN}OK${C_RST}"

  if [ "$VERBOSE" -eq 1 ]; then
    # shellcheck disable=SC2086
    vlog "  Threads IRQ (rede):   $(compact_range $NET_IRQ_CPUS)"
    # shellcheck disable=SC2086
    vlog "  Threads nginx:        $(compact_range $NET_NGINX_CPUS)"
  fi
}

# Comprime "0 1 2 3 5 6 7" -> "0-3,5-7"
compact_range() {
  local nums; nums=$(echo "$@" | tr ' ' '\n' | sort -n | uniq | xargs)
  [ -z "$nums" ] && return 0
  local out="" start prev cur
  for cur in $nums; do
    if [ -z "${start:-}" ]; then
      start=$cur; prev=$cur
    elif [ "$cur" -eq $((prev + 1)) ]; then
      prev=$cur
    else
      if [ "$start" = "$prev" ]; then
        out="${out},${start}"
      else
        out="${out},${start}-${prev}"
      fi
      start=$cur; prev=$cur
    fi
  done
  if [ "$start" = "$prev" ]; then
    out="${out},${start}"
  else
    out="${out},${start}-${prev}"
  fi
  printf '%s' "${out#,}"
  echo
}

# ============================================================================
# BITMASK: gera cpumask /proc-style (MSW,...,LSW hex agrupados em palavras
# de CPUMASK_BITS_PER_WORD bits). Escala dinamicamente conforme TOTAL_THREADS.
# Args: numeros das CPUs (zero ou mais)
# Output: ex "00000000,00010000,00000000,00010000" para CPUs 16+80 em maquina
# de 128 threads. Para maquinas com mais/menos threads, ajusta automaticamente
# o numero de palavras.
# Usado para /proc/irq/N/smp_affinity e /sys/class/net/<iface>/queues/tx-N/xps_cpus
# ============================================================================
build_cpumask() {
  local cpus=("$@")
  local total="$TOTAL_THREADS"
  [ "$total" -le 0 ] && die "TOTAL_THREADS nao detectado (chame detect_topology antes)"

  # Quantas palavras de CPUMASK_BITS_PER_WORD bits cobrem o universo.
  local nwords=$(( (total + CPUMASK_BITS_PER_WORD - 1) / CPUMASK_BITS_PER_WORD ))

  # Array de words inicializado em 0
  local -a words=()
  local i
  for ((i=0; i<nwords; i++)); do words[i]=0; done

  # Set bits: divide cada CPU em (palavra, bit dentro da palavra)
  local cpu word_idx bit_pos
  for cpu in "${cpus[@]}"; do
    [ "$cpu" -ge "$total" ] && die "CPU ${cpu} >= total ${total}"
    word_idx=$((cpu / CPUMASK_BITS_PER_WORD))
    bit_pos=$((cpu % CPUMASK_BITS_PER_WORD))
    words[word_idx]=$(( words[word_idx] | (1 << bit_pos) ))
  done

  # Output: MSW primeiro (mais significativa), separadas por virgula
  local out=""
  for ((i=nwords-1; i>=0; i--)); do
    if [ -n "$out" ]; then
      out=$(printf '%s,%0*x' "$out" "$CPUMASK_HEX_PER_WORD" "${words[i]}")
    else
      out=$(printf '%0*x' "$CPUMASK_HEX_PER_WORD" "${words[i]}")
    fi
  done
  echo "$out"
}

# ============================================================================
# BITMASK BINARIO: gera string de 0/1 com bit do CPU setado.
# Usado para worker_cpu_affinity do nginx (que aceita binario, nao hex).
# Bit menos significativo (direita) = CPU 0. Tamanho = TOTAL_THREADS.
# Args: 1 numero de CPU
# ============================================================================
build_cpumask_binary() {
  local cpu="$1"
  local total="$TOTAL_THREADS"
  [ "$total" -le 0 ] && die "TOTAL_THREADS nao detectado (chame detect_topology antes)"
  [ "$cpu" -ge "$total" ] && die "build_cpumask_binary: CPU ${cpu} >= total ${total}"

  # String de 'total' zeros, troca posicao do CPU por 1
  local zeros; zeros=$(printf '%*s' "$total" '' | tr ' ' '0')
  local pos=$((total - 1 - cpu))
  echo "${zeros:0:pos}1${zeros:$((pos+1))}"
}

# ============================================================================
# BITMASK BINARIO MULTI: gera string de 0/1 com N bits setados.
# Usado para worker_cpu_affinity quando precisa de mask de 2+ bits (nginx-irq-smt).
# Bit menos significativo (direita) = CPU 0. Tamanho = TOTAL_THREADS.
# Args: 1 ou mais numeros de CPU
# ============================================================================
build_cpumask_binary_multi() {
  local total="$TOTAL_THREADS"
  [ "$total" -le 0 ] && die "TOTAL_THREADS nao detectado (chame detect_topology antes)"

  local -a bits=()
  local i
  for ((i=0; i<total; i++)); do bits[i]=0; done

  local cpu pos
  for cpu in "$@"; do
    [ "$cpu" -ge "$total" ] && die "build_cpumask_binary_multi: CPU ${cpu} >= total ${total}"
    pos=$((total - 1 - cpu))
    bits[$pos]=1
  done

  local out=""
  for ((i=0; i<total; i++)); do out="${out}${bits[$i]}"; done
  printf '%s' "$out"
}

# ============================================================================
# NGINX MODE HELPERS
# ============================================================================
# Descricao humana do modo nginx.
nginx_mode_desc() {
  case "$NGINX_MODE" in
    auto)    echo "auto -- worker_processes auto + SEM worker_cpu_affinity" ;;
    irq)     echo "irq -- worker[i] pinado no IRQ thread" ;;
    smt)     echo "smt -- worker[i] pinado no SMT sibling do IRQ thread (classico)" ;;
    irq-smt) echo "irq-smt -- worker[i] mask = {IRQ thread, SMT sibling}" ;;
    *)       echo "??? (NGINX_MODE='${NGINX_MODE}' invalido)" ;;
  esac
}

# Constroi mask binaria de worker_cpu_affinity para 1 worker, dado core IRQ e sib.
# NAO usado em modo auto (que nao escreve worker_cpu_affinity).
# Args: <core> <sib_ou_vazio>
build_nginx_worker_mask() {
  local core="$1" sib="${2:-}"
  case "$NGINX_MODE" in
    irq)
      build_cpumask_binary_multi "$core"
      ;;
    smt)
      if [ -n "$sib" ]; then build_cpumask_binary_multi "$sib"
      else build_cpumask_binary_multi "$core"; fi
      ;;
    irq-smt)
      if [ -n "$sib" ]; then build_cpumask_binary_multi "$core" "$sib"
      else build_cpumask_binary_multi "$core"; fi
      ;;
    *)
      die "build_nginx_worker_mask: NGINX_MODE invalido para mask: '${NGINX_MODE}' (auto nao usa mask)"
      ;;
  esac
}

# ============================================================================
# XPS MODE HELPERS
# ============================================================================
# Descricao humana do modo XPS (usado em logs/plan/audit).
xps_mode_desc() {
  case "$XPS_MODE" in
    off)     echo "DESATIVADO (xps_cpus=0 em TODAS as tx queues)" ;;
    irq)     echo "irq-only (mask = CPU fisica do IRQ daquela queue)" ;;
    smt)     echo "smt-only (mask = SMT sibling do IRQ daquela queue)" ;;
    irq-smt) echo "irq+smt (mask = {CPU fisica, SMT sibling}) -- smt-irq classico" ;;
    spread)  echo "spread (mask = TODOS os ${TOTAL_THREADS} threads)" ;;
    *)       echo "??? (XPS_MODE='${XPS_MODE}' invalido)" ;;
  esac
}

# Constroi mask XPS para UMA queue do plano, dado o core IRQ e seu SMT sibling.
# Para modo "off" retorna "0" (mas o caller normalmente pula esta funcao).
# Args: <core> <sib_ou_vazio>
build_xps_mask_for_queue() {
  local core="$1" sib="${2:-}"
  case "$XPS_MODE" in
    off)
      printf '0'
      ;;
    irq)
      build_cpumask "$core"
      ;;
    smt)
      if [ -n "$sib" ]; then build_cpumask "$sib"
      else build_cpumask "$core"; fi
      ;;
    irq-smt)
      if [ -n "$sib" ]; then build_cpumask "$core" "$sib"
      else build_cpumask "$core"; fi
      ;;
    spread)
      # Mask cheio de TOTAL_THREADS bits. Pre-calculado em apply_irq_xps_rps,
      # mas fallback aqui para chamadas isoladas (dry-run/plan).
      local args=() i
      for ((i=0; i<TOTAL_THREADS; i++)); do args+=("$i"); done
      build_cpumask "${args[@]}"
      ;;
    *)
      die "build_xps_mask_for_queue: XPS_MODE invalido: '${XPS_MODE}'"
      ;;
  esac
}

# ============================================================================
# PREFLIGHT
# ============================================================================
preflight() {
  section "Pre-flight checks"

  require_root

  # Checa ethtool
  command -v ethtool >/dev/null || die "ethtool nao encontrado"
  ok "ethtool disponivel"

  # Checa driver + queues maximas (Pre-set maximums) e atuais (Current).
  # MAX_NIC_QUEUES e exposto como variavel global para uso por outras funcoes
  # (logs, validacoes, etc).
  local driver cur_combined
  driver=$(ethtool -i "$NIC" 2>/dev/null | awk '/^driver:/ {print $2}')
  MAX_NIC_QUEUES=$(ethtool -l "$NIC" 2>/dev/null | awk '/^Combined:/ {if (n==0) print $2; n++}' | head -1)
  cur_combined=$(ethtool -l "$NIC" 2>/dev/null | awk '/^Combined:/ {if (n==1) print $2; n++}' | head -1)
  [ -z "$driver" ] && die "Nao consegui ler driver de ${NIC}"
  [ -z "$MAX_NIC_QUEUES" ] && die "Nao consegui ler 'Combined' max via ethtool -l"
  log "Driver:               ${driver}"
  log "Queues NIC (max HW):  ${MAX_NIC_QUEUES}"
  log "Queues NIC (atual):   ${cur_combined:-?}"
  log "Queues NIC (plano):   ${NUM_QUEUES}"
  if [ "$NUM_QUEUES" -gt "$MAX_NIC_QUEUES" ]; then
    die "Plano requer ${NUM_QUEUES} queues mas NIC suporta no maximo ${MAX_NIC_QUEUES}"
  fi
  ok "NIC suporta ${NUM_QUEUES} queues (max=${MAX_NIC_QUEUES})"

  # Checa nginx.conf
  if [ ! -f "$DEFAULT_NGINX_CONF" ]; then
    warn "${DEFAULT_NGINX_CONF} nao encontrado; etapa nginx sera pulada"
  else
    ok "nginx.conf encontrado"
  fi

  # Checa xuione.service
  if [ ! -f "$DEFAULT_XUI_UNIT" ]; then
    warn "${DEFAULT_XUI_UNIT} nao encontrado; CPUAffinity do xuione sera pulado"
  else
    ok "xuione.service encontrado"
  fi

  # Checa cron.service
  if ! systemctl list-unit-files cron.service 2>/dev/null | grep -q '^cron\.service'; then
    warn "cron.service ausente neste sistema; drop-in sera pulado"
  else
    ok "cron.service encontrado"
  fi

  # Checa irqbalance: se ativo, reescreve /proc/irq/*/smp_affinity em segundos
  # e desmonta todo o plano CCD-aware. Aqui so INFORMA: a 1a fase do apply
  # (disable_irqbalance) faz stop + disable antes de tocar em qualquer coisa.
  if systemctl is-active --quiet irqbalance 2>/dev/null; then
    warn "irqbalance ATIVO: sera parado e desabilitado na 1a fase do apply"
  else
    ok "irqbalance inativo"
  fi
}

# ============================================================================
# CONFIRMAR (interativo)
# ============================================================================
# Apenas mostra aviso (sem read). Script nao tem confirmacao interativa --
# operador decide a janela ao rodar --apply.
notify_impact() {
  echo
  echo "${C_YEL}AVISO:${C_RST} ${C_BLD}ethtool -L combined ${NUM_QUEUES}${C_RST} e ${C_BLD}ethtool -G${C_RST} (ring)"
  echo "fazem ice_down()/ice_up() na NIC: breve interrupcao do trafego"
  echo "(~5-10s, depende do driver). Os dois sao pulados quando o valor ja"
  echo "esta correto; o ring tambem e pulado se houver trafego (salvo"
  echo "${C_BLD}--allow-nic-reset${C_RST})."
  echo "${C_BLD}ethtool -K${C_RST} so e emitido para features atualmente OFF."
  echo "${C_BLD}${SYSCTL_FILE}${C_RST} sera REESCRITO por completo (com backup)."
  echo "nginx reload e zero-downtime."
  echo
}

# ============================================================================
# APPLY: desativa RDMA (irdma)
# Razao: economiza recursos (vetores MSI-X, memoria do driver). Para load
# balancer XUI/IPTV nao usamos RDMA. Persiste via blacklist em modprobe.d.
# ============================================================================
apply_rdma_off() {
  section "Desativando RDMA (${RDMA_MODULE})"

  local loaded=0
  lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$RDMA_MODULE" && loaded=1

  if [ "$loaded" -eq 0 ] && [ -f "$RDMA_BLACKLIST_FILE" ]; then
    ok "${RDMA_MODULE} ja descarregado + blacklist ja existe (idempotente)"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    [ "$loaded" -eq 1 ] && log "[dry-run] rmmod ${RDMA_MODULE} (atualmente carregado)"
    [ ! -f "$RDMA_BLACKLIST_FILE" ] && log "[dry-run] criaria ${RDMA_BLACKLIST_FILE} com blacklist ${RDMA_MODULE}"
    return 0
  fi

  # Remove o modulo se carregado
  if [ "$loaded" -eq 1 ]; then
    if rmmod "$RDMA_MODULE" 2>/dev/null; then
      ok "rmmod ${RDMA_MODULE} aplicado"
    else
      warn "rmmod ${RDMA_MODULE} falhou (em uso? requer reboot apos blacklist)"
    fi
  else
    log "${RDMA_MODULE} ja nao carregado"
  fi

  # Blacklist persistente (idempotente)
  if [ ! -f "$RDMA_BLACKLIST_FILE" ] || ! grep -qx "blacklist ${RDMA_MODULE}" "$RDMA_BLACKLIST_FILE" 2>/dev/null; then
    cat > "$RDMA_BLACKLIST_FILE" <<EOF
# Gerado por ${SCRIPT_NAME} em $(date '+%Y-%m-%d %H:%M:%S')
# Servidor XUI/IPTV nao usa RDMA. Mantemos blacklist para nao recarregar
# automaticamente apos reboot (poupa MSI-X vectors e memoria do driver).
blacklist ${RDMA_MODULE}
EOF
    chmod 0644 "$RDMA_BLACKLIST_FILE"
    ok "blacklist criada: ${RDMA_BLACKLIST_FILE}"
  else
    ok "blacklist ja existe em ${RDMA_BLACKLIST_FILE}"
  fi
}

# ============================================================================
# APPLY: ring buffer no maximo
# Razao: ring maior absorve microbursts RX antes de o NAPI poll drenar.
# Reduz rx_dropped em rajadas curtas. Para E810: 8160 maximo (hardware limit).
# ============================================================================
# Ha trafego relevante passando na NIC? 2 amostras de rx+tx packets com 1s de
# intervalo. Usado para decidir se e seguro emitir ethtool -G (que derruba a
# interface). So e chamado quando o ring esta fora do maximo.
NIC_BUSY_PPS=1000   # acima disso: NIC em producao, nao mexer sem opt-in
nic_has_traffic() {
  local base="/sys/class/net/${NIC}/statistics"
  local rx1 tx1 rx2 tx2
  rx1=$(cat "${base}/rx_packets" 2>/dev/null || echo 0)
  tx1=$(cat "${base}/tx_packets" 2>/dev/null || echo 0)
  sleep 1
  rx2=$(cat "${base}/rx_packets" 2>/dev/null || echo 0)
  tx2=$(cat "${base}/tx_packets" 2>/dev/null || echo 0)
  [ "$(( (rx2 - rx1) + (tx2 - tx1) ))" -gt "$NIC_BUSY_PPS" ]
}

apply_ring_size_max() {
  section "Ring buffer no maximo da NIC"

  # Detecta max e current via ethtool -g
  # Output tem 2 secoes: "Pre-set maximums" e "Current hardware settings"
  local max_rx max_tx cur_rx cur_tx
  max_rx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^RX:/ {n++; if (n==1) print $2; }' | head -1)
  max_tx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^TX:/ {n++; if (n==1) print $2; }' | head -1)
  cur_rx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^RX:/ {n++; if (n==2) print $2; }' | head -1)
  cur_tx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^TX:/ {n++; if (n==2) print $2; }' | head -1)

  # Valida que valores sao numericos antes de prosseguir
  local re='^[0-9]+$'
  if ! [[ "$max_rx" =~ $re ]] || ! [[ "$max_tx" =~ $re ]]; then
    warn "Nao consegui detectar ring size max via ethtool -g (max_rx='${max_rx}' max_tx='${max_tx}')"
    return 0
  fi
  if ! [[ "$cur_rx" =~ $re ]] || ! [[ "$cur_tx" =~ $re ]]; then
    warn "Nao consegui ler ring size atual (cur_rx='${cur_rx}' cur_tx='${cur_tx}')"
    return 0
  fi

  log "Ring RX: atual=${cur_rx} max=${max_rx} | TX: atual=${cur_tx} max=${max_tx}"

  if [ "$cur_rx" = "$max_rx" ] && [ "$cur_tx" = "$max_tx" ]; then
    ok "Ring buffer ja no maximo (RX=${max_rx}, TX=${max_tx})"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] ethtool -G ${NIC} rx ${max_rx} tx ${max_tx}"
    if [ "$ALLOW_NIC_RESET" -eq 0 ]; then
      log "[dry-run] (seria PULADO se houvesse trafego; use --allow-nic-reset)"
    fi
    return 0
  fi

  # GUARDA: ethtool -G faz ice_down()/ice_up() na NIC (mesma pausa do -L).
  # Com trafego passando isso derruba os flows ativos; exige opt-in explicito.
  # NIC ociosa (ex: boot antes do nginx subir) aplica normalmente.
  if [ "$ALLOW_NIC_RESET" -eq 0 ] && nic_has_traffic; then
    warn "Ring fora do maximo, mas ha trafego na NIC: ethtool -G derruba a interface."
    warn "PULANDO ring resize. Rode em janela controlada com --allow-nic-reset."
    return 0
  fi

  if ethtool -G "$NIC" rx "$max_rx" tx "$max_tx" 2>/dev/null; then
    ok "ethtool -G ${NIC} rx ${max_rx} tx ${max_tx} aplicado"
  else
    nok "Falhou aplicar ring size max"
  fi
}

# ============================================================================
# APPLY: coalesce adaptive (RX e TX)
# Razao: adaptive coalesce ajusta dinamicamente o numero de pacotes/microseg
# por interrupt baseado na taxa de chegada. Reduz IRQs em alta carga (poupa
# CPU) e reduz latencia em baixa carga.
# ============================================================================
apply_coalesce_adaptive() {
  section "Coalesce adaptive RX/TX = on"

  local arx atx
  arx=$(ethtool -c "$NIC" 2>/dev/null | awk '/^Adaptive RX:/ {print $3}')
  atx=$(ethtool -c "$NIC" 2>/dev/null | awk '/^Adaptive RX:/ {print $5}')

  log "Atual: Adaptive RX=${arx:-?}  TX=${atx:-?}"

  if [ "$arx" = "on" ] && [ "$atx" = "on" ]; then
    ok "Coalesce adaptive ja em RX=on TX=on (idempotente)"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] ethtool -C ${NIC} adaptive-rx on adaptive-tx on"
    return 0
  fi

  if ethtool -C "$NIC" adaptive-rx on adaptive-tx on 2>/dev/null; then
    ok "ethtool -C ${NIC} adaptive-rx on adaptive-tx on aplicado"
  else
    nok "Falhou aplicar coalesce adaptive"
  fi
}

# ============================================================================
# APPLY: NAPI deferral (gro_flush_timeout + napi_defer_hard_irqs)
#
# Reduz IRQ rate batchando packets em janelas de microssegundos:
#   - gro_flush_timeout (ns): janela maxima que GRO segura packets antes
#     de empurrar pro stack. 200000 ns = 200 us (irrelevante para HLS).
#   - napi_defer_hard_irqs: numero de NAPI polls antes de re-armar HW IRQ.
#     2 = deixa o poll loop colher mais packets antes do proximo IRQ.
#
# Ganho tipico em 100G TX: 40-50% reducao de IRQ rate, ~1-2% menos %soft.
# Padrao Cilium/Cloudflare para NICs alta vazao.
#
# Per-NIC via sysfs. NAO persiste em reboot -- por isso o service systemd
# re-aplica o script no boot via xuione-ccd-net.path/.service.
# ============================================================================
readonly NAPI_GRO_FLUSH_TIMEOUT_NS=200000   # 200us
readonly NAPI_DEFER_HARD_IRQS=2

apply_napi_defer() {
  section "NAPI defer (gro_flush_timeout + napi_defer_hard_irqs)"

  local f_gro="/sys/class/net/${NIC}/gro_flush_timeout"
  local f_defer="/sys/class/net/${NIC}/napi_defer_hard_irqs"
  if [ ! -f "$f_gro" ] || [ ! -f "$f_defer" ]; then
    warn "sysfs nao tem $(basename "$f_gro")/$(basename "$f_defer") (kernel velho?); pulando"
    return 0
  fi

  local cur_gro cur_defer
  cur_gro=$(cat "$f_gro" 2>/dev/null)
  cur_defer=$(cat "$f_defer" 2>/dev/null)
  log "Atual: gro_flush_timeout=${cur_gro:-?} ns | napi_defer_hard_irqs=${cur_defer:-?}"
  log "Alvo:  gro_flush_timeout=${NAPI_GRO_FLUSH_TIMEOUT_NS} ns | napi_defer_hard_irqs=${NAPI_DEFER_HARD_IRQS}"

  if [ "$cur_gro" = "$NAPI_GRO_FLUSH_TIMEOUT_NS" ] && [ "$cur_defer" = "$NAPI_DEFER_HARD_IRQS" ]; then
    ok "NAPI defer ja aplicado (idempotente)"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] echo ${NAPI_GRO_FLUSH_TIMEOUT_NS} > ${f_gro}"
    log "[dry-run] echo ${NAPI_DEFER_HARD_IRQS} > ${f_defer}"
    return 0
  fi

  local fails=0
  if ! echo "$NAPI_GRO_FLUSH_TIMEOUT_NS" > "$f_gro" 2>/dev/null; then
    nok "Falha ao escrever ${f_gro}"
    fails=$((fails + 1))
  fi
  if ! echo "$NAPI_DEFER_HARD_IRQS" > "$f_defer" 2>/dev/null; then
    nok "Falha ao escrever ${f_defer}"
    fails=$((fails + 1))
  fi
  if [ "$fails" -eq 0 ]; then
    ok "NAPI defer aplicado: gro_flush_timeout=${NAPI_GRO_FLUSH_TIMEOUT_NS}ns napi_defer_hard_irqs=${NAPI_DEFER_HARD_IRQS}"
  fi
}

# ============================================================================
# APPLY: ethtool offloads (TSO/GSO/GRO/checksums/...)
#
# Garante que as features essenciais para 100G TX estejam ON. Lista:
#   - tx-nocache-copy: nao polui cache em TX heavy (streaming)
#   - TSO/GSO/GRO: segmentacao em HW/SW; reduz pps efetiva pro stack
#   - checksums: HW computa, libera CPU
#   - scatter-gather: TX direto de paginas sem coalesce
#   - tx-gso-partial: GSO em encapsulamentos parciais (tunnels)
#   - tx-gre-*/tx-udp_tnl-*: segmentacao de pacotes encapsulados (irrelevante
#     em HLS direto, mas inerte e ja default-on)
#   - tx-ipxip4-segmentation: IPIP/SIT segmentation
#   - VLAN offload (rx/tx): se usar VLAN tag (inerte se nao)
#   - VLAN stag-hw (802.1ad): double-tag (inerte se nao usar QinQ)
#   - receive-hashing: RSS (essencial para multi-queue)
#   - hw-tc-offload: tc-filter offload em HW (irrelevante sem TC rules)
#   - rx-udp_tunnel-port-offload: detecta portas de tuneis para offload
#
# Para cada feature:
#   - "on"          : idempotente, skip
#   - "off"         : ethtool -K tenta ligar; reverifica
#   - "off [fixed]" : driver nao suporta (warn, skip)
#   - "off [requested on]" : pedido aceito mas NAO honrado pelo driver/HW.
#                     Tratado igual a [fixed] (skip): reemitir ethtool -K a
#                     cada execucao so gera WARN eterno e quebra idempotencia.
#   - nao listada   : feature ausente (warn dim, skip)
# ============================================================================
readonly -a OFFLOAD_FEATURES_ON=(
  "tx-nocache-copy"
  "tx-tcp-segmentation"
  "tx-tcp6-segmentation"
  "generic-segmentation-offload"
  "generic-receive-offload"
  "rx-gro-hw"
  "tx-checksum-ipv4"
  "tx-checksum-ipv6"
  "rx-checksumming"
  "scatter-gather"
  "tx-scatter-gather"
  "tx-gso-partial"
  "tx-gre-segmentation"
  "tx-gre-csum-segmentation"
  "tx-udp_tnl-segmentation"
  "tx-udp_tnl-csum-segmentation"
  "tx-ipxip4-segmentation"
  "rx-vlan-offload"
  "tx-vlan-offload"
  "rx-vlan-stag-hw-parse"
  "tx-vlan-stag-hw-insert"
  "receive-hashing"
  "hw-tc-offload"
  "rx-udp_tunnel-port-offload"
)

# Le estado de uma feature: retorna "on", "off", "off-fixed", "missing"
read_offload_state() {
  local feature="$1"
  local line
  line=$(ethtool -k "$NIC" 2>/dev/null | awk -F: -v f="$feature" \
    '$0 ~ "^"f":|^\t"f":" {gsub(/^[ \t]+/,"",$2); print $2; exit}')
  if [ -z "$line" ]; then
    printf 'missing'
  elif echo "$line" | grep -qE '\[(fixed|requested [a-z]+)\]'; then
    printf 'off-fixed'
  elif [ "$line" = "on" ]; then
    printf 'on'
  else
    printf 'off'
  fi
}

apply_offloads() {
  section "Offloads ethtool (TSO/GSO/GRO/checksums/VLAN/tunnels)"

  local total=${#OFFLOAD_FEATURES_ON[@]}
  local already_on=0 set_on=0 fixed_off=0 missing=0 fail=0
  local fixed_list="" missing_list="" off_list=""

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Verificaria ${total} features e tentaria garantir 'on'"
    local f st
    for f in "${OFFLOAD_FEATURES_ON[@]}"; do
      st=$(read_offload_state "$f")
      case "$st" in
        on)        already_on=$((already_on + 1)) ;;
        off)       off_list="${off_list} ${f}"; set_on=$((set_on + 1)) ;;
        off-fixed) fixed_list="${fixed_list} ${f}"; fixed_off=$((fixed_off + 1)) ;;
        missing)   missing_list="${missing_list} ${f}"; missing=$((missing + 1)) ;;
      esac
    done
    log "[dry-run] ja ON:    ${already_on}/${total}"
    log "[dry-run] ligaria:  ${set_on}  (${off_list# })"
    [ "$fixed_off" -gt 0 ] && log "[dry-run] OFF [fixed/requested]: ${fixed_off}  (${fixed_list# })"
    [ "$missing"   -gt 0 ] && log "[dry-run] missing:   ${missing}  (${missing_list# })"
    return 0
  fi

  local f st
  for f in "${OFFLOAD_FEATURES_ON[@]}"; do
    st=$(read_offload_state "$f")
    case "$st" in
      on)
        already_on=$((already_on + 1))
        vlog "  ${f}: ja ON"
        ;;
      off-fixed)
        fixed_off=$((fixed_off + 1))
        fixed_list="${fixed_list} ${f}"
        vlog "  ${f}: OFF [fixed/requested] - nao honrado pelo driver, skip"
        ;;
      missing)
        missing=$((missing + 1))
        missing_list="${missing_list} ${f}"
        vlog "  ${f}: nao listada, skip"
        ;;
      off)
        if ethtool -K "$NIC" "$f" on 2>/dev/null; then
          local after; after=$(read_offload_state "$f")
          if [ "$after" = "on" ]; then
            set_on=$((set_on + 1))
            vlog "  ${f}: OFF -> ON"
          else
            fail=$((fail + 1))
            warn "  ${f}: ethtool -K aplicou mas estado=${after}"
          fi
        else
          fail=$((fail + 1))
          warn "  ${f}: ethtool -K falhou"
        fi
        ;;
    esac
  done

  ok "Offloads: ${already_on} ja ON, ${set_on} ligadas agora, ${fixed_off} OFF [fixed/requested], ${missing} missing, ${fail} fail"
  [ "$fixed_off" -gt 0 ] && log "  OFF [fixed/requested] (nao honrado pelo driver):${fixed_list}"
  [ "$missing"   -gt 0 ] && log "  missing (feature nao existe):${missing_list}"
}

# ============================================================================
# APPLY: sysctl /etc/sysctl.conf consolidado
#
# REESCREVE /etc/sysctl.conf inteiro com o template embedded abaixo
# (SYSCTL_TEMPLATE). Fluxo:
#   1) chattr -i (se imutavel)
#   2) Backup .bak.ccdnet.<ts>
#   3) Esvazia e escreve template novo
#   4) sysctl -p (aplica)
#   5) chattr +i (se estava imutavel)
#
# O template e o tuning consolidado para XUI/IPTV em EPYC 7702P + NIC E810
# 100G: buffers TCP, backlogs, NAPI budget, BBR+FQ, conntrack, hardening.
# Idempotente: se conteudo + runtime ja batem, no-op.
# ============================================================================
readonly SYSCTL_FILE="/etc/sysctl.conf"
readonly NETDEV_BUDGET_USECS=16000   # alvo runtime check
readonly NETDEV_BUDGET=1200          # alvo runtime check

# Template completo. Edits manuais sao SOBRESCRITAS pelo script -- adicione
# customizacoes aqui se quiser persistir.
sysctl_template() {
  cat <<EOF
# === BEGIN xuione-ccd-net ===
# Gerado por ${SCRIPT_NAME} em $(date '+%Y-%m-%d %H:%M:%S')
# Tuning de rede para XUI/IPTV em EPYC + E810 100G
# ATENCAO: arquivo travado com chattr +i para impedir sobrescrita pelo painel XUI.
# Para editar:  chattr -i ${SYSCTL_FILE}  &&  vim ${SYSCTL_FILE}  &&  chattr +i ${SYSCTL_FILE}

# === Buffers ===
net.core.rmem_max          = 268435456
net.core.wmem_max          = 268435456
net.core.rmem_default      = 1048576
net.core.wmem_default      = 1048576
net.core.optmem_max        = 8388608
net.core.busy_poll         = 0
net.core.busy_read         = 0

# === TCP auto-tune ===
net.ipv4.tcp_rmem            = 16384 1048576 268435456
net.ipv4.tcp_wmem            = 16384 1048576 268435456
net.ipv4.tcp_mem             = 8388608 12582912 16777216
net.ipv4.udp_mem             = 3145728 4194304 6291456
net.ipv4.tcp_notsent_lowat   = 131072
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# === Backlogs + NAPI budget ===
net.core.netdev_max_backlog  = 1000000
net.core.netdev_budget       = ${NETDEV_BUDGET}
net.core.netdev_budget_usecs = ${NETDEV_BUDGET_USECS}
net.core.somaxconn           = 655350
net.ipv4.tcp_max_syn_backlog = 524288
net.ipv4.tcp_max_tw_buckets  = 2000000
net.ipv4.tcp_syncookies      = 1

# === Portas / TIME-WAIT ===
# Range efemero NAO comeca em 1024: portas de servico (80/443/8880/31210)
# ficam fora do sorteio. Senao uma conexao de SAIDA (php-fpm->MySQL master,
# ffmpeg puxando source, curl de EPG) pode ocupar a porta enquanto o listener
# esta parado e o bind seguinte falha com EADDRINUSE.
net.ipv4.ip_local_port_range     = 16384 65000
net.ipv4.ip_local_reserved_ports = 80,443,8880,31210
net.ipv4.tcp_tw_reuse        = 1
net.ipv4.tcp_fin_timeout     = 15
net.ipv4.tcp_fastopen        = 3
net.ipv4.tcp_max_orphans     = 1000000

# === Handshake timeouts ===
net.ipv4.tcp_synack_retries  = 3
net.ipv4.tcp_syn_retries     = 4
net.ipv4.tcp_retries2        = 8

# === Congestion / qdisc ===
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc          = fq

# === RFS global (DESLIGADO; pode virar bottleneck com muitos flows) ===
net.core.rps_sock_flow_entries  = 0

# === Misc TCP ===
net.ipv4.tcp_mtu_probing      = 1
net.ipv4.tcp_sack             = 1
net.ipv4.tcp_dsack            = 1
net.ipv4.tcp_ecn              = 1
net.ipv4.tcp_window_scaling   = 1
net.ipv4.tcp_rfc1337          = 1
net.ipv4.tcp_keepalive_time   = 120
net.ipv4.tcp_keepalive_intvl  = 20
net.ipv4.tcp_keepalive_probes = 3

# === ARP table ===
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# === Streaming: nao reseta cwnd em idle ===
net.ipv4.tcp_slow_start_after_idle = 0

# === Filesystem ===
fs.file-max     = 12000000
fs.nr_open      = 12000000
fs.aio-max-nr   = 1048576

# === Process limit ===
kernel.pid_max  = 4194304

# === Scheduler (pinned workload: desativa agrupamento por session) ===
# sched_migration_cost_ns nao existe em kernels >=5.x (removido); manter pinning
# explicito via CPUAffinity ja resolve. autogroup=0 evita scheduler agrupar
# tasks da mesma session em um cgroup (atrapalha pinning forte do XUI).
kernel.sched_autogroup_enabled = 0

# === VM ===
vm.max_map_count          = 1048576
vm.overcommit_memory      = 1
vm.swappiness             = 1
vm.dirty_ratio            = 10
vm.dirty_background_ratio = 3
vm.min_free_kbytes        = 524288

# === IPv6 desabilitado ===
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6      = 1

# === Conntrack ===
net.netfilter.nf_conntrack_max                      = 4194304
net.netfilter.nf_conntrack_buckets                  = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established  = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait    = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait   = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait     = 30
net.netfilter.nf_conntrack_generic_timeout          = 120
net.netfilter.nf_conntrack_udp_timeout              = 30
net.netfilter.nf_conntrack_udp_timeout_stream       = 60
net.netfilter.nf_conntrack_tcp_loose                = 0

# === Hardening ===
net.ipv4.conf.all.rp_filter                = 1
net.ipv4.conf.default.rp_filter            = 1
net.ipv4.conf.all.accept_redirects         = 0
net.ipv4.conf.all.send_redirects           = 0
net.ipv4.conf.all.accept_source_route      = 0
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# === END xuione-ccd-net ===
EOF
}

# ---------------------------------------------------------------------------
# irqbalance: PRIMEIRA fase do apply. Ativo, ele reescreve /proc/irq/*/smp_affinity
# segundos depois do pinning e desmonta o plano CCD-aware; apenas "enabled",
# volta no proximo boot e desfaz o que a unit aplicou. stop + disable, idempotente.
# ---------------------------------------------------------------------------
disable_irqbalance() {
  section "irqbalance: stop + disable (antes de qualquer pinning)"
  if ! systemctl cat irqbalance.service >/dev/null 2>&1; then
    ok "irqbalance nao instalado; nada a fazer"
    return 0
  fi
  local active=0 enabled=0
  systemctl is-active  --quiet irqbalance.service 2>/dev/null && active=1
  systemctl is-enabled --quiet irqbalance.service 2>/dev/null && enabled=1
  if [ "$active" -eq 0 ] && [ "$enabled" -eq 0 ]; then
    ok "irqbalance ja inativo e desabilitado (idempotente)"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    [ "$active"  -eq 1 ] && log "[dry-run] systemctl stop irqbalance.service"
    [ "$enabled" -eq 1 ] && log "[dry-run] systemctl disable irqbalance.service"
    return 0
  fi
  if [ "$active" -eq 1 ]; then
    if systemctl stop irqbalance.service 2>/dev/null; then
      ok "irqbalance parado"
    else
      nok "falha ao parar irqbalance (o pinning abaixo pode ser desfeito)"
    fi
  fi
  if [ "$enabled" -eq 1 ]; then
    if systemctl disable irqbalance.service >/dev/null 2>&1; then
      ok "irqbalance desabilitado (nao volta no boot)"
    else
      nok "falha ao desabilitar irqbalance (vai voltar no proximo boot)"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# nf_conntrack x sysctl: as chaves net.netfilter.nf_conntrack_* do template so
# existem com o modulo carregado. Sem ele, sysctl -p da "cannot stat" em TODAS
# (o log de 2026-08-20 mostrava so as 3 ultimas por causa do tail), rc!=0,
# restore do backup e apply perdido. No boot o systemd-sysctl roda DEPOIS de
# systemd-modules-load, entao persistir o modulo em modules-load.d garante que
# as chaves existam quando /etc/sysctl.conf for aplicado.
# ---------------------------------------------------------------------------
NF_CONNTRACK_MODLOAD="/etc/modules-load.d/xuione-nf_conntrack.conf"
ensure_nf_conntrack_autoload() {
  if grep -qsxE '[[:space:]]*nf_conntrack[[:space:]]*' /etc/modules /etc/modules-load.d/*.conf 2>/dev/null; then
    [ -f "${NF_CONNTRACK_MODLOAD}" ] || log "nf_conntrack ja em modules-load (arquivo de terceiros); nada a fazer"
    return 0
  fi
  if printf '# xuione-ccd-net: carrega nf_conntrack ANTES de systemd-sysctl, senao as chaves\n# net.netfilter.nf_conntrack_* de /etc/sysctl.conf nao existem no boot.\nnf_conntrack\n' > "${NF_CONNTRACK_MODLOAD}"; then
    ok "criado ${NF_CONNTRACK_MODLOAD} (nf_conntrack no boot, antes do sysctl)"
  else
    warn "nao consegui escrever ${NF_CONNTRACK_MODLOAD}; chaves net.netfilter.* podem falhar no boot"
  fi
  return 0
}

# Lista (separada por espaco) as chaves de um arquivo sysctl cujo caminho em
# /proc/sys NAO existe neste kernel. `sysctl -e` ignora essas em silencio; aqui
# o operador fica sabendo QUAIS foram ignoradas.
sysctl_missing_keys() {
  local f="$1" k p out=""
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    p="/proc/sys/${k//./\/}"
    [ -e "$p" ] || out="${out} ${k}"
  done < <(awk -F'=' '/^[[:space:]]*[a-z]/{gsub(/[[:space:]]/,"",$1); print $1}' "$f" 2>/dev/null)
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# sysctl no BOOT: systemd-sysctl so le /etc/sysctl.conf via o symlink
# /etc/sysctl.d/99-sysctl.conf (convencao Debian/Ubuntu). Sem ele, tudo que
# este script grava em /etc/sysctl.conf e ignorado no boot ate a unit rodar.
# Tambem detecta chaves em sysctl.d que CONFLITAM com as nossas: systemd-sysctl
# aplica em ordem lexical de basename e o ULTIMO vence -- um 99-zzz.conf
# sobrescreveria o nosso em silencio.
# ---------------------------------------------------------------------------
SYSCTL_BOOT_LINK="/etc/sysctl.d/99-sysctl.conf"
ensure_sysctl_boot_link() {
  local target="${1:-/etc/sysctl.conf}"
  if [ -L "$SYSCTL_BOOT_LINK" ] && [ "$(readlink -f "$SYSCTL_BOOT_LINK" 2>/dev/null)" = "$target" ]; then
    return 0
  fi
  if [ -e "$SYSCTL_BOOT_LINK" ]; then
    warn "${SYSCTL_BOOT_LINK} existe mas nao aponta para ${target}: o boot pode ignorar o arquivo"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] ln -s ../sysctl.conf ${SYSCTL_BOOT_LINK} (systemd-sysctl passa a ler ${target} no boot)"
    return 0
  fi
  if ln -s ../sysctl.conf "$SYSCTL_BOOT_LINK" 2>/dev/null; then
    ok "criado ${SYSCTL_BOOT_LINK} -> ../sysctl.conf (systemd-sysctl aplica ${target} no boot)"
  else
    warn "nao consegui criar ${SYSCTL_BOOT_LINK}; ${target} NAO sera aplicado pelo systemd-sysctl no boot"
  fi
  return 0
}
# Imprime "chave|arquivo|valor_dele|valor_nosso|vencedor" por conflito.
sysctl_d_conflicts() {
  local ours_file="${1:-/etc/sysctl.conf}" f base k k_re theirs ours win
  for f in /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    base=$(basename "$f")
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      k_re=$(printf '%s' "$k" | sed 's/[.]/\\./g')
      ours=$(grep -E "^[[:space:]]*${k_re}[[:space:]]*=" "$ours_file" 2>/dev/null | tail -1 | sed 's/.*=[[:space:]]*//' | tr -s ' \t' ' ')
      [ -n "$ours" ] || continue
      theirs=$(grep -E "^[[:space:]]*${k_re}[[:space:]]*=" "$f" 2>/dev/null | tail -1 | sed 's/.*=[[:space:]]*//' | tr -s ' \t' ' ')
      [ "$ours" = "$theirs" ] && continue
      if [ "$(printf '%s\n%s\n' "$base" "99-sysctl.conf" | sort | tail -1)" = "99-sysctl.conf" ]; then
        win="sysctl.conf"
      else
        win="$base"
      fi
      printf '%s|%s|%s|%s|%s|%s\n' "$k" "$base" "$theirs" "$ours" "$win" "$(dirname "$f")"
    done < <(grep -E '^[[:space:]]*[a-z]' "$f" 2>/dev/null | sed 's/[[:space:]]*=.*//; s/^[[:space:]]*//')
  done
}
# Politica FONTE UNICA (decisao do operador, 2026-08-20): /etc/sysctl.conf e a
# UNICA configuracao de sysctl administrada. Arquivos em /etc/sysctl.d que
# conflitam com ela sao desativados (renomeados para .conf.disabled-by-xuione;
# systemd-sysctl so le *.conf) -- reversivel no --revert. Arquivos de distro
# em /usr/lib/sysctl.d e /run nao sao tocados: o 99-sysctl.conf ja os
# sobrescreve pela ordem lexical, e mascara-los derrubaria defaults alheios.
enforce_single_sysctl_source() {
  local ours_file="${1:-/etc/sysctl.conf}" k base theirs ours win dir f lost kk n=0 done_files=" "
  while IFS='|' read -r k base theirs ours win dir; do
    n=$((n + 1))
    if [ "$dir" != "/etc/sysctl.d" ]; then
      log "sysctl: ${k}=${theirs} em ${dir}/${base} (distro) e sobrescrito por sysctl.conf (${ours}) pela ordem; sem acao"
      continue
    fi
    f="${dir}/${base}"
    case "$done_files" in *" ${f} "*) continue ;; esac
    done_files="${done_files}${f} "
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] mv ${f} ${f}.disabled-by-xuione (conflita: ${k}=${theirs} vs ${ours} em sysctl.conf)"
      continue
    fi
    # Chaves do arquivo que NAO existem no nosso: o operador fica sabendo o que saiu de cena.
    lost=""
    while IFS= read -r kk; do
      [ -n "$kk" ] || continue
      grep -qE "^[[:space:]]*$(printf '%s' "$kk" | sed 's/[.]/\\./g')[[:space:]]*=" "$ours_file" 2>/dev/null || lost="${lost} ${kk}"
    done < <(grep -E '^[[:space:]]*[a-z]' "$f" 2>/dev/null | sed 's/[[:space:]]*=.*//; s/^[[:space:]]*//')
    if mv -f "$f" "${f}.disabled-by-xuione"; then
      ok "fonte unica: ${f} desativado (conflitava: ${k}=${theirs} vs ${ours} em sysctl.conf)"
      [ -n "$lost" ] && warn "  chaves de ${base} ausentes em sysctl.conf (adicione ao template se precisar):${lost}"
    else
      warn "nao consegui desativar ${f}; continua conflitando (vence pela ordem: ${win})"
    fi
  done < <(sysctl_d_conflicts "$ours_file")
  [ "$n" -eq 0 ] && log "fonte unica OK: nenhum conflito entre sysctl.d/* e ${ours_file}"
  return 0
}
# --revert: reativa o que o apply desativou.
restore_disabled_sysctl_d() {
  local df
  for df in /etc/sysctl.d/*.conf.disabled-by-xuione; do
    [ -f "$df" ] || continue
    if mv -f "$df" "${df%.disabled-by-xuione}"; then
      ok "reativado ${df%.disabled-by-xuione} (fonte unica desfeita)"
    else
      warn "nao consegui reativar ${df}"
    fi
  done
  return 0
}

apply_sysctl_netdev() {
  section "Sysctl ${SYSCTL_FILE} (reescreve consolidado)"

  if [ ! -f "$SYSCTL_FILE" ]; then
    warn "${SYSCTL_FILE} nao existe; pulando"
    return 0
  fi

  local desired_content current_content
  desired_content=$(sysctl_template | sed '/^# Gerado por/d')   # ignora timestamp na comparacao
  current_content=$(sed '/^# Gerado por/d' "$SYSCTL_FILE" 2>/dev/null)

  # Runtime checks (sentinels mais comuns)
  local cur_usecs cur_budget cur_cc cur_qdisc
  cur_usecs=$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null)
  cur_budget=$(sysctl -n net.core.netdev_budget 2>/dev/null)
  cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  log "Runtime: netdev_budget=${cur_budget} usecs=${cur_usecs} cc=${cur_cc} qdisc=${cur_qdisc}"

  local file_ok=0 runtime_ok=0
  [ "$desired_content" = "$current_content" ] && file_ok=1
  [ "$cur_usecs" = "$NETDEV_BUDGET_USECS" ] \
    && [ "$cur_budget" = "$NETDEV_BUDGET" ] \
    && [ "$cur_cc" = "bbr" ] \
    && [ "$cur_qdisc" = "fq" ] && runtime_ok=1

  if [ "$file_ok" = "1" ] && [ "$runtime_ok" = "1" ]; then
    ok "${SYSCTL_FILE} ja consolidado + runtime bate (idempotente)"
    # Mesmo sem reescrever, garante trava + persistencia no boot (alguem pode
    # ter tirado o +i ou o symlink do sysctl.d).
    if [ "$DRY_RUN" -eq 0 ] && ! lsattr "$SYSCTL_FILE" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
      if chattr +i "$SYSCTL_FILE" 2>/dev/null; then
        ok "chattr +i ${SYSCTL_FILE} (re-travado)"
      else
        warn "chattr +i ${SYSCTL_FILE} falhou"
      fi
    fi
    ensure_sysctl_boot_link "$SYSCTL_FILE"
    enforce_single_sysctl_source "$SYSCTL_FILE"
    return 0
  fi

  # Detecta imutabilidade
  local is_immutable=0
  if lsattr "$SYSCTL_FILE" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
    is_immutable=1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    [ "$is_immutable" -eq 1 ] && log "[dry-run] chattr -i ${SYSCTL_FILE}"
    log "[dry-run] backup ${SYSCTL_FILE} -> ${SYSCTL_FILE}.bak.ccdnet.<ts>"
    log "[dry-run] esvaziar e reescrever ${SYSCTL_FILE} (template embedded, $(sysctl_template | wc -l) linhas)"
    log "[dry-run] modprobe nf_conntrack + ${NF_CONNTRACK_MODLOAD} (chaves net.netfilter.* no template)"
    log "[dry-run] sysctl -e -p ${SYSCTL_FILE}"
    [ "$is_immutable" -eq 1 ] && log "[dry-run] chattr +i ${SYSCTL_FILE}"
    return 0
  fi

  # --- 1) chattr -i se imutavel ---
  if [ "$is_immutable" -eq 1 ]; then
    if chattr -i "$SYSCTL_FILE" 2>/dev/null; then
      log "chattr -i ${SYSCTL_FILE}"
    else
      die "chattr -i ${SYSCTL_FILE} falhou (precisa root/CAP_LINUX_IMMUTABLE)"
    fi
  fi

  # --- 2) Backup ---
  local ts bak
  ts=$(date +%Y%m%d-%H%M%S)
  bak="${SYSCTL_FILE}.bak.ccdnet.${ts}"
  cp -a "$SYSCTL_FILE" "$bak"
  log "Backup: ${bak}"

  # --- 3) Esvazia + reescreve via template ---
  if ! sysctl_template > "$SYSCTL_FILE"; then
    cp -a "$bak" "$SYSCTL_FILE"
    [ "$is_immutable" -eq 1 ] && chattr +i "$SYSCTL_FILE" 2>/dev/null
    die "Falha ao escrever ${SYSCTL_FILE}; backup restaurado"
  fi
  chmod 0644 "$SYSCTL_FILE"
  ok "${SYSCTL_FILE} reescrito ($(wc -l < "$SYSCTL_FILE") linhas)"

  # --- 3b) nf_conntrack ANTES do sysctl -p ---
  # Sem o modulo, toda chave net.netfilter.nf_conntrack_* falha ("cannot stat")
  # e o apply inteiro era perdido (visto em producao em 2026-08-20: modulo so
  # foi carregado depois, por uma regra ctstate do anti-flood do XUI).
  if grep -q '^net\.netfilter\.nf_conntrack' "$SYSCTL_FILE" 2>/dev/null; then
    if [ ! -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
      if modprobe nf_conntrack 2>/dev/null; then
        ok "modulo nf_conntrack carregado (chaves net.netfilter.* disponiveis)"
      else
        warn "modprobe nf_conntrack falhou: chaves net.netfilter.* serao ignoradas (-e)"
      fi
    fi
    ensure_nf_conntrack_autoload
  fi

  # --- 4) sysctl -e -p ---
  # sysctl -p aplica LINHA A LINHA e segue apos erro: o que veio antes da
  # chave problematica ja esta valendo no kernel. Por isso: (a) capturamos a
  # saida para mostrar QUAL chave falhou; (b) reaplicamos o backup para
  # reduzir o hibrido; (c) nao usamos die -- cenario tipico e uma chave de
  # nf_conntrack ausente (modulo nao carregado), e abortar aqui faria o apply
  # de boot perder IRQ pinning/ring/coalesce, alem de reincidir a cada boot.
  # `-e`: ignora SO "unknown key" (chave ausente neste kernel/modulo). Sem -e,
  # UMA chave inexistente dava rc!=0 -> restore do backup -> apply perdido.
  # Erros reais (EINVAL, permissao, sintaxe) continuam fatais e restauram.
  local sysctl_out sysctl_rc=0 missing_keys
  missing_keys=$(sysctl_missing_keys "$SYSCTL_FILE")
  [ -n "$missing_keys" ] && warn "chaves inexistentes neste kernel (ignoradas por -e):${missing_keys}"
  sysctl_out=$(sysctl -e -p "$SYSCTL_FILE" 2>&1) || sysctl_rc=$?
  if [ "$sysctl_rc" -eq 0 ]; then
    ok "sysctl -e -p ${SYSCTL_FILE} aplicado"
  else
    # Mostra so os ERROS: antes o tail -10 exibia as 7 chaves que passaram e
    # escondia as que falharam.
    printf '%s\n' "$sysctl_out" | grep -vE '^[a-z._0-9]+ = ' | tail -20 | sed 's/^/    /' >&2
    # Restaura backup em falha de syntax/chave inexistente
    cp -a "$bak" "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || \
      warn "runtime pode ter ficado hibrido (chaves aplicadas antes do erro) -- confira com sysctl -a"
    [ "$is_immutable" -eq 1 ] && chattr +i "$SYSCTL_FILE" 2>/dev/null
    nok "sysctl -p falhou; ${SYSCTL_FILE} restaurado de ${bak} (runtime parcialmente aplicado)"
    return 1
  fi

  # --- 5) chattr +i SEMPRE: politica = arquivo travado contra edicao acidental
  #        e sobrescrita por pacote; o proprio script tira e repoe a flag. ---
  if chattr +i "$SYSCTL_FILE" 2>/dev/null; then
    if [ "$is_immutable" -eq 1 ]; then
      log "chattr +i ${SYSCTL_FILE} (restaurado)"
    else
      ok "chattr +i ${SYSCTL_FILE} (travado)"
    fi
  else
    warn "chattr +i ${SYSCTL_FILE} falhou (fs sem suporte?); arquivo ficou SEM protecao"
  fi

  # --- 5b) persistencia no boot + conflitos com sysctl.d ---
  ensure_sysctl_boot_link "$SYSCTL_FILE"
  enforce_single_sysctl_source "$SYSCTL_FILE"

  # --- 6) Confirma runtime ---
  local final_usecs final_budget
  final_usecs=$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null)
  final_budget=$(sysctl -n net.core.netdev_budget 2>/dev/null)
  if [ "$final_usecs" = "$NETDEV_BUDGET_USECS" ] && [ "$final_budget" = "$NETDEV_BUDGET" ]; then
    ok "Runtime confirma: netdev_budget=${final_budget} netdev_budget_usecs=${final_usecs}"
  else
    nok "Runtime divergente: netdev_budget=${final_budget} netdev_budget_usecs=${final_usecs}"
  fi
}

# ============================================================================
# APPLY: NIC combined queues
# ============================================================================
apply_nic_queues() {
  section "Aplicando NIC combined queues = ${NUM_QUEUES}"
  local current re='^[0-9]+$'
  current=$(ethtool -l "$NIC" 2>/dev/null | awk '/^Combined:/ {if (n==1) print $2; n++}' | head -1)
  if ! [[ "$current" =~ $re ]]; then
    warn "Nao consegui ler 'Combined' atual via ethtool -l (saida='${current}')"
    current=0
  fi
  log "Combined atual: ${current}, alvo: ${NUM_QUEUES}"

  if [ "$current" = "$NUM_QUEUES" ]; then
    ok "Combined queues ja em ${NUM_QUEUES} (idempotente)"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] ethtool -L ${NIC} combined ${NUM_QUEUES}"
    return 0
  fi

  if ! ethtool -L "$NIC" combined "$NUM_QUEUES" 2>/dev/null; then
    die "ethtool -L ${NIC} combined ${NUM_QUEUES} falhou. Sem isso, queues nao batem com o plano e a FASE 2 (XPS) nao pode zerar/aplicar corretamente."
  fi
  sleep "$SLEEP_AFTER_QUEUE_RESIZE"  # driver reorganiza IRQ vectors

  # Validacao tripla:
  # 1) ethtool -l reporta combined == NUM_QUEUES?
  local now
  now=$(ethtool -l "$NIC" 2>/dev/null | awk '/^Combined:/ {if (n==1) print $2; n++}' | head -1)
  if [ "$now" != "$NUM_QUEUES" ]; then
    die "ethtool -L aplicou mas combined=${now} (esperado ${NUM_QUEUES})"
  fi

  # 2) /sys reflete a contagem? (poll com max 5s pois driver pode demorar
  # a popular as entradas em /sys/class/net/<iface>/queues/)
  local sys_tx sys_rx max_wait_sys=5 waited_sys=0
  while [ "$waited_sys" -lt "$max_wait_sys" ]; do
    shopt -s nullglob
    sys_tx=0; sys_rx=0
    local q
    for q in /sys/class/net/"${NIC}"/queues/tx-*; do [ -d "$q" ] && sys_tx=$((sys_tx + 1)); done
    for q in /sys/class/net/"${NIC}"/queues/rx-*; do [ -d "$q" ] && sys_rx=$((sys_rx + 1)); done
    shopt -u nullglob
    if [ "$sys_tx" = "$NUM_QUEUES" ] && [ "$sys_rx" = "$NUM_QUEUES" ]; then
      break
    fi
    sleep 1
    waited_sys=$((waited_sys + 1))
  done
  if [ "$sys_tx" != "$NUM_QUEUES" ] || [ "$sys_rx" != "$NUM_QUEUES" ]; then
    die "/sys/class/net/${NIC}/queues nao reflete combined=${NUM_QUEUES} apos ${max_wait_sys}s (tx=${sys_tx}, rx=${sys_rx})"
  fi

  ok "ethtool -L ${NIC} combined ${NUM_QUEUES} aplicado e validado (sys tx=${sys_tx}, rx=${sys_rx})"
}

# ============================================================================
# APPLY: IRQ pinning + XPS + RPS off + ARFS off
#
# Garantias:
#   - RPS sempre zerado em TODAS as rx-* queues da NIC (rps_cpus = 0)
#   - ARFS sempre zerado em TODAS as rx-* queues (rps_flow_cnt = 0)
#   - ARFS sempre zerado globalmente (net.core.rps_sock_flow_entries = 0)
#   - XPS (sequencia em DOIS passos, sempre):
#       PASSO A) TODAS as tx-* queues sao zeradas (xps_cpus=0)
#       PASSO B) se XPS_MODE != off, as queues do plano recebem mask
#                conforme o modo (irq | smt | irq-smt | spread)
#     Queues fora do plano (extras) permanecem zeradas em qualquer modo.
#   - IRQ smp_affinity aplicado por queue do plano (loop principal)
#
# Lida com caso de tx/rx queues remanescentes alem do plano (raro mas defensivo).
# ============================================================================
apply_irq_xps_rps() {
  section "Aplicando IRQ pinning + XPS + RPS/ARFS off"

  # Pega IRQ vectors da NIC (1 por queue)
  local irqs
  irqs=$(grep -E "${NIC}.*TxRx" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ' | sort -n)
  local n_irqs; n_irqs=$(echo "$irqs" | wc -w)

  if [ "$n_irqs" -ne "$NUM_QUEUES" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      # Em dry-run, ethtool -L nao rodou, entao IRQs atuais nao batem com o plano.
      # Apos --apply, IRQs serao recriados na quantidade planejada.
      log "Atualmente ha ${n_irqs} IRQs TxRx em /proc/interrupts; apos --apply serao ${NUM_QUEUES}"
    else
      warn "Detectei ${n_irqs} IRQs TxRx para ${NIC} mas esperava ${NUM_QUEUES}"
      warn "Aguardando ${SLEEP_IRQ_RETRY}s para driver popular IRQs..."
      sleep "$SLEEP_IRQ_RETRY"
      irqs=$(grep -E "${NIC}.*TxRx" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ' | sort -n)
      n_irqs=$(echo "$irqs" | wc -w)
      if [ "$n_irqs" -ne "$NUM_QUEUES" ]; then
        die "Esperava ${NUM_QUEUES} IRQs TxRx apos ethtool -L, mas tem ${n_irqs}. Verifique: ethtool -l ${NIC}"
      fi
    fi
  fi

  # Conta TODAS as queues fisicas atualmente alocadas na NIC (TX e RX).
  # Apos ethtool -L combined N (em apply_nic_queues), o /sys reflete N queues.
  # Loops de "zera-tudo" iteram este glob para garantir cobertura completa.
  local total_tx_queues=0 total_rx_queues=0
  shopt -s nullglob
  local q
  for q in /sys/class/net/"${NIC}"/queues/tx-*; do
    [ -d "$q" ] && total_tx_queues=$((total_tx_queues + 1))
  done
  for q in /sys/class/net/"${NIC}"/queues/rx-*; do
    [ -d "$q" ] && total_rx_queues=$((total_rx_queues + 1))
  done
  shopt -u nullglob
  log "NIC ${NIC}: queues alocadas tx=${total_tx_queues}, rx=${total_rx_queues} (max HW=${MAX_NIC_QUEUES})"
  log "Plano usa ${NUM_QUEUES} queues; loops abaixo zeram/aplicam em TODAS as alocadas."

  # Sanidade: depois de apply_nic_queues, o total DEVE bater com NUM_QUEUES.
  # Se nao bater, pode haver race ou inconsistencia do driver.
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$total_tx_queues" -ne "$NUM_QUEUES" ] || [ "$total_rx_queues" -ne "$NUM_QUEUES" ]; then
      die "Inconsistencia: plano=${NUM_QUEUES} mas /sys tem tx=${total_tx_queues}, rx=${total_rx_queues}. apply_nic_queues nao aplicou corretamente?"
    fi
  fi

  # Array de IRQ cores na ordem (word splitting intencional sobre NET_IRQ_CPUS)
  local irq_arr=()
  local cpu
  # shellcheck disable=SC2086
  for cpu in $NET_IRQ_CPUS; do irq_arr+=("$cpu"); done

  local q_idx=0 irq
  local irq_ok=0 irq_fail=0 xps_ok=0 xps_fail=0 xps_zero=0
  local rps_zero=0 rps_fail=0 arfs_zero=0

  # ============= DRY-RUN: descreve o que faria e sai =============
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] XPS_MODE = ${XPS_MODE}  $(xps_mode_desc)"
    log "[dry-run] FASE 1: IRQ smp_affinity para ${NUM_QUEUES} queues do plano"
    if [ "$VERBOSE" -eq 1 ]; then
      # Em dry-run, IRQs reais podem nao bater com plano (ethtool -L ainda nao
      # rodou). Itera sobre NUM_QUEUES e mostra IRQ atual quando disponivel,
      # "?" quando nao (driver vai criar apos ethtool -L).
      local _irqs_arr=()
      for irq in $irqs; do _irqs_arr+=("$irq"); done
      printf '%5s %6s %5s %9s   %s\n' "queue" "IRQ" "CPU" "+SMT" "XPS mask (hex)"
      printf '%5s %6s %5s %9s   %s\n' "-----" "------" "-----" "-----" "----------------------------------"
      while [ "$q_idx" -lt "$NUM_QUEUES" ]; do
        local core="${irq_arr[$q_idx]}"
        local sib="${SMT_SIBLING[$core]:-}"
        local xps_mask; xps_mask=$(build_xps_mask_for_queue "$core" "$sib")
        local irq_display="${_irqs_arr[$q_idx]:-?}"
        printf '%5d %6s %5d %9s   %s\n' "$q_idx" "$irq_display" "$core" "${core} ${sib}" "$xps_mask"
        q_idx=$((q_idx + 1))
      done
    fi
    log "[dry-run] FASE 2A: XPS=0 em TODAS as ${total_tx_queues} tx-* queues (passo de zeragem incondicional)"
    if [ "$XPS_MODE" = "off" ]; then
      log "[dry-run] FASE 2B: XPS_MODE=off -- nenhuma queue recebe mask (XPS continua zerado)"
    else
      log "[dry-run] FASE 2B: aplica mask ${XPS_MODE} nas ${NUM_QUEUES} tx-* do plano; demais permanecem zeradas"
    fi
    log "[dry-run] FASE 3: RPS=0 em TODAS as ${total_rx_queues} rx-* queues (rps_cpus=0)"
    log "[dry-run] FASE 4: ARFS=0 em TODAS as ${total_rx_queues} rx-* (rps_flow_cnt=0) + sysctl rps_sock_flow_entries=0"
    return 0
  fi

  # ============= APPLY REAL =============

  # --- FASE 1: IRQ smp_affinity por queue do plano ---
  if [ "$VERBOSE" -eq 1 ]; then
    printf '%5s %6s %5s %9s   %s\n' "queue" "IRQ" "CPU" "+SMT" "XPS mask (hex)"
    printf '%5s %6s %5s %9s   %s\n' "-----" "------" "-----" "-----" "----------------------------------"
  fi

  declare -A plan_xps_mask=()  # q_idx -> mask
  # Pre-calcula mask "spread" uma unica vez (igual para todas as queues).
  local spread_mask=""
  if [ "$XPS_MODE" = "spread" ]; then
    local _all=() _i
    for ((_i=0; _i<TOTAL_THREADS; _i++)); do _all+=("$_i"); done
    spread_mask=$(build_cpumask "${_all[@]}")
  fi
  for irq in $irqs; do
    [ "$q_idx" -ge "$NUM_QUEUES" ] && break
    local core="${irq_arr[$q_idx]}"
    local sib="${SMT_SIBLING[$core]:-}"
    local irq_mask xps_mask

    irq_mask=$(build_cpumask "$core")
    if [ "$XPS_MODE" = "spread" ]; then
      xps_mask="$spread_mask"
    else
      xps_mask=$(build_xps_mask_for_queue "$core" "$sib")
    fi
    plan_xps_mask[$q_idx]="$xps_mask"

    if [ "$VERBOSE" -eq 1 ]; then
      printf '%5d %6d %5d %9s   %s\n' "$q_idx" "$irq" "$core" "${core} ${sib}" "$xps_mask"
    fi

    if printf "%s" "$irq_mask" > "/proc/irq/${irq}/smp_affinity" 2>/dev/null; then
      irq_ok=$((irq_ok + 1))
    else
      irq_fail=$((irq_fail + 1))
    fi
    q_idx=$((q_idx + 1))
  done

  if [ "$q_idx" -ne "$NUM_QUEUES" ]; then
    nok "Processei apenas ${q_idx} de ${NUM_QUEUES} IRQs do plano"
  fi

  # --- FASE 2: XPS - DOIS passos atomicos por queue ---
  # Garantia explicita:
  #   PASSO A (zeragem incondicional): TODA tx-* recebe xps_cpus=0 primeiro.
  #     Isto remove qualquer mask herdado (driver reset, exec anterior, etc).
  #   PASSO B (apply conforme modo):
  #     * XPS_MODE=off    : nao escreve mais nada (todas ficam 0)
  #     * XPS_MODE=irq/smt/irq-smt/spread: tx-* do plano recebe mask;
  #       queues fora do plano permanecem em 0.
  # Iteramos pelo glob das queues fisicas existentes em /sys (uma unica vez,
  # aplicando A+B na mesma iteracao para evitar race).
  shopt -s nullglob
  local txdir tx_idx xps_target
  local xps_total_processed=0 xps_in_plan=0 xps_out_plan=0
  for txdir in /sys/class/net/"${NIC}"/queues/tx-*; do
    [ -d "$txdir" ] || continue
    tx_idx="${txdir##*/tx-}"
    xps_total_processed=$((xps_total_processed + 1))

    # PASSO A: zera incondicionalmente
    if ! printf "0" > "${txdir}/xps_cpus" 2>/dev/null; then
      xps_fail=$((xps_fail + 1))
      continue
    fi

    # PASSO B: decide se aplica mask
    if [ "$XPS_MODE" = "off" ]; then
      # Off: fica zerado, conta como zero
      xps_zero=$((xps_zero + 1))
      continue
    fi

    if ! [[ "$tx_idx" =~ ^[0-9]+$ ]] || [ "$tx_idx" -ge "$NUM_QUEUES" ]; then
      # Queue extra/fora do plano - permanece zerada
      xps_target=0
      xps_out_plan=$((xps_out_plan + 1))
      xps_zero=$((xps_zero + 1))
      continue
    fi

    xps_target="${plan_xps_mask[$tx_idx]:-0}"
    xps_in_plan=$((xps_in_plan + 1))

    if printf "%s" "$xps_target" > "${txdir}/xps_cpus" 2>/dev/null; then
      if [ "$xps_target" = "0" ]; then
        xps_zero=$((xps_zero + 1))
      else
        xps_ok=$((xps_ok + 1))
      fi
    else
      xps_fail=$((xps_fail + 1))
    fi
  done
  shopt -u nullglob

  # Validacao da cobertura: TODAS as queues fisicas devem ter sido tocadas
  if [ "$xps_total_processed" -ne "$total_tx_queues" ]; then
    nok "XPS FASE 2: processei ${xps_total_processed} mas detectei ${total_tx_queues} tx queues (race?)"
  fi
  if [ "$xps_fail" -gt 0 ]; then
    nok "XPS FASE 2: ${xps_fail} writes falharam"
  fi
  # Em modos != off, exige bater plan
  if [ "$XPS_MODE" != "off" ] && [ "$xps_in_plan" -ne "$NUM_QUEUES" ]; then
    nok "XPS FASE 2: ${xps_in_plan} queues do plano processadas (esperado ${NUM_QUEUES})"
  fi

  # --- FASE 3: RPS=0 em TODAS as rx-* queues ---
  # Garantia explicita: itera TODAS as rx queues fisicas; zera rps_cpus
  # em cada uma; conta para validar cobertura completa.
  shopt -s nullglob
  local rxdir
  local rx_total_processed=0
  for rxdir in /sys/class/net/"${NIC}"/queues/rx-*; do
    [ -d "$rxdir" ] || continue
    rx_total_processed=$((rx_total_processed + 1))
    if echo 0 > "${rxdir}/rps_cpus" 2>/dev/null; then
      rps_zero=$((rps_zero + 1))
    else
      rps_fail=$((rps_fail + 1))
    fi
    # FASE 4 per-queue (junto): ARFS rps_flow_cnt
    if echo 0 > "${rxdir}/rps_flow_cnt" 2>/dev/null; then
      arfs_zero=$((arfs_zero + 1))
    fi
  done
  shopt -u nullglob

  # Validacao de cobertura
  if [ "$rx_total_processed" -ne "$total_rx_queues" ]; then
    nok "RPS/ARFS: processei ${rx_total_processed} mas detectei ${total_rx_queues} rx queues"
  fi
  if [ "$rps_zero" -ne "$total_rx_queues" ]; then
    nok "RPS: ${rps_zero}/${total_rx_queues} rx queues zeradas (rps_cpus=0)"
  fi
  if [ "$arfs_zero" -ne "$total_rx_queues" ]; then
    nok "ARFS per-queue: ${arfs_zero}/${total_rx_queues} rx queues zeradas (rps_flow_cnt=0)"
  fi

  # --- FASE 4 (global): ARFS sysctl ---
  sysctl -w net.core.rps_sock_flow_entries=0 >/dev/null 2>&1 || \
    warn "Nao consegui zerar net.core.rps_sock_flow_entries"

  # === Sumario ===
  if [ "$irq_fail" -gt 0 ] || [ "$xps_fail" -gt 0 ] || [ "$rps_fail" -gt 0 ]; then
    nok "Houve falhas: IRQ ${irq_fail} fail / XPS ${xps_fail} fail / RPS ${rps_fail} fail"
  fi
  log "IRQ smp_affinity: ${irq_ok}/${NUM_QUEUES} aplicados"
  if [ "$XPS_MODE" = "off" ]; then
    ok "XPS DESATIVADO (modo=off): TODAS ${xps_zero}/${xps_total_processed} tx queues zeradas"
  else
    ok "XPS modo=${XPS_MODE}: ${xps_ok} tx queues do plano com mask + ${xps_zero} extras zeradas (TOTAL ${xps_total_processed} tx)"
  fi
  ok "RPS off: TODAS ${rps_zero}/${total_rx_queues} rx queues zeradas (rps_cpus=0)"
  ok "ARFS off: TODAS ${arfs_zero}/${total_rx_queues} rx queues zeradas (rps_flow_cnt=0) + sysctl rps_sock_flow_entries=0"
}

# ============================================================================
# Blocos delimitados conhecidos que o nginx pode ter de versoes anteriores
# de scripts (xuione-tune.sh) ou desta versao. Strip remove TODOS.
# ============================================================================
NGINX_KNOWN_BLOCKS_BEGIN=(
  "${NGINX_BLOCK_BEGIN}"
  "# === BEGIN xuione-tune-nginx ==="
)
NGINX_KNOWN_BLOCKS_END=(
  "${NGINX_BLOCK_END}"
  "# === END xuione-tune-nginx ==="
)

# Helper: conta linhas em arquivo matching regex ERE.
# BUG corrigido: `grep -c ... || echo 0` produzia "0\n0" quando grep retorna
# exit 1 (sem match), pois grep ja emite "0" no stdout antes do `|| echo 0`.
# Capturamos em var e tratamos vazio explicitamente.
count_matches() {
  local file="$1" pattern="$2"
  [ -f "$file" ] || { printf '0'; return; }
  local n
  n=$(grep -cE "$pattern" "$file" 2>/dev/null)
  [ -z "$n" ] && n=0
  printf '%s' "$n"
}

# ============================================================================
# APPLY: nginx.conf
# Fluxo determinista:
#   1) Backup do arquivo
#   2) STRIP: remove TODOS os blocos delimitados conhecidos
#             + TODAS as linhas worker_processes/worker_cpu_affinity soltas
#   3) Valida: count(worker_processes) == 0 E count(worker_cpu_affinity) == 0
#   4) INSERT: insere o bloco novo antes de "events {" (ou no fim)
#   5) Valida: count(worker_processes) == 1 E count(worker_cpu_affinity) == 1
#   6) nginx -t (em caso de falha, restaura backup); marca NGINX_CONF_CHANGED=1
# nginx -s reload e centralizado em apply_reloads() ao final.
# ============================================================================
apply_nginx_conf() {
  section "Aplicando nginx worker_processes + worker_cpu_affinity"

  if [ ! -f "$DEFAULT_NGINX_CONF" ]; then
    warn "nginx.conf nao encontrado, pulando"
    return 0
  fi

  # --- 0) Mostrar estado ANTES ---
  local pre_wp pre_wa pre_blocks
  pre_wp=$(count_matches "$DEFAULT_NGINX_CONF" '^[[:space:]]*worker_processes[[:space:]]')
  pre_wa=$(count_matches "$DEFAULT_NGINX_CONF" '^[[:space:]]*worker_cpu_affinity[[:space:]]')
  pre_blocks=$(count_matches "$DEFAULT_NGINX_CONF" '^# === BEGIN (xuione-tune-nginx|xuione-ccd-net) ===')
  log "ANTES: worker_processes=${pre_wp}, worker_cpu_affinity=${pre_wa}, blocos delimitados=${pre_blocks}"

  # --- Constroi conteudo do bloco conforme NGINX_MODE ---
  #   auto    : worker_processes auto;  (sem worker_cpu_affinity)
  #   irq     : N workers, mask 1-bit no IRQ thread
  #   smt     : N workers, mask 1-bit no SMT sibling (classico)
  #   irq-smt : N workers, mask 2-bit {IRQ thread, SMT sibling}
  local new_block
  if [ "$NGINX_MODE" = "auto" ]; then
    new_block=$(cat <<EOF
${NGINX_BLOCK_BEGIN}
# Gerado por ${SCRIPT_NAME} em $(date '+%Y-%m-%d %H:%M:%S')
# Modo --nginx-auto: nginx decide # de workers; sem worker_cpu_affinity.
worker_processes auto;
${NGINX_BLOCK_END}
EOF
)
    vlog "Modo --nginx-auto: worker_processes auto, sem worker_cpu_affinity"
  else
    # Constroi 1 mask por queue usando NGINX_MODE (irq | smt | irq-smt)
    local irq_arr=()
    local cpu
    # shellcheck disable=SC2086
    for cpu in $NET_IRQ_CPUS; do irq_arr+=("$cpu"); done

    local affinity_lines=""
    local mask_count=0
    local i core sib mask
    for ((i=0; i<NUM_QUEUES; i++)); do
      core="${irq_arr[$i]}"
      sib="${SMT_SIBLING[$core]:-}"
      mask=$(build_nginx_worker_mask "$core" "$sib")
      affinity_lines="${affinity_lines}${mask} "
      mask_count=$((mask_count + 1))
    done
    affinity_lines=$(echo "$affinity_lines" | xargs)

    # Assertion: numero de masks == NUM_QUEUES (1 worker por queue)
    if [ "$mask_count" -ne "$NUM_QUEUES" ]; then
      die "Geradas ${mask_count} masks mas NUM_QUEUES=${NUM_QUEUES}. Bug em apply_nginx_conf."
    fi
    local actual_tokens; actual_tokens=$(echo "$affinity_lines" | wc -w)
    if [ "$actual_tokens" -ne "$NUM_QUEUES" ]; then
      die "affinity_lines tem ${actual_tokens} masks mas esperava ${NUM_QUEUES}."
    fi
    vlog "Modo --nginx-${NGINX_MODE}: ${mask_count} masks binarias geradas"

    new_block=$(cat <<EOF
${NGINX_BLOCK_BEGIN}
# Gerado por ${SCRIPT_NAME} em $(date '+%Y-%m-%d %H:%M:%S')
# Modo --nginx-${NGINX_MODE} | CCDs rede: ${NET_CCD_LIST}
worker_processes ${NUM_QUEUES};
worker_cpu_affinity ${affinity_lines};
${NGINX_BLOCK_END}
EOF
)
  fi

  # ============================================================================
  # IDEMPOTENCY CHECK: simula o resultado final e compara com o atual.
  # Se byte-igual (ignorando linha "# Gerado por... <timestamp>"), no-op:
  # nao faz backup, nao mexe no arquivo, nao marca NGINX_CONF_CHANGED.
  # Evita nginx reload desnecessario em re-runs do script.
  # ============================================================================
  local sim_begins sim_ends
  sim_begins=$(printf '%s|' "${NGINX_KNOWN_BLOCKS_BEGIN[@]}" | sed 's/|$//')
  sim_ends=$(printf '%s|' "${NGINX_KNOWN_BLOCKS_END[@]}" | sed 's/|$//')
  local sim_stripped sim_final
  sim_stripped=$(awk -v begins="$sim_begins" -v ends="$sim_ends" '
    BEGIN { n_b = split(begins, b_arr, "|"); n_e = split(ends, e_arr, "|"); in_b = 0 }
    {
      sub(/\r$/, "")
      if (in_b == 0) { for (i=1;i<=n_b;i++) if ($0 == b_arr[i]) { in_b=1; next } }
      if (in_b == 1) { for (i=1;i<=n_e;i++) if ($0 == e_arr[i]) { in_b=0; next } ; next }
      if (/^[[:space:]]*worker_processes[[:space:]]/) next
      if (/^[[:space:]]*worker_cpu_affinity[[:space:]]/) next
      print
    }
  ' "$DEFAULT_NGINX_CONF")
  sim_final=$(awk -v block="$new_block" '
    BEGIN { added = 0 }
    /^events[[:space:]]*\{/ && added == 0 { print block; added = 1 }
    { print }
    END { if (added == 0) print block }
  ' <(printf '%s\n' "$sim_stripped"))

  # Normaliza: descarta linha "# Gerado por ..." (tem timestamp variable)
  local current_norm sim_norm
  current_norm=$(grep -v '^# Gerado por ' "$DEFAULT_NGINX_CONF" 2>/dev/null)
  sim_norm=$(printf '%s\n' "$sim_final" | grep -v '^# Gerado por ')

  if [ "$current_norm" = "$sim_norm" ]; then
    local blk_date
    blk_date=$(grep -m1 '^# Gerado por ' "$DEFAULT_NGINX_CONF" 2>/dev/null | sed 's/.* em //')
    ok "nginx.conf ja idempotente: conteudo byte-igual ao esperado, inalterado desde ${blk_date:-?} (a data no bloco marca a ultima MUDANCA, nao a ultima verificacao); sem reload"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] backup nginx.conf"
    log "[dry-run] STRIP: removeria blocos conhecidos + worker_processes/worker_cpu_affinity soltos"
    case "$NGINX_MODE" in
      auto)
        log "[dry-run] INSERT: bloco --nginx-auto (worker_processes auto; sem worker_cpu_affinity)" ;;
      *)
        log "[dry-run] INSERT: bloco --nginx-${NGINX_MODE} (worker_processes=${NUM_QUEUES}, mask por modo)" ;;
    esac
    log "[dry-run] nginx -t (validacao)"
    # Marca flag em dry-run para que apply_reloads liste o reload no plano
    NGINX_CONF_CHANGED=1
    return 0
  fi

  # --- 1) Backup (declare/assign separados: evita mascarar return de date) ---
  local bak ts
  ts=$(date +%Y%m%d-%H%M%S)
  bak="${DEFAULT_NGINX_CONF}.bak.ccdnet.${ts}"
  cp -a "$DEFAULT_NGINX_CONF" "$bak"
  log "Backup criado: ${bak}"

  # --- 2) STRIP em pass unico (awk) ---
  # Usa `cat tmp > target` para preservar inode/ownership/SELinux ctx.
  local tmp; tmp=$(mktemp_tracked) || die "mktemp falhou"
  local begins ends
  begins=$(printf '%s|' "${NGINX_KNOWN_BLOCKS_BEGIN[@]}" | sed 's/|$//')
  ends=$(printf '%s|' "${NGINX_KNOWN_BLOCKS_END[@]}" | sed 's/|$//')

  awk -v begins="$begins" -v ends="$ends" '
    BEGIN {
      n_begins = split(begins, b_arr, "|")
      n_ends = split(ends, e_arr, "|")
      in_block = 0
    }
    {
      # Lida com CRLF que XUI panel grava
      sub(/\r$/, "")
      # Detecta inicio de bloco
      if (in_block == 0) {
        for (i = 1; i <= n_begins; i++) {
          if ($0 == b_arr[i]) { in_block = 1; next }
        }
      }
      # Detecta fim de bloco
      if (in_block == 1) {
        for (i = 1; i <= n_ends; i++) {
          if ($0 == e_arr[i]) { in_block = 0; next }
        }
        next  # ainda dentro de bloco, pula linha
      }
      # FORA de bloco: remove linhas soltas de workers
      if (/^[[:space:]]*worker_processes[[:space:]]/) next
      if (/^[[:space:]]*worker_cpu_affinity[[:space:]]/) next
      print
    }
  ' "$DEFAULT_NGINX_CONF" > "$tmp"
  cat "$tmp" > "$DEFAULT_NGINX_CONF"

  # --- 3) Validar pos-strip: 0 ocorrencias ---
  local mid_wp mid_wa mid_blocks
  mid_wp=$(count_matches "$DEFAULT_NGINX_CONF" '^[[:space:]]*worker_processes[[:space:]]')
  mid_wa=$(count_matches "$DEFAULT_NGINX_CONF" '^[[:space:]]*worker_cpu_affinity[[:space:]]')
  mid_blocks=$(count_matches "$DEFAULT_NGINX_CONF" '^# === BEGIN (xuione-tune-nginx|xuione-ccd-net) ===')
  vlog "POS-STRIP: worker_processes=${mid_wp}, worker_cpu_affinity=${mid_wa}, blocos=${mid_blocks}"
  if [ "$mid_wp" != "0" ] || [ "$mid_wa" != "0" ] || [ "$mid_blocks" != "0" ]; then
    cp -a "$bak" "$DEFAULT_NGINX_CONF"
    die "STRIP falhou: nginx.conf nao ficou limpo (wp=${mid_wp} wa=${mid_wa} blocos=${mid_blocks}). Arquivo restaurado do backup."
  fi
  ok "STRIP OK: removidas ${pre_wp} worker_processes, ${pre_wa} worker_cpu_affinity, ${pre_blocks} blocos"

  # --- 4) INSERT do bloco novo antes de "events {" ---
  local tmp2; tmp2=$(mktemp_tracked) || die "mktemp falhou"
  awk -v block="$new_block" '
    BEGIN { added = 0 }
    /^events[[:space:]]*\{/ && added == 0 { print block; added = 1 }
    { print }
    END { if (added == 0) print block }
  ' "$DEFAULT_NGINX_CONF" > "$tmp2"
  cat "$tmp2" > "$DEFAULT_NGINX_CONF"

  # --- 5) Validar pos-insert: counts esperados conforme NGINX_MODE ---
  local post_wp post_wa post_blocks expected_wa
  post_wp=$(count_matches "$DEFAULT_NGINX_CONF" '^[[:space:]]*worker_processes[[:space:]]')
  post_wa=$(count_matches "$DEFAULT_NGINX_CONF" '^[[:space:]]*worker_cpu_affinity[[:space:]]')
  post_blocks=$(count_matches "$DEFAULT_NGINX_CONF" "^${NGINX_BLOCK_BEGIN}\$")
  log "DEPOIS: worker_processes=${post_wp}, worker_cpu_affinity=${post_wa}, blocos xuione-ccd-net=${post_blocks}"
  # auto: 0 linhas worker_cpu_affinity; outros modos: 1
  if [ "$NGINX_MODE" = "auto" ]; then expected_wa="0"; else expected_wa="1"; fi
  if [ "$post_wp" != "1" ] || [ "$post_wa" != "$expected_wa" ] || [ "$post_blocks" != "1" ]; then
    cp -a "$bak" "$DEFAULT_NGINX_CONF"
    die "INSERT falhou: counts inesperados (wp=${post_wp} wa=${post_wa} esperado=${expected_wa} blocos=${post_blocks}). Arquivo restaurado."
  fi
  case "$NGINX_MODE" in
    auto)
      ok "INSERT OK: bloco --nginx-auto (worker_processes auto; sem worker_cpu_affinity)" ;;
    *)
      ok "INSERT OK: bloco --nginx-${NGINX_MODE} (worker_processes=${NUM_QUEUES} + 1 worker_cpu_affinity)" ;;
  esac

  # --- 6) Validar sintaxe nginx (reload sera em apply_reloads ao final) ---
  # Exit code do nginx -t (mais robusto que grep em string traduzida).
  local nginx_bin=""
  local found_bin=""
  for nginx_bin in /home/xui/bin/nginx/sbin/nginx /usr/sbin/nginx nginx; do
    if command -v "$nginx_bin" >/dev/null 2>&1 || [ -x "$nginx_bin" ]; then
      found_bin="$nginx_bin"
      break
    fi
  done
  if [ -z "$found_bin" ]; then
    warn "nginx binary nao encontrado para validar; config gravada (sem reload)"
    NGINX_CONF_CHANGED=1
    return 0
  fi
  if LC_ALL=C "$found_bin" -t -c "$DEFAULT_NGINX_CONF" >/dev/null 2>&1; then
    ok "nginx config valida (${found_bin} -t)"
  else
    cp -a "$bak" "$DEFAULT_NGINX_CONF"
    LC_ALL=C "$found_bin" -t -c "$DEFAULT_NGINX_CONF" 2>&1 | tail -3 | sed 's/^/    /'
    die "nginx -t falhou na config nova. Arquivo restaurado do backup."
  fi
  # Marca flag; reload sera feito em apply_reloads() ao final
  NGINX_CONF_CHANGED=1
}

# ============================================================================
# STRIP_UNIT_DROPIN_AFFINITY: varre TODOS os drop-ins e overrides editaveis
# de um unit (em /etc/systemd/system/<unit>.d/ e /run/systemd/system/<unit>.d/)
# e remove qualquer linha CPUAffinity=.
#
# Drop-in que ficar sem conteudo efetivo (so cabecalhos/comentarios/vazias) e
# REMOVIDO. NAO toca em /lib ou /usr/lib (distribution-owned).
#
# Dry-run: lista matches sem alterar nada.
#
# Args: <unit_name>  (ex: "xuione.service" ou "cron.service")
# Sets globais: STRIP_DROPIN_FOUND, STRIP_DROPIN_MODIFIED, STRIP_DROPIN_REMOVED
# ============================================================================
strip_unit_dropin_affinity() {
  local unit="$1"
  STRIP_DROPIN_FOUND=0
  STRIP_DROPIN_MODIFIED=0
  STRIP_DROPIN_REMOVED=0

  local matches=() dir f
  shopt -s nullglob
  for dir in "/etc/systemd/system/${unit}.d" "/run/systemd/system/${unit}.d"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.conf; do
      [ -f "$f" ] || continue
      if grep -qE '^CPUAffinity=' "$f" 2>/dev/null; then
        matches+=("$f")
      fi
    done
  done
  shopt -u nullglob

  STRIP_DROPIN_FOUND=${#matches[@]}
  if [ "$STRIP_DROPIN_FOUND" -eq 0 ]; then
    log "  Drop-ins de ${unit} com CPUAffinity=: nenhum"
    return 0
  fi

  log "  Drop-ins de ${unit} com CPUAffinity= (${STRIP_DROPIN_FOUND}):"
  local m val
  for m in "${matches[@]}"; do
    val=$(grep -E '^CPUAffinity=' "$m" | head -1)
    log "    - ${m}: ${val}"
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    for m in "${matches[@]}"; do
      log "  [dry-run] STRIP: removeria CPUAffinity de ${m}"
    done
    return 0
  fi

  # Apply real: backup + strip + cleanup
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  for m in "${matches[@]}"; do
    cp -a "$m" "${m}.bak.ccdnet.${ts}"
    local tmp; tmp=$(mktemp_tracked) || die "mktemp falhou"
    awk '/^CPUAffinity=/ { next } { print }' "$m" > "$tmp"
    cat "$tmp" > "$m"

    # Pos-strip: arquivo vazio (so headers/comentarios/branco) -> remove
    local meaningful
    meaningful=$(awk '
      /^[[:space:]]*$/ { next }
      /^[[:space:]]*#/ { next }
      /^\[[^]]+\][[:space:]]*$/ { next }
      { c++ }
      END { print (c+0) }
    ' "$m")
    if [ "${meaningful:-0}" -eq 0 ]; then
      rm -f "$m"
      log "  Removido drop-in (sem conteudo apos strip): ${m} (backup .bak.ccdnet.${ts})"
      STRIP_DROPIN_REMOVED=$((STRIP_DROPIN_REMOVED + 1))
    else
      log "  Stripado CPUAffinity de: ${m} (backup .bak.ccdnet.${ts})"
      STRIP_DROPIN_MODIFIED=$((STRIP_DROPIN_MODIFIED + 1))
    fi
  done

  # Sumario
  ok "Drop-ins ${unit}: ${STRIP_DROPIN_MODIFIED} stripados + ${STRIP_DROPIN_REMOVED} removidos = ${STRIP_DROPIN_FOUND} total"
}

# ============================================================================
# APPLY: xuione.service CPUAffinity
# Fluxo determinista:
#   1) Backup
#   2) STRIP: remove TODAS as linhas CPUAffinity= do arquivo principal
#   3) Valida count == 0
#   4) Em --no-affinity: tambem varre TODOS drop-ins de xuione.service.d/
#      e remove CPUAffinity= deles (ou remove o drop-in inteiro se ficar vazio)
#   5) INSERT: 1 linha CPUAffinity= apos [Service] (so se !NO_AFFINITY)
#   6) Valida count == 1 E valor == APP_CPUS_RANGE
#   7) Marca XUI_UNIT_CHANGED=1
# daemon-reload e centralizado em apply_reloads() ao final.
# ============================================================================
apply_xuione_service() {
  if [ "$NO_AFFINITY" -eq 1 ]; then
    section "xuione.service: removendo CPUAffinity (--no-affinity)"
  else
    section "Aplicando CPUAffinity em xuione.service"
  fi

  if [ ! -f "$DEFAULT_XUI_UNIT" ]; then
    warn "xuione.service nao encontrado, pulando"
    return 0
  fi

  local desired="CPUAffinity=${APP_CPUS_RANGE}"

  # --- 0) Mostra estado ANTES ---
  local pre_count
  pre_count=$(count_matches "$DEFAULT_XUI_UNIT" '^CPUAffinity=')
  log "ANTES: CPUAffinity= count=${pre_count}"
  if [ "$VERBOSE" -eq 1 ]; then
    grep -n '^CPUAffinity=' "$DEFAULT_XUI_UNIT" 2>/dev/null | sed 's/^/    /' | head -5
  fi

  # ============================================================================
  # IDEMPOTENCY CHECK: arquivo ja contem EXATAMENTE 1 CPUAffinity= com valor
  # esperado, sem CPUAffinity em drop-ins? -> no-op, NAO marca XUI_UNIT_CHANGED.
  # Evita daemon-reload + warn de "precisa restartar xuione" em re-runs.
  # ============================================================================
  if [ "$NO_AFFINITY" -eq 0 ]; then
    # Modo normal: esperado 1 linha CPUAffinity=${APP_CPUS_RANGE}
    local existing_aff
    existing_aff=$(grep '^CPUAffinity=' "$DEFAULT_XUI_UNIT" 2>/dev/null)
    if [ "$pre_count" = "1" ] && [ "$existing_aff" = "$desired" ]; then
      # Conferir drop-ins tambem (nenhum drop-in com CPUAffinity divergente)
      local dropin_aff_count=0 dir f
      shopt -s nullglob
      for dir in /etc/systemd/system/xuione.service.d /run/systemd/system/xuione.service.d; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*.conf; do
          [ -f "$f" ] || continue
          if grep -qE '^CPUAffinity=' "$f" 2>/dev/null; then
            dropin_aff_count=$((dropin_aff_count + 1))
          fi
        done
      done
      shopt -u nullglob
      if [ "$dropin_aff_count" = "0" ]; then
        ok "xuione.service ja tem ${desired} (idempotente); sem daemon-reload"
        return 0
      fi
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$NO_AFFINITY" -eq 1 ]; then
      log "[dry-run] STRIP-ONLY: removeria todas ${pre_count} linhas CPUAffinity= do arquivo principal"
      log "[dry-run] Tambem varre /etc/systemd/system/xuione.service.d/ e /run/.../"
      strip_unit_dropin_affinity "xuione.service"
    else
      log "[dry-run] STRIP: removeria todas ${pre_count} linhas CPUAffinity= existentes"
      log "[dry-run] INSERT: ${desired} apos [Service]"
    fi
    # Marca flag se ha algo a mudar (remover existentes OU adicionar nova)
    if [ "$pre_count" -gt 0 ] || [ "$NO_AFFINITY" -eq 0 ] || [ "${STRIP_DROPIN_FOUND:-0}" -gt 0 ]; then
      XUI_UNIT_CHANGED=1
    fi
    return 0
  fi

  # Se --no-affinity e nao ha CPUAffinity para remover no arquivo principal,
  # ainda assim varre drop-ins (pode ter CPUAffinity em override .d/*.conf)
  if [ "$NO_AFFINITY" -eq 1 ] && [ "$pre_count" -eq 0 ]; then
    ok "xuione.service principal ja sem CPUAffinity"
    strip_unit_dropin_affinity "xuione.service"
    if [ "${STRIP_DROPIN_FOUND:-0}" -gt 0 ]; then
      XUI_UNIT_CHANGED=1
    fi
    return 0
  fi

  # --- 1) Backup ---
  local bak ts
  ts=$(date +%Y%m%d-%H%M%S)
  bak="${DEFAULT_XUI_UNIT}.bak.ccdnet.${ts}"
  cp -a "$DEFAULT_XUI_UNIT" "$bak"
  log "Backup: ${bak}"

  # --- 2) STRIP: remove TODAS as CPUAffinity= ---
  # Usa `cat tmp > target` (em vez de cp tmp target) para preservar inode,
  # ownership e SELinux context do arquivo systemd original.
  local tmp; tmp=$(mktemp_tracked) || die "mktemp falhou"
  awk '/^CPUAffinity=/ { next } { print }' "$DEFAULT_XUI_UNIT" > "$tmp"
  cat "$tmp" > "$DEFAULT_XUI_UNIT"

  # --- 3) Validar 0 ---
  local mid_count; mid_count=$(count_matches "$DEFAULT_XUI_UNIT" '^CPUAffinity=')
  if [ "$mid_count" != "0" ]; then
    cp -a "$bak" "$DEFAULT_XUI_UNIT"
    die "STRIP falhou: ainda restaram ${mid_count} CPUAffinity= em ${DEFAULT_XUI_UNIT}. Arquivo restaurado."
  fi
  ok "STRIP OK: removidas ${pre_count} linhas CPUAffinity= anteriores"

  # Se --no-affinity, paramos aqui no main file (strip-only) e varremos drop-ins
  if [ "$NO_AFFINITY" -eq 1 ]; then
    ok "xuione.service principal: SEM CPUAffinity (--no-affinity)"
    strip_unit_dropin_affinity "xuione.service"
    XUI_UNIT_CHANGED=1
    return 0
  fi

  # --- 4) INSERT: 1 linha apos [Service] ---
  # Validar que existe secao [Service] antes (sem ela, CPUAffinity= ficaria
  # solto no inicio do arquivo, sem efeito).
  if ! grep -qE '^\[Service\]' "$DEFAULT_XUI_UNIT"; then
    cp -a "$bak" "$DEFAULT_XUI_UNIT"
    die "${DEFAULT_XUI_UNIT} nao tem secao [Service]. Arquivo restaurado."
  fi
  local tmp2; tmp2=$(mktemp_tracked) || die "mktemp falhou"
  awk -v aff="${desired}" '
    BEGIN { added = 0 }
    /^\[Service\]/ && added == 0 { print; print aff; added = 1; next }
    { print }
  ' "$DEFAULT_XUI_UNIT" > "$tmp2"
  cat "$tmp2" > "$DEFAULT_XUI_UNIT"

  # --- 5) Validar 1 + valor correto ---
  local post_count post_value
  post_count=$(count_matches "$DEFAULT_XUI_UNIT" '^CPUAffinity=')
  post_value=$(grep '^CPUAffinity=' "$DEFAULT_XUI_UNIT" | head -1)
  if [ "$post_count" != "1" ] || [ "$post_value" != "$desired" ]; then
    cp -a "$bak" "$DEFAULT_XUI_UNIT"
    die "INSERT falhou: count=${post_count} valor=${post_value}. Esperado: count=1, ${desired}. Arquivo restaurado."
  fi
  ok "INSERT OK: ${post_value} (count=1)"

  # Marca flag; daemon-reload sera feito em apply_reloads() ao final
  XUI_UNIT_CHANGED=1
}

# ============================================================================
# APPLY: cron.service drop-in CPUAffinity
# Fluxo determinista:
#   1) Lista TODOS drop-ins em cron.service.d/ que tenham CPUAffinity=
#   2) STRIP: remove TODOS esses arquivos (systemd consolida CPUAffinity de
#      multiplos drop-ins via OR, entao deixar arquivos antigos contamina o
#      resultado final)
#   3) Valida que nenhum drop-in restante tem CPUAffinity=
#   4) INSERT: cria nosso drop-in unico
#   5) Marca CRON_DROPIN_CHANGED=1
# daemon-reload + restart cron + validacao runtime sao centralizados em
# apply_reloads() ao final.
# ============================================================================
apply_cron_dropin() {
  if [ "$NO_AFFINITY" -eq 1 ]; then
    section "cron.service: removendo drop-ins CPUAffinity (--no-affinity)"
  else
    section "Aplicando CPUAffinity em cron.service drop-in"
  fi

  if ! systemctl list-unit-files cron.service 2>/dev/null | grep -q '^cron\.service'; then
    warn "cron.service ausente, pulando"
    return 0
  fi

  local desired="CPUAffinity=${APP_CPUS_RANGE}"

  # --- 0) Listar TODOS drop-ins existentes com CPUAffinity ---
  # Inclui /etc/systemd/system/cron.service.d/ e /run/systemd/system/cron.service.d/
  local existing_dropins=()
  local dir d
  shopt -s nullglob
  for dir in /etc/systemd/system/cron.service.d /run/systemd/system/cron.service.d; do
    [ -d "$dir" ] || continue
    for d in "$dir"/*.conf; do
      [ -f "$d" ] || continue
      if grep -qE '^CPUAffinity=' "$d" 2>/dev/null; then
        existing_dropins+=("$d")
      fi
    done
  done
  shopt -u nullglob

  log "ANTES: ${#existing_dropins[@]} drop-in(s) com CPUAffinity= encontrados"
  if [ "${#existing_dropins[@]}" -gt 0 ]; then
    local d
    for d in "${existing_dropins[@]}"; do
      local val; val=$(grep -E '^CPUAffinity=' "$d" | head -1)
      log "  - ${d}: ${val}"
    done
  fi

  # --- 0b) Em --no-affinity, tambem verifica /etc/systemd/system/cron.service
  # (arquivo override local; NAO toca /lib/systemd/system) ---
  local cron_main_override="/etc/systemd/system/cron.service"
  local cron_main_count=0
  if [ "$NO_AFFINITY" -eq 1 ] && [ -f "$cron_main_override" ]; then
    cron_main_count=$(count_matches "$cron_main_override" '^CPUAffinity=')
    if [ "$cron_main_count" -gt 0 ]; then
      log "Override principal ${cron_main_override}: ${cron_main_count} linha(s) CPUAffinity= encontrada(s)"
      if [ "$VERBOSE" -eq 1 ]; then
        grep -E '^CPUAffinity=' "$cron_main_override" | sed 's/^/    /' | head -5
      fi
    fi
  fi

  # ============================================================================
  # IDEMPOTENCY CHECK: drop-in nosso ja tem o conteudo exato esperado,
  # nao ha drop-ins divergentes, nem CPUAffinity no override principal?
  # -> no-op, NAO marca CRON_DROPIN_CHANGED.
  # ============================================================================
  if [ "$NO_AFFINITY" -eq 0 ] && [ -f "$DEFAULT_CRON_DROPIN_FILE" ]; then
    # Conteudo esperado do nosso drop-in (ignora linha "# Gerado por <ts>")
    local our_dropin_norm expected_dropin_norm
    our_dropin_norm=$(grep -v '^# Gerado por' "$DEFAULT_CRON_DROPIN_FILE" 2>/dev/null)
    expected_dropin_norm=$(cat <<EOF
# CCDs rede: ${NET_CCD_LIST} | crontabs do XUI rodam nos cores app
[Service]
${desired}
EOF
)
    # Existe DROP-IN DIVERGENTE (que nao seja o nosso)?
    local other_dropin_count=0 d
    for d in "${existing_dropins[@]}"; do
      [ "$d" = "$DEFAULT_CRON_DROPIN_FILE" ] || other_dropin_count=$((other_dropin_count + 1))
    done

    if [ "$our_dropin_norm" = "$expected_dropin_norm" ] && [ "$other_dropin_count" = "0" ]; then
      ok "cron drop-in ${DEFAULT_CRON_DROPIN_FILE} ja correto (idempotente); sem daemon-reload"
      return 0
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "${#existing_dropins[@]}" -gt 0 ]; then
      local d
      for d in "${existing_dropins[@]}"; do
        log "[dry-run] STRIP: removeria ${d}"
      done
    fi
    if [ "$NO_AFFINITY" -eq 0 ]; then
      log "[dry-run] INSERT: criaria ${DEFAULT_CRON_DROPIN_FILE} com [Service]/${desired}"
    else
      log "[dry-run] STRIP-ONLY (--no-affinity): nao criaria drop-in novo"
      if [ "$cron_main_count" -gt 0 ]; then
        log "[dry-run] STRIP: removeria ${cron_main_count} CPUAffinity= de ${cron_main_override}"
      fi
      # Tambem varre /run/systemd/system/cron.service.d (ja feito acima) e
      # confere se nao ha mais nada em outros locais editaveis.
    fi
    # Marca flag se ha algo a mudar (remover existentes OU adicionar novo)
    if [ "${#existing_dropins[@]}" -gt 0 ] || [ "$NO_AFFINITY" -eq 0 ] || [ "$cron_main_count" -gt 0 ]; then
      CRON_DROPIN_CHANGED=1
    fi
    return 0
  fi

  # Se --no-affinity e nao ha drop-ins NEM override principal para remover, no-op
  if [ "$NO_AFFINITY" -eq 1 ] && [ "${#existing_dropins[@]}" -eq 0 ] && [ "$cron_main_count" -eq 0 ]; then
    ok "cron.service ja sem CPUAffinity em qualquer arquivo editavel (idempotente)"
    return 0
  fi

  # --- 1) Backup + STRIP de todos drop-ins com CPUAffinity ---
  # Reusa strip_unit_dropin_affinity(): remove APENAS a linha CPUAffinity=
  # (backup .bak.ccdnet.<ts> ao lado do arquivo, nao em /tmp) e so apaga o
  # drop-in se ele ficar sem conteudo efetivo. Antes o arquivo INTEIRO era
  # removido, destruindo drop-ins de terceiros que misturassem CPUAffinity=
  # com outras diretivas (LimitNOFILE=, Nice=, OOMScoreAdjust=, ...).
  if [ "${#existing_dropins[@]}" -gt 0 ]; then
    strip_unit_dropin_affinity "cron.service"
  fi

  # --- 2) Valida que nao restou drop-in com CPUAffinity ---
  local remaining=0
  shopt -s nullglob
  local f
  for dir in /etc/systemd/system/cron.service.d /run/systemd/system/cron.service.d; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.conf; do
      [ -f "$f" ] || continue
      if grep -qE '^CPUAffinity=' "$f" 2>/dev/null; then
        remaining=$((remaining + 1))
      fi
    done
  done
  shopt -u nullglob
  if [ "$remaining" != "0" ]; then
    die "STRIP falhou: ainda ha ${remaining} drop-in(s) com CPUAffinity= em cron.service.d/"
  fi
  ok "STRIP OK: nenhum drop-in restante com CPUAffinity="

  # Se --no-affinity, tambem stripa override principal (se aplicavel) e para aqui
  if [ "$NO_AFFINITY" -eq 1 ]; then
    if [ "$cron_main_count" -gt 0 ]; then
      local cron_bak cron_ts
      cron_ts=$(date +%Y%m%d-%H%M%S)
      cron_bak="${cron_main_override}.bak.ccdnet.${cron_ts}"
      cp -a "$cron_main_override" "$cron_bak"
      local ctmp; ctmp=$(mktemp_tracked) || die "mktemp falhou"
      awk '/^CPUAffinity=/ { next } { print }' "$cron_main_override" > "$ctmp"
      cat "$ctmp" > "$cron_main_override"
      local cron_after; cron_after=$(count_matches "$cron_main_override" '^CPUAffinity=')
      if [ "$cron_after" != "0" ]; then
        cp -a "$cron_bak" "$cron_main_override"
        die "STRIP falhou em ${cron_main_override}: ainda ha ${cron_after} CPUAffinity=. Arquivo restaurado."
      fi
      ok "Stripado ${cron_main_count} CPUAffinity= de ${cron_main_override} (backup ${cron_bak})"
    fi
    ok "cron.service: SEM CPUAffinity em arquivo principal nem drop-ins (--no-affinity)"
    CRON_DROPIN_CHANGED=1
    return 0
  fi

  # --- 3) INSERT do nosso drop-in ---
  mkdir -p "$DEFAULT_CRON_DROPIN_DIR"
  cat > "$DEFAULT_CRON_DROPIN_FILE" <<EOF
# Gerado por ${SCRIPT_NAME} em $(date '+%Y-%m-%d %H:%M:%S')
# CCDs rede: ${NET_CCD_LIST} | crontabs do XUI rodam nos cores app
[Service]
${desired}
EOF
  chmod 0644 "$DEFAULT_CRON_DROPIN_FILE"
  ok "INSERT OK: ${DEFAULT_CRON_DROPIN_FILE}"

  # Marca flag; daemon-reload + restart cron + validacao runtime sera feito
  # em apply_reloads() ao final (consolidando com xuione.service)
  CRON_DROPIN_CHANGED=1
}

# ============================================================================
# INSTALL_PERSISTENCE: instala unit systemd + path-trigger para re-aplicar
# o tuning no boot e quando NIC operstate muda.
#
# Cria 3 artefatos:
#   1) /usr/local/sbin/xuione-ccd-net.sh  (COPIA canonica, refeita em todo apply;
#      nao e symlink: o repo em /root pode ser apagado e o boot tem que seguir)
#   2) /etc/systemd/system/xuione-ccd-net.service  (oneshot que re-aplica)
#   3) /etc/systemd/system/xuione-ccd-net.path     (gatilho operstate)
#
# ExecStart e construido com as MESMAS flags usadas nesta execucao
# (--nic, --ccds, --xps-* se != off, --no-affinity?) + --apply. SEM
# --no-systemd: cada boot/trigger re-sincroniza a persistencia (idempotente),
# entao fix no fonte chega ao boot sozinho. Nao ha loop: nada e escrito sem
# comparar antes, e o proprio service nunca recebe `start` daqui.
#
# NO_SYSTEMD=1 so pula a INSTALACAO de persistencia nova; se ja existe, e
# sempre sincronizada (persistencia defasada e bug, nao escolha).
# ============================================================================
install_persistence() {
  # --no-systemd = opt-out de INSTALAR persistencia nova. Se ela JA existe, e
  # sempre mantida em sincronia (copia canonica do script, conteudo das units,
  # enabled): persistencia instalada e defasada e bug, nao escolha. Por isso o
  # ExecStart gerado nao carrega mais --no-systemd: rodar sob a propria unit e
  # seguro -- tudo e comparado antes de escrever e o proprio service nunca
  # recebe `start` daqui (apply_reloads so da start no .path).
  if [ "$NO_SYSTEMD" -eq 1 ] && [ ! -f "$PERSIST_UNIT_SERVICE" ] && [ ! -f "$PERSIST_UNIT_PATH" ]; then
    log "Persistencia systemd nao sera instalada (--no-systemd e nao ha units previas)"
    return 0
  fi
  [ "$NO_SYSTEMD" -eq 1 ] && log "--no-systemd: persistencia ja existe -> apenas sincronizando (copia/units/enable)"

  section "Instalando persistencia systemd (re-aplica no boot e em operstate change)"

  # Resolve path absoluto do script atual e valida que e' um arquivo .sh
  # (defesa: 'bash <(curl ...)' ou similar pode dar $0 = '/dev/fd/N' ou 'bash')
  local self
  self=$(readlink -f "$0" 2>/dev/null)
  if [ -z "$self" ] || [ ! -f "$self" ]; then
    die "Nao consegui resolver path do proprio script via readlink -f \$0='${0}'. Persistencia precisa de arquivo real no disco."
  fi
  case "$self" in
    *.sh) ;;
    *)
      die "Script atual ('${self}') nao termina em .sh - persistencia abortada por seguranca. Use --no-systemd para pular."
      ;;
  esac

  # Constroi ExecStart com flags determinadas em runtime
  local ccds_arg
  case "$CCDS_MODE" in
    core)    ccds_arg="core" ;;
    spread)  ccds_arg="spread" ;;
    numeric) ccds_arg="${CCDS_NET}" ;;
    *)       die "CCDS_MODE invalido em install_persistence: '${CCDS_MODE}'" ;;
  esac
  local exec_flags="--nic ${NIC} --ccds ${ccds_arg}"
  case "$XPS_MODE" in
    off)     : ;;  # default, sem flag
    irq)     exec_flags="${exec_flags} --xps-irq" ;;
    smt)     exec_flags="${exec_flags} --xps-smt" ;;
    irq-smt) exec_flags="${exec_flags} --xps-irq-smt" ;;
    spread)  exec_flags="${exec_flags} --xps-spread" ;;
    *)       die "XPS_MODE invalido em install_persistence: '${XPS_MODE}'" ;;
  esac
  [ "$NO_AFFINITY" -eq 1 ] && exec_flags="${exec_flags} --no-affinity"
  case "$NGINX_MODE" in
    smt)     : ;;  # default, sem flag explicita
    auto)    exec_flags="${exec_flags} --nginx-auto" ;;
    irq)     exec_flags="${exec_flags} --nginx-irq" ;;
    irq-smt) exec_flags="${exec_flags} --nginx-irq-smt" ;;
    *)       die "NGINX_MODE invalido em install_persistence: '${NGINX_MODE}'" ;;
  esac
  # --apply executa direto (script nao tem confirmacao interativa). SEM
  # --no-systemd: a unit re-sincroniza a propria persistencia a cada boot /
  # path-trigger (idempotente: no-op quando nada mudou), entao um fix no fonte
  # chega ao boot sozinho -- antes a copia em /usr/local/sbin envelhecia.
  exec_flags="${exec_flags} --apply"

  local exec_start="${PERSIST_BIN_PATH} ${exec_flags}"

  log "Source:      ${self}"
  log "Binario:     ${PERSIST_BIN_PATH}"
  log "Service:     ${PERSIST_UNIT_SERVICE}"
  log "Path-trigger: ${PERSIST_UNIT_PATH}"
  log "ExecStart:   ${exec_start}"

  # ============================================================================
  # IDEMPOTENCY CHECK: binario + unit files + path-trigger ja existem com o
  # conteudo esperado E enabled? -> no-op, NAO marca PERSISTENCE_CHANGED.
  # Evita daemon-reload desnecessario em re-runs do script.
  # ============================================================================
  local bin_ok=0 svc_ok=0 path_ok=0 enabled_ok=0
  # PERSIST_BIN_PATH = COPIA CANONICA real (nao symlink: o repo em /root pode
  # ser apagado e a unit do boot precisa continuar funcionando). A copia e
  # atualizada em TODO apply a partir do script executado: byte a byte igual
  # -> ok; diferente -> refresh atomico com .prev. O drift de 2026-08-20 (2
  # rodadas de fixes nunca chegaram ao boot) so existia porque --no-systemd
  # pulava este passo -- agora persistencia existente e sempre sincronizada.
  if [ "$self" = "$PERSIST_BIN_PATH" ]; then
    bin_ok=1   # rodando a propria copia canonica (ex.: pela unit, ou repo apagado)
  elif [ -f "$PERSIST_BIN_PATH" ] && [ ! -L "$PERSIST_BIN_PATH" ] && cmp -s "$self" "$PERSIST_BIN_PATH" 2>/dev/null; then
    bin_ok=1
  fi
  # Unit service ja contem ExecStart esperado E sem RemainAfterExit legado?
  # (unit antiga com RemainAfterExit=yes fica "active (exited)" para sempre e
  # anula o path-trigger; forcar rewrite aqui torna a correcao auto-aplicavel)
  if [ -f "$PERSIST_UNIT_SERVICE" ] && grep -qxF "ExecStart=${exec_start}" "$PERSIST_UNIT_SERVICE" 2>/dev/null \
  && ! grep -qE '^RemainAfterExit=' "$PERSIST_UNIT_SERVICE" 2>/dev/null; then
    svc_ok=1
  fi
  # Path-trigger aponta para a NIC correta?
  if [ -f "$PERSIST_UNIT_PATH" ] && grep -qxF "PathChanged=/sys/class/net/${NIC}/operstate" "$PERSIST_UNIT_PATH" 2>/dev/null; then
    path_ok=1
  fi
  # Enabled em systemd?
  if systemctl is-enabled xuione-ccd-net.service >/dev/null 2>&1 \
  && systemctl is-enabled xuione-ccd-net.path >/dev/null 2>&1; then
    enabled_ok=1
  fi
  if [ "$bin_ok" = "1" ] && [ "$svc_ok" = "1" ] && [ "$path_ok" = "1" ] && [ "$enabled_ok" = "1" ]; then
    ok "Persistencia systemd ja instalada e correta (idempotente); sem daemon-reload"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$bin_ok" -eq 1 ]; then
      log "[dry-run] ${PERSIST_BIN_PATH} ja identico a ${self} (nada a fazer)"
    else
      [ -L "$PERSIST_BIN_PATH" ] && log "[dry-run] rm symlink ${PERSIST_BIN_PATH} (modelo antigo)"
      [ -f "$PERSIST_BIN_PATH" ] && [ ! -L "$PERSIST_BIN_PATH" ] \
        && log "[dry-run] cp ${PERSIST_BIN_PATH} ${PERSIST_BIN_PATH}.prev (versao anterior)"
      log "[dry-run] install -m 0755 ${self} ${PERSIST_BIN_PATH} (atomico via .tmp + mv)"
    fi
    log "[dry-run] criaria ${PERSIST_UNIT_SERVICE}"
    log "[dry-run] criaria ${PERSIST_UNIT_PATH}"
    log "[dry-run] systemctl enable xuione-ccd-net.{service,path}"
    PERSISTENCE_CHANGED=1
    return 0
  fi

  # 1) Garante dir destino existe + copia binario (se diferente)
  local bin_dir
  bin_dir=$(dirname "$PERSIST_BIN_PATH")
  if ! mkdir -p "$bin_dir"; then
    die "Nao consegui criar diretorio ${bin_dir} para instalar binario."
  fi
  if [ "$bin_ok" -eq 1 ]; then
    ok "${PERSIST_BIN_PATH} ja identico ao script executado"
  else
    # Symlink do modelo intermediario (nunca chegou a producao, mas por via das duvidas)
    [ -L "$PERSIST_BIN_PATH" ] && rm -f "$PERSIST_BIN_PATH"
    # Aviso de downgrade: o script executado e a fonte de verdade (o operador
    # escolheu rodar ESTE), mas se a copia instalada for mais nova, avisa alto.
    if [ -f "$PERSIST_BIN_PATH" ]; then
      local inst_ver
      inst_ver=$(grep -m1 -E '^VERSION=' "$PERSIST_BIN_PATH" 2>/dev/null | cut -d'"' -f2)
      if [ -n "$inst_ver" ] && [ "$inst_ver" != "$VERSION" ] \
         && [ "$(printf '%s\n%s\n' "$inst_ver" "$VERSION" | sort -V | tail -1)" = "$inst_ver" ]; then
        warn "DOWNGRADE: copia instalada e v${inst_ver}, este script e v${VERSION} -- instalando mesmo assim (.prev guarda a anterior)"
      fi
      cp -af "$PERSIST_BIN_PATH" "${PERSIST_BIN_PATH}.prev" 2>/dev/null \
        || warn "nao consegui guardar ${PERSIST_BIN_PATH}.prev"
    fi
    # Escrita atomica: um path-trigger no meio da copia nunca ve script truncado.
    if install -m 0755 "$self" "${PERSIST_BIN_PATH}.tmp" && mv -f "${PERSIST_BIN_PATH}.tmp" "$PERSIST_BIN_PATH"; then
      ok "Copia canonica atualizada: ${self} -> ${PERSIST_BIN_PATH} (v${VERSION}; anterior em .prev)"
    else
      rm -f "${PERSIST_BIN_PATH}.tmp"
      die "Falha ao instalar ${self} -> ${PERSIST_BIN_PATH} (disco cheio? permissoes?)"
    fi
  fi

  # 2) Cria xuione-ccd-net.service
  cat > "$PERSIST_UNIT_SERVICE" <<EOF
[Unit]
Description=XuiOne CCD-aware NIC + nginx tuning (re-applies on boot / NIC operstate)
Documentation=https://github.com/local/xuione-ccd-net
After=network-online.target
Wants=network-online.target
ConditionPathExists=/sys/class/net/${NIC}
# Freio: se a NIC entrar em flap, o .path pode disparar em rajada.
# (systemctl reset-failed xuione-ccd-net.service libera apos o limite)
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
# SEM RemainAfterExit: com ele a unit ficaria "active (exited)" para sempre e
# o start job vindo do xuione-ccd-net.path viraria no-op -- ou seja, o tuning
# NUNCA seria re-aplicado apos flap/reset da NIC (IRQ affinity, XPS/RPS,
# gro_flush_timeout e napi_defer_hard_irqs sao per-netdev e nao sobrevivem).
Type=oneshot
ExecStart=${exec_start}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$PERSIST_UNIT_SERVICE"
  ok "Criado ${PERSIST_UNIT_SERVICE}"

  # 3) Cria xuione-ccd-net.path
  cat > "$PERSIST_UNIT_PATH" <<EOF
[Unit]
Description=Re-apply XuiOne CCD-aware tuning when NIC operstate changes

[Path]
PathChanged=/sys/class/net/${NIC}/operstate
Unit=xuione-ccd-net.service

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$PERSIST_UNIT_PATH"
  ok "Criado ${PERSIST_UNIT_PATH}"

  # 4) Enable (cria symlinks - nao precisa daemon-reload antes;
  #    daemon-reload + start path serao em apply_reloads)
  if systemctl enable xuione-ccd-net.service >/dev/null 2>&1; then
    ok "enable xuione-ccd-net.service"
  else
    nok "Falhou: systemctl enable xuione-ccd-net.service"
  fi
  if systemctl enable xuione-ccd-net.path >/dev/null 2>&1; then
    ok "enable xuione-ccd-net.path"
  else
    nok "Falhou: systemctl enable xuione-ccd-net.path"
  fi

  PERSISTENCE_CHANGED=1
}

# ============================================================================
# APPLY_RELOADS: consolida reloads/restarts apos TODAS as mudancas de config.
#
# Justificativa: cada apply_* (xuione, cron, nginx) marca uma flag em vez de
# fazer seu proprio reload. Aqui:
#   - 1 unico systemctl daemon-reload se xuione e/ou cron mudaram
#   - 1 restart cron + validacao runtime (se cron mudou)
#   - 1 nginx -s reload (se nginx.conf mudou)
# Vantagem: evita daemon-reload duplicado, fluxo claro, log unificado.
# ============================================================================
apply_reloads() {
  if [ "$XUI_UNIT_CHANGED" -eq 0 ] && \
     [ "$CRON_DROPIN_CHANGED" -eq 0 ] && \
     [ "$NGINX_CONF_CHANGED" -eq 0 ] && \
     [ "$PERSISTENCE_CHANGED" -eq 0 ]; then
    log "Sem mudancas em xuione/cron/nginx/persistencia -> nenhum reload necessario"
    return 0
  fi

  section "Recarregando services apos mudancas"

  if [ "$DRY_RUN" -eq 1 ]; then
    # Mesma ordem do apply real: daemon-reload -> path-trigger -> xuione -> cron -> nginx
    if [ "$XUI_UNIT_CHANGED" -eq 1 ] || [ "$CRON_DROPIN_CHANGED" -eq 1 ] || [ "$PERSISTENCE_CHANGED" -ne 0 ]; then
      local what=""
      [ "$XUI_UNIT_CHANGED" -eq 1 ] && what="${what} xuione.service"
      [ "$CRON_DROPIN_CHANGED" -eq 1 ] && what="${what} cron.service"
      [ "$PERSISTENCE_CHANGED" -eq 1 ] && what="${what} xuione-ccd-net.{service,path}(INSTALL)"
      [ "$PERSISTENCE_CHANGED" -eq 2 ] && what="${what} xuione-ccd-net.{service,path}(REMOVE)"
      log "[dry-run] systemctl daemon-reload  (re-leria:${what})"
    fi
    if [ "$PERSISTENCE_CHANGED" -eq 1 ]; then
      log "[dry-run] systemctl start xuione-ccd-net.path (gatilho ativo)"
    elif [ "$PERSISTENCE_CHANGED" -eq 2 ]; then
      log "[dry-run] persistencia removida; sem start (apenas daemon-reload)"
    fi
    if [ "$XUI_UNIT_CHANGED" -eq 1 ]; then
      if [ "$RESTART_SERVICES" -eq 1 ]; then
        log "[dry-run] systemctl restart xuione  (--restart com CPUAffinity alterada)"
      else
        warn "xuione.service NAO sera reiniciado (CPUAffinity mudou: passe --restart para reiniciar agora)"
      fi
    fi
    if [ "$CRON_DROPIN_CHANGED" -eq 1 ]; then
      if [ "$RESTART_SERVICES" -eq 1 ]; then
        log "[dry-run] systemctl restart cron + validacao runtime  (--restart com drop-in alterado)"
      else
        warn "cron.service NAO sera reiniciado (drop-in mudou: passe --restart para reiniciar agora)"
      fi
    fi
    [ "$NGINX_CONF_CHANGED" -eq 1 ] && log "[dry-run] nginx -s reload (zero-downtime)"
    return 0
  fi

  # --- 1) daemon-reload UNICO (se qualquer unit mudou) ---
  if [ "$XUI_UNIT_CHANGED" -eq 1 ] || [ "$CRON_DROPIN_CHANGED" -eq 1 ] || [ "$PERSISTENCE_CHANGED" -ne 0 ]; then
    if systemctl daemon-reload; then
      local changed=""
      [ "$XUI_UNIT_CHANGED" -eq 1 ] && changed="${changed} xuione.service"
      [ "$CRON_DROPIN_CHANGED" -eq 1 ] && changed="${changed} cron.service"
      [ "$PERSISTENCE_CHANGED" -eq 1 ] && changed="${changed} xuione-ccd-net.{service,path}(INSTALLED)"
      [ "$PERSISTENCE_CHANGED" -eq 2 ] && changed="${changed} xuione-ccd-net.{service,path}(REMOVED)"
      ok "systemctl daemon-reload aplicado (re-leu:${changed})"
    else
      nok "systemctl daemon-reload falhou"
    fi
  fi

  # --- 1b) Start path-trigger da persistencia (apenas em INSTALL=1) ---
  if [ "$PERSISTENCE_CHANGED" -eq 1 ]; then
    if systemctl start xuione-ccd-net.path 2>/dev/null; then
      ok "xuione-ccd-net.path ativo (re-aplica em operstate change)"
    else
      warn "Falha ao iniciar xuione-ccd-net.path"
    fi
  fi

  # --- 2) xuione.service: restart APENAS se CPUAffinity mudou E --restart foi passado ---
  # Reiniciar mata PHP-FPM masters e ffmpegs em pleno trafego, entao por default
  # so informamos. Operador opta-in com --restart quando esta em janela controlada.
  if [ "$XUI_UNIT_CHANGED" -eq 1 ]; then
    if [ "$RESTART_SERVICES" -eq 1 ]; then
      log "Reiniciando xuione.service (--restart + CPUAffinity alterada)"
      if systemctl restart xuione.service 2>/dev/null; then
        ok "systemctl restart xuione aplicado"
      else
        nok "systemctl restart xuione falhou (verifique: systemctl status xuione)"
      fi
    else
      warn "xuione.service NAO foi reiniciado (CPUAffinity mudou)."
      warn "Para que o pinning surta efeito, rode em janela controlada:"
      warn "    sudo systemctl restart xuione"
      warn "Ou re-rode este script com --restart."
    fi
  fi

  # --- 3) cron.service: restart APENAS se drop-in mudou E --restart foi passado ---
  # Sem restart, a config nova esta no disco mas o cron rodando ainda tem
  # CPUAffinity antiga. Usuario controla a janela via --restart.
  if [ "$CRON_DROPIN_CHANGED" -eq 1 ]; then
    if [ "$RESTART_SERVICES" -eq 1 ]; then
      log "Reiniciando cron.service (--restart + drop-in alterado)"
      if systemctl restart cron 2>/dev/null; then
        ok "systemctl restart cron aplicado"
      else
        nok "systemctl restart cron falhou"
      fi

      # Valida runtime: PID cron tem Cpus_allowed_list correto?
      # Poll com timeout (cron pode demorar ~1s para reaparecer).
      local crond="" actual="" max_wait=10 waited=0
      while [ "$waited" -lt "$max_wait" ]; do
        crond=$(pgrep -of cron 2>/dev/null | head -1)
        if [ -n "$crond" ] && [ -f "/proc/${crond}/status" ]; then
          break
        fi
        sleep 1
        waited=$((waited + 1))
      done

      if [ -z "$crond" ]; then
        warn "Nao consegui pegar PID do cron apos ${max_wait}s para validar"
      else
        actual=$(awk '/^Cpus_allowed_list:/{print $2}' "/proc/${crond}/status" 2>/dev/null)
        if [ -z "$APP_CPUS_RANGE" ]; then
          # Caso revert (sem plano): apenas reporta o valor atual
          ok "cron PID=${crond} Cpus_allowed_list = ${actual} (revert: sem alvo a validar)"
        elif [ "$actual" = "$APP_CPUS_RANGE" ]; then
          ok "cron PID=${crond} Cpus_allowed_list = ${actual} (== plano)"
        else
          nok "cron PID=${crond} Cpus_allowed_list = ${actual} (esperado ${APP_CPUS_RANGE})"
        fi
      fi
    else
      warn "cron.service NAO foi reiniciado (drop-in mudou)."
      warn "Para que o pinning do cron surta efeito, rode em janela controlada:"
      warn "    sudo systemctl restart cron"
      warn "Ou re-rode este script com --restart."
    fi
  fi

  # --- 4) nginx -s reload (zero-downtime) ---
  if [ "$NGINX_CONF_CHANGED" -eq 1 ]; then
    local nginx_bin=""
    for nginx_bin in /home/xui/bin/nginx/sbin/nginx /usr/sbin/nginx nginx; do
      if command -v "$nginx_bin" >/dev/null 2>&1 || [ -x "$nginx_bin" ]; then
        break
      fi
      nginx_bin=""
    done
    # nginx -t ANTES do reload. O -p e necessario no nginx do XUI:
    # include/mime.types/logs sao resolvidos relativos ao prefix, e sem ele o
    # teste pode falhar por caminho (falso negativo).
    local -a nginx_test=("$nginx_bin" -t -c "$DEFAULT_NGINX_CONF")
    if [ "$nginx_bin" = "/home/xui/bin/nginx/sbin/nginx" ]; then
      nginx_test=("$nginx_bin" -t -p /home/xui/bin/nginx -c "$DEFAULT_NGINX_CONF")
    fi
    if [ -z "$nginx_bin" ]; then
      warn "nginx binary nao encontrado; reload manual necessario"
    elif ! LC_ALL=C "${nginx_test[@]}" >/dev/null 2>&1; then
      nok "nginx -t falhou; NAO recarregando (revise ${DEFAULT_NGINX_CONF})"
    elif LC_ALL=C "$nginx_bin" -s reload -c "$DEFAULT_NGINX_CONF" 2>/dev/null; then
      ok "nginx -s reload aplicado (zero-downtime)"
    elif pkill -HUP -x nginx 2>/dev/null; then
      ok "nginx HUP enviado (reload via signal)"
    else
      warn "Nao consegui reload do nginx; faca manualmente: ${nginx_bin} -s reload"
    fi
  fi
}

# ============================================================================
# VALIDATION
# ============================================================================
validate_all() {
  section "Validacao final"

  local fails=0

  # RDMA off
  if lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$RDMA_MODULE"; then
    nok "RDMA (${RDMA_MODULE}) ainda carregado"
    fails=$((fails + 1))
  else
    ok "RDMA (${RDMA_MODULE}) descarregado"
  fi
  if [ -f "$RDMA_BLACKLIST_FILE" ]; then
    ok "blacklist persistente em ${RDMA_BLACKLIST_FILE}"
  else
    nok "blacklist ausente"
    fails=$((fails + 1))
  fi

  # Ring size max
  local max_rx cur_rx
  max_rx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^RX:/ {n++; if (n==1) print $2;}' | head -1)
  cur_rx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^RX:/ {n++; if (n==2) print $2;}' | head -1)
  if [ "$cur_rx" = "$max_rx" ] && [ -n "$max_rx" ]; then
    ok "Ring RX/TX no maximo (${max_rx})"
  else
    nok "Ring RX=${cur_rx} (esperado ${max_rx})"
    fails=$((fails + 1))
  fi

  # Coalesce adaptive
  local arx atx
  arx=$(ethtool -c "$NIC" 2>/dev/null | awk '/^Adaptive RX:/ {print $3}')
  atx=$(ethtool -c "$NIC" 2>/dev/null | awk '/^Adaptive RX:/ {print $5}')
  if [ "$arx" = "on" ] && [ "$atx" = "on" ]; then
    ok "Coalesce adaptive RX=on TX=on"
  else
    nok "Coalesce: RX=${arx:-?} TX=${atx:-?}"
    fails=$((fails + 1))
  fi

  # NIC combined queues
  local actual_q; actual_q=$(ethtool -l "$NIC" 2>/dev/null | awk '/^Combined:/ {if (n==1) print $2; n++}' | head -1)
  if [ "$actual_q" = "$NUM_QUEUES" ]; then
    ok "NIC combined queues = ${actual_q}"
  else
    nok "NIC combined queues = ${actual_q} (esperado ${NUM_QUEUES})"
    fails=$((fails + 1))
  fi

  # ---- IRQ pinning: valida TODAS as queues do plano ----
  # Mapa queue -> IRQ pelo NOME do vetor (<nic>-TxRx-N), fonte autoritativa
  # (imune a ordem numerica dos IRQs).
  local -A irq_of_q=()
  local _qn _irqn
  while read -r _qn _irqn; do
    [ -n "$_qn" ] && irq_of_q[$_qn]="$_irqn"
  done < <(awk -F: -v nic="$NIC" '$0 ~ ("-" nic "-TxRx-[0-9]+$") {
      irq = $1; gsub(/[ \t]/, "", irq)
      qn = $0; sub(/.*-TxRx-/, "", qn)
      print qn, irq
    }' /proc/interrupts)

  local irq_bad=0 irq_good=0 q_i irq_num irq_cpu irq_aff irq_eff
  for ((q_i = 0; q_i < NUM_QUEUES; q_i++)); do
    irq_num="${irq_of_q[$q_i]:-}"
    # shellcheck disable=SC2086
    irq_cpu=$(echo $NET_IRQ_CPUS | awk -v i=$((q_i + 1)) '{print $i}')
    irq_aff=$(cat "/proc/irq/${irq_num}/smp_affinity_list" 2>/dev/null || true)
    if [ -n "$irq_num" ] && [ "$irq_aff" = "$irq_cpu" ]; then
      irq_good=$((irq_good + 1))
    else
      irq_bad=$((irq_bad + 1))
      # effective_affinity_list e informativo: em vetor managed pode divergir
      # do smp_affinity_list sem que o pinning esteja errado.
      irq_eff=$(cat "/proc/irq/${irq_num}/effective_affinity_list" 2>/dev/null || true)
      vlog "IRQ ${irq_num:-?} (q${q_i}) affinity=${irq_aff:-?} efetiva=${irq_eff:-?} esperado=${irq_cpu}"
    fi
  done
  if [ "$irq_bad" -eq 0 ]; then
    ok "IRQ pinning: ${irq_good}/${NUM_QUEUES} queues no core planejado"
  else
    nok "IRQ pinning: ${irq_bad}/${NUM_QUEUES} queues fora do plano (use -v para detalhe)"
    fails=$((fails + 1))
  fi

  # ---- irqbalance: anula o pinning validado logo acima ----
  if systemctl is-active --quiet irqbalance 2>/dev/null; then
    nok "irqbalance ATIVO -- o pinning validado acima sera desfeito"
    fails=$((fails + 1))
  else
    ok "irqbalance inativo"
  fi

  # ---- sysctl.conf: travado (chattr +i), lido no boot, sem conflito em sysctl.d ----
  if [ -f "$SYSCTL_FILE" ]; then
    if lsattr "$SYSCTL_FILE" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
      ok "${SYSCTL_FILE} travado (chattr +i)"
    else
      nok "${SYSCTL_FILE} SEM chattr +i (apply re-trava)"
      fails=$((fails + 1))
    fi
    if [ -L "$SYSCTL_BOOT_LINK" ] && [ "$(readlink -f "$SYSCTL_BOOT_LINK" 2>/dev/null)" = "$SYSCTL_FILE" ]; then
      ok "boot: ${SYSCTL_BOOT_LINK} -> ${SYSCTL_FILE} (systemd-sysctl aplica no boot)"
    else
      nok "boot: ${SYSCTL_BOOT_LINK} ausente/errado -- ${SYSCTL_FILE} NAO e aplicado no boot (apply cria)"
      fails=$((fails + 1))
    fi
    # Fonte unica: conflito em /etc/sysctl.d = FAIL (apply desativa o arquivo);
    # /usr/lib e /run (distro) sao sobrescritos pela ordem -- informativo.
    local cf_k cf_base cf_theirs cf_ours cf_dir cf_n=0
    while IFS='|' read -r cf_k cf_base cf_theirs cf_ours _ cf_dir; do
      if [ "$cf_dir" = "/etc/sysctl.d" ]; then
        cf_n=$((cf_n + 1))
        nok "fonte unica violada: ${cf_k}=${cf_theirs} em ${cf_dir}/${cf_base} vs ${cf_ours} em sysctl.conf (apply desativa)"
        fails=$((fails + 1))
      else
        ok "sysctl: ${cf_k}=${cf_theirs} em ${cf_dir}/${cf_base} (distro) sobrescrito por sysctl.conf (${cf_ours})"
      fi
    done < <(sysctl_d_conflicts "$SYSCTL_FILE")
    [ "$cf_n" -eq 0 ] && ok "fonte unica: nenhum conflito em /etc/sysctl.d com ${SYSCTL_FILE}"
  fi

  # ---- XPS: valida TODAS as tx-* queues ----
  # Considera "zerado" se valor for "0" OU all-zeros hex (formato cpumask)
  local xps_with_mask=0 xps_zeroed=0
  shopt -s nullglob
  local q val
  for q in /sys/class/net/"${NIC}"/queues/tx-*/xps_cpus; do
    val=$(cat "$q" 2>/dev/null)
    if [ "$val" = "0" ] || [[ "$val" =~ ^0+(,0+)*$ ]]; then
      xps_zeroed=$((xps_zeroed + 1))
    else
      xps_with_mask=$((xps_with_mask + 1))
    fi
  done
  shopt -u nullglob

  if [ "$XPS_MODE" = "off" ]; then
    # Esperado: TODAS zeradas
    if [ "$xps_with_mask" -eq 0 ]; then
      ok "XPS: ${xps_zeroed} tx queues zeradas (modo=off OK)"
    else
      nok "XPS: ${xps_with_mask} tx queues com mask quando esperava TODAS zeradas (modo=off)"
      fails=$((fails + 1))
    fi
  else
    # Esperado: NUM_QUEUES com mask + restante (se houver) zeradas
    if [ "$xps_with_mask" -eq "$NUM_QUEUES" ]; then
      ok "XPS modo=${XPS_MODE}: ${xps_with_mask} tx queues com mask (plano), ${xps_zeroed} zeradas (fora plano)"
    else
      nok "XPS modo=${XPS_MODE}: ${xps_with_mask} com mask, esperava ${NUM_QUEUES}"
      fails=$((fails + 1))
    fi
  fi

  # ---- RPS: valida TODAS as rx-* zeradas ----
  local rps_zeroed=0 rps_with_mask=0
  shopt -s nullglob
  for q in /sys/class/net/"${NIC}"/queues/rx-*/rps_cpus; do
    val=$(cat "$q" 2>/dev/null)
    if [ "$val" = "0" ] || [[ "$val" =~ ^0+(,0+)*$ ]]; then
      rps_zeroed=$((rps_zeroed + 1))
    else
      rps_with_mask=$((rps_with_mask + 1))
    fi
  done
  shopt -u nullglob
  if [ "$rps_with_mask" -eq 0 ]; then
    ok "RPS: TODAS ${rps_zeroed} rx queues zeradas (rps_cpus=0)"
  else
    nok "RPS: ${rps_with_mask} rx queues com mask diferente de zero"
    fails=$((fails + 1))
  fi

  # ---- ARFS per-queue: rps_flow_cnt=0 em TODAS as rx-* ----
  local arfs_zeroed=0 arfs_with=0
  shopt -s nullglob
  for q in /sys/class/net/"${NIC}"/queues/rx-*/rps_flow_cnt; do
    val=$(cat "$q" 2>/dev/null)
    if [ "$val" = "0" ]; then
      arfs_zeroed=$((arfs_zeroed + 1))
    else
      arfs_with=$((arfs_with + 1))
    fi
  done
  shopt -u nullglob
  if [ "$arfs_with" -eq 0 ]; then
    ok "ARFS per-queue: TODAS ${arfs_zeroed} rx queues zeradas (rps_flow_cnt=0)"
  else
    nok "ARFS per-queue: ${arfs_with} rx queues com rps_flow_cnt != 0"
    fails=$((fails + 1))
  fi

  # ---- ARFS global: net.core.rps_sock_flow_entries ----
  local arfs_global
  arfs_global=$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)
  if [ "${arfs_global:-0}" -eq 0 ]; then
    ok "ARFS global: rps_sock_flow_entries=0"
  else
    nok "ARFS global: rps_sock_flow_entries=${arfs_global} (esperado 0)"
    fails=$((fails + 1))
  fi

  # nginx: bloco presente + worker_processes correto conforme NGINX_MODE
  if [ -f "$DEFAULT_NGINX_CONF" ]; then
    if grep -q "^${NGINX_BLOCK_BEGIN}\$" "$DEFAULT_NGINX_CONF" 2>/dev/null; then
      local wp_value wa_count wa_count_total
      wp_value=$(awk '/^worker_processes/ {gsub(";","",$2); print $2; exit}' "$DEFAULT_NGINX_CONF")
      # Conta linhas worker_cpu_affinity (0 ou 1)
      wa_count_total=$(count_matches "$DEFAULT_NGINX_CONF" '^[[:space:]]*worker_cpu_affinity[[:space:]]')
      # Conta tokens da linha worker_cpu_affinity (se existir)
      wa_count=$(awk '/^worker_cpu_affinity/ {gsub(";",""); print NF-1; exit}' "$DEFAULT_NGINX_CONF")
      [ -z "$wa_count" ] && wa_count=0

      case "$NGINX_MODE" in
        auto)
          # Esperado: worker_processes auto; SEM linha worker_cpu_affinity
          if [ "$wp_value" = "auto" ]; then
            ok "nginx.conf worker_processes=auto (--nginx-auto OK)"
          else
            nok "nginx.conf worker_processes=${wp_value} mas --nginx-auto esperava 'auto'"
            fails=$((fails + 1))
          fi
          if [ "$wa_count_total" = "0" ]; then
            ok "nginx.conf SEM worker_cpu_affinity (--nginx-auto OK)"
          else
            nok "nginx.conf tem ${wa_count_total} linha(s) worker_cpu_affinity (--nginx-auto esperava 0)"
            fails=$((fails + 1))
          fi
          ;;
        irq|smt|irq-smt)
          # Esperado: worker_processes=NUM_QUEUES + 1 linha worker_cpu_affinity com NUM_QUEUES masks
          if [ "$wp_value" = "$NUM_QUEUES" ]; then
            ok "nginx.conf worker_processes=${wp_value} (= ${NUM_QUEUES} workers do plano)"
          else
            nok "nginx.conf worker_processes=${wp_value} mas esperava ${NUM_QUEUES}"
            fails=$((fails + 1))
          fi
          if [ "$wa_count" = "$NUM_QUEUES" ]; then
            ok "nginx.conf worker_cpu_affinity tem ${wa_count} masks (--nginx-${NGINX_MODE})"
          else
            nok "nginx.conf worker_cpu_affinity tem ${wa_count} masks mas esperava ${NUM_QUEUES}"
            fails=$((fails + 1))
          fi
          ;;
        *)
          nok "validate_all: NGINX_MODE invalido: '${NGINX_MODE}'"
          fails=$((fails + 1))
          ;;
      esac
      # Workers nginx em execucao (pode demorar 1-2s apos reload)
      local active_workers; active_workers=$(pgrep -c -x nginx 2>/dev/null); [ -z "$active_workers" ] && active_workers=0
      vlog "Workers nginx ativos (master+workers): ${active_workers}"
    else
      nok "nginx.conf sem bloco ccd-net"
      fails=$((fails + 1))
    fi
  fi

  # xuione.service
  if [ -f "$DEFAULT_XUI_UNIT" ]; then
    local aff; aff=$(grep '^CPUAffinity=' "$DEFAULT_XUI_UNIT" | head -1)
    if [ "$NO_AFFINITY" -eq 1 ]; then
      # Esperado: SEM CPUAffinity= no arquivo principal nem em drop-ins
      if [ -z "$aff" ]; then
        ok "xuione.service: SEM CPUAffinity (--no-affinity OK)"
      else
        nok "xuione.service ainda tem CPUAffinity (--no-affinity): ${aff}"
        fails=$((fails + 1))
      fi
      # Tambem checa drop-ins (helper apenas LISTA, nao strippa neste contexto)
      local dropin_with=0 dir f
      shopt -s nullglob
      for dir in /etc/systemd/system/xuione.service.d /run/systemd/system/xuione.service.d; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*.conf; do
          [ -f "$f" ] || continue
          if grep -qE '^CPUAffinity=' "$f" 2>/dev/null; then
            dropin_with=$((dropin_with + 1))
          fi
        done
      done
      shopt -u nullglob
      if [ "$dropin_with" -eq 0 ]; then
        ok "xuione.service drop-ins: SEM CPUAffinity"
      else
        nok "xuione.service: ${dropin_with} drop-in(s) ainda com CPUAffinity"
        fails=$((fails + 1))
      fi
    else
      # Esperado: CPUAffinity= bate com APP_CPUS_RANGE
      if [ "$aff" = "CPUAffinity=${APP_CPUS_RANGE}" ]; then
        ok "xuione.service: ${aff}"
      else
        nok "xuione.service: ${aff} (esperado CPUAffinity=${APP_CPUS_RANGE})"
        fails=$((fails + 1))
      fi
    fi
  fi

  # cron drop-in
  if [ "$NO_AFFINITY" -eq 1 ]; then
    # Esperado: nenhum drop-in com CPUAffinity em cron.service.d/
    local cron_dropin_with=0 dir f
    shopt -s nullglob
    for dir in /etc/systemd/system/cron.service.d /run/systemd/system/cron.service.d; do
      [ -d "$dir" ] || continue
      for f in "$dir"/*.conf; do
        [ -f "$f" ] || continue
        if grep -qE '^CPUAffinity=' "$f" 2>/dev/null; then
          cron_dropin_with=$((cron_dropin_with + 1))
        fi
      done
    done
    shopt -u nullglob
    if [ "$cron_dropin_with" -eq 0 ]; then
      ok "cron drop-ins: SEM CPUAffinity (--no-affinity OK)"
    else
      nok "cron drop-ins: ${cron_dropin_with} arquivo(s) ainda com CPUAffinity"
      fails=$((fails + 1))
    fi
  elif [ -f "$DEFAULT_CRON_DROPIN_FILE" ]; then
    if grep -qx "CPUAffinity=${APP_CPUS_RANGE}" "$DEFAULT_CRON_DROPIN_FILE" 2>/dev/null; then
      ok "cron drop-in: CPUAffinity=${APP_CPUS_RANGE}"
    else
      nok "cron drop-in com mask divergente"
      fails=$((fails + 1))
    fi
  else
    nok "cron drop-in nao existe (${DEFAULT_CRON_DROPIN_FILE})"
    fails=$((fails + 1))
  fi

  echo
  if [ "$fails" -eq 0 ]; then
    printf '%s\n' "$(c_grn '*** TUDO APLICADO COM SUCESSO ***')"
  else
    printf '%s\n' "$(c_red "*** ${fails} CHECKS FALHARAM ***")"
    return 1
  fi
}

# ============================================================================
# REVERT
# ============================================================================
do_revert() {
  section "REVERT: restaurando estado limpo"

  require_nic

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Restauraria:"
    log "[dry-run]   - XPS/RPS zerados em todas queues"
    log "[dry-run]   - remover ${RDMA_BLACKLIST_FILE} (permite RDMA recarregar em reboot)"
    log "[dry-run]   - manter ring size atual (nao reverte: e tuning generico bom)"
    log "[dry-run]   - manter coalesce adaptive (nao reverte: e tuning generico bom)"
    log "[dry-run]   - manter combined queues atual"
    log "[dry-run]   - manter NAPI defer (gro_flush_timeout + napi_defer_hard_irqs)"
    log "[dry-run]   - manter offloads ethtool (TSO/GSO/GRO/checksums/...)"
    log "[dry-run]   - manter ${SYSCTL_FILE} (sysctl consolidado, nao reverte)"
    log "[dry-run]   - reativar /etc/sysctl.d/*.conf.disabled-by-xuione (fonte unica desfeita)"
    # Detecta o que MUDARIA para mostrar reloads correspondentes
    if [ -f "$DEFAULT_NGINX_CONF" ] && grep -q "^${NGINX_BLOCK_BEGIN}\$" "$DEFAULT_NGINX_CONF" 2>/dev/null; then
      log "[dry-run]   - remover bloco ccd-net do nginx.conf"
      NGINX_CONF_CHANGED=1
    fi
    if [ -f "$DEFAULT_XUI_UNIT" ] && grep -q '^CPUAffinity=' "$DEFAULT_XUI_UNIT"; then
      log "[dry-run]   - remover CPUAffinity de xuione.service"
      XUI_UNIT_CHANGED=1
    fi
    if [ -f "$DEFAULT_CRON_DROPIN_FILE" ]; then
      log "[dry-run]   - remover ${DEFAULT_CRON_DROPIN_FILE}"
      CRON_DROPIN_CHANGED=1
    fi
    if [ -f "$PERSIST_UNIT_SERVICE" ] || [ -f "$PERSIST_UNIT_PATH" ] || [ -f "$PERSIST_BIN_PATH" ]; then
      log "[dry-run]   - desabilitar + remover persistencia systemd (xuione-ccd-net.{service,path}, binario)"
      PERSISTENCE_CHANGED=2  # 2 = removida
    fi
    apply_reloads
    return 0
  fi

  # Remove blacklist RDMA (permite recarga em reboot)
  if [ -f "$RDMA_BLACKLIST_FILE" ]; then
    rm -f "$RDMA_BLACKLIST_FILE"
    ok "blacklist removida: ${RDMA_BLACKLIST_FILE}"
  fi

  # Zera XPS/RPS
  if [ -d "/sys/class/net/${NIC}/queues" ]; then
    local q
    # nullglob: se nao houver match, expande para vazio (nao para o glob literal)
    shopt -s nullglob
    for q in "/sys/class/net/${NIC}/queues"/tx-*/xps_cpus; do
      if echo 0 > "$q" 2>/dev/null; then vlog "zerado: $q"; fi
    done
    for q in "/sys/class/net/${NIC}/queues"/rx-*/rps_cpus; do
      if echo 0 > "$q" 2>/dev/null; then vlog "zerado: $q"; fi
    done
    shopt -u nullglob
    ok "XPS/RPS zerados"
  fi

  # nginx: remove bloco (marca flag; reload em apply_reloads)
  if [ -f "$DEFAULT_NGINX_CONF" ] && grep -q "^${NGINX_BLOCK_BEGIN}\$" "$DEFAULT_NGINX_CONF" 2>/dev/null; then
    local bak ts
    ts=$(date +%Y%m%d-%H%M%S)
    bak="${DEFAULT_NGINX_CONF}.bak.revert.${ts}"
    cp -a "$DEFAULT_NGINX_CONF" "$bak"
    local tmp; tmp=$(mktemp_tracked) || die "mktemp falhou"
    awk -v b="${NGINX_BLOCK_BEGIN}" -v e="${NGINX_BLOCK_END}" '
      BEGIN { skip = 0 }
      { sub(/\r$/, "") }
      $0 == b { skip = 1; print "worker_processes auto;"; next }
      $0 == e { skip = 0; next }
      skip == 0 { print }
    ' "$DEFAULT_NGINX_CONF" > "$tmp"
    cat "$tmp" > "$DEFAULT_NGINX_CONF"
    NGINX_CONF_CHANGED=1
    ok "nginx.conf: bloco ccd-net removido (backup: ${bak})"
    # apply_nginx_conf tinha removido a diretiva avulsa; sem reinserir, o
    # nginx voltaria ao default worker_processes 1 no reload logo abaixo.
    ok "nginx.conf: worker_processes auto; reinserido (valor original)"
    warn "Atencao: 'auto' = 1 worker por CPU logica (bem mais que o plano CCD-aware)."
  fi

  # xuione.service: remove CPUAffinity (marca flag; daemon-reload em apply_reloads)
  if [ -f "$DEFAULT_XUI_UNIT" ] && grep -q '^CPUAffinity=' "$DEFAULT_XUI_UNIT"; then
    local bak ts
    ts=$(date +%Y%m%d-%H%M%S)
    bak="${DEFAULT_XUI_UNIT}.bak.revert.${ts}"
    cp -a "$DEFAULT_XUI_UNIT" "$bak"
    sed -i '/^CPUAffinity=/d' "$DEFAULT_XUI_UNIT"
    XUI_UNIT_CHANGED=1
    ok "xuione.service: CPUAffinity removida (backup: ${bak})"
  fi

  # cron drop-in (marca flag; daemon-reload + restart em apply_reloads)
  if [ -f "$DEFAULT_CRON_DROPIN_FILE" ]; then
    rm -f "$DEFAULT_CRON_DROPIN_FILE"
    rmdir "$DEFAULT_CRON_DROPIN_DIR" 2>/dev/null || true
    CRON_DROPIN_CHANGED=1
    ok "cron drop-in removido"
  fi

  # Persistencia systemd: disable + remover (marca 2 = removida)
  if [ -f "$PERSIST_UNIT_PATH" ] || [ -f "$PERSIST_UNIT_SERVICE" ]; then
    systemctl disable --now xuione-ccd-net.path xuione-ccd-net.service 2>/dev/null || true
    rm -f "$PERSIST_UNIT_PATH" "$PERSIST_UNIT_SERVICE"
    PERSISTENCE_CHANGED=2  # 2 = removida (apply_reloads NAO faz start path)
    ok "Persistencia systemd removida (units desabilitados)"
  fi
  if [ -e "$PERSIST_BIN_PATH" ] || [ -L "$PERSIST_BIN_PATH" ]; then
    rm -f "$PERSIST_BIN_PATH" "${PERSIST_BIN_PATH}.prev"
    ok "Copia canonica de persistencia removida: ${PERSIST_BIN_PATH} (+ .prev)"
  fi

  # Consolida reloads (daemon-reload + restart cron + nginx reload)
  apply_reloads

  echo
  # Fonte unica desfeita: reativa os sysctl.d que o apply desativou
  # (sysctl.conf em si e mantido, como documentado acima).
  section "REVERT: reativando /etc/sysctl.d desativados pela fonte unica"
  restore_disabled_sysctl_d

  printf '%s\n' "$(c_grn '*** REVERT CONCLUIDO ***')"
  log "Nota: ethtool combined queues NAO foi alterado (use 'ethtool -L ${NIC} combined N' manualmente se quiser)"
}

# ============================================================================
# ANALYZE TOPOLOGY: imprime analise rica de CPU + NIC + estado atual
# Nao aplica nada. Util para decidir quantos CCDs alocar para rede.
# ============================================================================
analyze_topology() {
  section "ANALISE DE TOPOLOGIA"

  # --- CPU ---
  echo
  printf '%s\n' "$(c_bld '[CPU]')"
  local model
  model=$(awk -F: '/^model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ *//')
  printf '  Modelo:         %s\n' "$model"
  printf '  Threads totais: %d\n' "$TOTAL_THREADS"
  printf '  Cores fisicos:  %d\n' "$TOTAL_PHYSICAL_CORES"
  # Le sizes diretamente; trata ausencia. tr -d 'K' remove sufixo (ex "16384K"->"16384")
  local l3_kb_raw l2_kb_raw l1d_kb_raw
  l3_kb_raw=$(tr -d 'K' < /sys/devices/system/cpu/cpu0/cache/index3/size 2>/dev/null || echo 0)
  l2_kb_raw=$(tr -d 'K' < /sys/devices/system/cpu/cpu0/cache/index2/size 2>/dev/null || echo 0)
  l1d_kb_raw=$(tr -d 'K' < /sys/devices/system/cpu/cpu0/cache/index0/size 2>/dev/null || echo 0)
  local l3_mb=$(( ${l3_kb_raw:-0} / 1024 ))
  printf '  CCXes:          %d (L3 separados, %d MB cada)\n' "$NUM_CCXES" "$l3_mb"
  printf '  CCDs:           %d (assumindo %d CCXes/CCD)\n' "$NUM_CCDS" "$CCXES_PER_CCD"
  printf '  L2/core fisico: %d KB\n' "${l2_kb_raw:-0}"
  printf '  L1d/core:       %d KB\n' "${l1d_kb_raw:-0}"

  # --- Tabela CCDs ---
  echo
  printf '%s\n' "$(c_bld '[Mapa CCDs - CPUs (fisicas) por CCD + seus SMT siblings]')"
  printf '  %-6s  %-25s  %s\n' "CCD" "CPUs (fisicas)" "SMT siblings (=nginx)"
  printf '  %-6s  %-25s  %s\n' "------" "-------------------------" "-------------------------"
  local ccd_id
  for ccd_id in $(seq 0 $((NUM_CCDS - 1))); do
    local phys="${CCD_PHYSCORES[$ccd_id]}"
    local sibs=""
    local cpu
    for cpu in $phys; do
      sibs="$sibs ${SMT_SIBLING[$cpu]:--}"
    done
    # shellcheck disable=SC2086  # listas de CPUs precisam word splitting
    sibs=$(echo $sibs | xargs)
    # shellcheck disable=SC2086
    printf '  CCD%-3d  %-25s  %s\n' "$ccd_id" "$(compact_range $phys)" "$(compact_range $sibs)"
  done

  # --- NIC ---
  echo
  printf '%s\n' "$(c_bld '[NIC]')"
  printf '  Interface:      %s\n' "$NIC"
  local driver fw
  driver=$(ethtool -i "$NIC" 2>/dev/null | awk '/^driver:/ {print $2}')
  fw=$(ethtool -i "$NIC" 2>/dev/null | awk '/^firmware-version:/ {print $2" "$3}')
  printf '  Driver:         %s  (firmware: %s)\n' "$driver" "$fw"
  local cur_combined max_combined
  cur_combined=$(ethtool -l "$NIC" 2>/dev/null | awk '/^Combined:/ {if (n==1) print $2; n++}' | head -1)
  max_combined=$(ethtool -l "$NIC" 2>/dev/null | awk '/^Combined:/ {if (n==0) print $2; n++}' | head -1)
  printf '  Combined queues: %s atual / %s maximo\n' "${cur_combined:-?}" "${max_combined:-?}"
  local ring_rx ring_tx
  ring_rx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^RX:/ {if (n==1) print $2; n++}' | head -1)
  ring_tx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^TX:/ {if (n==1) print $2; n++}' | head -1)
  printf '  Ring buffer:    RX=%s TX=%s\n' "${ring_rx:-?}" "${ring_tx:-?}"
  local speed
  speed=$(cat "/sys/class/net/${NIC}/speed" 2>/dev/null)
  printf '  Velocidade:     %s Mbps\n' "${speed:-?}"

  # --- IRQ atual ---
  echo
  printf '%s\n' "$(c_bld '[IRQ NIC atualmente em /proc/interrupts]')"
  local n_irqs
  n_irqs=$(count_matches "/proc/interrupts" "${NIC}.*TxRx")
  printf '  Total IRQs TxRx: %s\n' "$n_irqs"
  if [ "$VERBOSE" -eq 1 ] && [ "$n_irqs" -gt 0 ]; then
    grep -E "${NIC}.*TxRx" /proc/interrupts | head -5 | awk -F: '{print "    "$1": "$NF}' | sed 's/^/  /'
    [ "$n_irqs" -gt 5 ] && echo "  ... ($((n_irqs - 5)) outros)"
  fi

  # --- Tuning NIC (RDMA / ring / coalesce) ---
  echo
  printf '%s\n' "$(c_bld '[Tuning NIC]')"
  # RDMA
  if lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$RDMA_MODULE"; then
    printf '  RDMA (%s):  %s carregado (ainda ativo)\n' "$RDMA_MODULE" "$(c_yel '*')"
  else
    printf '  RDMA (%s):  %s nao carregado\n' "$RDMA_MODULE" "$(c_dim '-')"
  fi
  if [ -f "$RDMA_BLACKLIST_FILE" ]; then
    printf '  Blacklist:      %s %s\n' "$(c_grn '*')" "$RDMA_BLACKLIST_FILE"
  else
    printf '  Blacklist:      %s nao existe (RDMA pode recarregar em reboot)\n' "$(c_dim '-')"
  fi
  # Ring
  local max_rx max_tx cur_rx cur_tx
  max_rx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^RX:/ {n++; if (n==1) print $2;}' | head -1)
  max_tx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^TX:/ {n++; if (n==1) print $2;}' | head -1)
  cur_rx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^RX:/ {n++; if (n==2) print $2;}' | head -1)
  cur_tx=$(ethtool -g "$NIC" 2>/dev/null | awk '/^TX:/ {n++; if (n==2) print $2;}' | head -1)
  if [ "$cur_rx" = "$max_rx" ] && [ "$cur_tx" = "$max_tx" ]; then
    printf '  Ring:           %s RX=%s TX=%s (max alcancado)\n' "$(c_grn '*')" "${cur_rx:-?}" "${cur_tx:-?}"
  else
    printf '  Ring:           %s RX=%s/%s TX=%s/%s (nao esta no max)\n' "$(c_yel '*')" \
      "${cur_rx:-?}" "${max_rx:-?}" "${cur_tx:-?}" "${max_tx:-?}"
  fi
  # Coalesce
  local arx atx
  arx=$(ethtool -c "$NIC" 2>/dev/null | awk '/^Adaptive RX:/ {print $3}')
  atx=$(ethtool -c "$NIC" 2>/dev/null | awk '/^Adaptive RX:/ {print $5}')
  if [ "$arx" = "on" ] && [ "$atx" = "on" ]; then
    printf '  Coalesce adapt: %s RX=on TX=on\n' "$(c_grn '*')"
  else
    printf '  Coalesce adapt: %s RX=%s TX=%s (nao adaptive)\n' "$(c_yel '*')" "${arx:-?}" "${atx:-?}"
  fi
  # NAPI defer
  local gro_to napi_defer
  gro_to=$(cat "/sys/class/net/${NIC}/gro_flush_timeout" 2>/dev/null)
  napi_defer=$(cat "/sys/class/net/${NIC}/napi_defer_hard_irqs" 2>/dev/null)
  if [ "$gro_to" = "$NAPI_GRO_FLUSH_TIMEOUT_NS" ] && [ "$napi_defer" = "$NAPI_DEFER_HARD_IRQS" ]; then
    printf '  NAPI defer:     %s gro_flush=%sns napi_defer_hard_irqs=%s\n' "$(c_grn '*')" "${gro_to}" "${napi_defer}"
  else
    printf '  NAPI defer:     %s gro_flush=%s napi_defer=%s (alvo %s/%s)\n' "$(c_yel '*')" \
      "${gro_to:-?}" "${napi_defer:-?}" "$NAPI_GRO_FLUSH_TIMEOUT_NS" "$NAPI_DEFER_HARD_IRQS"
  fi
  # Offloads ethtool (sumario)
  local off_on=0 off_off=0 off_fixed=0 off_missing=0
  local f
  for f in "${OFFLOAD_FEATURES_ON[@]}"; do
    local st; st=$(read_offload_state "$f")
    case "$st" in
      on)        off_on=$((off_on + 1)) ;;
      off)       off_off=$((off_off + 1)) ;;
      off-fixed) off_fixed=$((off_fixed + 1)) ;;
      missing)   off_missing=$((off_missing + 1)) ;;
    esac
  done
  if [ "$off_off" -eq 0 ] && [ "$off_on" -gt 0 ]; then
    printf '  Offloads:       %s %d ON / %d fixed / %d missing\n' "$(c_grn '*')" "$off_on" "$off_fixed" "$off_missing"
  else
    printf '  Offloads:       %s %d ON / %d OFF (ligaveis) / %d fixed / %d missing\n' "$(c_yel '*')" "$off_on" "$off_off" "$off_fixed" "$off_missing"
  fi
  # sysctl netdev_budget*
  local nb nbu
  nb=$(sysctl -n net.core.netdev_budget 2>/dev/null)
  nbu=$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null)
  if [ "$nb" = "$NETDEV_BUDGET" ] && [ "$nbu" = "$NETDEV_BUDGET_USECS" ]; then
    printf '  netdev_budget:  %s %s packets / %s us\n' "$(c_grn '*')" "${nb}" "${nbu}"
  else
    printf '  netdev_budget:  %s %s pkts / %s us (alvo %s/%s)\n' "$(c_yel '*')" \
      "${nb:-?}" "${nbu:-?}" "$NETDEV_BUDGET" "$NETDEV_BUDGET_USECS"
  fi

  # --- Estado atual da config ---
  echo
  printf '%s\n' "$(c_bld '[Estado atual da configuracao]')"
  local q0_xps q0_rps
  q0_xps=$(cat "/sys/class/net/${NIC}/queues/tx-0/xps_cpus" 2>/dev/null)
  q0_rps=$(cat "/sys/class/net/${NIC}/queues/rx-0/rps_cpus" 2>/dev/null)
  if [ -n "$q0_xps" ] && [ "$q0_xps" != "0" ] && ! echo "$q0_xps" | grep -qxE '0+(,0+)*'; then
    printf '  XPS:            %s ATIVO (tx-0 = %s)\n' "$(c_grn '*')" "$q0_xps"
  else
    printf '  XPS:            %s desativado/zerado\n' "$(c_dim '-')"
  fi
  if [ -n "$q0_rps" ] && [ "$q0_rps" != "0" ] && ! echo "$q0_rps" | grep -qxE '0+(,0+)*'; then
    printf '  RPS:            %s ATIVO (rx-0 = %s)\n' "$(c_yel '*')" "$q0_rps"
  else
    printf '  RPS:            %s desativado/zerado\n' "$(c_dim '-')"
  fi
  local arfs_global
  arfs_global=$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)
  if [ "${arfs_global:-0}" -gt 0 ]; then
    printf '  ARFS (global):  %s ATIVO (rps_sock_flow_entries=%s)\n' "$(c_yel '*')" "$arfs_global"
  else
    printf '  ARFS (global):  %s desativado (rps_sock_flow_entries=0)\n' "$(c_dim '-')"
  fi

  if [ -f "$DEFAULT_NGINX_CONF" ]; then
    if grep -q "^${NGINX_BLOCK_BEGIN}\$" "$DEFAULT_NGINX_CONF" 2>/dev/null; then
      printf '  nginx.conf:     %s tem bloco xuione-ccd-net\n' "$(c_grn '*')"
    else
      printf '  nginx.conf:     %s sem bloco xuione-ccd-net\n' "$(c_dim '-')"
    fi
    # Le valor de worker_processes (pode ser N inteiro OU "auto")
    local nginx_workers
    nginx_workers=$(awk '/^[[:space:]]*worker_processes[[:space:]]/ {gsub(";",""); print $2; exit}' "$DEFAULT_NGINX_CONF" 2>/dev/null)
    printf '  worker_processes: %s\n' "${nginx_workers:-?}"
    # Conta linhas worker_cpu_affinity (0 em --nginx-auto, 1 nos outros modos)
    local nginx_wa_count
    nginx_wa_count=$(count_matches "$DEFAULT_NGINX_CONF" '^[[:space:]]*worker_cpu_affinity[[:space:]]')
    printf '  worker_cpu_affinity: %s linha(s)\n' "$nginx_wa_count"
  fi

  if [ -f "$DEFAULT_XUI_UNIT" ]; then
    local aff; aff=$(grep '^CPUAffinity=' "$DEFAULT_XUI_UNIT" 2>/dev/null | head -1)
    if [ -n "$aff" ]; then
      printf '  xuione.service: %s %s\n' "$(c_grn '*')" "$aff"
    else
      printf '  xuione.service: %s sem CPUAffinity\n' "$(c_dim '-')"
    fi
  fi

  if [ -f "$DEFAULT_CRON_DROPIN_FILE" ]; then
    local aff; aff=$(grep '^CPUAffinity=' "$DEFAULT_CRON_DROPIN_FILE" 2>/dev/null | head -1)
    printf '  cron drop-in:   %s %s\n' "$(c_grn '*')" "$aff"
  else
    printf '  cron drop-in:   %s nao existe\n' "$(c_dim '-')"
  fi

  # --- Recomendacoes ---
  echo
  printf '%s\n' "$(c_bld '[Recomendacoes - quantos CCDs alocar para rede]')"
  local cpus_per_ccd
  cpus_per_ccd=$(echo "${CCD_PHYSCORES[0]}" | wc -w)
  printf '  CPUs (fisicas) por CCD: %d\n' "$cpus_per_ccd"
  printf '  Cada --ccds N => %d * N queues NIC + %d * N nginx workers\n' "$cpus_per_ccd" "$cpus_per_ccd"
  printf '  Lembre: 1 queue = 1 CPU fisica; 1 nginx worker = 1 SMT sibling.\n'
  echo
  printf '  %-10s  %-9s  %-13s  %-13s  %s\n' "Opcao" "Queues" "nginx wkrs" "App threads" "Uso recomendado"
  printf '  %-10s  %-9s  %-13s  %-13s  %s\n' "----------" "---------" "-------------" "-------------" "------------------------------------"
  local n
  for n in $(seq 1 $((NUM_CCDS - 1))); do
    local q=$((n * cpus_per_ccd))
    local nginx_w=$q
    local app_cpus=$(( (NUM_CCDS - n) * cpus_per_ccd ))
    local app_threads=$((app_cpus * 2))
    local rec=""
    if [ "$n" -eq 2 ]; then rec="conservador (RX leve)"
    elif [ "$n" -eq 3 ]; then rec="medio (~10-15 Gbps)"
    elif [ "$n" -eq 4 ]; then rec="${C_GRN}simetrico 50/50 - sweet spot${C_RST}"
    elif [ "$n" -eq 5 ]; then rec="rede-pesado (>40 Gbps)"
    elif [ "$n" -le 1 ]; then rec="minimo, so para teste"
    else rec="rede-extremo, app limitado"
    fi
    printf '  %-10s  %-9d  %-13d  %-13s  %b\n' "--ccds $n" "$q" "$nginx_w" \
      "${app_cpus}cpu/${app_threads}t" "$rec"
  done
  # Modos especiais: core (todos fisicos) e spread (todos threads)
  printf '  %-10s  %-9d  %-13d  %-13s  %b\n' "core" \
    "$TOTAL_PHYSICAL_CORES" "$TOTAL_PHYSICAL_CORES" "0cpu/0t" \
    "rede-total (sem app pinning; --no-affinity auto)"
  printf '  %-10s  %-9d  %-13s  %-13s  %b\n' "spread" \
    "$TOTAL_THREADS" "auto" "0cpu/0t" \
    "1 IRQ por thread (auto --no-affinity + --nginx-auto)"

  # --- Carga atual ---
  echo
  printf '%s\n' "$(c_bld '[Carga atual (snapshot)]')"
  local load; load=$(awk '{printf "%.2f %.2f %.2f", $1, $2, $3}' /proc/loadavg)
  printf '  load avg:       %s\n' "$load"
  local rx_pps tx_pps tx_gbps
  if command -v sar >/dev/null 2>&1; then
    local rx_kbs="" tx_kbs=""
    read -r rx_pps tx_pps rx_kbs tx_kbs < <(timeout 4 sar -n DEV 1 3 2>/dev/null | awk -v i="$NIC" '/Average:/ && $2==i {printf "%d %d %d %d", $3, $4, $5, $6; exit}')
    tx_gbps=$(awk -v t="${tx_kbs:-0}" 'BEGIN {printf "%.2f", t*8/1000000}')
    local rx_gbps
    rx_gbps=$(awk -v r="${rx_kbs:-0}" 'BEGIN {printf "%.2f", r*8/1000000}')
    printf '  Trafego:        RX %s pps (%s Gbps) | TX %s pps (%s Gbps)\n' \
      "${rx_pps:-?}" "$rx_gbps" "${tx_pps:-?}" "$tx_gbps"
  fi
  local mem_used mem_total
  read -r mem_total mem_used < <(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%d %d", t, t-a}' /proc/meminfo)
  printf '  RAM:            %d GB usado / %d GB total\n' \
    "$((mem_used / 1024 / 1024))" "$((mem_total / 1024 / 1024))"

  echo
  printf '%s\n' "$(c_cya "Para aplicar:  sudo ${SCRIPT_NAME} --nic ${NIC} --ccds N --apply")"
  printf '%s\n' "$(c_cya "Para preview:  sudo ${SCRIPT_NAME} --nic ${NIC} --ccds N")"
  echo
}

# ============================================================================
# MAIN
# ============================================================================
main() {
  parse_args "$@"

  echo
  printf '%s\n' "$(c_bld "${SCRIPT_NAME} v${VERSION} - CCD-aware NIC + nginx pinning")"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$(c_yel '*** MODO DRY-RUN *** (use --apply para executar)')"
  else
    printf '%s\n' "$(c_grn '*** MODO APPLY ***')"
  fi

  if [ "$REVERT" -eq 1 ]; then
    require_root
    acquire_lock
    do_revert
    exit $?
  fi

  detect_topology
  require_nic

  if [ "$ANALYZE_ONLY" -eq 1 ]; then
    analyze_topology
    exit 0
  fi

  build_plan

  if [ "$SHOW_PLAN_ONLY" -eq 1 ]; then
    log "Apenas exibindo plano (--plan); saindo."
    exit 0
  fi

  preflight

  # Lock adquirido apenas em apply (dry-run nao precisa - so leitura)
  if [ "$DRY_RUN" -eq 0 ]; then
    acquire_lock
    notify_impact
  fi

  disable_irqbalance      # PRIMEIRO: stop + disable, senao desfaz o pinning abaixo
  apply_rdma_off
  apply_ring_size_max
  apply_nic_queues
  apply_coalesce_adaptive
  apply_napi_defer        # gro_flush_timeout + napi_defer_hard_irqs
  apply_offloads          # ethtool -K TSO/GSO/GRO/checksums/etc -> on
  apply_sysctl_netdev     # /etc/sysctl.conf consolidado (chattr -i/+i)
  apply_irq_xps_rps
  apply_nginx_conf
  apply_xuione_service
  apply_cron_dropin

  # Persistencia systemd (re-aplica no boot). Opt-out via --no-systemd.
  install_persistence

  # Consolida daemon-reload + restart cron + nginx reload em fase unica.
  # Apenas executa o que cada apply_* marcou como mudado.
  apply_reloads

  # Exit code do script = resultado da validacao final. Sem isso o systemd
  # reportava sucesso (unit active/exited) mesmo com checks falhando.
  local validate_rc=0
  if [ "$DRY_RUN" -eq 0 ]; then
    validate_all || validate_rc=1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo
    log "Para aplicar de verdade, rode novamente com ${C_BLD}--apply${C_RST}"
  fi

  return "$validate_rc"
}

main "$@"
