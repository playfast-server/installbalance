#!/usr/bin/env bash
# xuione-tune.sh -- tuning de rede 100G para XuiOne
# Hardware-alvo: EPYC 7702P (Zen2 64C/128T 8xCCD/16xCCX) + Intel E810-C 100GbE.
# Kernel: 5.15 (generic) ou 7.x (xanmod, ice in-tree + BBR3 + BORE).
#
# Versao FINAL apos diagnostico empirico em producao (XuiOne LB com 9k+ flows).
#
# Pillars:
#   - N filas combined topology-aware (1 IRQ MSI-X = 1 fila TxRx). Default:
#     4 IRQs por CCX (=64 no 7702P 16-CCX). Modos:
#       --cache-first       : 1 IRQ/CCX (max isolamento de L3, melhor p/ tail latency)
#       --reserve-ccx LIST  : libera CCX(es) inteiros p/ housekeeping do kernel
#       --irqs N            : override explicito (multiplo de NUM_CCX_ACTIVE)
#   - IRQs pinnados em cores fisicos do(s) CCX(es) ATIVO(s); libera SMT siblings
#   - XPS sibling-pattern: fila N -> {core IRQ_CPUS[N], sibling do mesmo core}
#     (mantem fila no mesmo CCX/L3)
#   - APP_CPUS = online \ IRQ_CPUS \ RESERVED_CPUS  (escrito como CPUAffinity=
#     em xuione.service)
#   - RFS DESLIGADO por padrao (ver comentario em RFS_PER_QUEUE: era o gargalo)
#   - ring 8160, coalesce adaptive 50us
#   - qdisc (mq+fq) NAO e tocado: kernel ja faz via default_qdisc=fq + mq auto
#   - sysctl: /etc/sysctl.conf e a FONTE UNICA DE VERDADE (do operador). O apply
#     NAO reescreve o conteudo: so aplica (sysctl -p), confere chave a chave
#     contra o runtime e trava (chattr +i). Para gerar o arquivo do zero a
#     partir do template embutido: apply --sysctl-init.
#   - persistencia via systemd unit + path watcher; flags topology-aware sao
#     propagadas via @EXTRA_FLAGS@ no template do service (re-aplicacao no
#     boot/path-trigger calcula o MESMO plano).
#
# Self-contained: logica do `set_irq_affinity` da Intel (BSD-3-Clause) foi
# PORTADA aqui (sem clone de repo, sem dependencia externa). Suporta modos
# all|local|one|<ranges>, validacao contra affinity_hint, build_mask hex,
# discover IRQ multi-padrao, aviso de irqbalance ativo.
#
# IMPORTANTE: apos `ethtool -L combined N` + `ip link down/up` no driver ice,
# /sys/class/net/.../statistics fica temporariamente congelado (bug do driver),
# induzindo a falso diagnostico de "TX=0". cmd_collect usa `ethtool -S` como
# fonte autoritativa.
#
# Idempotente. Use --dry-run para inspecionar acoes antes de executar.
#
# ATENCAO -- CONVIVENCIA: em hosts onde xuione-ccd-net.{service,path} estao
# instalados, AQUELE e o script canonico (reaplica NIC+nginx+sysctl no boot e a
# cada operstate change). Os dois disputam os MESMOS arquivos com marcadores
# diferentes; por isso apply/rollback/nginx-patch --apply abortam aqui quando o
# ccd-net esta instalado (bypass consciente: --force-legacy). status/validate/
# collect/plan/--dry-run continuam livres.
#
# Receita pos-reboot (xanmod 7.x):
#   cd /root/tunning-e810
#   ./xuione-tune.sh status                                  # confirma NIC/driver
#   ./xuione-tune.sh collect ANTES
#   ./xuione-tune.sh --nic <IFACE> apply --nic-all --systemd  # NIC tuning + persistencia
#                                                             #   (NAO escreve sysctl, NAO toca xuione.service)
#   ./xuione-tune.sh validate                                # PASS/FAIL de cada item
#   ./xuione-tune.sh collect DEPOIS
#
# Para aplicar TUDO (sysctl + modprobe + nic-all + xui-affinity + systemd) use:
#   ./xuione-tune.sh apply                  # equivalente a 'apply --all' (aplica -- sem reescrever --
#                                           # /etc/sysctl.conf e escreve em xuione.service)
#   ./xuione-tune.sh apply --sysctl-init    # 1a instalacao: gera /etc/sysctl.conf do template

set -eu
# NOTA: NAO ativar `set -o pipefail`. Varias funcoes usam pipes onde o primeiro
# comando legitimamente retorna nao-zero (ex.: `systemctl is-active inactive_svc | head -1`,
# `grep -v ... | sort`). Com pipefail + set -e, esses pipes matam o script.
# Audit 2026-05-11 adicionou pipefail "defensivamente" e quebrou apply em
# do_irqbalance. Removido.

# ---------- defaults ----------
NIC="${NIC:-}"

# TARGET_IRQS = numero total de IRQs (= QUEUES) que serao usados pela NIC.
# DEVE ser multiplo de NUM_CCX_ACTIVE (= NUM_CCX detectados - len(--reserve-ccx)).
# Range valido: NUM_CCX_ACTIVE .. (CCX_size - 1) * NUM_CCX_ACTIVE -- max sempre
# reserva pelo menos 1 thread/CCX para app (impede que TARGET_IRQS use TODOS
# os threads do menor CCX).
#
# Default: 0 = autodetect:
#   - sem --cache-first: NUM_CCX_ACTIVE * 4 (default historico, 64 no 7702P 16-CCX)
#   - com --cache-first: NUM_CCX_ACTIVE     (1 IRQ/CCX, max isolamento de L3)
#
# Mapa pratico no EPYC 7702P (16 CCX, cada um com 4 fisicos + 4 SMT, sem reserva):
#    16 IRQs = 1/CCX  -> 16 cores ocupados, 112 livres pra app  [--cache-first]
#    32 IRQs = 2/CCX  -> 32 cores ocupados, 96  livres
#    48 IRQs = 3/CCX  -> 48 cores ocupados, 80  livres
#    64 IRQs = 4/CCX  -> 64 cores ocupados (todos fisicos), 64 livres (SMT)  [auto]
#    80 IRQs = 5/CCX  -> 80 cores (4 fisicos + 1 SMT por CCX), 48 livres
#    96 IRQs = 6/CCX  -> 96 cores, 32 livres
#   112 IRQs = 7/CCX  -> 112 cores, 16 livres (limite com 16 CCXes)
# Com --reserve-ccx 0 (NUM_CCX_ACTIVE=15) os multiplos validos ficam: 15,30,45,60,75,90,105
TARGET_IRQS=0

# QUEUES e derivado de TARGET_IRQS apos compute_plan().
QUEUES=0

# RFS_PER_QUEUE default = 0 (DESLIGADO).
#
# Em workloads com muitos flows TCP simultaneos (XuiOne LB com 9k+ conexoes),
# RFS faz lookup em rps_sock_flow_entries para CADA pacote. Com tabela grande
# e muitos flows ativos, o lookup vira o GARGALO: medido em producao no
# E810 100Gb com EPYC 7702P, softirq nos cores do IRQ saltou para 95%+ com
# RFS=16384/fila (1M entries globais), contra ~5% sem RFS. RFS so vale a pena
# para workloads de poucos sockets persistentes.
#
# Para ligar: --rfs-per-queue 2048 (testar e medir).
RFS_PER_QUEUE=0

DRY_RUN=0

# --restart  -> OPT-IN para reiniciar servicos cujo drop-in mudou (hoje so
# cron.service). Default OFF: `systemctl restart cron` mata o cgroup do cron e
# junto os ffmpeg forkados pelos crontabs do XUI (streams.php tick 1min).
# Mesma politica ja usada com xuione.service (nunca reiniciado pelo script).
RESTART_SERVICES=0

# --force-legacy -> OPT-IN para rodar apply/rollback/nginx-patch mesmo com as
# units do xuione-ccd-net instaladas (ver require_no_ccdnet_conflict).
FORCE_LEGACY=0

# --nginx-takeover -> OPT-IN para assumir um nginx.conf que hoje esta sob
# gestao do xuione-ccd-net.sh (bloco "# === BEGIN xuione-ccd-net ==="). Sem a
# flag, do_nginx_affinity PULA o arquivo: os dois scripts editando o mesmo
# nginx.conf com ancoras diferentes gera flip-flop com reload de ~160 workers.
NGINX_TAKEOVER=0

# VERBOSE=1: mostra cada comando executado (prefixo $) e estado lido apos cada acao.
# VERBOSE=0: so log() das fases. Use --quiet para silenciar.
VERBOSE="${VERBOSE:-1}"
# FORCE_HW=1 (--force-hw) bypassa validacao de hardware (use por sua conta e risco).
FORCE_HW=0

# Plano calculado por compute_plan() apos detect_topology():
#   IRQ_CPUS_ARR     -> array de CPUs (1 por IRQ, na ordem das filas)
#   APP_CPUS_LIST    -> string com lista compacta para CPUAffinity= (ex.: "4-7,12-15,...")
#   NUM_CCX          -> contagem de CCXes detectados
#   NUM_CCX_ACTIVE   -> CCXes que recebem IRQ/app (= NUM_CCX - len(--reserve-ccx))
#   RESERVED_CPUS_LIST -> lista compacta dos CPUs em CCXes reservados (info p/ GRUB/log)
NUM_CCX=0
NUM_CCX_ACTIVE=0
declare -a IRQ_CPUS_ARR=()
declare -a CCX_PHYS_ARR=()    # CCX_PHYS_ARR[i] = "c0 c1 c2 c3" cores fisicos do CCX i
declare -a CCX_SMT_ARR=()     # CCX_SMT_ARR[i]  = "c0 c1 c2 c3" SMT siblings  do CCX i
declare -a CCX_RESERVED=()    # CCX_RESERVED[i] = 1 se CCX i reservado p/ kernel, 0 senao
APP_CPUS_LIST=""
RESERVED_CPUS_LIST=""

# --reserve-ccx LIST  -> CCXes reservados INTEIROS para housekeeping do kernel
# (ex.: "0" = libera os 8 threads + 16 MB de L3 do CCX 0 para timer tick, RCU,
# kworkers, ksoftirqd, kthreadd; remove esses CCXes do plano de IRQ E do APP_CPUS).
# Aceita "0", "0,5", "0-2". Default vazio = comportamento original.
RESERVED_CCX_LIST=""

# --cache-first  -> modo "1 IRQ por CCX ativo" (= NUM_CCX_ACTIVE total).
# Maximiza isolamento de L3: cada CCX tem 1 core em softirq usando seus 16 MB
# de L3 sozinho, em vez de 4 cores compartilhando. Em LB de streaming a perda
# em filas (16-32 vs 64) e compensada pela queda de cache miss.
CACHE_FIRST=0

# --isolcpus-domain  -> OPT-IN. Default = sem flag `domain` em isolcpus.
# Por que default OFF:
#   `domain` retira os cores dos sched_domains -> scheduler NAO faz load
#   balancing entre eles. Tasks pinadas em ranges (CPUAffinity=A-B com A!=B)
#   ficam no primeiro core onde calham e nao migram. Incidente 2026-05-07
#   neste servidor: streams.php (cron) forkou 1813 ffmpegs e TODOS ficaram no
#   CPU 5 (psr herdado do parent), porque `domain` proibia rebalance. Removido.
# Quando ligar:
#   workloads de hard-realtime onde voce pina cada task em UM core especifico
#   (DPDK, HFT) e quer scheduler 100% out-of-the-way. NAO o caso de IPTV LB.
ISOLCPUS_DOMAIN=0

# --nohz_full  -> OPT-IN via --nohz-full. Default = NAO emitir nohz_full= no
# cmdline. Mesma classe de risco que motivou tirar `domain` do isolcpus:
#   housekeeping_nohz_full_setup() liga TICK|WQ|TIMER|RCU|MISC|KTHREAD, entao
#   nohz_full=<data plane> confina TODO kthread nao-pinado e TODA workqueue
#   unbound do host nos poucos threads do CCX reservado (que ja recebe
#   irqaffinity=). E o ganho nao se materializa: o tick so para com <=1 task
#   runnable, condicao que nunca ocorre com ~160 workers nginx + 64 pools
#   php-fpm + ffmpegs -- sobra so o custo de context tracking em cada
#   transicao user<->kernel num workload dominado por syscalls de I/O.
# rcu_nocbs continua SEMPRE ligado: ele nao mexe na mascara de housekeeping,
# apenas cria os kthreads rcuo/* (que o scheduler posiciona livremente) e tira
# os callbacks de RCU do softirq dos cores de data plane.
NOHZ_FULL=0

# --nginx-pin-mode  -> controla como do_nginx_affinity escolhe worker_processes
# e o bitmask de worker_cpu_affinity.
#
#   spread (default)  : worker_processes = #APP_CPUS, bitmask = APP_CPUS_LIST inteiro.
#                       Nginx workers espalhados em todos os cores app.
#                       Locality parcial (so workers que calham num IRQ core ganham
#                       L1d/L2 quente; outros usam L3 do CCX).
#
#   smt-irq           : worker_processes = TARGET_IRQS * 2, bitmask = uniao(
#                       IRQ_CPUS_ARR, SMT siblings de cada IRQ_CPUS_ARR).
#                       Cada nginx worker pinado no par SMT da queue NIC -> max
#                       cache locality (L1d/L2 do par SMT compartilhado entre
#                       softirq RX e worker). PHP-FPM/ffmpeg ocupam os outros
#                       (APP_CPUS - cores_nginx) cores.
#                       Modo otimizado p/ workload onde hot path (auth, parse HTTP,
#                       proxy para FPM) e o gargalo, e nao memory bandwidth.
#                       Recomendado quando carga passar de ~15k clientes.
NGINX_PIN_MODE="spread"

# --segregate-network  -> Modo C: EXCLUI cores de rede (IRQ + SMT siblings) do
# CPUAffinity= de xuione.service e cron.service. PHP-FPM/ffmpeg ficam APENAS
# nos cores nao-rede; rede (softirq + nginx smt-irq) tem L1d/L2 dedicados.
#
# Requer --nginx-pin-mode=smt-irq (sem ele, nao ha nginx pinado e segregar
# nao faz sentido -- die com mensagem). Reduz cores PHP-FPM de 105 -> 90 no
# 7702P 16-CCX com --cache-first --reserve-ccx 0 (tira os 15 SMT siblings dos
# cores de IRQ, que passam a ser exclusivos do nginx smt-irq). Sem
# --reserve-ccx e 112 -> 96.
#
# Quando ligar: hot path (RX softirq -> nginx -> FPM proxy) virou gargalo
# medido. NIC saturada >60% sustentado. Scheduler nao da conta sozinho.
# Hoje em sid18402 (NIC 6.4%) nao vale -- scheduler resolve SMT contention
# automaticamente. Documentado como opt-in para escala futura.
SEGREGATE_NETWORK=0

# === NAPI defer (portado de xuione-ccd-net.sh em 2026-05-14) ===
# gro_flush_timeout: NAPI busy-waits Nns apos RX antes de soltar CPU (reduz IRQ rate)
# napi_defer_hard_irqs: ate N polls antes de re-enable IRQ
NAPI_GRO_FLUSH_TIMEOUT_NS=200000
NAPI_DEFER_HARD_IRQS=2

# === Valores do template embutido (usados SO por --sysctl-init) ===
# Nao sao mais sentinels de runtime: a verificacao do apply compara TODAS as
# chaves do /etc/sysctl.conf contra `sysctl -n` (ver sysctl_runtime_diff).
NETDEV_BUDGET=1200
NETDEV_BUDGET_USECS=16000

# Diretorio onde estao os arquivos .conf e .service que acompanham o script
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# SYSCTL_SRC (99-xuione-100g.conf) removido: o sysctl virou heredoc embedded
# (sysctl_template) em 2026-05-14 e a variavel ficou morta.
# MODPROBE_SRC/SERVICE_SRC/PATH_SRC continuam aqui como OVERRIDE opcional: se o
# arquivo existir no SCRIPT_DIR ele tem precedencia sobre o template embedded.
MODPROBE_SRC="${SCRIPT_DIR}/blacklist-irdma.conf"
SERVICE_SRC="${SCRIPT_DIR}/xuione-net-tune.service"
PATH_SRC="${SCRIPT_DIR}/xuione-net-tune.path"

# /etc/sysctl.conf: FONTE UNICA de verdade (conteudo do operador). Os
# marcadores abaixo sobrevivem apenas dentro do template de --sysctl-init --
# o apply NAO reescreve mais nada entre eles.
SYSCTL_TARGET="/etc/sysctl.conf"
# Nome CANONICO do script para os carimbos gravados em arquivos do sistema
# (cabecalho de sysctl.conf, bloco do nginx.conf, sufixo de backup). NAO usar
# ${0##*/}: uma copia/symlink/teste renomeado carimbaria um nome que nao existe
# e a auditoria da fonte unica passaria a apontar para lugar nenhum.
SCRIPT_NAME="xuione-tune.sh"
SYSCTL_BEGIN="# === BEGIN xuione-tune ==="
SYSCTL_END="# === END xuione-tune ==="

MODPROBE_DST="/etc/modprobe.d/blacklist-irdma.conf"
SCRIPT_DST="/usr/local/sbin/xuione-tune.sh"
SERVICE_DST="/etc/systemd/system/xuione-net-tune.service"
PATH_DST="/etc/systemd/system/xuione-net-tune.path"

# ---------- util: cores, simbolos, layout ----------
# Detecta se a saida e um terminal real. Sem TTY (pipe/redirect/systemd),
# desativa cores e simbolos UTF-8 para nao poluir logs/captura.
if [ -t 1 ] && [ -t 2 ] && [ "${NO_COLOR:-}" = "" ]; then
  ESC_RED=$'\033[31m';   ESC_GRN=$'\033[32m';   ESC_YEL=$'\033[33m'
  ESC_BLU=$'\033[34m';   ESC_MAG=$'\033[35m';   ESC_CYA=$'\033[36m'
  ESC_DIM=$'\033[2m';    ESC_BLD=$'\033[1m';    ESC_RST=$'\033[0m'
  # Simbolos UTF-8 (terminais modernos suportam)
  SYM_OK="✓";  SYM_FAIL="✗";  SYM_WARN="⚠";  SYM_INFO="ℹ"
  SYM_ARROW="▸";  SYM_BULLET="●";  SYM_DIAMOND="◆"
  # Box drawing
  BOX_HL="─"; BOX_VL="│"; BOX_TL="┌"; BOX_TR="┐"; BOX_BL="└"; BOX_BR="┘"
  BOX_LT="├"; BOX_RT="┤"; BOX_DH="═"
else
  ESC_RED=""; ESC_GRN=""; ESC_YEL=""; ESC_BLU=""; ESC_MAG=""; ESC_CYA=""
  ESC_DIM=""; ESC_BLD=""; ESC_RST=""
  SYM_OK="[OK]"; SYM_FAIL="[FAIL]"; SYM_WARN="[WARN]"; SYM_INFO="[*]"
  SYM_ARROW=">"; SYM_BULLET="*"; SYM_DIAMOND="*"
  BOX_HL="-"; BOX_VL="|"; BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"
  BOX_LT="+"; BOX_RT="+"; BOX_DH="="
fi

c_red(){ printf '%s%s%s' "$ESC_RED" "$*" "$ESC_RST"; }
c_grn(){ printf '%s%s%s' "$ESC_GRN" "$*" "$ESC_RST"; }
c_yel(){ printf '%s%s%s' "$ESC_YEL" "$*" "$ESC_RST"; }
c_blu(){ printf '%s%s%s' "$ESC_BLU" "$*" "$ESC_RST"; }
c_mag(){ printf '%s%s%s' "$ESC_MAG" "$*" "$ESC_RST"; }
c_cya(){ printf '%s%s%s' "$ESC_CYA" "$*" "$ESC_RST"; }
c_dim(){ printf '%s%s%s' "$ESC_DIM" "$*" "$ESC_RST"; }
c_bld(){ printf '%s%s%s' "$ESC_BLD" "$*" "$ESC_RST"; }

# Largura padrao do "box" de cabecalho/rodape.
BOX_WIDTH=70
hline() {
  # hline [char] [width]  -> imprime linha horizontal
  local ch="${1:-$BOX_HL}" w="${2:-$BOX_WIDTH}"
  local i; for ((i=0; i<w; i++)); do printf '%s' "$ch"; done; echo
}

# Tag colorida [TEXTO] (usada em log/ok/nok)
tag_ok()    { printf '%s%s%s'   "$ESC_GRN" "$SYM_OK"   "$ESC_RST"; }
tag_fail()  { printf '%s%s%s'   "$ESC_RED" "$SYM_FAIL" "$ESC_RST"; }
tag_warn()  { printf '%s%s%s'   "$ESC_YEL" "$SYM_WARN" "$ESC_RST"; }
tag_info()  { printf '%s%s%s'   "$ESC_BLU" "$SYM_INFO" "$ESC_RST"; }
tag_arrow() { printf '%s%s%s'   "$ESC_CYA" "$SYM_ARROW" "$ESC_RST"; }

log(){  printf '%s %s\n' "$(tag_arrow)" "$*"; }
warn(){ printf '%s %s\n' "$(tag_warn)"  "$*" >&2; G_NOK=$((G_NOK+1)); }
die(){  printf '%s %s\n' "$(tag_fail)"  "$*" >&2; exit 1; }
ok(){   printf '      %s %s\n' "$(tag_ok)"   "$*"; G_OK=$((G_OK+1)); }
nok(){  printf '      %s %s\n' "$(tag_warn)" "$*" >&2; G_NOK=$((G_NOK+1)); }

# Tally global de OK / issues -- usado por cmd_apply para imprimir resumo final.
G_OK=0
G_NOK=0

# Numeracao de fases [N/M]. cmd_apply seta PHASE_TOTAL via count_phases().
PHASE_CUR=0
PHASE_TOTAL=0

# Cabecalho de fase. Uso: section "titulo"
# Com PHASE_TOTAL>0: '[N/M] titulo' colorido; senao bloco com box-drawing.
section() {
  PHASE_CUR=$((PHASE_CUR+1))
  echo
  if [ "$PHASE_TOTAL" -gt 0 ]; then
    printf '%s[%s%d/%d%s]%s %s%s%s\n' \
      "$ESC_DIM" "$ESC_RST$ESC_BLD" "$PHASE_CUR" "$PHASE_TOTAL" "$ESC_RST$ESC_DIM" "$ESC_RST" \
      "$ESC_BLD" "$*" "$ESC_RST"
  else
    printf '%s%s%s %s%s%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST" "$ESC_BLD" "$*" "$ESC_RST"
  fi
}

# Indenta linha de log dentro de uma fase (6 espacos, mesmo padrao do bnxt-pin).
phase_log()     { printf '      %s\n' "$*"; }
phase_summary() { printf '      %s %s\n' "───" "$*"; }

# Imprime "label  value" alinhado dentro do box (largura BOX_WIDTH).
# Usa cor azul para o label.
box_kv() {
  local label="$1"; shift
  printf '  %s%-10s%s  %s\n' "$ESC_BLU" "$label" "$ESC_RST" "$*"
}

# Box de cabecalho: nome do script + data + NIC + topologia + config.
# Chamado no inicio de cmd_apply quando NIC/topologia ja foram determinados.
header_box() {
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  printf '  %sxuione-tune%s  %s%s%s   %s%s%s\n' \
    "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "tuning de rede 100G" "$ESC_RST" \
    "$ESC_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$ESC_RST"
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"

  if [ -n "${NIC}" ] && [ -e "/sys/class/net/${NIC}" ]; then
    local bdf numa speed
    bdf="$(readlink -f /sys/class/net/${NIC}/device 2>/dev/null | awk -F/ '{print $NF}')"
    numa="$(cat /sys/class/net/${NIC}/device/numa_node 2>/dev/null || echo '?')"
    [ "$numa" = "-1" ] && numa="?"
    speed="$(cat /sys/class/net/${NIC}/speed 2>/dev/null || echo '?')"
    box_kv "NIC" "$(c_bld "${NIC}")  $(c_dim "BDF=${bdf:-?}  NUMA=${numa}  ${speed}Mb/s")"
  fi

  if [ "${NUM_CCX}" -gt 0 ]; then
    local nphys; nphys=$(echo "${CCX_PHYS_ARR[0]}" | wc -w)
    local active=${NUM_CCX_ACTIVE:-$NUM_CCX}
    local topo_str
    if [ -n "${RESERVED_CCX_LIST}" ]; then
      topo_str="$(c_bld "${active}/${NUM_CCX}") CCXes ativos $(c_dim "(${nphys} cores/CCX, $(c_yel "CCX ${RESERVED_CCX_LIST} reservado"))")"
    else
      topo_str="$(c_bld "${active}/${NUM_CCX}") CCXes $(c_dim "(${nphys} cores/CCX)")"
    fi
    box_kv "topology" "${topo_str}"
    if [ -n "${RESERVED_CPUS_LIST}" ]; then
      box_kv "reserved" "$(c_yel "CPUs ${RESERVED_CPUS_LIST}")  $(c_dim "→ kernel housekeeping (timer tick, RCU, kworkers)")"
    fi
  fi

  if [ "${QUEUES}" -gt 0 ]; then
    local active=${NUM_CCX_ACTIVE:-$NUM_CCX}
    local per_ccx=$((TARGET_IRQS / active))
    local mode_label
    if [ "${CACHE_FIRST}" = "1" ]; then
      mode_label="$(c_mag "cache-first")"
    else
      mode_label="$(c_blu "ccx-aware")"
    fi
    box_kv "plan" "${mode_label}  $(c_dim "per_ccx=")$(c_bld ${per_ccx})  $(c_dim "queues=")$(c_bld ${QUEUES})  $(c_dim "irqs=")$(c_bld ${TARGET_IRQS})"
  fi
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
}

# Box final com resumo dos parametros aplicados na NIC.
# Aceita multiplas linhas via $1.."$N" (cada arg vira uma linha).
final_box() {
  echo
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  local first=1 status_sym status_lbl
  if [ "${G_NOK}" -eq 0 ]; then
    status_sym="$(c_grn "$SYM_OK")"; status_lbl="$(c_grn 'CONCLUIDO')"
  else
    status_sym="$(c_yel "$SYM_WARN")"; status_lbl="$(c_yel 'COM AVISOS')"
  fi
  for line in "$@"; do
    if [ "$first" = "1" ]; then
      printf '  %s %s  %s\n' "${status_sym}" "${status_lbl}" "$line"
      first=0
    else
      printf '              %s\n' "$line"
    fi
  done
  local ok_str fail_str
  ok_str="$(c_grn "$SYM_OK") $(c_grn ${G_OK}) ok"
  if [ "${G_NOK}" -gt 0 ]; then
    fail_str="$(c_yel "$SYM_WARN") $(c_yel ${G_NOK}) issues"
  else
    fail_str="$(c_dim "$SYM_FAIL 0 issues")"
  fi
  printf '              %s   %s\n' "${ok_str}" "${fail_str}"
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
}

run() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "      $(c_cya '[dry-run]') $*"
  else
    [ "${VERBOSE}" -eq 1 ] && echo "      $(c_cya '$') $*"
    eval "$@"
  fi
}

# Como run(), mas em loops com muitas iteracoes mostra so as 3 primeiras +
# uma linha "... (omitindo N similares)". Args: idx (0-based) total cmd...
RUN_CAP_LIMIT=3
run_cap() {
  local idx="$1" total="$2"; shift 2
  if [ "$idx" -lt "$RUN_CAP_LIMIT" ]; then
    run "$@"
  else
    if [ "$idx" -eq "$RUN_CAP_LIMIT" ]; then
      if [ "${DRY_RUN}" -eq 1 ]; then
        echo "      $(c_cya '[dry-run]') ... (omitindo $((total - RUN_CAP_LIMIT)) similares)"
      elif [ "${VERBOSE}" -eq 1 ]; then
        echo "      $(c_cya '$') ... (omitindo $((total - RUN_CAP_LIMIT)) similares)"
      fi
    fi
    [ "${DRY_RUN}" -eq 1 ] || eval "$@"
  fi
}

# Le um arquivo do sysfs/proc/etc. e compara com o esperado. Loga OK ou nok.
# Uso: verify_eq "label" "esperado" "$(cat /sys/.../foo)"
verify_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    ok "${label} = ${actual}"
  else
    nok "${label} = ${actual} (esperado ${expected})"
  fi
}

require_root(){ [ "$(id -u)" -eq 0 ] || die "execute como root"; }
require_file(){ [ -f "$1" ] || die "arquivo ausente: $1"; }

# Guard de convivencia com o script IRMAO.
# Em hosts onde xuione-ccd-net.{service,path} estao instalados, ELE e o script
# canonico: reaplica NIC + nginx.conf + sysctl no boot e a cada mudanca de
# operstate. Rodar xuione-tune.sh por cima gera ping-pong permanente -- os dois
# gerenciam /etc/sysctl.conf, nginx.conf e o drop-in de cron com marcadores
# diferentes, e cada lado desfaz o bloco do outro (com reload de ~160 workers
# nginx e, no caso do tune, `ethtool -L` que reseta o driver).
# Bypass consciente: --force-legacy.
require_no_ccdnet_conflict() {
  local ctx="${1:-esta operacao}"
  [ "${FORCE_LEGACY}" -eq 1 ] && return 0
  [ "${DRY_RUN}" -eq 1 ] && return 0   # dry-run nao escreve nada -- sempre liberado
  local svc_active pth_enabled
  svc_active=$(systemctl is-active  xuione-ccd-net.service 2>/dev/null | head -1)
  pth_enabled=$(systemctl is-enabled xuione-ccd-net.path   2>/dev/null | head -1)
  if [ "${svc_active}" = "active" ] || [ "${pth_enabled}" = "enabled" ]; then
    warn "xuione-ccd-net detectado (service=${svc_active:-nao-instalado} path=${pth_enabled:-nao-instalado})"
    warn "  esse e o script CANONICO neste host; xuione-tune.sh e LEGADO e disputa os"
    warn "  mesmos arquivos (sysctl.conf, nginx.conf, cron drop-in, filas da NIC)."
    warn "  Escolha UM: pare/desabilite as units do ccd-net, ou rode o proprio ccd-net."
    die "${ctx} abortada para evitar ping-pong entre os dois scripts (use --force-legacy para ignorar)"
  fi
  return 0
}

# Helper: conta linhas de um arquivo que casam com regex ERE (portado de
# xuione-ccd-net.sh:count_matches em 2026-08-20).
# BUG corrigido: `grep -c ... || echo 0` produzia "0\n0" quando grep retorna
# exit 1 (sem match), pois grep JA emite "0" no stdout antes do `|| echo 0`.
# O valor com 2 linhas quebrava `[ "$n" -eq 0 ]` (rc=2, "integer expression
# expected") e `$((a - n))` ("syntax error in expression", fatal).
count_matches() {
  local file="$1" pattern="$2"
  [ -f "$file" ] || { printf '0'; return 0; }
  local n
  n=$(grep -cE "$pattern" "$file" 2>/dev/null)
  [ -z "$n" ] && n=0
  printf '%s' "$n"
}

# ---------- hardware compatibility ----------
# Retorna lista de problemas de compatibilidade de hardware, 1 por linha.
# Vazio = totalmente suportado (AMD Zen2/3/4/5 + ice + single-socket + x86_64).
# Avalia: arch, vendor da CPU, family (Zen), nr de sockets, driver da NIC.
detect_hw_issues() {
  local issues="" arch vendor family sockets drv

  arch="$(uname -m)"
  if [ "$arch" != "x86_64" ]; then
    issues="${issues}arquitetura ${arch} (suporta apenas x86_64)"$'\n'
  fi

  vendor="$(awk -F: '/^vendor_id/{gsub(/[[:space:]]/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  family="$(awk -F: '/^cpu family/{gsub(/[[:space:]]/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"

  case "$vendor" in
    AuthenticAMD)
      # 23 = Zen/Zen+/Zen2 (precisa olhar model pra Zen2 estritamente, mas Zen e Zen+
      # ja sao raros em servidor; Zen2 = 7xx2 Rome). 25 = Zen3/4. 26 = Zen5.
      case "$family" in
        23|25|26) ;;   # AMD Zen 2/3/4/5 -- ok
        *) issues="${issues}CPU AMD family ${family} fora de Zen2/3/4/5 (testado: family 23/25/26)"$'\n' ;;
      esac
      ;;
    GenuineIntel)
      issues="${issues}CPU Intel detectado (script otimizado para AMD Zen com L3 per-CCX; --cache-first nao se aplica direito porque Intel tem L3 per-socket/tile)"$'\n'
      ;;
    "")
      issues="${issues}vendor da CPU nao detectado (CPU exotica? VM sem cpuid?)"$'\n'
      ;;
    *)
      issues="${issues}CPU vendor desconhecido: ${vendor}"$'\n'
      ;;
  esac

  # Multi-socket: script trata tudo como NUMA unico, sem awareness de NUMA-local
  # IRQ. Em 2P+ o pinning pode ficar cross-socket = cache miss caro.
  sockets="$(awk -F: '/^physical id/{print $2}' /proc/cpuinfo 2>/dev/null | sort -un | wc -l)"
  if [ "${sockets:-1}" -gt 1 ]; then
    issues="${issues}multi-socket: ${sockets} sockets detectados (script nao tem awareness de NUMA-local; pinning ficaria cross-socket)"$'\n'
  fi

  # Driver da NIC: se NIC informada, exige ice (E810/E822/E823). Demais drivers
  # podem funcionar parcialmente mas o tuning (ring 8160, padroes de IRQ name)
  # foi calibrado para ice.
  if [ -n "${NIC:-}" ] && [ -e "/sys/class/net/${NIC}" ]; then
    drv="$(basename "$(readlink -f "/sys/class/net/${NIC}/device/driver" 2>/dev/null)" 2>/dev/null)"
    if [ -z "$drv" ]; then
      issues="${issues}driver da NIC ${NIC}: nao detectado"$'\n'
    elif [ "$drv" != "ice" ]; then
      issues="${issues}driver da NIC ${NIC}: ${drv} (esperado: ice -- Intel E810/E822/E823)"$'\n'
    fi
  fi

  # Limita o trailing newline
  printf '%s' "${issues%$'\n'}"
}

# Para comandos que MODIFICAM estado (apply, rollback): bloqueia se hardware
# nao suportado, a menos que --force-hw. Imprime diagnostico claro.
require_hw_supported() {
  local issues; issues="$(detect_hw_issues)"
  [ -z "$issues" ] && return 0

  {
    echo "================================================================"
    echo "  $(c_red 'HARDWARE NAO SUPORTADO / NAO TESTADO')"
    echo "================================================================"
    echo "  Detectado:"
    printf '%s\n' "$issues" | sed 's/^/    - /'
    echo
    echo "  Suportado oficialmente:"
    echo "    - CPU: AMD EPYC Zen 2 (Rome 7xx2) -- alvo primario"
    echo "    - CPU: AMD EPYC Zen 3/4/5 (Milan/Genoa/Turin) -- mesma topologia per-CCX/CCD"
    echo "    - NIC: Intel E810/E822/E823 (driver ice)"
    echo "    - Topologia: single-socket, x86_64"
    echo
    echo "  Em hardware nao listado as recomendacoes podem nao se aplicar:"
    echo "    - Intel: L3 per-socket invalida o argumento de --cache-first"
    echo "    - Multi-socket: IRQ pode ficar cross-socket (cache miss caro)"
    echo "    - Drivers nao-ice: ring 8160 e padroes de IRQ podem falhar"
    echo
    echo "  Para forcar mesmo assim (sem garantias): adicione --force-hw"
    echo "================================================================"
  } >&2
  [ "$FORCE_HW" = "1" ] || die "hardware nao suportado (use --force-hw para sobrescrever)"
  warn "FORCANDO execucao em hardware nao testado (--force-hw)"
}

# Para comandos READ-ONLY (status, plan, validate): so avisa, nao bloqueia.
warn_hw_if_unsupported() {
  local issues; issues="$(detect_hw_issues)"
  [ -z "$issues" ] && return 0
  printf '%s %shardware fora do perfil testado%s %s(use -h)%s\n' \
    "$(tag_warn)" "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "$ESC_RST" >&2
  printf '%s\n' "$issues" | sed 's/^/  /' >&2
}

# Mascara hex para 1 CPU no formato esperado por /proc/irq/N/smp_affinity.
# Portado de build_mask() do set_irq_affinity da Intel (BSD-3-Clause).
build_irq_mask() {
  local cpu=$1
  local mask_fill="" mask_zero="00000000" idx vec
  if [ "$cpu" -ge 32 ]; then
    idx=$(( cpu / 32 ))
    for ((i=1; i<=idx; i++)); do
      mask_fill="${mask_fill},${mask_zero}"
    done
    vec=$(( cpu - 32 * idx ))
    printf "%X%s" $((1 << vec)) "$mask_fill"
  else
    printf "%X" $((1 << cpu))
  fi
}

# Numero de grupos de 32 bits que o sysfs/proc esperam para mascaras de CPU
# (xps_cpus, rps_cpus, smp_affinity). Calculado a partir do maior CPU possivel
# arredondado para o proximo multiplo de 32. Cobre maquinas com >128 CPUs
# (ex.: EPYC Genoa-X 192C/384T; multi-socket; ARM Altra Max 128C).
cpu_mask_groups() {
  local raw last
  raw="$(cat /sys/devices/system/cpu/possible 2>/dev/null || echo '0-127')"
  # Pega o ultimo numero (lida com "0-127", "0-3,8-15", "0-127,128-191")
  last="${raw##*,}"
  last="${last##*-}"
  case "$last" in ''|*[!0-9]*) last=127 ;; esac
  echo $(( (last + 1 + 31) / 32 ))
}

# Mascara para N CPUs no formato sysfs (%08x,%08x,...,%08x do MSB ao LSB).
# Numero de grupos = cpu_mask_groups(). Aceita 1..N CPUs como args.
mask_for_cpus() {
  local groups c g v i out=""
  groups=$(cpu_mask_groups)
  local -a m
  for ((i=0; i<groups; i++)); do m[$i]=0; done
  for c in "$@"; do
    g=$(( c / 32 ))
    v=$(( c - 32 * g ))
    [ "$g" -lt "$groups" ] || die "mask_for_cpus: CPU $c excede ${groups} grupos (cpu/possible)"
    m[$g]=$(( m[$g] | (1 << v) ))
  done
  for ((i=groups-1; i>=0; i--)); do
    if [ -z "$out" ]; then printf -v out '%08x' "${m[$i]}"
    else                   printf -v out '%s,%08x' "$out" "${m[$i]}"
    fi
  done
  printf '%s\n' "$out"
}

# Wrapper retrocompativel para call sites antigos
mask_for_two_cpus() { mask_for_cpus "$1" "$2"; }

ensure_nic(){
  [ -n "${NIC}" ] || NIC="$(prompt_nic)"
  [ -n "${NIC}" ] || die "NIC nao informada (use --nic IFACE ou rode em terminal interativo)"
  [ -e "/sys/class/net/${NIC}" ] || die "NIC ${NIC} ausente"
}

# Lista NICs fisicas (nao-virtuais), 1 por linha, no formato:
#   IFACE  driver  speed  operstate
list_nic_candidates() {
  local d iface drv sp oper
  for d in /sys/class/net/*/device; do
    [ -e "$d" ] || continue
    iface="$(echo "$d" | awk -F/ '{print $5}')"
    case "$iface" in lo|docker*|veth*|br-*|bond*|virbr*|tap*|tun*) continue ;; esac
    drv="$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
    sp="$(cat /sys/class/net/$iface/speed 2>/dev/null || echo '?')"
    oper="$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo '?')"
    printf '%s\t%s\t%s\t%s\n' "$iface" "${drv:-?}" "$sp" "$oper"
  done
}

# Lista candidatas e pede ao usuario para escolher uma. Em modo nao-interativo
# (sem TTY -- ex.: systemd, pipe), retorna vazio para que ensure_nic falhe com
# erro claro. NUNCA escolhe NIC sozinho: o usuario precisa confirmar.
prompt_nic() {
  if [ ! -t 0 ] || [ ! -t 2 ]; then
    warn "modo nao-interativo: passe --nic IFACE explicitamente"
    return 0
  fi
  local list n
  list="$(list_nic_candidates)"
  n="$(echo "$list" | grep -c .)"
  if [ "$n" -eq 0 ]; then
    warn "nenhuma NIC fisica encontrada"
    return 0
  fi
  {
    echo "=== NICs disponiveis ==="
    printf '  %-3s %-20s %-10s %-10s %s\n' "#" "IFACE" "DRIVER" "SPEED" "STATE"
    local i=1 line
    while IFS= read -r line; do
      printf '  %-3s %s\n' "$i" "$(echo "$line" | awk -F'\t' '{printf "%-20s %-10s %-10s %s",$1,$2,$3,$4}')"
      i=$((i+1))
    done <<< "$list"
  } >&2
  local choice picked
  printf "Escolha a NIC (numero ou nome): " >&2
  read -r choice </dev/tty
  case "$choice" in
    ''|0) warn "nada escolhido"; return 0 ;;
    *[!0-9]*)
      # tratado como nome
      if echo "$list" | awk -F'\t' '{print $1}' | grep -qx "$choice"; then
        echo "$choice"; return 0
      fi
      warn "NIC '$choice' nao esta na lista"; return 0 ;;
    *)
      picked="$(echo "$list" | awk -F'\t' -v n="$choice" 'NR==n{print $1}')"
      [ -n "$picked" ] || { warn "indice fora da lista"; return 0; }
      echo "$picked" ;;
  esac
}

# Expande "0-3,8,12-15" em "0 1 2 3 8 12 13 14 15"
expand_range() {
  local r="${1//,/ }" out="" item s e
  for item in $r; do
    if [[ "$item" == *-* ]]; then
      s="${item%-*}"; e="${item#*-}"
      out="$out $(seq "$s" "$e")"
    else
      out="$out $item"
    fi
  done
  echo $out
}

# Inverso de expand_range: compacta "0 1 2 3 8 9 12" em "0-3,8-9,12"
compact_range() {
  local list="$*" sorted prev start out=""
  sorted="$(echo "$list" | tr ' ' '\n' | sort -un)"
  for n in $sorted; do
    if [ -z "${prev:-}" ]; then
      start=$n; prev=$n; continue
    fi
    if [ $((n - prev)) -eq 1 ]; then
      prev=$n
    else
      if [ "$start" = "$prev" ]; then out="${out},${start}"
      else out="${out},${start}-${prev}"; fi
      start=$n; prev=$n
    fi
  done
  if [ -n "${prev:-}" ]; then
    if [ "$start" = "$prev" ]; then out="${out},${start}"
    else out="${out},${start}-${prev}"; fi
  fi
  echo "${out#,}"
}

# Devolve a lista de CPUs online (do /sys), separadas por espaco.
# Fallback dinamico via cpu/possible -> nproc (sem hardcode 0-127), pra
# funcionar em sistemas com mais (ou menos) de 128 CPUs.
online_cpus() {
  local raw
  raw="$(cat /sys/devices/system/cpu/online 2>/dev/null || echo "")"
  if [ -n "$raw" ]; then
    expand_range "$raw"
    return 0
  fi
  raw="$(cat /sys/devices/system/cpu/possible 2>/dev/null || echo "")"
  if [ -n "$raw" ]; then
    expand_range "$raw"
    return 0
  fi
  local n; n=$(nproc 2>/dev/null || echo 0)
  [ "$n" -gt 0 ] || die "nao foi possivel descobrir CPUs online"
  seq 0 $((n - 1))
}

# Devolve o SMT sibling de uma CPU (ou ela mesma se nao houver SMT)
smt_sibling_of() {
  local cpu=$1
  local list sib
  list="$(cat /sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list 2>/dev/null)"
  [ -z "$list" ] && { echo "$cpu"; return; }
  for sib in $(expand_range "$list"); do
    [ "$sib" != "$cpu" ] && { echo "$sib"; return; }
  done
  echo "$cpu"
}

# Detecta CCXes via L3 cache groups (/sys/.../cache/index3/shared_cpu_list).
# Popula:
#   NUM_CCX
#   CCX_PHYS_ARR[i] = cores fisicos (thread 0) do CCX i, ordenados
#   CCX_SMT_ARR[i]  = SMT siblings do CCX i, na mesma ordem
detect_topology() {
  local seen_lists="" l3 first cpu d cores_in_ccx phys smt sib_list sib first_sib
  local i=0
  CCX_PHYS_ARR=()
  CCX_SMT_ARR=()
  # ITERACAO NUMERICA (nao glob): `cpu[0-9]*` expande em ordem LEXICOGRAFICA
  # (cpu0, cpu1, cpu10, cpu100, ...), o que numerava os CCXes fora de ordem
  # (CCX[1] virava 12-15, CCX[8] virava 4-7) e embaralhava --reserve-ccx,
  # IRQ_CPUS_ARR (fila N -> CPU N) e a tabela do `plan`.
  # online_cpus() devolve 0 1 2 ... N em ordem numerica; CPU offline nao tem
  # cache/index3 e cai no `continue` abaixo.
  for cpu in $(online_cpus); do
    d="/sys/devices/system/cpu/cpu${cpu}"
    l3="$(cat "$d/cache/index3/shared_cpu_list" 2>/dev/null || true)"
    [ -z "$l3" ] && continue
    # so processa o representante do grupo (primeira CPU online do CCX)
    first="$(expand_range "$l3" | awk '{print $1}')"
    [ "$cpu" != "$first" ] && continue
    # evita duplicar (caso o representante apareca via mais de um caminho)
    case " $seen_lists " in *" $l3 "*) continue ;; esac
    seen_lists="$seen_lists $l3"
    # separa fisicos x siblings: "fisico" = menor CPU id de cada par SMT
    cores_in_ccx="$(expand_range "$l3")"
    phys=""; smt=""
    for c in $cores_in_ccx; do
      sib_list="$(cat /sys/devices/system/cpu/cpu${c}/topology/thread_siblings_list 2>/dev/null)"
      first_sib="$(expand_range "$sib_list" | awk '{print $1}')"
      if [ "$c" = "$first_sib" ]; then phys="$phys $c"; else smt="$smt $c"; fi
    done
    # ordena ambas as listas
    phys="$(echo $phys | tr ' ' '\n' | sort -un | tr '\n' ' ')"
    smt="$(echo $smt  | tr ' ' '\n' | sort -un | tr '\n' ' ')"
    CCX_PHYS_ARR[$i]="$(echo $phys)"
    CCX_SMT_ARR[$i]="$(echo $smt)"
    i=$((i+1))
  done
  NUM_CCX=$i
  [ "$NUM_CCX" -gt 0 ] || die "nao foi possivel detectar CCXes (L3 cache topology indisponivel)"
}

# Marca CCX_RESERVED[i]=1 para cada CCX em RESERVED_CCX_LIST.
# Popula NUM_CCX_ACTIVE e RESERVED_CPUS_LIST (cores fisicos+SMT dos CCXes reservados).
# RESERVED_CCX_LIST vazio = todos ativos (comportamento original).
mark_reserved_ccx() {
  CCX_RESERVED=()
  local i; for i in $(seq 0 $((NUM_CCX-1))); do CCX_RESERVED[$i]=0; done
  NUM_CCX_ACTIVE=$NUM_CCX
  RESERVED_CPUS_LIST=""
  [ -z "$RESERVED_CCX_LIST" ] && return 0

  local idx reserved_cpus=""
  for idx in $(expand_range "$RESERVED_CCX_LIST"); do
    case "$idx" in ''|*[!0-9]*) die "--reserve-ccx: indice invalido '$idx'" ;; esac
    [ "$idx" -ge 0 ] && [ "$idx" -lt "$NUM_CCX" ] || \
      die "--reserve-ccx: indice $idx fora do range 0..$((NUM_CCX-1)) (NUM_CCX=${NUM_CCX})"
    [ "${CCX_RESERVED[$idx]}" = "1" ] && continue   # idempotente em duplicatas
    CCX_RESERVED[$idx]=1
    NUM_CCX_ACTIVE=$((NUM_CCX_ACTIVE - 1))
    reserved_cpus="$reserved_cpus ${CCX_PHYS_ARR[$idx]} ${CCX_SMT_ARR[$idx]}"
  done
  [ "$NUM_CCX_ACTIVE" -gt 0 ] || \
    die "--reserve-ccx removeu TODOS os CCXes -- nada sobra para IRQ/app"
  RESERVED_CPUS_LIST="$(compact_range $reserved_cpus)"
}

# A partir de TARGET_IRQS + topologia ja detectada, popula:
#   IRQ_CPUS_ARR  -> 1 CPU por IRQ (na ordem)
#   APP_CPUS_LIST -> compacta range das CPUs nao usadas pelas IRQs nem reservadas
#   QUEUES        -> = TARGET_IRQS
compute_plan() {
  [ "$NUM_CCX" -gt 0 ] || die "compute_plan: detect_topology() nao foi chamado"
  mark_reserved_ccx

  # --cache-first (1 IRQ/CCX ativo) tem precedencia sobre auto, mas perde para
  # --irqs explicito (operador no controle).
  if [ "$TARGET_IRQS" -eq 0 ]; then
    if [ "$CACHE_FIRST" = "1" ]; then
      TARGET_IRQS="$NUM_CCX_ACTIVE"
      log "auto --irqs=${TARGET_IRQS} (cache-first: 1 por CCX, ${NUM_CCX_ACTIVE} CCXes ativos)"
    else
      TARGET_IRQS=$((NUM_CCX_ACTIVE * 4))
      log "auto --irqs=${TARGET_IRQS} (4 por CCX, ${NUM_CCX_ACTIVE} CCXes ativos)"
    fi
  fi

  # validacao de TARGET_IRQS
  case "$TARGET_IRQS" in ''|*[!0-9]*) die "--irqs deve ser inteiro" ;; esac
  # range minimo: 1 IRQ por CCX ativo (nao faz sentido menos);
  # range maximo: max_per_ccx*NUM_CCX_ACTIVE (calculado abaixo)
  [ "$TARGET_IRQS" -ge "$NUM_CCX_ACTIVE" ] || \
    die "--irqs ${TARGET_IRQS} < NUM_CCX_ACTIVE=${NUM_CCX_ACTIVE} (use no minimo 1 IRQ/CCX ativo)"
  if [ $((TARGET_IRQS % NUM_CCX_ACTIVE)) -ne 0 ]; then
    die "--irqs ${TARGET_IRQS} nao e multiplo de NUM_CCX_ACTIVE=${NUM_CCX_ACTIVE} (use ${NUM_CCX_ACTIVE},$((NUM_CCX_ACTIVE*2)),$((NUM_CCX_ACTIVE*3))...)"
  fi
  local per_ccx=$((TARGET_IRQS / NUM_CCX_ACTIVE))

  # max_per_ccx: usa o MENOR CCX ativo (caso CCXes reservados sejam diferentes
  # de tamanho ou se havia hot-unplug). Reserva sempre 1 thread/CCX p/ app.
  local max_per_ccx min_size=999 size i
  for i in $(seq 0 $((NUM_CCX-1))); do
    [ "${CCX_RESERVED[$i]}" = "1" ] && continue
    size=$(( $(echo ${CCX_PHYS_ARR[$i]} | wc -w) + $(echo ${CCX_SMT_ARR[$i]} | wc -w) ))
    [ "$size" -lt "$min_size" ] && min_size=$size
  done
  max_per_ccx=$(( min_size - 1 ))
  [ "$per_ccx" -le "$max_per_ccx" ] || \
    die "--irqs ${TARGET_IRQS} pede ${per_ccx} por CCX, max ${max_per_ccx} (reserva 1/CCX pra app)"

  IRQ_CPUS_ARR=()
  local idx=0 k phys_arr smt_arr ordered c
  for i in $(seq 0 $((NUM_CCX-1))); do
    [ "${CCX_RESERVED[$i]}" = "1" ] && continue
    # ordem de uso: fisicos primeiro, depois SMT siblings
    read -ra phys_arr <<< "${CCX_PHYS_ARR[$i]}"
    read -ra smt_arr  <<< "${CCX_SMT_ARR[$i]}"
    ordered=("${phys_arr[@]}" "${smt_arr[@]}")
    for k in $(seq 0 $((per_ccx-1))); do
      c="${ordered[$k]}"
      IRQ_CPUS_ARR[$idx]="$c"
      idx=$((idx+1))
    done
  done
  QUEUES="$TARGET_IRQS"

  # APP_CPUS = todos online \ IRQ_CPUS_ARR \ RESERVED_CPUS_LIST
  local online_list irq_set=" " reserved_set=" " cpu app=""
  online_list="$(online_cpus)"
  for c in "${IRQ_CPUS_ARR[@]}"; do irq_set="${irq_set}${c} "; done
  for c in $(expand_range "${RESERVED_CPUS_LIST:-}"); do reserved_set="${reserved_set}${c} "; done
  for cpu in $online_list; do
    case "$irq_set"      in *" $cpu "*) continue ;; esac
    case "$reserved_set" in *" $cpu "*) continue ;; esac
    app="$app $cpu"
  done
  APP_CPUS_LIST="$(compact_range $app)"
}

# Descobre IRQs da NIC. Tenta:
#   1) padrao "ice-${NIC}-TxRx" (driver ice atual)
#   2) padrao generico "${NIC}-.*TxRx"
#   3) fallback /sys/class/net/${NIC}/device/msi_irqs
discover_nic_irqs() {
  local irqs
  irqs="$(grep -E "ice-${NIC}-TxRx" /proc/interrupts | awk -F: '{print $1+0}' || true)"
  if [ -z "$irqs" ]; then
    irqs="$(grep -E "${NIC}-.*TxRx" /proc/interrupts | awk -F: '{print $1+0}' || true)"
  fi
  if [ -z "$irqs" ]; then
    local d="/sys/class/net/${NIC}/device/msi_irqs"
    if [ -d "$d" ]; then
      irqs="$(ls -1 "$d" 2>/dev/null | sort -n)"
    fi
  fi
  echo "$irqs"
}

# ---------- acoes individuais ----------
# Detecta se um arquivo tem flag immutable (chattr +i) setada.
# Retorna 0 se imutavel, 1 caso contrario (ou erro).
is_immutable() {
  local f="$1"
  [ -f "$f" ] || return 1
  lsattr "$f" 2>/dev/null | awk '{print $1}' | grep -q 'i'
}

# sysctl_template: heredoc com o conteudo completo de /etc/sysctl.conf.
# USO UNICO desde 2026-08-20: `apply --sysctl-init` (bootstrap do arquivo).
# O apply normal NAO usa este template -- /etc/sysctl.conf e a fonte unica e
# quem manda nele e o operador. Os marcadores # === BEGIN/END xuione-tune ===
# ficam so por compatibilidade visual com auditorias antigas.
sysctl_template() {
  cat <<EOF
${SYSCTL_BEGIN}
# Gerado por xuione-tune.sh em $(date '+%Y-%m-%d %H:%M:%S')
# Tuning de rede para XUI/IPTV em EPYC + E810 100G
# ATENCAO: arquivo travado com chattr +i para impedir sobrescrita pelo painel XUI.
# Este arquivo e a FONTE UNICA de verdade: o script NAO reescreve o conteudo,
# so aplica (sysctl -p) e confere. Edite a mao quando precisar:
# Para editar:  chattr -i ${SYSCTL_TARGET}  &&  vim ${SYSCTL_TARGET}  &&  chattr +i ${SYSCTL_TARGET}

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
${SYSCTL_END}
EOF
}

# ---------------------------------------------------------------------------
# FONTE UNICA DE VERDADE (decisao do operador, 2026-08-20):
# /etc/sysctl.conf pertence ao OPERADOR. O apply NAO reescreve mais o conteudo
# a partir do template embutido -- ele so aplica (sysctl -p), confere chave a
# chave contra o runtime e trava (chattr +i). O template embutido
# (sysctl_template) sobrou EXCLUSIVAMENTE para 'apply --sysctl-init', que gera
# o arquivo do zero quando ele ainda nao existe / esta vazio.
# ---------------------------------------------------------------------------

# Lista as chaves (uma por linha) de um arquivo sysctl, ignorando comentarios
# e linhas em branco. Aceita a forma "chave = valor" com espacos/tabs.
sysctl_file_keys() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk -F'=' '
    { sub(/\r$/, "") }
    /^[[:space:]]*[#;]/ { next }
    /=/ {
      k=$1; gsub(/[[:space:]]/, "", k)
      sub(/^-/, "", k)          # "-chave" = ignora erro (sintaxe do sysctl)
      if (k != "") print k
    }
  ' "$f"
}

# 0 = o arquivo tem PELO MENOS uma chave (nao e so comentario/vazio).
sysctl_file_has_keys() {
  local f="$1"
  [ -f "$f" ] || return 1
  [ -n "$(sysctl_file_keys "$f" | head -1)" ]
}

# Quantas chaves do arquivo EXISTEM neste kernel (as inexistentes ja sao
# reportadas por sysctl_missing_keys e ignoradas por `sysctl -e`).
sysctl_key_count() {
  local f="$1" k n=0
  while IFS= read -r k; do
    if [ -n "$k" ] && [ -e "/proc/sys/${k//./\/}" ]; then
      n=$((n+1))
    fi
  done < <(sysctl_file_keys "$f")
  printf '%s' "$n"
}

# Normaliza um valor de sysctl para comparacao: tabs -> espaco, colapsa
# espacos repetidos, tira espaco nas pontas (o kernel devolve TAB em chaves
# multi-valor como net.ipv4.tcp_rmem).
sysctl_norm_val() {
  printf '%s' "$1" | tr '\t' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# 0 = a chave e LEGIVEL (tem bit de leitura do dono em /proc/sys). Chaves
# write-only do kernel (net.ipv4.route.flush, vm.drop_caches, net.ipv6.route.
# flush) existem no /proc mas `sysctl -n` devolve string VAZIA com rc=0 -- se
# forem comparadas viram divergencia PERMANENTE e o validate da FAIL eterno.
# `[ -r ]` nao serve: root ignora o DAC e tudo parece legivel.
sysctl_key_readable() {
  local p m
  p="/proc/sys/${1//./\/}"
  m="$(stat -c '%a' "$p" 2>/dev/null)" || return 0
  [ -n "$m" ] || return 0
  m="${m: -3}"
  case "${m:0:1}" in 0|1|2|3) return 1 ;; esac
  return 0
}

# Chaves do arquivo que existem mas sao write-only (nao verificaveis).
# Imprime " chave" por chave (mesmo formato de sysctl_missing_keys).
sysctl_writeonly_keys() {
  local f="$1" k out=""
  [ -f "$f" ] || return 0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    [ -e "/proc/sys/${k//./\/}" ] || continue
    sysctl_key_readable "$k" || out="${out} ${k}"
  done < <(sysctl_file_keys "$f")
  printf '%s' "${out}"
}

# VERIFICACAO REAL: compara CADA chave do arquivo com o runtime (`sysctl -n`).
# Imprime uma linha "chave|valor_do_arquivo|valor_runtime" por DIVERGENCIA
# (nada se tudo bate). Chaves inexistentes neste kernel sao puladas, assim
# como as write-only (ver sysctl_key_readable).
sysctl_runtime_diff() {
  local f="$1" line k v cur
  [ -f "$f" ] || return 0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"   # trim a esquerda
    case "$line" in
      ''|'#'*|';'*) continue ;;
      *=*)          : ;;
      *)            continue ;;
    esac
    k="${line%%=*}"; v="${line#*=}"
    k="$(printf '%s' "$k" | tr -d '[:space:]')"
    k="${k#-}"
    [ -n "$k" ] || continue
    case "$k" in [!a-zA-Z]*) continue ;; esac
    [ -e "/proc/sys/${k//./\/}" ] || continue
    sysctl_key_readable "$k" || continue     # write-only: nao da para conferir
    v="$(sysctl_norm_val "$v")"
    cur="$(sysctl_norm_val "$(sysctl -n "$k" 2>/dev/null || true)")"
    [ "$v" = "$cur" ] && continue
    printf '%s|%s|%s\n' "$k" "$v" "$cur"
  done < "$f"
  return 0
}

# Atualiza SO a linha de data do cabecalho de ${SYSCTL_TARGET} (o resto do
# arquivo e do operador e NAO e tocado). A primeira linha que casa
# '^# (Gerado|Aplicado) por ... em ' vira o cabecalho novo; se nenhuma casar,
# o cabecalho e INSERIDO como primeira linha.
# Escrita atomica (tmp no mesmo dir + mv, modo 0644). Sem backup .bak: e so
# um comentario. Exige o arquivo destravado (chattr -i) -- quem chama cuida.
sysctl_touch_header() {
  local f="$1" hdr tmp
  hdr="# Aplicado por ${SCRIPT_NAME} em $(date '+%Y-%m-%d %H:%M:%S') (fonte unica: este arquivo; o script NAO reescreve o conteudo)"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') atualizaria a linha de data do cabecalho de ${f}:"
    echo "  $(c_cya '[dry-run]')   ${hdr}"
    return 0
  fi
  tmp="$(mktemp "$(dirname "$f")/.sysctl.conf.xuione.XXXXXX" 2>/dev/null)" || {
    warn "mktemp falhou em $(dirname "$f"); cabecalho de ${f} nao atualizado"
    return 0
  }
  if grep -qE '^# (Gerado|Aplicado) por .* em ' "$f" 2>/dev/null; then
    awk -v h="${hdr}" '
      BEGIN { done=0 }
      !done && /^# (Gerado|Aplicado) por .* em / { print h; done=1; next }
      { print }
    ' "$f" > "${tmp}" || { rm -f "${tmp}"; warn "falha ao gerar cabecalho novo de ${f}"; return 0; }
  else
    { printf '%s\n' "${hdr}"; cat "$f"; } > "${tmp}" || { rm -f "${tmp}"; warn "falha ao inserir cabecalho em ${f}"; return 0; }
  fi
  if [ ! -s "${tmp}" ]; then
    rm -f "${tmp}"
    warn "cabecalho: saida vazia; ${f} NAO alterado"
    return 0
  fi
  chmod 0644 "${tmp}"
  if mv -f "${tmp}" "$f"; then
    log "cabecalho de ${f} atualizado (so a linha de data; conteudo intocado)"
  else
    rm -f "${tmp}"
    warn "mv atomico falhou; cabecalho de ${f} nao atualizado"
  fi
  return 0
}

# Passos comuns a do_sysctl e do_sysctl_init, com o arquivo JA no formato que
# o operador quer:
#   b) nf_conntrack (modprobe + modules-load) se o arquivo tem net.netfilter.*
#   c) cabecalho: so a linha de data
#   d) sysctl -e -p (stderr preservado + aviso de chaves inexistentes)
#   e) verificacao real chave a chave contra o runtime
#   f) chattr +i SEMPRE + boot link + fonte unica
# NAO restaura backup em falha de sysctl -p: o conteudo e do operador e nao
# foi reescrito por nos -- nao ha o que desfazer.
sysctl_apply_lock_verify() {
  local f="${1:-${SYSCTL_TARGET}}"

  # --- b) nf_conntrack ANTES do sysctl -p ---
  # Sem o modulo, toda chave net.netfilter.nf_conntrack_* falha ("cannot stat").
  # Carrega agora e persiste em modules-load.d: no boot, systemd-sysctl roda
  # DEPOIS de systemd-modules-load, entao as chaves passam a existir quando
  # /etc/sysctl.conf e aplicado (visto em producao em 2026-08-20).
  if grep -q '^[[:space:]]*net\.netfilter\.nf_conntrack' "${f}" 2>/dev/null; then
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "  $(c_cya '[dry-run]') modprobe nf_conntrack + ${NF_CONNTRACK_MODLOAD} (chaves net.netfilter.* no arquivo)"
    else
      if [ ! -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
        if modprobe nf_conntrack 2>/dev/null; then
          ok "modulo nf_conntrack carregado (chaves net.netfilter.* disponiveis)"
        else
          warn "modprobe nf_conntrack falhou: chaves net.netfilter.* serao ignoradas (-e)"
        fi
      fi
      ensure_nf_conntrack_autoload
    fi
  fi

  # --- 1) destrava se preciso (o proprio script repoe a flag em (f)) ---
  local was_immutable=0
  if is_immutable "${f}"; then
    was_immutable=1
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "  $(c_cya '[dry-run]') chattr -i ${f}"
    else
      log "${f} esta IMUTAVEL (chattr +i) -- removendo flag temporariamente"
      chattr -i "${f}" || die "chattr -i ${f} falhou (sem CAP_LINUX_IMMUTABLE? fs sem suporte?)"
    fi
  fi

  # --- c) cabecalho: SO a linha de data ---
  sysctl_touch_header "${f}"

  local missing_keys
  missing_keys=$(sysctl_missing_keys "${f}")
  [ -n "${missing_keys}" ] && warn "chaves inexistentes neste kernel (ignoradas por -e):${missing_keys}"

  # --- d) sysctl -e -p ---
  # `-e`: ignora SO "unknown key" -- sem ele UMA chave inexistente (netfilter
  # sem nf_conntrack carregado, ipv6.* com ipv6.disable=1, ou qualquer chave de
  # terceiros) aborta o apply inteiro. Erros de escrita/EINVAL continuam
  # visiveis. O stderr e PRESERVADO para o operador saber QUAL chave reclamou.
  # Falha aqui NAO e fatal: nada foi reescrito, so avisamos e seguimos.
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') sysctl -e -p ${f}"
  else
    local sysctl_err
    if sysctl_err="$(sysctl -e -p "${f}" 2>&1 >/dev/null)"; then
      [ -n "${sysctl_err}" ] && warn "sysctl -p avisos: ${sysctl_err}"
      ok "sysctl -p ${f} aplicado"
    else
      nok "sysctl -p ${f} falhou: ${sysctl_err:-<sem stderr>} (arquivo MANTIDO -- corrija a mao)"
    fi
  fi

  # --- e) verificacao real: cada chave do arquivo vs runtime ---
  sysctl_report_runtime "${f}" || true

  # --- f) chattr +i SEMPRE: politica = arquivo travado contra edicao acidental
  #        e sobrescrita pelo painel XUI; o proprio script tira e repoe a flag ---
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') chattr +i ${f}"
  elif chattr +i "${f}" 2>/dev/null; then
    if [ "$was_immutable" -eq 1 ]; then
      log "flag immutable (chattr +i) restaurada em ${f}"
    else
      ok "chattr +i ${f} (travado)"
    fi
  else
    warn "chattr +i ${f} falhou (fs sem suporte?) -- arquivo ficou SEM protecao immutable"
  fi

  # --- f2) persistencia no boot + conflitos com sysctl.d ---
  ensure_sysctl_boot_link "${f}"
  enforce_single_sysctl_source "${f}"
  return 0
}

# Imprime "N/M chaves do arquivo em vigor" + lista as divergentes.
# M = chaves VERIFICAVEIS (existem neste kernel e sao legiveis); as write-only
# saem do denominador e viram uma linha informativa, nunca divergencia.
# Retorna 1 se ha divergencia (usado pelo validate para marcar FAIL).
sysctl_report_runtime() {
  local f="${1:-${SYSCTL_TARGET}}" total diverg n_div k fv rv wo n_wo=0
  total=$(sysctl_key_count "${f}")
  wo="$(sysctl_writeonly_keys "${f}")"
  if [ -n "${wo}" ]; then
    n_wo=$(printf '%s' "${wo}" | wc -w)
    total=$((total - n_wo))
    log "  ${n_wo} chave(s) write-only, nao verificaveis (fora do denominador):${wo}"
  fi
  diverg="$(sysctl_runtime_diff "${f}")"
  if [ -z "${diverg}" ]; then
    n_div=0
  else
    n_div=$(printf '%s\n' "${diverg}" | wc -l)
  fi
  if [ "${n_div}" -eq 0 ]; then
    ok "${total}/${total} chaves do arquivo em vigor no runtime"
    return 0
  fi
  nok "$((total - n_div))/${total} chaves do arquivo em vigor -- ${n_div} divergente(s):"
  while IFS='|' read -r k fv rv; do
    [ -n "${k}" ] || continue
    log "  ${k} (arquivo=${fv} runtime=${rv:-<vazio>})"
  done <<< "${diverg}"
  return 1
}

# do_sysctl: /etc/sysctl.conf e a FONTE UNICA DE VERDADE (2026-08-20).
# O script NAO gera mais o conteudo no apply -- ele so:
#   a) checa que o arquivo existe e tem chaves (senao AVISA e pula a fase)
#   b) garante nf_conntrack (chaves net.netfilter.* precisam do modulo)
#   c) atualiza SO a linha de data do cabecalho (in-place, atomico)
#   d) sysctl -e -p
#   e) confere CADA chave do arquivo contra o runtime (N/M em vigor)
#   f) chattr +i + symlink de boot + fonte unica (sysctl.d)
# Para GERAR o arquivo a partir do template embutido: apply --sysctl-init.
do_sysctl() {
  require_root
  section "sysctl: ${SYSCTL_TARGET} (fonte unica -- o script nao reescreve o conteudo)"

  # --- a) sem arquivo / sem chaves: NAO gera sozinho ---
  if [ ! -f "${SYSCTL_TARGET}" ] || ! sysctl_file_has_keys "${SYSCTL_TARGET}"; then
    warn "sem configuracao em ${SYSCTL_TARGET}; gere com --sysctl-init"
    warn "  (o arquivo e a fonte unica de verdade: o apply nunca escreve o conteudo dele)"
    log  "fase de sysctl PULADA (nao e erro fatal)"
    return 0
  fi

  log "arquivo do operador: $(sysctl_key_count "${SYSCTL_TARGET}") chaves validas neste kernel ($(wc -l < "${SYSCTL_TARGET}") linhas)"
  sysctl_apply_lock_verify "${SYSCTL_TARGET}"

  # Verbose: lista chaves cruciais
  if [ "${VERBOSE}" -eq 1 ]; then
    local k
    for k in net.core.rmem_max net.core.wmem_max net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_max_orphans kernel.sched_autogroup_enabled; do
      log "  ${k} = $(sysctl -n "${k}" 2>/dev/null || echo '?')"
    done
  fi
  return 0
}

# sysctl_init_guard [force]: recusa (die) quando ${SYSCTL_TARGET} ja tem chaves
# e o operador nao passou --sysctl-init-force. Chamado DUAS vezes: cedo em
# cmd_apply (para 'apply --all --sysctl-init' nao morrer no meio das fases, com
# irqbalance ja desligado) e dentro de do_sysctl_init (caminho direto).
sysctl_init_guard() {
  local force="${1:-0}"
  [ "${force}" -eq 1 ] && return 0
  if [ -f "${SYSCTL_TARGET}" ] && sysctl_file_has_keys "${SYSCTL_TARGET}"; then
    die "${SYSCTL_TARGET} ja tem chaves configuradas -- --sysctl-init NAO sobrescreve.
       O arquivo e a FONTE UNICA de verdade (o script nunca reescreve o conteudo).
       Edite a mao:  chattr -i ${SYSCTL_TARGET} && vim ${SYSCTL_TARGET} && chattr +i ${SYSCTL_TARGET}
       Ou, se quiser MESMO regerar do template: apply --sysctl-init-force (faz backup antes)."
  fi
  return 0
}

# Repoe o chattr +i (quando o arquivo estava imutavel) ANTES de abortar.
# Usado nos caminhos de erro de do_sysctl_init: sair com ${SYSCTL_TARGET}
# destravado deixaria o arquivo exposto a sobrescrita pelo painel XUI ate a
# proxima execucao manual do script -- exatamente o que o chattr evita.
sysctl_init_die() {
  local was_immutable="${1:-0}"; shift
  if [ "${was_immutable}" -eq 1 ]; then
    chattr +i "${SYSCTL_TARGET}" 2>/dev/null || true
  fi
  die "$@"
}

# do_sysctl_init [force]: UNICO caminho que ainda usa sysctl_template().
# Gera ${SYSCTL_TARGET} do zero. RECUSA se o arquivo ja tem qualquer chave
# (o conteudo e do operador) -- salvo force=1 (--sysctl-init-force), que faz
# backup .bak.<script>.<ts> antes de sobrescrever.
do_sysctl_init() {
  local force="${1:-0}"
  require_root
  section "sysctl: --sysctl-init (gera ${SYSCTL_TARGET} do template embutido)"

  sysctl_init_guard "${force}"
  if [ "${force}" -eq 1 ] && [ -f "${SYSCTL_TARGET}" ] && sysctl_file_has_keys "${SYSCTL_TARGET}"; then
    warn "--sysctl-init-force: ${SYSCTL_TARGET} sera REGERADO do template (backup antes)"
  fi

  local was_immutable=0
  is_immutable "${SYSCTL_TARGET}" && was_immutable=1

  local ts bak bak_done=0
  ts=$(date +%Y%m%d-%H%M%S)
  bak="${SYSCTL_TARGET}.bak.${SCRIPT_NAME%.sh}.${ts}"

  if [ "${DRY_RUN}" -eq 1 ]; then
    [ "$was_immutable" -eq 1 ] && echo "  $(c_cya '[dry-run]') chattr -i ${SYSCTL_TARGET}"
    [ -f "${SYSCTL_TARGET}" ] && echo "  $(c_cya '[dry-run]') backup ${SYSCTL_TARGET} -> ${bak}"
    echo "  $(c_cya '[dry-run]') gerar ${SYSCTL_TARGET} do template embutido ($(sysctl_template | wc -l) linhas)"
    echo "  $(c_cya '[dry-run]') a verificacao abaixo compara o arquivo ATUAL com o runtime (o template ainda nao foi gerado)"
    sysctl_apply_lock_verify "${SYSCTL_TARGET}"
    return 0
  fi

  if [ "$was_immutable" -eq 1 ]; then
    chattr -i "${SYSCTL_TARGET}" || die "chattr -i ${SYSCTL_TARGET} falhou (sem CAP_LINUX_IMMUTABLE? fs sem suporte?)"
  fi
  # Backup OBRIGATORIO antes de sobrescrever a fonte unica do operador: se o
  # cp falhar (disco cheio, /etc read-only, EIO) abortamos SEM tocar no arquivo.
  # Com `&&` o cp ficaria isento do errexit e o mv abaixo destruiria a config.
  if [ -f "${SYSCTL_TARGET}" ]; then
    cp -a "${SYSCTL_TARGET}" "${bak}" \
      || sysctl_init_die "${was_immutable}" "backup ${bak} falhou -- --sysctl-init-force ABORTADO (${SYSCTL_TARGET} NAO foi tocado)"
    bak_done=1
    log "backup em ${bak}"
  fi

  # Todos os caminhos de erro daqui para baixo passam por sysctl_init_die, que
  # repoe o chattr +i antes de sair (o arquivo original fica intacto e travado).
  local tmp; tmp="$(mktemp "$(dirname "${SYSCTL_TARGET}")/.sysctl.conf.xuione.XXXXXX")" \
    || sysctl_init_die "${was_immutable}" "mktemp falhou em $(dirname "${SYSCTL_TARGET}")"
  if sysctl_template > "${tmp}" && [ -s "${tmp}" ]; then
    chmod 0644 "${tmp}"
    mv -f "${tmp}" "${SYSCTL_TARGET}" \
      || { rm -f "${tmp}"; sysctl_init_die "${was_immutable}" "falha ao publicar ${SYSCTL_TARGET}$([ "${bak_done}" -eq 1 ] && printf ' (backup em %s)' "${bak}")"; }
  else
    rm -f "${tmp}"
    sysctl_init_die "${was_immutable}" "falha ao gerar ${SYSCTL_TARGET} a partir do template"
  fi
  ok "${SYSCTL_TARGET} gerado do template ($(wc -l < "${SYSCTL_TARGET}") linhas) -- a partir de agora ele e a fonte unica"

  sysctl_apply_lock_verify "${SYSCTL_TARGET}"
  return 0
}

# ---------------------------------------------------------------------------
# nf_conntrack x sysctl: as chaves net.netfilter.nf_conntrack_* do arquivo so
# existem com o modulo carregado. Persistir em modules-load.d garante que o
# systemd-sysctl do boot (que roda DEPOIS de systemd-modules-load) as encontre.
# Removido por do_sysctl_remove (rollback).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# sysctl no BOOT: systemd-sysctl so le /etc/sysctl.conf via o symlink
# /etc/sysctl.d/99-sysctl.conf (convencao Debian/Ubuntu). Sem ele, o arquivo
# que o operador mantem e ignorado no boot ate a unit rodar. Tambem detecta
# chaves em sysctl.d que CONFLITAM com as nossas: systemd-sysctl aplica em
# ordem lexical de basename e o ULTIMO vence.
# ---------------------------------------------------------------------------
SYSCTL_BOOT_LINK="/etc/sysctl.d/99-sysctl.conf"
ensure_sysctl_boot_link() {
  local target="${1:-/etc/sysctl.conf}"
  if [ -L "${SYSCTL_BOOT_LINK}" ] && [ "$(readlink -f "${SYSCTL_BOOT_LINK}" 2>/dev/null)" = "${target}" ]; then
    return 0
  fi
  if [ -e "${SYSCTL_BOOT_LINK}" ]; then
    warn "${SYSCTL_BOOT_LINK} existe mas nao aponta para ${target}: o boot pode ignorar o arquivo"
    return 0
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "[dry-run] ln -s ../sysctl.conf ${SYSCTL_BOOT_LINK} (systemd-sysctl passa a ler ${target} no boot)"
    return 0
  fi
  if ln -s ../sysctl.conf "${SYSCTL_BOOT_LINK}" 2>/dev/null; then
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
    [ -f "${f}" ] || continue
    [ -L "${f}" ] && continue
    base=$(basename "${f}")
    while IFS= read -r k; do
      [ -n "${k}" ] || continue
      k_re=$(printf '%s' "${k}" | sed 's/[.]/\\./g')
      ours=$(grep -E "^[[:space:]]*${k_re}[[:space:]]*=" "${ours_file}" 2>/dev/null | tail -1 | sed 's/.*=[[:space:]]*//' | tr -s ' \t' ' ')
      [ -n "${ours}" ] || continue
      theirs=$(grep -E "^[[:space:]]*${k_re}[[:space:]]*=" "${f}" 2>/dev/null | tail -1 | sed 's/.*=[[:space:]]*//' | tr -s ' \t' ' ')
      [ "${ours}" = "${theirs}" ] && continue
      if [ "$(printf '%s\n%s\n' "${base}" "99-sysctl.conf" | sort | tail -1)" = "99-sysctl.conf" ]; then
        win="sysctl.conf"
      else
        win="${base}"
      fi
      printf '%s|%s|%s|%s|%s|%s\n' "${k}" "${base}" "${theirs}" "${ours}" "${win}" "$(dirname "${f}")"
    done < <(grep -E '^[[:space:]]*[a-z]' "${f}" 2>/dev/null | sed 's/[[:space:]]*=.*//; s/^[[:space:]]*//')
  done
  return 0
}
# Politica FONTE UNICA (decisao do operador, 2026-08-20): /etc/sysctl.conf e a
# UNICA configuracao de sysctl administrada. Arquivos em /etc/sysctl.d que
# conflitam com ela sao desativados (renomeados para .conf.disabled-by-xuione;
# systemd-sysctl so le *.conf) -- reversivel no rollback. Arquivos de distro
# em /usr/lib/sysctl.d e /run nao sao tocados: o 99-sysctl.conf ja os
# sobrescreve pela ordem lexical, e mascara-los derrubaria defaults alheios.
enforce_single_sysctl_source() {
  local ours_file="${1:-/etc/sysctl.conf}" k base theirs ours win dir f lost kk n=0 done_files=" "
  while IFS='|' read -r k base theirs ours win dir; do
    n=$((n + 1))
    if [ "${dir}" != "/etc/sysctl.d" ]; then
      log "sysctl: ${k}=${theirs} em ${dir}/${base} (distro) e sobrescrito por sysctl.conf (${ours}) pela ordem; sem acao"
      continue
    fi
    f="${dir}/${base}"
    case "${done_files}" in *" ${f} "*) continue ;; esac
    done_files="${done_files}${f} "
    if [ "${DRY_RUN}" -eq 1 ]; then
      log "[dry-run] mv ${f} ${f}.disabled-by-xuione (conflita: ${k}=${theirs} vs ${ours} em sysctl.conf)"
      continue
    fi
    lost=""
    while IFS= read -r kk; do
      [ -n "${kk}" ] || continue
      grep -qE "^[[:space:]]*$(printf '%s' "${kk}" | sed 's/[.]/\\./g')[[:space:]]*=" "${ours_file}" 2>/dev/null || lost="${lost} ${kk}"
    done < <(grep -E '^[[:space:]]*[a-z]' "${f}" 2>/dev/null | sed 's/[[:space:]]*=.*//; s/^[[:space:]]*//')
    if mv -f "${f}" "${f}.disabled-by-xuione"; then
      ok "fonte unica: ${f} desativado (conflitava: ${k}=${theirs} vs ${ours} em sysctl.conf)"
      # O template embutido so serve ao bootstrap (--sysctl-init): mandar o
      # operador edita-lo nao teria efeito nenhum num host ja instalado. O
      # destino certo e o proprio ${ours_file}, a fonte unica.
      [ -n "${lost}" ] && warn "  chaves de ${base} ausentes em ${ours_file} (adicione a mao se precisar: chattr -i ${ours_file} && vim ${ours_file} && chattr +i ${ours_file}):${lost}"
    else
      warn "nao consegui desativar ${f}; continua conflitando (vence pela ordem: ${win})"
    fi
  done < <(sysctl_d_conflicts "${ours_file}")
  [ "${n}" -eq 0 ] && log "fonte unica OK: nenhum conflito entre sysctl.d/* e ${ours_file}"
  return 0
}
# rollback: reativa o que o apply desativou.
# Publica em RESTORED_SYSCTL_D_N quantos arquivos foram (ou seriam) reativados,
# para quem chama decidir se precisa recarregar (`sysctl --system`).
RESTORED_SYSCTL_D_N=0
restore_disabled_sysctl_d() {
  local df
  RESTORED_SYSCTL_D_N=0
  for df in /etc/sysctl.d/*.conf.disabled-by-xuione; do
    [ -f "${df}" ] || continue
    if [ "${DRY_RUN}" -eq 1 ]; then
      log "[dry-run] mv ${df} ${df%.disabled-by-xuione}"
      RESTORED_SYSCTL_D_N=$((RESTORED_SYSCTL_D_N+1))
      continue
    fi
    if mv -f "${df}" "${df%.disabled-by-xuione}"; then
      ok "reativado ${df%.disabled-by-xuione} (fonte unica desfeita)"
      RESTORED_SYSCTL_D_N=$((RESTORED_SYSCTL_D_N+1))
    else
      warn "nao consegui reativar ${df}"
    fi
  done
  return 0
}

NF_CONNTRACK_MODLOAD="/etc/modules-load.d/xuione-nf_conntrack.conf"
ensure_nf_conntrack_autoload() {
  if grep -qsxE '[[:space:]]*nf_conntrack[[:space:]]*' /etc/modules /etc/modules-load.d/*.conf 2>/dev/null; then
    [ -f "${NF_CONNTRACK_MODLOAD}" ] || log "nf_conntrack ja em modules-load (arquivo de terceiros); nada a fazer"
    return 0
  fi
  if printf '# xuione-tune: carrega nf_conntrack ANTES de systemd-sysctl, senao as chaves\n# net.netfilter.nf_conntrack_* de /etc/sysctl.conf nao existem no boot.\nnf_conntrack\n' > "${NF_CONNTRACK_MODLOAD}"; then
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

# do_sysctl_remove: rollback do sysctl.
# MUDANCA 2026-08-20 (fonte unica): NAO apaga mais nada de ${SYSCTL_TARGET} --
# o conteudo do arquivo e do OPERADOR, nao foi gerado por este script no apply
# e portanto nao ha bloco nosso para remover. O rollback se limita ao que o
# apply de fato criou por fora do arquivo:
#   - ${NF_CONNTRACK_MODLOAD} (autoload do nf_conntrack)
#   - arquivos de /etc/sysctl.d desativados por enforce_single_sysctl_source
# Os valores de kernel continuam em vigor: para reverte-los, edite o arquivo
# (chattr -i -> vim -> chattr +i) e rode `sysctl -p`.
do_sysctl_remove() {
  require_root

  if [ -f "${NF_CONNTRACK_MODLOAD}" ]; then
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "  $(c_cya '[dry-run]') rm -f ${NF_CONNTRACK_MODLOAD}"
    else
      rm -f "${NF_CONNTRACK_MODLOAD}" && log "removido ${NF_CONNTRACK_MODLOAD} (rollback)"
    fi
  fi

  restore_disabled_sysctl_d
  # Renomear de volta NAO reaplica: os valores dos arquivos reativados so
  # entrariam em vigor no proximo boot. Recarrega agora (nunca em dry-run --
  # o guard e o fix desta rodada) e sem `set -e` matar o resto do rollback.
  if [ "${RESTORED_SYSCTL_D_N}" -gt 0 ]; then
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "  $(c_cya '[dry-run]') sysctl --system (reaplica os ${RESTORED_SYSCTL_D_N} arquivo(s) de /etc/sysctl.d reativados)"
    else
      if sysctl --system >/dev/null 2>&1; then
        ok "sysctl --system: arquivos de /etc/sysctl.d reativados ja em vigor"
      else
        warn "sysctl --system retornou erro; os arquivos reativados so valem no proximo boot (rollback continua)"
      fi
    fi
  fi

  log "${SYSCTL_TARGET} MANTIDO INTACTO (fonte unica do operador -- o script nao escreve o conteudo)"
  log "  para desfazer valores de kernel: chattr -i ${SYSCTL_TARGET} && vim ${SYSCTL_TARGET} && chattr +i ${SYSCTL_TARGET} && sysctl -p ${SYSCTL_TARGET}"
  if is_immutable "${SYSCTL_TARGET}"; then
    log "  (arquivo segue travado com chattr +i -- rollback nao destrava por seguranca)"
  fi
  return 0
}

# modprobe_template: conteudo do blacklist irdma (embedded desde 2026-08-20).
# Antes vinha do arquivo externo ${MODPROBE_SRC}, que nao existe mais no repo
# -- o require_file matava `apply --all` na FASE 2, DEPOIS de do_sysctl ja ter
# reescrito /etc/sysctl.conf (estado meio-aplicado).
# Conteudo IDENTICO ao que ja esta instalado em producao (byte a byte), para
# que do_modprobe seja no-op nos hosts que ja tem o arquivo.
modprobe_template() {
  cat <<'EOF'
# /etc/modprobe.d/blacklist-irdma.conf
# Bloqueia o irdma (iWARP/RDMA) que falha em carregar com este firmware do E810
# e polui o dmesg. Sem efeito em HTTP/HLS.
blacklist irdma
EOF
}

do_modprobe() {
  require_root
  section "modprobe: blacklist irdma"
  # Se o template externo ainda existir no repo, ele tem precedencia (permite
  # override manual); senao usa o embedded.
  local desired
  if [ -f "${MODPROBE_SRC}" ]; then
    desired="$(cat "${MODPROBE_SRC}")"
  else
    desired="$(modprobe_template)"
  fi
  if [ -f "${MODPROBE_DST}" ] && [ "$(cat "${MODPROBE_DST}")" = "${desired}" ]; then
    ok "${MODPROBE_DST} ja consolidado (idempotente)"
    return 0
  fi
  log "escrevendo ${MODPROBE_DST} (efeito no proximo boot)"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') escreveria ${MODPROBE_DST} ($(printf '%s\n' "${desired}" | wc -l) linhas)"
  else
    printf '%s\n' "${desired}" > "${MODPROBE_DST}"
    chmod 0644 "${MODPROBE_DST}"
  fi
  if [ "${DRY_RUN}" -eq 0 ]; then
    if [ -f "${MODPROBE_DST}" ]; then
      ok "blacklist instalado em ${MODPROBE_DST}"
      if lsmod 2>/dev/null | grep -q '^irdma'; then
        warn "irdma ainda CARREGADO -- blacklist so vale no proximo boot (ou rmmod manual)"
      else
        ok "irdma nao carregado neste kernel"
      fi
    else
      nok "${MODPROBE_DST} nao foi criado"
    fi
  fi
}

do_irqbalance() {
  require_root
  local target="${1:-off}"
  section "irqbalance: ${target}"
  case "${target}" in
    off) if systemctl is-active --quiet irqbalance.service 2>/dev/null \
            || systemctl is-enabled --quiet irqbalance.service 2>/dev/null; then
           log "parando e desabilitando irqbalance"
           run "systemctl stop irqbalance.service 2>&1 || true"
           run "systemctl disable irqbalance.service 2>&1 || true"
         else
           log "irqbalance ja inativo e desabilitado (idempotente)"
         fi ;;
    on)  log "ligando irqbalance"
         run "systemctl enable --now irqbalance 2>&1 || true" ;;
    *)   die "irqbalance: use 'on' ou 'off'" ;;
  esac
  if [ "${DRY_RUN}" -eq 0 ]; then
    local act
    act=$(systemctl is-active irqbalance 2>&1 | head -1)
    if [ "${target}" = "on" ]; then
      # 'on' so aceita 'active' (failed/inactive sao erro real)
      [ "${act}" = "active" ] && ok "irqbalance: active" || nok "irqbalance: ${act} (esperado active)"
    else
      # 'off' aceita inactive, failed, ou ausente (todos = nao roda)
      case "${act}" in
        active) nok "irqbalance: active (esperado inactive)" ;;
        *)      ok "irqbalance: ${act:-inactive}" ;;
      esac
    fi
  fi
}

do_queues() {
  require_root; ensure_nic
  [ "${QUEUES}" -gt 0 ] || die "do_queues: QUEUES nao calculado (compute_plan() faltando)"
  section "ethtool -L: combined queues = ${QUEUES} em ${NIC}"
  local cur
  cur=$(ethtool -l "${NIC}" 2>/dev/null | awk '/Current hardware settings/{f=1} f && /Combined:/{print $2; exit}')
  if [ "${cur}" = "${QUEUES}" ]; then
    log "filas ja em ${QUEUES} (skip)"
    ok "combined queues = ${QUEUES}"
    return 0
  fi
  log "ethtool -L ${NIC} combined ${QUEUES} (atual=${cur})"
  run "ethtool -L ${NIC} combined ${QUEUES}"
  run "sleep 1"
  if [ "${DRY_RUN}" -eq 0 ]; then
    local pos
    pos=$(ethtool -l "${NIC}" 2>/dev/null | awk '/Current hardware settings/{f=1} f && /Combined:/{print $2; exit}')
    verify_eq "combined queues" "${QUEUES}" "${pos}"
  fi
}

# Reconstroi a tabela de indirecao RSS para distribuir uniformemente sobre
# rings 0..QUEUES-1. Defesa contra drivers (mlx5, bnxt) que preservam a
# tabela antiga apos `ethtool -L combined` -- a tabela velha pode citar
# apenas as primeiras N/2 rings, deixando metade das IRQs sem trafego.
# ice (Intel E810) reseta automaticamente, mas reaplicar e idempotente e
# protege contra regressao de driver.
do_rss() {
  require_root; ensure_nic
  [ "${QUEUES}" -gt 0 ] || die "do_rss: QUEUES nao calculado (compute_plan() faltando)"
  section "ethtool -X: tabela RSS equal sobre ${QUEUES} rings em ${NIC}"
  log "ethtool -X ${NIC} equal ${QUEUES}"
  run "ethtool -X ${NIC} equal ${QUEUES} 2>&1 || true"
  if [ "${DRY_RUN}" -eq 0 ]; then
    # Le rings citados na indir table; valida (a) nenhum fora de [0,QUEUES-1]
    # e (b) que TODAS as QUEUES rings sao usadas. Detecta o bug Mellanox em
    # qualquer NIC futura sem rodar profile completo.
    local rings_used n_distinct out_of_range
    rings_used=$(ethtool -x "${NIC}" 2>/dev/null \
      | awk '/^[[:space:]]+[0-9]+:/{for(i=2;i<=NF;i++) print $i}' \
      | sort -un)
    if [ -z "${rings_used}" ]; then
      nok "tabela RSS vazia ou ethtool -x nao suportado em ${NIC}"
      return 0
    fi
    out_of_range=$(echo "${rings_used}" | awk -v q="${QUEUES}" '$1+0 >= q+0 {print $1}' | tr '\n' ' ')
    if [ -n "${out_of_range}" ]; then
      nok "RSS table cita rings fora de [0,$((QUEUES-1))]: ${out_of_range}"
    else
      ok "RSS table so usa rings [0,$((QUEUES-1))]"
    fi
    n_distinct=$(echo "${rings_used}" | wc -l)
    verify_eq "rings distintos na RSS table" "${QUEUES}" "${n_distinct}"
  fi
}

do_ring() {
  require_root; ensure_nic
  section "ethtool -G: ring buffers RX/TX = 8160 em ${NIC}"
  log "ring buffers RX/TX = 8160 (max do hw)"
  run "ethtool -G ${NIC} rx 8160 tx 8160 2>&1 || true"
  if [ "${DRY_RUN}" -eq 0 ]; then
    local rx tx
    rx=$(ethtool -g "${NIC}" 2>/dev/null | awk '/Current hardware/{f=1} f && /^RX:/{print $2; exit}')
    tx=$(ethtool -g "${NIC}" 2>/dev/null | awk '/Current hardware/{f=1} f && /^TX:/{print $2; exit}')
    verify_eq "ring RX" "8160" "${rx}"
    verify_eq "ring TX" "8160" "${tx}"
  fi
}

# IRQ pinning -- usa plano calculado por compute_plan():
#   - avisa se irqbalance esta ativo
#   - 1 IRQ por CPU em IRQ_CPUS_ARR (na ordem das filas)
#   - escreve hex em /proc/irq/N/smp_affinity (build_irq_mask)
#   - valida contra smp_affinity efetiva apos escrever
do_irq() {
  require_root; ensure_nic
  [ "${#IRQ_CPUS_ARR[@]}" -gt 0 ] || die "do_irq: plano vazio (compute_plan() faltando)"
  section "IRQ pinning: ${TARGET_IRQS} IRQs distribuidos em ${NUM_CCX} CCXes (CCX-aware) em ${NIC}"

  if systemctl is-active irqbalance >/dev/null 2>&1; then
    warn "irqbalance esta ATIVO -- vai sobrescrever a afinidade. Considere: apply --irqbalance off"
  fi

  local irqs; irqs="$(discover_nic_irqs)"
  [ -n "$irqs" ] || die "nenhum IRQ encontrado para ${NIC} (rodou 'apply --nic-all' primeiro?)"
  local nirqs; nirqs="$(echo $irqs | wc -w)"
  local nplan="${#IRQ_CPUS_ARR[@]}"

  if [ "$nirqs" -ne "$nplan" ]; then
    warn "IRQs descobertos (${nirqs}) != plano (${nplan}); usando round-robin sobre o plano"
  fi

  log "IRQ pinning: ${nirqs} IRQs em ${nplan} CPUs do plano (--irqs ${TARGET_IRQS}, ${NUM_CCX} CCXes)"

  local i=0 irq core mask hint_norm act_norm mismatches=0
  for irq in $irqs; do
    core="${IRQ_CPUS_ARR[$((i % nplan))]}"
    mask="$(build_irq_mask "$core")"
    # Mostra os 3 primeiros + "... (omitindo N)" antes de processar o resto silencioso
    if [ "${DRY_RUN}" -eq 1 ]; then
      if [ "$i" -lt "$RUN_CAP_LIMIT" ]; then
        echo "      $(c_cya '[dry-run]') echo $mask > /proc/irq/${irq}/smp_affinity  (core=${core})"
      elif [ "$i" -eq "$RUN_CAP_LIMIT" ]; then
        echo "      $(c_cya '[dry-run]') ... (omitindo $((nirqs - RUN_CAP_LIMIT)) IRQs similares)"
      fi
    else
      if [ "${VERBOSE}" -eq 1 ]; then
        if [ "$i" -lt "$RUN_CAP_LIMIT" ]; then
          echo "      $(c_cya '$') echo $mask > /proc/irq/${irq}/smp_affinity  (core=${core})"
        elif [ "$i" -eq "$RUN_CAP_LIMIT" ]; then
          echo "      $(c_cya '$') ... (omitindo $((nirqs - RUN_CAP_LIMIT)) IRQs similares)"
        fi
      fi
      printf "%s" "$mask" > "/proc/irq/${irq}/smp_affinity" 2>/dev/null || \
        warn "falhou gravar smp_affinity de IRQ ${irq}"
      act_norm="$(sed -E 's/^[,0]+//' /proc/irq/${irq}/smp_affinity 2>/dev/null | tr 'a-f' 'A-F')"
      hint_norm="$(echo "$mask" | sed -E 's/^[,0]+//' | tr 'a-f' 'A-F')"
      if [ "$act_norm" != "$hint_norm" ]; then
        warn "IRQ ${irq}: smp_affinity efetiva=${act_norm} (esperado ${hint_norm})"
        mismatches=$((mismatches+1))
      fi
    fi
    i=$((i+1))
  done
  log "IRQs processados: ${i}"
  if [ "${DRY_RUN}" -eq 0 ]; then
    if [ "${mismatches}" -eq 0 ]; then
      ok "IRQ pinning: ${i}/${i} alinhados com plano (CCX-aware)"
    else
      warn "${mismatches} IRQ(s) com afinidade divergente apos gravacao"
      nok "IRQ pinning: $((i - mismatches))/${i} alinhados, ${mismatches} divergentes"
    fi
  fi
}

# XPS: fila N -> {IRQ_CPUS_ARR[N], SMT sibling desse core} (mesmo core fisico)
do_xps() {
  require_root; ensure_nic
  [ "${#IRQ_CPUS_ARR[@]}" -gt 0 ] || die "do_xps: plano vazio (compute_plan() faltando)"
  section "XPS: ${QUEUES} filas TX (cada fila N -> {core, SMT sibling}) em ${NIC}"
  log "fila N -> {IRQ_CPUS[N], SMT sibling} (par SMT do mesmo core fisico)"
  # Clampa pelo numero REAL de filas TX: `apply --xps` isolado nao roda
  # do_queues, entao a NIC pode ainda ter menos filas que o plano -- escrever
  # em tx-N inexistente mata o script (set -e) na 1a fila.
  local ntx=0 nq="${QUEUES}" _tq
  for _tq in "/sys/class/net/${NIC}/queues/"tx-*; do
    if [ -d "${_tq}" ]; then ntx=$((ntx+1)); fi
  done
  if [ "${ntx}" -gt 0 ] && [ "${ntx}" -lt "${nq}" ]; then
    warn "NIC tem ${ntx} filas TX, plano pede ${nq} (rode 'apply --irq' ou '--nic-all' antes); aplicando XPS em ${ntx}"
    nq="${ntx}"
  fi
  local q core sib mask
  for q in $(seq 0 $((nq-1))); do
    core="${IRQ_CPUS_ARR[$q]}"
    sib="$(smt_sibling_of "$core")"
    mask=$(mask_for_two_cpus "$core" "$sib")
    run_cap "$q" "$nq" "echo ${mask} > /sys/class/net/${NIC}/queues/tx-${q}/xps_cpus"
  done
  if [ "${DRY_RUN}" -eq 0 ]; then
    local fail=0 actual expected
    for q in $(seq 0 $((nq-1))); do
      core="${IRQ_CPUS_ARR[$q]}"
      sib="$(smt_sibling_of "$core")"
      expected=$(mask_for_two_cpus "$core" "$sib")
      actual=$(cat /sys/class/net/${NIC}/queues/tx-${q}/xps_cpus 2>/dev/null)
      [ "$actual" != "$expected" ] && fail=$((fail+1))
    done
    if [ "${fail}" -eq 0 ]; then
      ok "XPS: ${nq}/${nq} filas com mask {core, sibling} correto"
    else
      nok "XPS: ${fail}/${nq} filas divergentes"
    fi
  fi
}

# RFS/RPS: zera RPS (so RSS hardware) e configura RFS conforme RFS_PER_QUEUE.
# Se RFS_PER_QUEUE=0 (default), RFS fica DESLIGADO -- evita o gargalo de
# lookup em workloads com muitos flows TCP. Use --rfs-per-queue N para ligar.
do_rfs() {
  require_root; ensure_nic
  local total=$((QUEUES * RFS_PER_QUEUE)) q
  if [ "${RFS_PER_QUEUE}" -le 0 ]; then
    section "RFS/RPS: DESLIGADOS em ${NIC} (RFS_PER_QUEUE=0)"
  else
    section "RFS/RPS: RFS=${RFS_PER_QUEUE}/fila em ${NIC} (total=${total})"
  fi
  log "RPS=0 em todas as filas RX (${QUEUES} filas)"
  local i=0 q
  for q in /sys/class/net/${NIC}/queues/rx-*/rps_cpus; do
    run_cap "$i" "$QUEUES" "echo 0 > ${q}"
    i=$((i+1))
  done
  if [ "${RFS_PER_QUEUE}" -le 0 ]; then
    log "RFS DESLIGADO (rps_flow_cnt=0 e rps_sock_flow_entries=0)"
    run "sysctl -w net.core.rps_sock_flow_entries=0 >/dev/null"
    i=0
    for q in /sys/class/net/${NIC}/queues/rx-*/rps_flow_cnt; do
      run_cap "$i" "$QUEUES" "echo 0 > ${q}"
      i=$((i+1))
    done
    if [ "${DRY_RUN}" -eq 0 ]; then
      verify_eq "rx-0 rps_flow_cnt" "0" "$(cat /sys/class/net/${NIC}/queues/rx-0/rps_flow_cnt 2>/dev/null)"
      verify_eq "rps_sock_flow_entries" "0" "$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)"
    fi
    return 0
  fi
  log "RFS por fila = ${RFS_PER_QUEUE}, global rps_sock_flow_entries = ${total}"
  run "sysctl -w net.core.rps_sock_flow_entries=${total} >/dev/null"
  i=0
  for q in /sys/class/net/${NIC}/queues/rx-*/rps_flow_cnt; do
    run_cap "$i" "$QUEUES" "echo ${RFS_PER_QUEUE} > ${q}"
    i=$((i+1))
  done
  if [ "${DRY_RUN}" -eq 0 ]; then
    verify_eq "rx-0 rps_flow_cnt" "${RFS_PER_QUEUE}" "$(cat /sys/class/net/${NIC}/queues/rx-0/rps_flow_cnt 2>/dev/null)"
    verify_eq "rps_sock_flow_entries" "${total}" "$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)"
  fi
}

do_coalesce() {
  require_root; ensure_nic
  section "ethtool -C: coalesce em ${NIC}"
  log "coalesce adaptive on, rx-usecs=50, tx-usecs=50"
  run "ethtool -C ${NIC} adaptive-rx on adaptive-tx on rx-usecs 50 tx-usecs 50 2>&1 || true"
  # Offloads gerais (gro/gso/tso/checksums/...) agora em do_offloads (24 features).
  # Mantemos ntuple-filters=off aqui pois nao esta na lista de OFFLOAD_FEATURES_ON_DEFAULT.
  log "ntuple-filters off (RSS via RX hashing, sem ntuple rules manuais)"
  run "ethtool -K ${NIC} ntuple off 2>&1 || true"
  if [ "${DRY_RUN}" -eq 0 ]; then
    local arx atx nt
    arx=$(ethtool -c "${NIC}" 2>/dev/null | awk '/Adaptive RX/{print $3; exit}')
    atx=$(ethtool -c "${NIC}" 2>/dev/null | awk '/Adaptive RX/{print $5; exit}')
    nt=$(ethtool -k "${NIC}" 2>/dev/null | awk -F: '/^ntuple-filters:/{gsub(/ /,"",$2); print $2; exit}')
    verify_eq "adaptive-rx" "on" "${arx}"
    verify_eq "adaptive-tx" "on" "${atx}"
    verify_eq "ntuple-filters" "off" "${nt}"
  fi
}

# do_napi_defer: NAPI deferral via sysfs (portado de xuione-ccd-net.sh)
# Configura busy-wait pos-RX para reduzir taxa de IRQs em workload pesado.
# Idempotente: leitura+compara antes de escrever.
do_napi_defer() {
  require_root; ensure_nic
  section "NAPI defer em ${NIC} (gro_flush_timeout + napi_defer_hard_irqs)"

  local f_gro="/sys/class/net/${NIC}/gro_flush_timeout"
  local f_defer="/sys/class/net/${NIC}/napi_defer_hard_irqs"
  if [ ! -f "$f_gro" ] || [ ! -f "$f_defer" ]; then
    warn "sysfs nao tem gro_flush_timeout/napi_defer_hard_irqs em ${NIC} (kernel velho?); pulando"
    return 0
  fi

  local cur_gro cur_defer
  cur_gro=$(cat "$f_gro" 2>/dev/null)
  cur_defer=$(cat "$f_defer" 2>/dev/null)
  log "atual: gro_flush_timeout=${cur_gro:-?} ns | napi_defer_hard_irqs=${cur_defer:-?}"
  log "alvo:  gro_flush_timeout=${NAPI_GRO_FLUSH_TIMEOUT_NS} ns | napi_defer_hard_irqs=${NAPI_DEFER_HARD_IRQS}"

  if [ "$cur_gro" = "$NAPI_GRO_FLUSH_TIMEOUT_NS" ] && [ "$cur_defer" = "$NAPI_DEFER_HARD_IRQS" ]; then
    ok "NAPI defer ja aplicado (idempotente)"
    return 0
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') echo ${NAPI_GRO_FLUSH_TIMEOUT_NS} > ${f_gro}"
    echo "  $(c_cya '[dry-run]') echo ${NAPI_DEFER_HARD_IRQS} > ${f_defer}"
    return 0
  fi

  local fails=0
  if ! echo "$NAPI_GRO_FLUSH_TIMEOUT_NS" > "$f_gro" 2>/dev/null; then
    nok "falha ao escrever ${f_gro}"
    fails=$((fails + 1))
  fi
  if ! echo "$NAPI_DEFER_HARD_IRQS" > "$f_defer" 2>/dev/null; then
    nok "falha ao escrever ${f_defer}"
    fails=$((fails + 1))
  fi
  if [ "$fails" -eq 0 ]; then
    ok "NAPI defer aplicado: gro_flush_timeout=${NAPI_GRO_FLUSH_TIMEOUT_NS}ns napi_defer_hard_irqs=${NAPI_DEFER_HARD_IRQS}"
  fi
}

# Lista de 24 features ethtool -K para habilitar (portada de xuione-ccd-net.sh).
# Cada feature recebe um teste "on/off/off-fixed/missing":
#  - on          : ja ligada (idempotente, skip)
#  - off         : ethtool -K tenta ligar; reverifica
#  - off [fixed] : driver nao suporta -- inclui "off [requested on]", que e o
#                  driver recusando o pedido (warn dim, skip; religar em todo
#                  apply quebraria a idempotencia)
#  - missing     : feature ausente no driver (skip)
OFFLOAD_FEATURES_ON_DEFAULT=(
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

# do_offloads: 24 ethtool -K features (portado de xuione-ccd-net.sh)
# Substitui o antigo subset de offloads em do_coalesce (gro/gso/tso on).
# Idempotente: skip se ja ON; warn em fixed; missing nao e erro.
do_offloads() {
  require_root; ensure_nic
  section "Offloads ethtool em ${NIC} (TSO/GSO/GRO/checksums/VLAN/tunnels)"

  local total=${#OFFLOAD_FEATURES_ON_DEFAULT[@]}
  local already_on=0 set_on=0 fixed_off=0 missing=0 fail=0
  local fixed_list="" missing_list="" off_list=""

  if [ "${DRY_RUN}" -eq 1 ]; then
    log "[dry-run] verificaria ${total} features e tentaria garantir 'on'"
    local f st
    for f in "${OFFLOAD_FEATURES_ON_DEFAULT[@]}"; do
      st=$(read_offload_state "$f")
      case "$st" in
        on)        already_on=$((already_on + 1)) ;;
        off)       off_list="${off_list} ${f}"; set_on=$((set_on + 1)) ;;
        off-fixed) fixed_list="${fixed_list} ${f}"; fixed_off=$((fixed_off + 1)) ;;
        missing)   missing_list="${missing_list} ${f}"; missing=$((missing + 1)) ;;
      esac
    done
    log "[dry-run] ja ON:       ${already_on}/${total}"
    log "[dry-run] ligaria:     ${set_on}  (${off_list# })"
    [ "$fixed_off" -gt 0 ] && log "[dry-run] OFF [fixed/requested]: ${fixed_off}  (${fixed_list# })"
    [ "$missing"   -gt 0 ] && log "[dry-run] missing:     ${missing}  (${missing_list# })"
    return 0
  fi

  local f st
  for f in "${OFFLOAD_FEATURES_ON_DEFAULT[@]}"; do
    st=$(read_offload_state "$f")
    case "$st" in
      on)
        already_on=$((already_on + 1))
        [ "${VERBOSE}" -eq 1 ] && log "  ${f}: ja ON"
        ;;
      off-fixed)
        fixed_off=$((fixed_off + 1))
        fixed_list="${fixed_list} ${f}"
        [ "${VERBOSE}" -eq 1 ] && log "  ${f}: OFF [fixed/requested] - driver nao aceita, skip"
        ;;
      missing)
        missing=$((missing + 1))
        missing_list="${missing_list} ${f}"
        [ "${VERBOSE}" -eq 1 ] && log "  ${f}: nao listada, skip"
        ;;
      off)
        if ethtool -K "$NIC" "$f" on 2>/dev/null; then
          local after; after=$(read_offload_state "$f")
          if [ "$after" = "on" ]; then
            set_on=$((set_on + 1))
            [ "${VERBOSE}" -eq 1 ] && log "  ${f}: OFF -> ON"
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
  [ "$fixed_off" -gt 0 ] && log "  OFF [fixed/requested] (driver nao aceita):${fixed_list}"
  [ "$missing"   -gt 0 ] && log "  missing (feature nao existe):${missing_list}"
  # OBRIGATORIO: sem este `return 0` a funcao herda o status do teste acima.
  # Com missing=0 (caso normal no E810) o `[ ... ]` retorna 1, do_offloads
  # retorna 1 e, sob `set -e`, do_nic_all/apply --all MORRIAM aqui em silencio
  # (antes de xui-affinity/systemd/summary).
  return 0
}

do_nic_all() {
  # qdisc INTENCIONALMENTE FORA: kernel ja cria mq+fq automaticamente
  # (default_qdisc=fq do xanmod + mq auto-instalado em NIC multi-queue).
  # Bouncer qdisc com trafego ativo pode dar microdropout. Nao replicar
  # trabalho do kernel.
  ensure_plan
  do_queues
  do_rss                 # ethtool -X equal QUEUES (defensivo: drivers nao-ice preservam indir table)
  do_ring
  do_irq_xps_rps_table   # combina IRQ + XPS + RPS-zero numa unica fase tabular
  do_coalesce
  do_napi_defer          # NAPI deferral (portado de xuione-ccd-net.sh)
  do_offloads            # 24 ethtool offloads (portado de xuione-ccd-net.sh)
}

# Aplica IRQ pinning + XPS + RPS-zero (e RFS conforme RFS_PER_QUEUE) numa unica
# fase tabular. Cada fila vira uma linha mostrando IRQ, CPU, sibling, XPS mask,
# RPS status. Substitui o trio do_irq + do_xps + do_rfs em do_nic_all.
do_irq_xps_rps_table() {
  require_root; ensure_nic
  [ "${#IRQ_CPUS_ARR[@]}" -gt 0 ] || die "do_irq_xps_rps_table: plano vazio"

  local irqs nirq
  irqs="$(discover_nic_irqs)"
  [ -n "$irqs" ] || die "nenhum IRQ encontrado para ${NIC} (rodou 'apply --nic-all' primeiro?)"
  nirq="$(echo $irqs | wc -w)"

  if systemctl is-active irqbalance >/dev/null 2>&1; then
    warn "irqbalance ATIVO -- vai sobrescrever afinidade. Considere: apply --irqbalance off"
  fi

  section "IRQ pin + XPS + RPS-zero  (${QUEUES} queues)"

  # Largura da coluna XPS depende do nr de CPUs do sistema:
  # 128 CPUs = 4 grupos × 8 + 3 virgulas = 35 chars
  # 256 CPUs = 8 grupos × 8 + 7 virgulas = 71 chars
  # ajusta dinamicamente para nao truncar nem desperdicar espaco em maquinas pequenas.
  local xps_w=$(( $(cpu_mask_groups) * 9 - 1 ))
  [ "$xps_w" -lt 22 ] && xps_w=22
  local xps_dash; xps_dash=$(printf '%*s' "$xps_w" '' | tr ' ' '-')

  # Cabecalho da tabela
  printf '      %-3s %-5s %-4s %-9s  %-*s %s\n' "Q" "IRQ" "CPU" "siblings" "$xps_w" "XPS mask (hex)" "RPS"
  printf '      %-3s %-5s %-4s %-9s  %s %s\n'   "---" "-----" "----" "---------" "$xps_dash" "------"

  local i=0 irq core sib irq_mask xps_mask
  local irq_fail=0 xps_fail=0 rps_fail=0
  local rps_status xps_status

  for irq in $irqs; do
    [ "$i" -ge "$QUEUES" ] && break
    core="${IRQ_CPUS_ARR[$i]}"
    sib="$(smt_sibling_of "$core")"
    irq_mask="$(build_irq_mask "$core")"
    xps_mask="$(mask_for_two_cpus "$core" "$sib")"

    if [ "${DRY_RUN}" -eq 1 ]; then
      rps_status="dry-run"
      xps_status="dry-run"
    else
      # IRQ
      if ! printf "%s" "$irq_mask" > "/proc/irq/${irq}/smp_affinity" 2>/dev/null; then
        irq_fail=$((irq_fail+1))
      fi
      # XPS
      if printf "%s" "$xps_mask" > "/sys/class/net/${NIC}/queues/tx-${i}/xps_cpus" 2>/dev/null; then
        xps_status="set"
      else
        xps_status="fail"; xps_fail=$((xps_fail+1))
      fi
      # RPS=0
      if echo 0 > "/sys/class/net/${NIC}/queues/rx-${i}/rps_cpus" 2>/dev/null; then
        rps_status="zeroed"
      else
        rps_status="fail"; rps_fail=$((rps_fail+1))
      fi
      # RFS por fila (rps_flow_cnt) -- 0 (off) ou RFS_PER_QUEUE
      echo "${RFS_PER_QUEUE}" > "/sys/class/net/${NIC}/queues/rx-${i}/rps_flow_cnt" 2>/dev/null || true
    fi

    printf '      %-3d %-5d %-4d %-9s  %-*s %s\n' "$i" "$irq" "$core" "${core} ${sib}" "$xps_w" "$xps_mask" "$rps_status"
    i=$((i+1))
  done

  # RFS global rps_sock_flow_entries
  if [ "${DRY_RUN}" -eq 0 ]; then
    sysctl -w net.core.rps_sock_flow_entries=$((QUEUES * RFS_PER_QUEUE)) >/dev/null 2>&1 || true
  fi

  local irq_ok=$((i - irq_fail)) xps_ok=$((i - xps_fail)) rps_ok=$((i - rps_fail))
  phase_summary "${i} IRQs pinadas (${irq_fail} fails) | XPS: ${xps_ok} ok / 0 skip / ${xps_fail} fail | RPS: ${rps_ok} zeroed / 0 skip / ${rps_fail} fail"
  # Reflete cada acao individual no tally global (i*3 acoes no caso ideal)
  G_OK=$((G_OK + irq_ok + xps_ok + rps_ok))
  if [ "${irq_fail}" -gt 0 ] || [ "${xps_fail}" -gt 0 ] || [ "${rps_fail}" -gt 0 ]; then
    G_NOK=$((G_NOK + irq_fail + xps_fail + rps_fail))
  fi
}

# Roda detect_topology + compute_plan se ainda nao foi rodado (idempotente)
ensure_plan() {
  if [ "${NUM_CCX}" -eq 0 ]; then detect_topology; fi
  if [ "${QUEUES}" -eq 0 ] || [ "${#IRQ_CPUS_ARR[@]}" -eq 0 ]; then compute_plan; fi
}

# Retorna a lista de CPUs efetiva para PHP-FPM/ffmpeg via CPUAffinity=.
# - Sem --segregate-network: retorna APP_CPUS_LIST completo (default)
# - Com --segregate-network: retorna APP_CPUS_LIST - SMT_siblings_of(IRQ_CPUS_ARR)
#   IRQ cores ja nao estao em APP_CPUS_LIST (sao isolados pelo plano), entao so
#   precisa filtrar os SMTs siblings que estao em APP_CPUS_LIST.
# Requer plano calculado (ensure_plan).
effective_app_cpus_list() {
  if [ "${SEGREGATE_NETWORK}" != "1" ]; then
    echo "${APP_CPUS_LIST}"
    return 0
  fi
  # Defensa: se nao tem plano ou IRQs, nao filtra (retorna tudo)
  if [ "${#IRQ_CPUS_ARR[@]}" -eq 0 ]; then
    echo "${APP_CPUS_LIST}"
    return 0
  fi
  local cpu sib
  declare -A exclude=()
  for cpu in "${IRQ_CPUS_ARR[@]}"; do
    sib="$(smt_sibling_of "$cpu")"
    [ -n "$sib" ] && [ "$sib" != "$cpu" ] && exclude[$sib]=1
  done
  local kept=""
  for cpu in $(expand_range "${APP_CPUS_LIST}"); do
    if [ -z "${exclude[$cpu]:-}" ]; then
      kept="$kept $cpu"
    fi
  done
  compact_range $kept
}

# --segregate-network so faz sentido se sobra CPU para PHP-FPM/ffmpeg. Com o
# plano DEFAULT (4 IRQs/CCX = TODOS os cores fisicos) o filtro de SMT siblings
# zera a lista e do_xui_affinity/do_cron_affinity morreriam com "lista efetiva
# vazia" -- so que DEPOIS de sysctl + NIC ja terem sido escritos (estado
# meio-aplicado). Estas duas funcoes permitem barrar isso ANTES de escrever.
# Requer plano calculado (ensure_plan).
segregate_leaves_no_app_cpu() {
  [ "${SEGREGATE_NETWORK}" = "1" ] || return 1
  [ -z "$(effective_app_cpus_list)" ]
}
segregate_empty_msg() {
  local per_ccx="?"
  [ "${NUM_CCX_ACTIVE}" -gt 0 ] && per_ccx=$((TARGET_IRQS / NUM_CCX_ACTIVE))
  printf '%s' "--segregate-network deixaria 0 CPUs para PHP-FPM/ffmpeg: o plano atual usa TODOS os cores fisicos para IRQ (--irqs=${TARGET_IRQS} = ${per_ccx}/CCX). Use --cache-first ou --irqs menor (ex.: ${NUM_CCX_ACTIVE} ou $((NUM_CCX_ACTIVE*2)))."
}

# Edita /etc/systemd/system/xuione.service para fixar
# CPUAffinity=<APP_CPUS_LIST ou APP_CPUS_NO_NET>. Idempotente: substitui linha
# existente ou adiciona logo apos [Service]. Faz daemon-reload mas NAO reinicia
# o service.
XUI_UNIT="/etc/systemd/system/xuione.service"
do_xui_affinity() {
  require_root
  ensure_plan
  local app_cpus_eff; app_cpus_eff="$(effective_app_cpus_list)"
  local label="${app_cpus_eff}"
  [ "${SEGREGATE_NETWORK}" = "1" ] && label="${app_cpus_eff}  (segregate-network: -SMTs IRQ)"
  section "xuione.service: CPUAffinity=${label}"
  [ -f "${XUI_UNIT}" ] || { warn "${XUI_UNIT} ausente, pulando CPUAffinity do xuione"; return 0; }
  [ -n "${app_cpus_eff}" ] || die "lista efetiva vazia (plano + segregate-network deixou 0 CPUs)"

  # Idempotencia byte-level (portado de xuione-ccd-net.sh em 2026-05-14):
  # Simula o que a edicao produziria e compara com o arquivo atual. Se ja bate,
  # PULA daemon-reload completamente (evita restart spurio do xuione).
  local desired_aff="CPUAffinity=${app_cpus_eff}"
  local simulated; simulated=$(awk -v aff="${desired_aff}" '
    BEGIN{added=0}
    /^CPUAffinity=/ { next }
    /^\[Service\]/ && added==0 { print; print aff; added=1; next }
    { print }
  ' "${XUI_UNIT}")
  local current; current=$(cat "${XUI_UNIT}")
  if [ "$simulated" = "$current" ]; then
    ok "${XUI_UNIT} ja consolidado com ${desired_aff} (idempotente, sem daemon-reload)"
    do_cron_affinity
    do_nginx_affinity
    return 0
  fi

  log "ajustando ${XUI_UNIT}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') editaria ${XUI_UNIT} para ${desired_aff}"
    echo "  $(c_cya '[dry-run]') systemctl daemon-reload (sem restart)"
    do_cron_affinity
    do_nginx_affinity
    return 0
  fi
  local bak="${XUI_UNIT}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "${XUI_UNIT}" "${bak}"
  local pre_count; pre_count=$(count_matches "${XUI_UNIT}" '^CPUAffinity=')
  printf '%s\n' "${simulated}" > "${XUI_UNIT}"
  chmod 0644 "${XUI_UNIT}"
  if grep -q "^CPUAffinity=" "${XUI_UNIT}"; then
    log "backup em ${bak}"
    [ "${pre_count}" -gt 1 ] && log "removidas ${pre_count} linhas CPUAffinity= duplicadas, deixando 1"
    systemctl daemon-reload
    log "daemon-reload feito; service NAO foi reiniciado (efeito no proximo restart)"
    local post_count; post_count=$(count_matches "${XUI_UNIT}" '^CPUAffinity=')
    local applied;     applied=$(grep -m1 '^CPUAffinity=' "${XUI_UNIT}" 2>/dev/null)
    if [ "${post_count}" = "1" ]; then
      ok "${XUI_UNIT}: ${applied}  (1 linha)"
    else
      nok "${XUI_UNIT}: ${post_count} linhas CPUAffinity= (esperado 1)"
    fi
  else
    cp -a "${bak}" "${XUI_UNIT}"
    warn "nao foi possivel inserir CPUAffinity em ${XUI_UNIT} (sem secao [Service]?) -- backup restaurado"
    nok "CPUAffinity nao gravado"
  fi

  # Consolidacao: a "afinidade da aplicacao" e uma unidade logica.
  # 3 partes que precisam casar:
  #   (a) CPUAffinity= no xuione.service (acima) - processos do XUI iniciados pelo
  #       service ja respeitam.
  #   (b) cron.service drop-in - SEM isso, crontabs do XUI (streams.php tick 1min)
  #       herdam affinity do PID 1 que com isolcpus filtra para CCX 0. Resultado:
  #       todos os ffmpegs forkados pelo cron amontoam em CCX 0.
  #   (c) nginx worker_processes + worker_cpu_affinity - alinha o pinning interno
  #       do nginx com os APP_CPUS (impede que nginx tente pinar em IRQ cores).
  do_cron_affinity
  do_nginx_affinity
}

# Aplica flags de isolamento de CPU em /etc/default/grub (cmdline do kernel)
# e roda update-grub. Efeito apenas apos reboot.
#
# So faz sentido com --reserve-ccx (CCX dedicado para housekeeping). Sem isso,
# isolcpus deixaria o kernel sem onde rodar e o sistema fica instavel.
#
# Estrategia de edicao: edita GRUB_CMDLINE_LINUX_DEFAULT in-place, removendo
# as 4 flags conhecidas (isolcpus/nohz_full/rcu_nocbs/irqaffinity) e anexando
# as novas. Outras flags (mitigations, nps, etc.) sao preservadas.
#
# Trata chattr +i (mesma logica do do_sysctl).
GRUB_DEFAULT="/etc/default/grub"
do_grub() {
  require_root
  ensure_plan
  section "GRUB cmdline: aplicando flags de isolamento em ${GRUB_DEFAULT}"
  require_file "${GRUB_DEFAULT}"

  if [ -z "${RESERVED_CPUS_LIST}" ]; then
    warn "GRUB tuning so faz sentido com --reserve-ccx (CCX inteiro reservado)."
    warn "Sem CCX reservado, isolcpus=${data_plane:-...} deixaria o kernel"
    warn "sem onde rodar (housekeeping precisa de CPUs nao-isoladas)."
    nok "GRUB nao aplicado: --reserve-ccx ausente"
    return 0
  fi

  # Detecta o updater do GRUB
  local grub_update=""
  if command -v update-grub >/dev/null 2>&1; then
    grub_update="update-grub"
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    if [ -f /boot/grub2/grub.cfg ]; then
      grub_update="grub2-mkconfig -o /boot/grub2/grub.cfg"
    elif [ -f /boot/efi/EFI/redhat/grub.cfg ]; then
      grub_update="grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg"
    elif [ -f /boot/efi/EFI/centos/grub.cfg ]; then
      grub_update="grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg"
    else
      die "encontrei grub2-mkconfig mas nao sei onde esta grub.cfg"
    fi
  else
    die "nao encontrei update-grub nem grub2-mkconfig"
  fi

  # Calcula as flags. `domain` em isolcpus e OPT-IN via --isolcpus-domain
  # (default OFF: ver comentario em ISOLCPUS_DOMAIN; incidente 2026-05-07).
  local data_plane isolcpus_flag
  data_plane="$(compact_range $(expand_range "${APP_CPUS_LIST}") ${IRQ_CPUS_ARR[*]})"
  if [ "${ISOLCPUS_DOMAIN}" = "1" ]; then
    isolcpus_flag="isolcpus=managed_irq,domain,${data_plane}"
  else
    isolcpus_flag="isolcpus=managed_irq,${data_plane}"
  fi
  # nohz_full e OPT-IN via --nohz-full (ver comentario em NOHZ_FULL).
  local new_flags="${isolcpus_flag} rcu_nocbs=${data_plane} irqaffinity=${RESERVED_CPUS_LIST}"
  [ "${NOHZ_FULL}" = "1" ] && new_flags="${new_flags} nohz_full=${data_plane}"

  # Le linha atual de GRUB_CMDLINE_LINUX_DEFAULT
  local current_line current_cmdline
  current_line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "${GRUB_DEFAULT}" | head -1)"
  if [ -z "${current_line}" ]; then
    die "GRUB_CMDLINE_LINUX_DEFAULT= nao encontrado em ${GRUB_DEFAULT}"
  fi
  current_cmdline="${current_line#GRUB_CMDLINE_LINUX_DEFAULT=}"
  current_cmdline="${current_cmdline%\"}"
  current_cmdline="${current_cmdline#\"}"

  # Remove flags antigas e anexa novas
  local cleaned new_cmdline
  cleaned="$(echo "${current_cmdline}" | tr ' ' '\n' | grep -vE '^(isolcpus|nohz_full|rcu_nocbs|irqaffinity)=' | tr '\n' ' ' | xargs)"
  new_cmdline="$(echo "${cleaned} ${new_flags}" | xargs)"

  if [ "${new_cmdline}" = "${current_cmdline}" ]; then
    log "GRUB cmdline ja esta com as flags corretas"
    ok "GRUB_CMDLINE_LINUX_DEFAULT inalterada"
    return 0
  fi

  log "antes : GRUB_CMDLINE_LINUX_DEFAULT=\"${current_cmdline}\""
  log "depois: GRUB_CMDLINE_LINUX_DEFAULT=\"${new_cmdline}\""

  local was_immutable=0
  if is_immutable "${GRUB_DEFAULT}"; then
    was_immutable=1
    log "${GRUB_DEFAULT} esta IMUTAVEL -- removendo flag temporariamente"
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    [ "$was_immutable" -eq 1 ] && echo "  $(c_cya '[dry-run]') chattr -i ${GRUB_DEFAULT}"
    echo "  $(c_cya '[dry-run]') reescrever GRUB_CMDLINE_LINUX_DEFAULT em ${GRUB_DEFAULT}"
    [ "$was_immutable" -eq 1 ] && echo "  $(c_cya '[dry-run]') chattr +i ${GRUB_DEFAULT}"
    echo "  $(c_cya '[dry-run]') ${grub_update}"
    echo "  $(c_cya '[dry-run]') AVISO: efeito apenas no proximo reboot"
    return 0
  fi

  local bak="${GRUB_DEFAULT}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "${GRUB_DEFAULT}" "${bak}"

  [ "$was_immutable" -eq 1 ] && { chattr -i "${GRUB_DEFAULT}" || die "chattr -i falhou"; }

  set +e
  (
    set -e
    awk -v new="GRUB_CMDLINE_LINUX_DEFAULT=\"${new_cmdline}\"" '
      /^GRUB_CMDLINE_LINUX_DEFAULT=/ && !done { print new; done=1; next }
      { print }
    ' "${GRUB_DEFAULT}" > "${GRUB_DEFAULT}.tmp"
    cat "${GRUB_DEFAULT}.tmp" > "${GRUB_DEFAULT}"
    rm -f "${GRUB_DEFAULT}.tmp"
  )
  local edit_rc=$?
  set -e

  if [ "$was_immutable" -eq 1 ]; then
    chattr +i "${GRUB_DEFAULT}" 2>/dev/null || warn "chattr +i ${GRUB_DEFAULT} falhou"
  fi

  [ "$edit_rc" -eq 0 ] || die "edicao de ${GRUB_DEFAULT} falhou (rc=${edit_rc})"

  # Validacao defensiva: confirma que a linha GRUB_CMDLINE_LINUX_DEFAULT
  # continua bem formada apos a edicao. Se algo deu errado (awk produziu
  # vazio, cmdline sem aspas, etc.) restaura do backup ANTES de rodar
  # grub_update -- evita gerar grub.cfg com kernel sem flags ou unbootable.
  if ! grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"[[:space:]]*$' "${GRUB_DEFAULT}"; then
    warn "GRUB_CMDLINE_LINUX_DEFAULT mal-formado em ${GRUB_DEFAULT} apos edicao"
    warn "restaurando backup de ${bak}"
    [ "$was_immutable" -eq 1 ] && chattr -i "${GRUB_DEFAULT}" 2>/dev/null
    cp -a "${bak}" "${GRUB_DEFAULT}"
    [ "$was_immutable" -eq 1 ] && chattr +i "${GRUB_DEFAULT}" 2>/dev/null
    die "edicao do GRUB nao passou validacao -- arquivo restaurado, NADA mudou"
  fi

  log "backup em ${bak}"
  ok "${GRUB_DEFAULT} atualizado"

  log "rodando ${grub_update}"
  local out
  if out="$(${grub_update} 2>&1)"; then
    ok "${grub_update} concluido (${grub_update% *})"
  else
    echo "${out}" | sed 's/^/  /' >&2
    nok "${grub_update} retornou erro"
    return 1
  fi

  echo
  warn "ATENCAO: as flags de isolamento so terao efeito apos REBOOT"
  warn "Apos reboot, valide:"
  warn "  cat /sys/devices/system/cpu/isolated     # esperado: ${data_plane}"
  [ "${NOHZ_FULL}" = "1" ] && \
    warn "  cat /sys/devices/system/cpu/nohz_full    # esperado: ${data_plane}"
  warn "  cat /proc/cmdline                        # contem as flags acima"
}

# Templates das units (embedded desde 2026-08-20). Mantem os placeholders
# @NIC@/@IRQS@/@EXTRA_FLAGS@ para o fluxo de sed ja existente continuar valendo.
# Antes vinham de ${SERVICE_SRC}/${PATH_SRC}, arquivos que nao existem mais no
# repo -- sem persistencia instalada, `apply --systemd` so dava die.
service_template() {
  cat <<EOF
[Unit]
Description=XuiOne E810 100G network tuning (reaplica no boot / operstate change)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/sys/class/net/@NIC@

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT_DST} --nic @NIC@ --irqs @IRQS@ @EXTRA_FLAGS@ apply --nic-all --systemd
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

path_template() {
  cat <<'EOF'
[Unit]
Description=Reaplica tuning XuiOne quando o operstate da NIC muda

[Path]
PathChanged=/sys/class/net/@NIC@/operstate
Unit=xuione-net-tune.service

[Install]
WantedBy=multi-user.target
EOF
}

do_systemd_install() {
  require_root
  ensure_nic
  ensure_plan
  section "systemd: install service+path (NIC=${NIC} IRQS=${TARGET_IRQS})"
  # Precedencia: template no SCRIPT_DIR (repo) > unit instalada ainda com
  # placeholders > template embedded. Scratch em /run (tmpfs, some no boot).
  local svc_src="${SERVICE_SRC}" path_src="${PATH_SRC}"
  local scratch="/run/xuione-tune"
  if [ ! -f "${svc_src}" ]; then
    if [ -f "${SERVICE_DST}" ] && grep -q '@NIC@\|@IRQS@' "${SERVICE_DST}"; then
      svc_src="${SERVICE_DST}"
    else
      mkdir -p "${scratch}" 2>/dev/null || scratch="$(mktemp -d)"
      svc_src="${scratch}/xuione-net-tune.service"
      service_template > "${svc_src}"
      log "template ${SERVICE_SRC} ausente -- usando template embedded"
    fi
  fi
  if [ ! -f "${path_src}" ]; then
    if [ -f "${PATH_DST}" ] && grep -q '@NIC@' "${PATH_DST}"; then
      path_src="${PATH_DST}"
    else
      mkdir -p "${scratch}" 2>/dev/null || scratch="$(mktemp -d)"
      path_src="${scratch}/xuione-net-tune.path"
      path_template > "${path_src}"
      log "template ${PATH_SRC} ausente -- usando template embedded"
    fi
  fi
  local self
  self="$(readlink -f "$0")"
  # SCRIPT_DST = COPIA CANONICA real (nao symlink: o repo em /root pode ser
  # apagado e a unit do boot precisa continuar). Atualizada em TODO apply a
  # partir do script executado: byte a byte igual -> ok; diferente -> refresh
  # atomico (.tmp + mv) guardando a anterior em .prev. O drift (copia que
  # envelhecia, 2026-08-20) so existia porque --no-systemd pulava este passo.
  local script_match=0 script_changed=0
  if [ "${self}" = "${SCRIPT_DST}" ] \
     || { [ -f "${SCRIPT_DST}" ] && [ ! -L "${SCRIPT_DST}" ] && cmp -s "${self}" "${SCRIPT_DST}"; }; then
    script_match=1
  else
    log "atualizando copia canonica ${SCRIPT_DST} a partir de ${self}"
    [ -L "${SCRIPT_DST}" ] && run "rm -f ${SCRIPT_DST}"
    if [ -f "${SCRIPT_DST}" ] && [ ! -L "${SCRIPT_DST}" ]; then
      run "cp -af ${SCRIPT_DST} ${SCRIPT_DST}.prev"
    fi
    run "install -m 0755 ${self} ${SCRIPT_DST}.tmp && mv -f ${SCRIPT_DST}.tmp ${SCRIPT_DST}"
    script_changed=1
    [ "${DRY_RUN}" -eq 0 ] && script_match=1
  fi
  # Monta EXTRA_FLAGS para a unit re-aplicar com as MESMAS flags do operador
  # (--reserve-ccx, --cache-first, --force-hw). Sem isso, re-aplicacao no boot
  # usaria defaults: ou sobrescreve o pinning customizado, ou (se hw nao
  # testado) die porque o hw-check bloqueia sem --force-hw.
  local extra=""
  [ -n "${RESERVED_CCX_LIST}" ] && extra="${extra} --reserve-ccx ${RESERVED_CCX_LIST}"
  [ "${CACHE_FIRST}" = "1" ]    && extra="${extra} --cache-first"
  [ "${ISOLCPUS_DOMAIN}" = "1" ] && extra="${extra} --isolcpus-domain"
  [ "${NOHZ_FULL}" = "1" ]       && extra="${extra} --nohz-full"
  [ "${NGINX_PIN_MODE}" != "spread" ] && extra="${extra} --nginx-pin-mode ${NGINX_PIN_MODE}"
  [ "${SEGREGATE_NETWORK}" = "1" ] && extra="${extra} --segregate-network"
  # RFS: sem propagar, a re-aplicacao no boot rodaria com RFS_PER_QUEUE=0 e
  # zeraria rps_flow_cnt/rps_sock_flow_entries sem aviso.
  [ "${RFS_PER_QUEUE}" -gt 0 ]  && extra="${extra} --rfs-per-queue ${RFS_PER_QUEUE}"
  [ "${FORCE_HW}"    = "1" ]    && extra="${extra} --force-hw"
  extra="${extra# }"   # trim leading space

  # Idempotencia byte-level (portado de xuione-ccd-net.sh em 2026-05-14):
  # Computa o conteudo desejado de SERVICE_DST e PATH_DST (apos placeholder
  # substitution) e compara com os arquivos atuais. Se ambos batem E o
  # service+path ja estao enabled + path active, PULA daemon-reload/enable/start
  # completamente (evita reload spurio em re-runs).
  local desired_svc desired_pth
  desired_svc=$(sed "s|@NIC@|${NIC}|g; s|@IRQS@|${TARGET_IRQS}|g; s|@EXTRA_FLAGS@|${extra}|g" "${svc_src}" 2>/dev/null)
  desired_pth=$(sed "s|@NIC@|${NIC}|g; s|@IRQS@|${TARGET_IRQS}|g; s|@EXTRA_FLAGS@|${extra}|g" "${path_src}" 2>/dev/null)
  local cur_svc="" cur_pth=""
  [ -f "${SERVICE_DST}" ] && cur_svc=$(cat "${SERVICE_DST}")
  [ -f "${PATH_DST}"    ] && cur_pth=$(cat "${PATH_DST}")

  local files_match=0
  if [ "$desired_svc" = "$cur_svc" ] && [ "$desired_pth" = "$cur_pth" ]; then
    files_match=1
  fi
  local svc_enabled=""; svc_enabled=$(systemctl is-enabled xuione-net-tune.service 2>/dev/null || echo "no")
  local pth_enabled=""; pth_enabled=$(systemctl is-enabled xuione-net-tune.path    2>/dev/null || echo "no")
  local pth_active="";  pth_active=$(systemctl is-active  xuione-net-tune.path    2>/dev/null | head -1)
  local persistence_ok=0
  if [ "$script_match" = "1" ] && [ "$script_changed" = "0" ] && [ "$files_match" = "1" ] \
     && [ "$svc_enabled" = "enabled" ] && [ "$pth_enabled" = "enabled" ] \
     && [ "$pth_active" = "active" ]; then
    persistence_ok=1
  fi

  if [ "$persistence_ok" = "1" ]; then
    ok "systemd: script + ${SERVICE_DST} + ${PATH_DST} ja consolidados, service/path enabled+active (idempotente, sem daemon-reload)"
    if [ "${DRY_RUN}" -eq 0 ]; then
      log "ExecStart instalado:"
      grep '^ExecStart=' "${SERVICE_DST}" | sed 's/^/  /'
      log "PathChanged instalado:"
      grep '^PathChanged=' "${PATH_DST}" | sed 's/^/  /'
    fi
    return 0
  fi

  log "instalando ${SERVICE_DST} e ${PATH_DST} (--nic ${NIC} --irqs ${TARGET_IRQS}${extra:+ ${extra}})"
  # install -m 0644 falha com 'same file' se svc_src == SERVICE_DST -- skip nesse caso
  [ "${svc_src}"  = "${SERVICE_DST}" ] || run "install -m 0644 ${svc_src} ${SERVICE_DST}"
  [ "${path_src}" = "${PATH_DST}"    ] || run "install -m 0644 ${path_src} ${PATH_DST}"
  # sed: substitui placeholders. Se @EXTRA_FLAGS@ fica vazio, o argv do bash
  # ignora o token (split por espaco), nao causa argv vazio espurio.
  run "sed -i 's|@NIC@|${NIC}|g; s|@IRQS@|${TARGET_IRQS}|g; s|@EXTRA_FLAGS@|${extra}|g' ${SERVICE_DST} ${PATH_DST}"
  run "systemctl daemon-reload"
  # enable sem --now: a aplicacao ja foi feita pelo do_nic_all desta sessao;
  # o service vai disparar no proximo boot ou via path-trigger
  run "systemctl enable xuione-net-tune.service 2>&1 || true"
  run "systemctl enable xuione-net-tune.path    2>&1 || true"
  run "systemctl start  xuione-net-tune.path    2>&1 || true"
  if [ "${DRY_RUN}" -eq 0 ]; then
    local svc_en pth_en pth_ac
    svc_en=$(systemctl is-enabled xuione-net-tune.service 2>/dev/null || echo not-installed)
    pth_en=$(systemctl is-enabled xuione-net-tune.path    2>/dev/null || echo not-installed)
    pth_ac=$(systemctl is-active  xuione-net-tune.path    2>&1 | head -1)
    verify_eq "xuione-net-tune.service enabled" "enabled" "${svc_en}"
    verify_eq "xuione-net-tune.path enabled"    "enabled" "${pth_en}"
    verify_eq "xuione-net-tune.path active"     "active"  "${pth_ac}"
    log "ExecStart instalado:"
    grep '^ExecStart=' "${SERVICE_DST}" | sed 's/^/  /'
    log "PathChanged instalado:"
    grep '^PathChanged=' "${PATH_DST}" | sed 's/^/  /'
  fi
}

# Comenta as linhas que iniciam nginx_rtmp em /home/xui/service.
# Idempotente: se ja estao comentadas, nao faz nada.
# Backup: /home/xui/service.bak.<ts>
XUI_SERVICE_SH="/home/xui/service"
do_disable_nginx_rtmp() {
  require_root
  section "nginx_rtmp: desabilitar em ${XUI_SERVICE_SH}"
  if [ ! -f "${XUI_SERVICE_SH}" ]; then
    warn "${XUI_SERVICE_SH} ausente -- pulando"
    return 0
  fi
  # Detecta linhas ATIVAS (nao comentadas) que iniciam/recarregam nginx_rtmp
  local n_active
  n_active=$(count_matches "${XUI_SERVICE_SH}" '^[[:space:]]*sudo.*nginx_rtmp')
  if [ "${n_active}" -eq 0 ]; then
    log "ja desabilitado (nenhuma linha ativa de nginx_rtmp)"
    ok "nginx_rtmp ja comentado em ${XUI_SERVICE_SH}"
    return 0
  fi
  log "${n_active} linhas ativas encontradas; comentando"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') sed -i 's|^([[:space:]]*sudo.*nginx_rtmp)|# &|' ${XUI_SERVICE_SH}"
    echo "  $(c_cya '[dry-run]') AVISO: 'systemctl restart xuione' eh necessario para parar nginx_rtmp atual"
    return 0
  fi
  local bak="${XUI_SERVICE_SH}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "${XUI_SERVICE_SH}" "${bak}"
  # Comenta linhas que comecam com whitespace + sudo + ... + nginx_rtmp
  sed -i -E 's|^([[:space:]]*sudo.*nginx_rtmp.*)$|# DISABLED by xuione-tune.sh: \1|' "${XUI_SERVICE_SH}"
  log "backup em ${bak}"
  local n_after
  n_after=$(count_matches "${XUI_SERVICE_SH}" '^[[:space:]]*sudo.*nginx_rtmp')
  if [ "${n_after}" -eq 0 ]; then
    ok "${n_active} linhas comentadas em ${XUI_SERVICE_SH}"
    warn "para parar nginx_rtmp em execucao agora: 'systemctl restart xuione' (ou 'pkill -f nginx_rtmp/sbin/nginx_rt')"
  else
    nok "${n_after} linhas ainda ativas em ${XUI_SERVICE_SH} (sed falhou?)"
  fi
}

# Reverso: descomenta linhas com nginx_rtmp. Detecta tanto o marcador do
# script ("# DISABLED by xuione-tune.sh: ") quanto comentarios manuais
# genericos do tipo "#<spaces>sudo.*nginx_rtmp". Ignora linhas em bloco de
# comentario explicativo (linhas inteiras de comentario sem 'sudo').
do_enable_nginx_rtmp() {
  require_root
  [ -f "${XUI_SERVICE_SH}" ] || return 0
  # Linhas a descomentar: comeca com '#' (e qualquer coisa, incluindo nosso
  # marcador) e contem 'sudo' + 'nginx_rtmp'.
  local n_disabled
  n_disabled=$(count_matches "${XUI_SERVICE_SH}" '^[[:space:]]*#.*sudo.*nginx_rtmp')
  if [ "${n_disabled}" -eq 0 ]; then
    log "nenhuma linha de nginx_rtmp comentada em ${XUI_SERVICE_SH}"
    return 0
  fi
  log "rollback: descomentando ${n_disabled} linhas com sudo+nginx_rtmp em ${XUI_SERVICE_SH}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') sed: descomenta '^[[:space:]]*# (DISABLED by xuione-tune.sh: )?(sudo.*nginx_rtmp)' -> '\\2'"
    return 0
  fi
  local bak="${XUI_SERVICE_SH}.bak.rollback.$(date +%Y%m%d-%H%M%S)"
  cp -a "${XUI_SERVICE_SH}" "${bak}"
  # Padroes: "# DISABLED by xuione-tune.sh: <cmd>" OU "#<spaces>sudo ... nginx_rtmp ..."
  # Restaura o comando original removendo o prefixo de comentario.
  sed -i -E 's|^([[:space:]]*)# DISABLED by xuione-tune\.sh: (.*)$|\1\2|; t end
            s|^[[:space:]]*#[[:space:]]*(sudo[[:space:]].*nginx_rtmp.*)$|  \1|
            :end' "${XUI_SERVICE_SH}"
  local n_after; n_after=$(count_matches "${XUI_SERVICE_SH}" '^[[:space:]]*#.*sudo.*nginx_rtmp')
  ok "$((n_disabled - n_after)) linhas restauradas (backup em ${bak})"
  if [ "${n_after}" -gt 0 ]; then
    warn "${n_after} linhas comentadas restantes (verificar manualmente)"
  fi
  # `return 0` obrigatorio: como ultimo comando, o teste acima retornaria 1 no
  # caminho de SUCESSO (n_after=0) e mataria cmd_rollback no passo 9 (set -e),
  # pulando o passo 10 (GRUB) e o banner final.
  return 0
}

# Drop-in CPUAffinity= em /etc/systemd/system/cron.service.d/affinity.conf.
# Sem isso, cron.service herda a affinity default do PID 1, que com
# isolcpus=4-63,68-127 fica em 0-3,64-67 (CCX 0). Como crontabs do XUI
# (streams.php tick 1 min) forkam ffmpegs, todos amontoavam em CCX 0.
CRON_DROPIN_DIR="/etc/systemd/system/cron.service.d"
CRON_DROPIN="${CRON_DROPIN_DIR}/xuione-affinity.conf"
do_cron_affinity() {
  require_root
  ensure_plan
  local app_cpus_eff; app_cpus_eff="$(effective_app_cpus_list)"
  section "cron.service: drop-in CPUAffinity=${app_cpus_eff}"
  if ! systemctl list-unit-files cron.service 2>/dev/null | grep -q '^cron\.service'; then
    log "cron.service ausente neste sistema -- pulando"
    return 0
  fi
  [ -n "${app_cpus_eff}" ] || die "lista efetiva vazia (plano + segregate-network deixou 0 CPUs)"
  local desired_aff="CPUAffinity=${app_cpus_eff}"

  # Idempotencia byte-level (portado de xuione-ccd-net.sh em 2026-05-14):
  # Gera o conteudo desejado em memoria, normaliza linha "# Gerado por" do
  # timestamp e compara byte a byte com o drop-in atual. Skip restart se ja
  # bate. Tambem detecta drop-ins extras (que precisariam ser removidos).
  local desired_content current_content
  desired_content=$(cat <<EOF
[Service]
${desired_aff}
EOF
)
  if [ -f "${CRON_DROPIN}" ]; then
    current_content=$(sed '/^# Gerado por/d' "${CRON_DROPIN}" 2>/dev/null)
  else
    current_content=""
  fi
  # Verifica se ha drop-ins EXTRAS no diretorio (alem do nosso) -- afetam idempotencia
  local extra_dropins=0
  if [ -d "${CRON_DROPIN_DIR}" ]; then
    extra_dropins=$(find "${CRON_DROPIN_DIR}" -maxdepth 1 -type f -name '*.conf' ! -path "${CRON_DROPIN}" 2>/dev/null | wc -l)
  fi
  # Idempotencia olha SO o NOSSO drop-in. Exigir extra_dropins==0 (como antes)
  # nunca convergia num host onde o xuione-ccd-net instalou o dele: toda rodada
  # reescrevia e dava `systemctl restart cron` -- que mata o cgroup do cron e
  # derruba os ffmpeg forkados pelos crontabs do XUI.
  if [ "$desired_content" = "$current_content" ]; then
    ok "cron.service drop-in ja consolidado (${app_cpus_eff}) [idempotente, sem restart]"
    if [ "$extra_dropins" -gt 0 ]; then
      nok "drop-ins concorrentes em ${CRON_DROPIN_DIR}: $(find "${CRON_DROPIN_DIR}" -maxdepth 1 -type f -name '*.conf' ! -path "${CRON_DROPIN}" -printf '%f ' 2>/dev/null)"
      warn "ordem lexical do systemd faz o ULTIMO nome vencer -- resolva manualmente (rollback de um dos scripts)"
    fi
    return 0
  fi

  log "criando ${CRON_DROPIN} com ${desired_aff}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') mkdir -p ${CRON_DROPIN_DIR}"
    echo "  $(c_cya '[dry-run]') write ${CRON_DROPIN} (CPUAffinity=${app_cpus_eff})"
    echo "  $(c_cya '[dry-run]') systemctl daemon-reload$([ "${RESTART_SERVICES}" -eq 1 ] && echo ' && systemctl restart cron')"
    return 0
  fi
  mkdir -p "${CRON_DROPIN_DIR}"
  cat > "${CRON_DROPIN}" <<EOF
# Gerado por xuione-tune.sh em $(date '+%Y-%m-%d %H:%M:%S')
# Sem isso, cron.service herda affinity do PID 1. Com isolcpus=4-63,68-127
# ativo, isso filtra para CCX 0 (cores 0-3,64-67), e crontabs do XUI
# (streams.php) forkariam ffmpegs amontoados em CCX 0.
[Service]
${desired_aff}
EOF
  systemctl daemon-reload
  # restart de cron e OPT-IN (--restart): reiniciar o cron mata os ffmpeg que os
  # crontabs do XUI forkaram (ficam no cgroup do cron.service).
  if [ "${RESTART_SERVICES}" -eq 1 ]; then
    systemctl restart cron
    sleep 1
  else
    warn "cron drop-in atualizado; rode 'systemctl restart cron' em janela controlada (--restart automatiza)"
    ok "${CRON_DROPIN} escrito (efeito no proximo restart do cron)"
    return 0
  fi
  local crond; crond=$(pgrep -of cron 2>/dev/null)
  if [ -n "${crond}" ]; then
    local actual; actual=$(awk '/^Cpus_allowed_list:/{print $2}' /proc/${crond}/status 2>/dev/null)
    if [ "${actual}" = "${app_cpus_eff}" ]; then
      ok "cron.service Cpus_allowed_list = ${actual}"
    else
      nok "cron.service Cpus_allowed_list = ${actual} (esperado ${app_cpus_eff})"
    fi
  fi
}

# Reverso: remove drop-in cron + restart cron (volta ao default).
do_remove_cron_affinity() {
  require_root
  if [ ! -f "${CRON_DROPIN}" ]; then
    log "cron drop-in nao existe (${CRON_DROPIN})"
    return 0
  fi
  log "rollback: removendo ${CRON_DROPIN}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') rm ${CRON_DROPIN}"
    echo "  $(c_cya '[dry-run]') rmdir ${CRON_DROPIN_DIR} (se vazio)"
    echo "  $(c_cya '[dry-run]') systemctl daemon-reload && systemctl restart cron"
    return 0
  fi
  rm -f "${CRON_DROPIN}"
  rmdir "${CRON_DROPIN_DIR}" 2>/dev/null || true
  systemctl daemon-reload
  systemctl restart cron 2>/dev/null || true
  ok "cron drop-in removido"
}

# Remove o bloco delimitado xuione-tune-nginx do nginx.conf (volta ao default
# auto/auto). Idempotente.
do_remove_nginx_affinity_block() {
  require_root
  local f="/home/xui/bin/nginx/conf/nginx.conf"
  [ -f "$f" ] || { log "nginx.conf ausente"; return 0; }
  if ! grep -q "^${NGINX_BLOCK_BEGIN}\$" "$f" 2>/dev/null; then
    log "bloco xuione-tune-nginx nao encontrado em ${f}"
    return 0
  fi
  log "rollback: removendo bloco delimitado de ${f}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') awk strip BEGIN..END do bloco xuione-tune-nginx em ${f}"
    return 0
  fi
  local bak="${f}.bak.rollback.$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "${bak}"
  local tmp; tmp=$(mktemp)
  # Reemite 'worker_processes auto;' no lugar do bloco: do_nginx_affinity apagou
  # as diretivas avulsas originais, e nginx.conf SEM worker_processes cai no
  # default do nginx = 1 worker (bomba-relogio ate o proximo reload).
  awk -v B="${NGINX_BLOCK_BEGIN}" -v E="${NGINX_BLOCK_END}" '
    { sub(/\r$/, "") }
    $0==B {in_block=1; print "worker_processes auto;"; next}
    $0==E {in_block=0; next}
    in_block {next}
    { print }
  ' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
  ok "bloco removido, 'worker_processes auto;' reposto (backup em ${bak})"
  log "Para aplicar: nginx -s reload"
}

# Remove flags de isolamento (isolcpus/nohz_full/rcu_nocbs/irqaffinity) de
# GRUB_CMDLINE_LINUX_DEFAULT em /etc/default/grub. Roda update-grub. Avisa
# que o efeito so vem com REBOOT.
do_remove_grub_isolation() {
  require_root
  [ -f "${GRUB_DEFAULT}" ] || { log "${GRUB_DEFAULT} ausente"; return 0; }
  local current
  current=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "${GRUB_DEFAULT}" | head -1)
  if ! echo "${current}" | grep -qE 'isolcpus=|nohz_full=|rcu_nocbs=|irqaffinity='; then
    log "${GRUB_DEFAULT} sem flags de isolamento -- nada a remover"
    return 0
  fi
  log "rollback: removendo isolcpus/nohz_full/rcu_nocbs/irqaffinity de ${GRUB_DEFAULT}"
  local cleaned
  cleaned=$(echo "${current}" | sed -E 's/(isolcpus|nohz_full|rcu_nocbs|irqaffinity)=[^ "]+\s*//g; s/ +"$/"/; s/  +/ /g')
  log "antes : ${current}"
  log "depois: ${cleaned}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') reescrever GRUB_CMDLINE_LINUX_DEFAULT em ${GRUB_DEFAULT}"
    echo "  $(c_cya '[dry-run]') update-grub"
    return 0
  fi
  local bak="${GRUB_DEFAULT}.bak.rollback.$(date +%Y%m%d-%H%M%S)"
  cp -a "${GRUB_DEFAULT}" "${bak}"
  local was_immutable=0
  if is_immutable "${GRUB_DEFAULT}"; then
    was_immutable=1
    chattr -i "${GRUB_DEFAULT}" || die "chattr -i falhou"
  fi
  awk -v repl="${cleaned}" '
    /^GRUB_CMDLINE_LINUX_DEFAULT=/ && !done { print repl; done=1; next }
    { print }
  ' "${GRUB_DEFAULT}" > "${GRUB_DEFAULT}.tmp"
  cat "${GRUB_DEFAULT}.tmp" > "${GRUB_DEFAULT}"
  rm -f "${GRUB_DEFAULT}.tmp"
  [ "$was_immutable" -eq 1 ] && chattr +i "${GRUB_DEFAULT}" 2>/dev/null

  local grub_update=""
  command -v update-grub >/dev/null && grub_update="update-grub"
  command -v grub2-mkconfig >/dev/null && [ -f /boot/grub2/grub.cfg ] && grub_update="grub2-mkconfig -o /boot/grub2/grub.cfg"
  if [ -n "${grub_update}" ]; then
    log "rodando ${grub_update}"
    ${grub_update} 2>&1 | tail -3 | sed 's/^/  /'
    ok "GRUB cmdline limpo (backup em ${bak})"
  else
    nok "update-grub/grub2-mkconfig nao encontrado -- rode manualmente"
  fi
  warn "REBOOT necessario para o cmdline limpo entrar em vigor"
}

do_systemd_uninstall() {
  require_root
  section "systemd: uninstall service+path"
  log "removendo units systemd"
  run "systemctl disable --now xuione-net-tune.path    >/dev/null 2>&1 || true"
  run "systemctl disable --now xuione-net-tune.service >/dev/null 2>&1 || true"
  run "rm -f ${SERVICE_DST} ${PATH_DST} ${SCRIPT_DST} ${SCRIPT_DST}.prev"
  run "systemctl daemon-reload"
}

# ---------- comandos ----------
cmd_status() {
  ensure_nic
  warn_hw_if_unsupported

  # Cabecalho
  echo
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  printf '  %sStatus%s   %s%s%s\n' "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$ESC_RST"
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"

  # NIC summary
  local speed mtu link drv combined_cur combined_max rx_ring tx_ring
  speed="$(cat /sys/class/net/${NIC}/speed 2>/dev/null || echo '?')"
  mtu="$(cat /sys/class/net/${NIC}/mtu 2>/dev/null || echo '?')"
  link="$(cat /sys/class/net/${NIC}/operstate 2>/dev/null || echo '?')"
  drv="$(basename "$(readlink -f /sys/class/net/${NIC}/device/driver 2>/dev/null)" 2>/dev/null || echo '?')"
  combined_cur=$(ethtool -l "${NIC}" 2>/dev/null | awk '/Current hardware/{f=1} f && /Combined:/{print $2; exit}')
  combined_max=$(ethtool -l "${NIC}" 2>/dev/null | awk '/Pre-set maximums/{f=1} f && /Combined:/{print $2; exit}')
  rx_ring=$(ethtool -g "${NIC}" 2>/dev/null | awk '/Current hardware/{f=1} f && /^RX:/{print $2; exit}')
  tx_ring=$(ethtool -g "${NIC}" 2>/dev/null | awk '/Current hardware/{f=1} f && /^TX:/{print $2; exit}')

  # Link badge
  local link_badge
  if [ "$link" = "up" ]; then link_badge="$(c_grn "● up")"
  else link_badge="$(c_red "● ${link}")"; fi

  printf '\n%s%s NIC%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST"
  box_kv "iface"   "$(c_bld "${NIC}")  ${link_badge}  $(c_dim "driver=${drv}  ${speed}Mb/s  MTU=${mtu}")"
  box_kv "queues"  "$(c_bld ${combined_cur:-?})$(c_dim "/${combined_max:-?}") combined  $(c_dim "ring RX/TX=")$(c_bld ${rx_ring:-?})$(c_dim "/")$(c_bld ${tx_ring:-?})"

  # IRQ pinning summary
  local total_irqs; total_irqs="$(discover_nic_irqs | wc -w)"
  printf '\n%s%s IRQ pinning%s   %s(%d IRQs total, mostrando primeiras 8)%s\n' \
    "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST" "$ESC_DIM" "$total_irqs" "$ESC_RST"
  printf '  %s%-7s %-9s %s%s\n' "$ESC_DIM" "IRQ" "CPU(s)" "queue" "$ESC_RST"
  local irq idx=0
  for irq in $(discover_nic_irqs | head -8); do
    local cpus name
    cpus="$(cat /proc/irq/${irq}/smp_affinity_list 2>/dev/null)"
    name="$(grep "^ *${irq}:" /proc/interrupts 2>/dev/null | awk '{print $NF}')"
    printf '  %-7s %-9s %s%s%s\n' "$(c_bld ${irq})" "$(c_grn ${cpus})" "$ESC_DIM" "${name}" "$ESC_RST"
    idx=$((idx+1))
  done

  # XPS (primeiras 4)
  printf '\n%s%s XPS%s   %s(primeiras 4 tx queues)%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  for i in 0 1 2 3; do
    local mask; mask="$(cat /sys/class/net/${NIC}/queues/tx-${i}/xps_cpus 2>/dev/null || echo '?')"
    printf '  %-6s %s%s%s\n' "$(c_bld tx-${i})" "$ESC_DIM" "${mask}" "$ESC_RST"
  done

  # RFS / RPS
  printf '\n%s%s RFS%s   %s(primeiras 4 rx queues)%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  for i in 0 1 2 3; do
    local cnt; cnt="$(cat /sys/class/net/${NIC}/queues/rx-${i}/rps_flow_cnt 2>/dev/null || echo '?')"
    local sym; [ "$cnt" = "0" ] && sym="$(c_dim "$SYM_FAIL off")" || sym="$(c_grn "$SYM_OK ${cnt}")"
    printf '  %-6s %s\n' "$(c_bld rx-${i})" "${sym}"
  done

  # qdisc
  local fq_n pf_n
  fq_n=$(tc qdisc show dev "${NIC}" 2>/dev/null | grep -c "qdisc fq " || true)
  pf_n=$(tc qdisc show dev "${NIC}" 2>/dev/null | grep -c "pfifo_fast" || true)
  printf '\n%s%s qdisc%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST"
  if [ "${pf_n:-0}" -eq 0 ] && [ "${fq_n:-0}" -gt 0 ]; then
    printf '  %s%s%s %s%d%s fq classes  %s0 pfifo_fast%s\n' \
      "$ESC_GRN" "$SYM_OK" "$ESC_RST" "$ESC_BLD" "${fq_n}" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  else
    printf '  %s%s%s fq=%d  pfifo_fast=%d\n' "$ESC_YEL" "$SYM_WARN" "$ESC_RST" "${fq_n:-0}" "${pf_n:-0}"
  fi

  # sysctl chaves
  printf '\n%s%s sysctl%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST"
  local sb_state
  if [ -f "${SYSCTL_TARGET}" ] && sysctl_file_has_keys "${SYSCTL_TARGET}"; then
    sb_state="$(c_grn "$SYM_OK $(sysctl_key_count "${SYSCTL_TARGET}") chaves") $(c_dim "em ${SYSCTL_TARGET} (fonte unica)")"
  else
    sb_state="$(c_yel "$SYM_WARN sem chaves") $(c_dim "(gere com 'apply --sysctl-init')")"
  fi
  box_kv "arquivo"    "${sb_state}"
  # Defensivo: defaults se sysctl falhar / chave inexistente / kernel sem o modulo
  local cc qd rmm wmm tw_b plr
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  rmm="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
  wmm="$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)"
  tw_b="$(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null || echo '?')"
  plr="$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | tr '\t' '-')"
  : "${cc:=?}" "${qd:=?}" "${rmm:=0}" "${wmm:=0}" "${tw_b:=?}" "${plr:=?}"
  box_kv "tcp"        "$(c_dim "cc=")$(c_bld ${cc})  $(c_dim "qdisc=")$(c_bld ${qd})"
  box_kv "buffers"    "$(c_dim "rmem_max=")$(c_bld $((rmm/1024/1024))MB)  $(c_dim "wmem_max=")$(c_bld $((wmm/1024/1024))MB)"
  box_kv "ports"      "$(c_dim "ephemeral=")$(c_bld ${plr})  $(c_dim "tw_buckets=")$(c_bld ${tw_b})"

  # Servicos
  printf '\n%s%s servicos%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST"
  local irqb_st; irqb_st="$(systemctl is-active irqbalance 2>&1 | head -1)"
  local irqb_badge
  case "$irqb_st" in
    inactive|failed|"") irqb_badge="$(c_grn "$SYM_OK ${irqb_st:-inactive}")" ;;
    *)                  irqb_badge="$(c_red "$SYM_FAIL ${irqb_st}") $(c_dim "(deve estar inactive)")" ;;
  esac
  box_kv "irqbalance" "${irqb_badge}"

  for u in xuione-net-tune.service xuione-net-tune.path; do
    local en; en="$(systemctl is-enabled $u 2>/dev/null || echo 'not-installed')"
    local ub
    case "$en" in
      enabled) ub="$(c_grn "$SYM_OK enabled")" ;;
      disabled) ub="$(c_yel "$SYM_WARN disabled")" ;;
      *) ub="$(c_dim "$SYM_FAIL ${en}")" ;;
    esac
    box_kv "${u}" "${ub}"
  done

  # Avisos finais (drift do script, NIC inexistente)
  local drift_msgs=""
  local self; self="$(readlink -f "$0")"
  if [ -f "${SCRIPT_DST}" ] && [ "${self}" != "${SCRIPT_DST}" ]; then
    if ! cmp -s "${self}" "${SCRIPT_DST}" 2>/dev/null; then
      drift_msgs+=$'\n'"  $(tag_warn) $(c_bld "${self}")$(c_dim " difere de ")$(c_bld "${SCRIPT_DST}")"
      drift_msgs+=$'\n'"     $(c_dim "A unit chama ${SCRIPT_DST}. Rode 'apply --systemd' para sincronizar.")"
    fi
  fi
  if [ -f "${SERVICE_DST}" ]; then
    local cond_nic
    cond_nic=$(grep -E '^ConditionPathExists=' "${SERVICE_DST}" 2>/dev/null | sed 's|.*/net/||' | head -1)
    if [ -n "${cond_nic}" ] && [ ! -e "/sys/class/net/${cond_nic}" ]; then
      drift_msgs+=$'\n'"  $(tag_warn) ConditionPathExists=$(c_bld ${cond_nic}) $(c_dim "mas NIC nao existe")"
      drift_msgs+=$'\n'"     $(c_dim "Unit nunca dispara. Re-instale com 'apply --systemd --nic <NIC>'")"
    fi
  fi
  if [ -n "${drift_msgs}" ]; then
    printf '\n%s%s avisos%s%s\n' "$ESC_YEL" "$SYM_DIAMOND" "$ESC_RST" "${drift_msgs}"
  fi
  echo
}

## Le ExecStart= da unit instalada e auto-popula TARGET_IRQS / RESERVED_CCX_LIST
## / CACHE_FIRST se o operador NAO passou explicitamente. Garante que validate
## (e outros comandos read-only) comparem contra o plano REAL aplicado, nao
## contra defaults que podem divergir.
read_installed_flags() {
  [ -f "${SERVICE_DST}" ] || return 0
  local execstart
  execstart="$(grep -E '^ExecStart=' "${SERVICE_DST}" 2>/dev/null | head -1)"
  [ -n "${execstart}" ] || return 0
  # --irqs N
  if [ "${TARGET_IRQS}" -eq 0 ]; then
    if [[ "${execstart}" =~ --irqs[[:space:]]+([0-9]+) ]]; then
      TARGET_IRQS="${BASH_REMATCH[1]}"
      log "auto-detect: --irqs=${TARGET_IRQS} (lido de ${SERVICE_DST})"
    fi
  fi
  # --rfs-per-queue N
  if [ "${RFS_PER_QUEUE}" -eq 0 ]; then
    if [[ "${execstart}" =~ --rfs-per-queue[[:space:]]+([0-9]+) ]]; then
      RFS_PER_QUEUE="${BASH_REMATCH[1]}"
      log "auto-detect: --rfs-per-queue=${RFS_PER_QUEUE} (lido de ${SERVICE_DST})"
    fi
  fi
  # --reserve-ccx LIST  (LIST = digitos, virgulas, hifens)
  if [ -z "${RESERVED_CCX_LIST}" ]; then
    if [[ "${execstart}" =~ --reserve-ccx[[:space:]]+([0-9,-]+) ]]; then
      RESERVED_CCX_LIST="${BASH_REMATCH[1]}"
      log "auto-detect: --reserve-ccx=${RESERVED_CCX_LIST} (lido de ${SERVICE_DST})"
    fi
  fi
  # --cache-first (boolean)
  if [ "${CACHE_FIRST}" != "1" ]; then
    if [[ "${execstart}" =~ --cache-first ]]; then
      CACHE_FIRST=1
      log "auto-detect: --cache-first (lido de ${SERVICE_DST})"
    fi
  fi
  # --isolcpus-domain (boolean)
  if [ "${ISOLCPUS_DOMAIN}" != "1" ]; then
    if [[ "${execstart}" =~ --isolcpus-domain ]]; then
      ISOLCPUS_DOMAIN=1
      log "auto-detect: --isolcpus-domain (lido de ${SERVICE_DST})"
    fi
  fi
  # --nohz-full (boolean)
  if [ "${NOHZ_FULL}" != "1" ]; then
    if [[ "${execstart}" =~ --nohz-full ]]; then
      NOHZ_FULL=1
      log "auto-detect: --nohz-full (lido de ${SERVICE_DST})"
    fi
  fi
  # --nginx-pin-mode MODE
  if [ "${NGINX_PIN_MODE}" = "spread" ]; then
    if [[ "${execstart}" =~ --nginx-pin-mode[[:space:]]+(spread|smt-irq) ]]; then
      NGINX_PIN_MODE="${BASH_REMATCH[1]}"
      log "auto-detect: --nginx-pin-mode=${NGINX_PIN_MODE} (lido de ${SERVICE_DST})"
    fi
  fi
  # --segregate-network (boolean)
  if [ "${SEGREGATE_NETWORK}" != "1" ]; then
    if [[ "${execstart}" =~ --segregate-network ]]; then
      SEGREGATE_NETWORK=1
      log "auto-detect: --segregate-network (lido de ${SERVICE_DST})"
    fi
  fi
  # --force-hw (boolean)
  if [ "${FORCE_HW}" != "1" ]; then
    if [[ "${execstart}" =~ --force-hw ]]; then
      FORCE_HW=1
      log "auto-detect: --force-hw (lido de ${SERVICE_DST})"
    fi
  fi
}

cmd_validate() {
  ensure_nic
  warn_hw_if_unsupported
  read_installed_flags   # auto-popula flags do unit instalado se operador nao passou
  ensure_plan   # popula QUEUES + IRQ_CPUS_ARR (caso contrario validacoes comparam contra 0)
  # read_installed_flags so olha ${SERVICE_DST}; se quem tunou este host foi o
  # xuione-ccd-net.sh, o plano cai no DEFAULT e o validate reporta FAIL em
  # massa (combined, RSS, IRQ, XPS, qdisc) contra um plano que ninguem aplicou.
  if [ ! -f "${SERVICE_DST}" ] && \
     { [ "$(systemctl is-active xuione-ccd-net.service 2>/dev/null)" = "active" ] || \
       [ "$(systemctl is-enabled xuione-ccd-net.path 2>/dev/null)" = "enabled" ]; }; then
    warn "tuning ativo e do xuione-ccd-net.sh (nao ha ${SERVICE_DST}); o plano default (${QUEUES} filas) NAO descreve este host"
    warn "  use: ./xuione-ccd-net.sh --nic ${NIC} --analyze"
    warn "  ou:  $0 --nic ${NIC} --irqs <combined atual> --force-legacy validate"
    [ "${FORCE_LEGACY}" -eq 1 ] || die "validate abortado para nao reportar FAILs falsos"
  fi
  set +e   # validate deve continuar mesmo com FAILs para mostrar resumo completo
  local fail=0 ok_count=0 fail_count=0
  # Wrappers locais que usam os simbolos novos + tally
  c_ok()   { printf '  %s %s\n' "$(tag_ok)"   "$*"; ok_count=$((ok_count+1)); }
  c_fail() { printf '  %s %s\n' "$(tag_fail)" "$*"; fail_count=$((fail_count+1)); fail=1; }
  c_warn() { printf '  %s %s\n' "$(tag_warn)" "$*"; }

  echo
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  printf '  %sValidate%s   %sNIC=%s   %s%s%s\n' "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "${NIC}" "$ESC_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$ESC_RST"
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  echo

  # 1) Filas combined
  local cur_q
  cur_q=$(ethtool -l "${NIC}" 2>/dev/null | awk '/Current hardware/{f=1} f && /Combined:/{print $2; exit}')
  if [ "${cur_q}" = "${QUEUES}" ]; then
    c_ok "Filas combined = ${QUEUES}"
  else
    c_fail "Filas combined = ${cur_q} (esperado ${QUEUES})"
  fi

  # 1b) Tabela RSS (indirection): detecta o bug "metade das rings mortas"
  # observado em mlx5/bnxt apos mudanca de channels. ice reseta sozinho;
  # validar mesmo assim protege contra regressao de driver e portabilidade.
  local rss_rings rss_distinct rss_oor
  rss_rings=$(ethtool -x "${NIC}" 2>/dev/null \
    | awk '/^[[:space:]]+[0-9]+:/{for(i=2;i<=NF;i++) print $i}' \
    | sort -un)
  if [ -z "${rss_rings}" ]; then
    c_warn "RSS table: ethtool -x nao retornou entradas em ${NIC}"
  else
    rss_distinct=$(echo "${rss_rings}" | wc -l)
    rss_oor=$(echo "${rss_rings}" | awk -v q="${QUEUES}" '$1+0 >= q+0 {print $1}' | tr '\n' ' ')
    if [ -n "${rss_oor}" ]; then
      c_fail "RSS table cita rings fora de [0,$((QUEUES-1))]: ${rss_oor}"
    elif [ "${rss_distinct}" -ne "${QUEUES}" ]; then
      c_fail "RSS table usa ${rss_distinct} rings distintos (esperado ${QUEUES}) -- rebalanceamento ethtool -X faltando"
    else
      c_ok "RSS table: ${rss_distinct} rings distintos cobertos uniformemente"
    fi
  fi

  # 2) Ring buffers
  local rx_ring tx_ring
  rx_ring=$(ethtool -g "${NIC}" 2>/dev/null | awk '/Current hardware/{f=1} f && /^RX:/{print $2; exit}')
  tx_ring=$(ethtool -g "${NIC}" 2>/dev/null | awk '/Current hardware/{f=1} f && /^TX:/{print $2; exit}')
  if [ "${rx_ring}" = "8160" ] && [ "${tx_ring}" = "8160" ]; then
    c_ok "Ring buffers RX/TX = 8160/8160"
  else
    c_fail "Ring buffers RX=${rx_ring} TX=${tx_ring} (esperado 8160/8160)"
  fi

  # 3) IRQ pinning -- compara contra IRQ_CPUS_ARR[i] (plano real, distribuido por CCX),
  # nao contra i sequencial (que so seria correto se plan fosse 0..63 puro).
  local irqs nirq mismatch=0 irq cpu i=0 expected_cpu
  irqs=$(discover_nic_irqs)
  nirq=$(echo "$irqs" | wc -w)
  for irq in $irqs; do
    cpu=$(cat /proc/irq/${irq}/smp_affinity_list 2>/dev/null)
    if [ "$i" -lt "${QUEUES}" ]; then
      expected_cpu="${IRQ_CPUS_ARR[$i]}"
      [ "$cpu" != "$expected_cpu" ] && mismatch=$((mismatch+1))
    fi
    i=$((i+1))
  done
  if [ "${nirq}" -ge "${QUEUES}" ] && [ "${mismatch}" -eq 0 ]; then
    c_ok "IRQ pinning: ${nirq} IRQs alinhados com plano (CCX-aware)"
  else
    c_fail "IRQ pinning: ${nirq} IRQs, ${mismatch} fora do plano"
  fi

  # 4) XPS sibling-pattern -- usa plano real (IRQ_CPUS_ARR[q] + seu SMT sibling)
  # Clampado pelo numero real de filas TX: se a NIC tem menos filas que o plano,
  # o `cat` de uma fila inexistente mataria o validate (set -e).
  local xps_fail=0 q core sib mask expected vntx=0 vnq="${QUEUES}" _tq
  for _tq in "/sys/class/net/${NIC}/queues/"tx-*; do
    if [ -d "${_tq}" ]; then vntx=$((vntx+1)); fi
  done
  if [ "${vntx}" -gt 0 ] && [ "${vntx}" -lt "${vnq}" ]; then vnq="${vntx}"; fi
  for q in $(seq 0 $((vnq-1))); do
    core="${IRQ_CPUS_ARR[$q]}"
    sib="$(smt_sibling_of "$core")"
    expected=$(mask_for_two_cpus "$core" "$sib")
    mask=$(cat /sys/class/net/${NIC}/queues/tx-$q/xps_cpus 2>/dev/null || true)
    [ "$mask" != "$expected" ] && xps_fail=$((xps_fail+1))
  done
  if [ "${xps_fail}" -eq 0 ]; then
    c_ok "XPS sibling-pattern em ${vnq} filas"
  else
    c_fail "XPS divergente em ${xps_fail} filas"
  fi

  # 5) RFS configurado conforme RFS_PER_QUEUE
  local rfs_actual
  rfs_actual=$(cat /sys/class/net/${NIC}/queues/rx-0/rps_flow_cnt 2>/dev/null)
  if [ "${RFS_PER_QUEUE}" -eq 0 ] && [ "${rfs_actual}" = "0" ]; then
    c_ok "RFS DESLIGADO (rps_flow_cnt=0)"
  elif [ "${RFS_PER_QUEUE}" -gt 0 ] && [ "${rfs_actual}" = "${RFS_PER_QUEUE}" ]; then
    c_ok "RFS = ${RFS_PER_QUEUE} por fila"
  else
    c_fail "RFS rps_flow_cnt=${rfs_actual} (esperado ${RFS_PER_QUEUE})"
  fi

  # 6) RPS desligado
  local rps_set=0
  for q in /sys/class/net/${NIC}/queues/rx-*/rps_cpus; do
    local v; v=$(cat "$q" | tr -d ',0')
    [ -n "$v" ] && rps_set=$((rps_set+1))
  done
  [ "${rps_set}" -eq 0 ] && c_ok "RPS=0 em todas as filas" || c_fail "RPS != 0 em ${rps_set} filas"

  # 7) qdisc fq
  local fq_count pf_count
  fq_count=$(tc qdisc show dev "${NIC}" | grep -c "qdisc fq " 2>/dev/null)
  pf_count=$(tc qdisc show dev "${NIC}" | grep -c "pfifo_fast" 2>/dev/null)
  if [ "${fq_count}" -ge "${QUEUES}" ] && [ "${pf_count}" -eq 0 ]; then
    c_ok "qdisc: ${fq_count} fq classes, 0 pfifo_fast"
  else
    c_fail "qdisc: ${fq_count} fq, ${pf_count} pfifo_fast"
  fi

  # 8) Coalesce
  local cstate
  cstate=$(ethtool -c "${NIC}" 2>/dev/null | awk '/Adaptive/{print $3"/"$5}')
  if [ "${cstate}" = "on/on" ]; then
    c_ok "Coalesce adaptive on/on"
  else
    c_warn "Coalesce: ${cstate}"
  fi

  # 8b) ntuple-filters off (sem aRFS, sem regras manuais)
  local nt
  nt=$(ethtool -k "${NIC}" 2>/dev/null | awk -F: '/^ntuple-filters:/{gsub(/ /,"",$2); print $2}')
  if [ "${nt}" = "off" ]; then
    c_ok "ntuple-filters off"
  else
    c_warn "ntuple-filters=${nt} (esperado off neste perfil)"
  fi

  # 10) ${SYSCTL_TARGET} e a FONTE UNICA: existe + tem chaves, e CADA chave do
  # arquivo esta de fato em vigor no runtime (substitui os sentinels antigos).
  local sysctl_keys_present=0 v_total v_div v_ndiv vk vf vr v_all v_missing v_wo v_nwo
  if [ -f "${SYSCTL_TARGET}" ] && sysctl_file_has_keys "${SYSCTL_TARGET}"; then
    v_total=$(sysctl_key_count "${SYSCTL_TARGET}")
    v_all=$(sysctl_file_keys "${SYSCTL_TARGET}" | wc -l)
    c_ok "${SYSCTL_TARGET} presente com ${v_total} chaves validas de ${v_all} no arquivo (fonte unica)"
    sysctl_keys_present=1
    # Chaves que o kernel nao conhece somem do denominador (sysctl -e as ignora):
    # sem este aviso o validate diria "N/N em vigor" escondendo o gap -- p.ex.
    # as 7 chaves net.netfilter.* quando nf_conntrack nao esta carregado.
    v_missing=$(sysctl_missing_keys "${SYSCTL_TARGET}")
    if [ -n "${v_missing}" ]; then
      c_warn "sysctl: chaves do arquivo inexistentes neste kernel (ignoradas por -e):${v_missing}"
    fi
    # Write-only (route.flush, drop_caches...): existem mas `sysctl -n` volta
    # vazio -- ficam fora do denominador em vez de virar FAIL permanente.
    v_wo=$(sysctl_writeonly_keys "${SYSCTL_TARGET}")
    if [ -n "${v_wo}" ]; then
      v_nwo=$(printf '%s' "${v_wo}" | wc -w)
      v_total=$((v_total - v_nwo))
      c_warn "sysctl: ${v_nwo} chave(s) write-only, nao verificaveis:${v_wo}"
    fi
    v_div="$(sysctl_runtime_diff "${SYSCTL_TARGET}")"
    if [ -z "${v_div}" ]; then
      c_ok "sysctl: ${v_total}/${v_total} chaves do arquivo em vigor"
    else
      v_ndiv=$(printf '%s\n' "${v_div}" | wc -l)
      c_fail "sysctl: $((v_total - v_ndiv))/${v_total} chaves do arquivo em vigor (${v_ndiv} divergente(s))"
      while IFS='|' read -r vk vf vr; do
        [ -n "${vk}" ] || continue
        printf '       %s%s (arquivo=%s runtime=%s)%s\n' "$ESC_DIM" "${vk}" "${vf}" "${vr:-<vazio>}" "$ESC_RST"
      done <<< "${v_div}"
    fi
  else
    c_warn "${SYSCTL_TARGET} sem chaves (kernel defaults em uso -- gere com 'apply --sysctl-init')"
  fi

  # 10b) sysctl.conf travado (chattr +i), lido no boot, sem conflito em sysctl.d
  if is_immutable "${SYSCTL_TARGET}"; then
    c_ok "${SYSCTL_TARGET} travado (chattr +i)"
  else
    c_fail "${SYSCTL_TARGET} SEM chattr +i (apply re-trava)"
  fi
  if [ -L "${SYSCTL_BOOT_LINK}" ] && [ "$(readlink -f "${SYSCTL_BOOT_LINK}" 2>/dev/null)" = "${SYSCTL_TARGET}" ]; then
    c_ok "boot: ${SYSCTL_BOOT_LINK} -> ${SYSCTL_TARGET} (systemd-sysctl aplica no boot)"
  else
    c_fail "boot: ${SYSCTL_BOOT_LINK} ausente/errado -- ${SYSCTL_TARGET} NAO e aplicado no boot (apply cria)"
  fi
  # Fonte unica: conflito em /etc/sysctl.d = FAIL (apply desativa o arquivo);
  # /usr/lib e /run (distro) sao sobrescritos pela ordem -- informativo.
  local cf_k cf_base cf_theirs cf_ours cf_dir cf_n=0
  while IFS='|' read -r cf_k cf_base cf_theirs cf_ours _ cf_dir; do
    if [ "${cf_dir}" = "/etc/sysctl.d" ]; then
      cf_n=$((cf_n + 1))
      c_fail "fonte unica violada: ${cf_k}=${cf_theirs} em ${cf_dir}/${cf_base} vs ${cf_ours} em sysctl.conf (apply desativa)"
    else
      c_ok "sysctl: ${cf_k}=${cf_theirs} em ${cf_dir}/${cf_base} (distro) sobrescrito por sysctl.conf (${cf_ours})"
    fi
  done < <(sysctl_d_conflicts "${SYSCTL_TARGET}")
  [ "${cf_n}" -eq 0 ] && c_ok "fonte unica: nenhum conflito em /etc/sysctl.d com ${SYSCTL_TARGET}"

  # 9) sysctl chave -- so c_fail se o arquivo TEM chaves E o valor nao bate.
  # Sem chaves no arquivo, valores default sao ok (escolha do operador).
  local cc qd rmm wmm rsfe
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  rmm=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
  wmm=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
  rsfe=$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null || echo 0)
  # cc/qd: BBR e fq sao defaults do xanmod tambem -- sempre esperados, c_warn se nao
  [ "${cc}" = "bbr" ]                && c_ok "tcp_congestion_control=bbr"     || c_warn "tcp_congestion_control=${cc} (xanmod pode ter bbr3 disponivel)"
  [ "${qd}" = "fq" ]                 && c_ok "default_qdisc=fq"               || c_warn "default_qdisc=${qd} (esperado fq -- kernel xanmod default)"
  # rmem/wmem: condicional ao bloco do script
  if [ "${sysctl_keys_present}" -eq 1 ]; then
    [ "${rmm}" -ge 268435456 ]       && c_ok "rmem_max>=256MB (${rmm})"       || c_fail "rmem_max=${rmm} (perfil 100G espera >=256MB)"
    [ "${wmm}" -ge 268435456 ]       && c_ok "wmem_max>=256MB (${wmm})"       || c_fail "wmem_max=${wmm} (perfil 100G espera >=256MB)"
  else
    c_warn "rmem_max=${rmm} wmem_max=${wmm} (defaults do kernel; ${SYSCTL_TARGET} sem chaves)"
  fi
  if [ "${RFS_PER_QUEUE}" -eq 0 ]; then
    [ "${rsfe}" = "0" ]              && c_ok "rps_sock_flow_entries=0"        || c_warn "rps_sock_flow_entries=${rsfe} (RFS off, esperado 0)"
  fi

  # 11) irqbalance off
  local irqb
  irqb=$(systemctl is-active irqbalance 2>&1 | head -1)
  case "${irqb}" in
    inactive|failed|"") c_ok "irqbalance ${irqb:-inactive}" ;;
    *)                  c_fail "irqbalance ${irqb}" ;;
  esac

  # 12) blacklist irdma
  if [ -f "${MODPROBE_DST}" ]; then
    c_ok "blacklist irdma instalado"
  else
    c_warn "blacklist irdma nao instalado (efeito apenas no proximo boot)"
  fi

  # 13) systemd persistencia
  local svc pth
  svc=$(systemctl is-enabled xuione-net-tune.service 2>/dev/null || echo not-installed)
  pth=$(systemctl is-enabled xuione-net-tune.path 2>/dev/null || echo not-installed)
  if [ "${svc}" = "enabled" ] && [ "${pth}" = "enabled" ]; then
    c_ok "systemd persistencia: service+path enabled"
  else
    c_warn "systemd: service=${svc} path=${pth} (use 'apply --systemd' para persistir)"
  fi

  # 14) Trafego e drops em 5s
  echo
  printf '%s%s saude da rede em 5s%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST"
  local R1 T1 R2 T2 RXD1 RXD2 SQ1 SQ2 SD1 SD2
  R1=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*rx_bytes:/ {print $2; exit}')
  T1=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*tx_bytes:/ {print $2; exit}')
  RXD1=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*rx_dropped:/ {print $2; exit}')
  SQ1=$(awk '{s+=strtonum("0x"$3)} END{print s}' /proc/net/softnet_stat)
  SD1=$(awk '{d+=strtonum("0x"$2)} END{print d}' /proc/net/softnet_stat)
  sleep 5
  R2=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*rx_bytes:/ {print $2; exit}')
  T2=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*tx_bytes:/ {print $2; exit}')
  RXD2=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*rx_dropped:/ {print $2; exit}')
  SQ2=$(awk '{s+=strtonum("0x"$3)} END{print s}' /proc/net/softnet_stat)
  SD2=$(awk '{d+=strtonum("0x"$2)} END{print d}' /proc/net/softnet_stat)
  : "${R1:=0}" "${T1:=0}" "${R2:=0}" "${T2:=0}" "${RXD1:=0}" "${RXD2:=0}"
  printf '  %sRX:%s %s Mbps    %sTX:%s %s Mbps\n' \
    "$ESC_BLD" "$ESC_RST" "$(c_grn $(((R2-R1)*8/5/1000000)))" \
    "$ESC_BLD" "$ESC_RST" "$(c_grn $(((T2-T1)*8/5/1000000)))"
  [ "$((RXD2-RXD1))" -eq 0 ] && c_ok "rx_dropped delta = 0" || c_warn "rx_dropped delta = $((RXD2-RXD1))"
  [ "$((SD2-SD1))" -eq 0 ]   && c_ok "softnet drops delta = 0" || c_fail "softnet drops delta = $((SD2-SD1))"
  [ "$((SQ2-SQ1))" -lt 100 ] && c_ok "softnet squeezes delta < 100 ($((SQ2-SQ1)))" || c_warn "softnet squeezes delta = $((SQ2-SQ1))"

  # Resumo final
  echo
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  if [ "${fail_count}" -eq 0 ]; then
    printf '  %s %sCONCLUIDO%s   %s%d ok%s   %s%d fail%s\n' \
      "$(c_grn "$SYM_OK")" "$ESC_GRN" "$ESC_RST" \
      "$ESC_GRN" "${ok_count}" "$ESC_RST" "$ESC_DIM" "${fail_count}" "$ESC_RST"
  else
    printf '  %s %sCOM FALHAS%s   %s%d ok%s   %s%d fail%s\n' \
      "$(c_red "$SYM_FAIL")" "$ESC_RED" "$ESC_RST" \
      "$ESC_GRN" "${ok_count}" "$ESC_RST" "$ESC_RED" "${fail_count}" "$ESC_RST"
  fi
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  return ${fail}
}

cmd_collect() {
  local tag="${1:-snapshot}"
  local out="${SCRIPT_DIR}/metrics-${tag}-$(date +%Y%m%d-%H%M%S).txt"
  ensure_nic
  {
    echo "=== TAG: ${tag} ==="; date; echo
    echo "--- NIC stats snapshot (via ethtool -S, autoritativo) ---"
    ethtool -S "${NIC}" 2>/dev/null | grep -E "^[[:space:]]*(rx|tx)_(bytes|packets|unicast):" | head -8
    echo
    echo "--- taxa em 5s (via ethtool -S, contornando bug do /sys apos ethtool -L) ---"
    local R1 T1 RP1 TP1 R2 T2 RP2 TP2
    R1=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*rx_bytes:/ {print $2; exit}')
    T1=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*tx_bytes:/ {print $2; exit}')
    RP1=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*rx_unicast:/ {print $2; exit}')
    TP1=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*tx_unicast:/ {print $2; exit}')
    sleep 5
    R2=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*rx_bytes:/ {print $2; exit}')
    T2=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*tx_bytes:/ {print $2; exit}')
    RP2=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*rx_unicast:/ {print $2; exit}')
    TP2=$(ethtool -S "${NIC}" 2>/dev/null | awk '/^[[:space:]]*tx_unicast:/ {print $2; exit}')
    echo "RX: $(( (R2-R1)*8/5/1000000 )) Mbps  $(( (RP2-RP1)/5 )) pps"
    echo "TX: $(( (T2-T1)*8/5/1000000 )) Mbps  $(( (TP2-TP1)/5 )) pps"
    echo
    echo "--- softnet ---"
    awk '{tot+=strtonum("0x"$1); drop+=strtonum("0x"$2); sq+=strtonum("0x"$3)} END{print "processed="tot" drops="drop" squeezes="sq}' /proc/net/softnet_stat
    echo
    echo "--- ethtool drops/erros nao-zero ---"
    ethtool -S "${NIC}" 2>/dev/null | grep -iE "drop|err|busy|restart|alloc_fail" | grep -v ":0$" || echo "(nenhum)"
    echo
    echo "--- TCP ---"
    nstat -az 2>/dev/null | grep -E "TcpRetransSegs|TCPLostRetrans|TCPTimeouts|ListenDrops|ListenOverflows|TCPBacklogDrop|TCPSynRetrans|TCPMemoryPressure" || true
    echo
    echo "--- sockets ---"; ss -s
    echo
    echo "--- load ---"; uptime
  } | tee "${out}"
  echo
  log "salvo em ${out}"
}

cmd_apply() {
  local mode_all=0
  local m_sysctl=0 m_modp=0
  local m_sinit=0 m_sinit_force=0
  local m_nicall=0 m_irq=0 m_xps=0 m_rfs=0 m_coa=0 m_ring=0 m_rss=0
  local m_sysd=0 no_sysd=0 m_xuiaff=0 no_xuiaff=0
  local m_grub=0 m_disable_rtmp=0
  local irqbal=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --all)             mode_all=1 ;;
      --sysctl)          m_sysctl=1 ;;
      --sysctl-init)     m_sinit=1 ;;
      --sysctl-init-force) m_sinit=1; m_sinit_force=1 ;;
      --modprobe)        m_modp=1 ;;
      --nic-all)         m_nicall=1 ;;
      --irq)             m_irq=1 ;;
      --xps)             m_xps=1 ;;
      --rfs)             m_rfs=1 ;;
      --coalesce)        m_coa=1 ;;
      --ring)            m_ring=1 ;;
      --rss)             m_rss=1 ;;
      --systemd)         m_sysd=1 ;;
      --no-systemd)      no_sysd=1 ;;
      --xui-affinity)    m_xuiaff=1 ;;
      --no-xui-affinity) no_xuiaff=1 ;;
      --grub)            m_grub=1 ;;
      --disable-rtmp)    m_disable_rtmp=1 ;;
      --irqbalance)      shift || true; irqbal="${1:-off}" ;;
      *) die "apply: flag desconhecida '$1' (use -h)" ;;
    esac
    shift || break   # se foi o ultimo arg, sai limpo (set -e nao mata em loop vazio)
  done

  # Consolidacao: --grub IMPLICA --xui-affinity (CPUAffinity systemd + nginx).
  # Sem isso, isolcpus removeria os cores do scheduler e o nginx ficaria preso
  # apenas no CCX de housekeeping -- estado quebrado em producao.
  # Respeita --no-xui-affinity se o operador foi explicito.
  if [ "${m_grub}" -eq 1 ] && [ "${no_xuiaff}" -eq 0 ] && [ "${m_xuiaff}" -eq 0 ] && [ "${mode_all}" -eq 0 ]; then
    log "--grub implica --xui-affinity (CPUAffinity precisa casar com isolcpus)"
    m_xuiaff=1
  fi

  # --sysctl-init so pode gerar o arquivo se ele ainda nao tem chaves. Checa
  # AQUI (antes de qualquer fase) para 'apply --all --sysctl-init' nao abortar
  # no meio, com irqbalance ja desligado.
  [ "${m_sinit}" -eq 1 ] && sysctl_init_guard "${m_sinit_force}"

  local total=$((mode_all+m_sysctl+m_sinit+m_modp+m_nicall+m_irq+m_xps+m_rfs+m_coa+m_ring+m_rss+m_sysd+m_xuiaff+m_grub+m_disable_rtmp))
  if [ "${total}" -eq 0 ] && [ -z "${irqbal}" ]; then
    log "sem flags -> aplicando --all"
    mode_all=1
  fi

  # Bloqueia se o script canonico (xuione-ccd-net) estiver instalado -- antes
  # de qualquer escrita (sysctl/nginx/cron/NIC).
  require_no_ccdnet_conflict "apply"

  # Bloqueia em hardware nao testado (a menos que --force-hw) APENAS se a
  # invocacao toca NIC/IRQ. apply --sysctl/--modprobe/--irqbalance puros nao
  # dependem de hw e podem rodar em qualquer maquina. NIC ainda nao foi
  # resolvida aqui -- o check de driver da NIC roda DEPOIS via _hw_recheck_nic.
  local touches_hw=0
  [ "${mode_all}"  -eq 1 ] && touches_hw=1
  [ "${m_nicall}"  -eq 1 ] && touches_hw=1
  [ "${m_irq}"     -eq 1 ] && touches_hw=1
  [ "${m_xps}"     -eq 1 ] && touches_hw=1
  [ "${m_rfs}"     -eq 1 ] && touches_hw=1
  [ "${m_coa}"     -eq 1 ] && touches_hw=1
  [ "${m_ring}"    -eq 1 ] && touches_hw=1
  [ "${m_rss}"     -eq 1 ] && touches_hw=1
  [ "${m_grub}"    -eq 1 ] && touches_hw=1
  [ "${touches_hw}" -eq 1 ] && require_hw_supported

  # Qualquer fase que pina IRQ (--irq / --nic-all) implica irqbalance off,
  # salvo --irqbalance explicito. Definido ANTES de count_phases para a
  # numeracao [n/total] sair certa.
  if [ -z "${irqbal}" ] && { [ "${m_nicall}" -eq 1 ] || [ "${m_irq}" -eq 1 ]; }; then
    irqbal="off"
  fi

  # reset tally + numeracao de fases
  G_OK=0; G_NOK=0; PHASE_CUR=0
  PHASE_TOTAL=$(count_phases "${mode_all}" "${m_sysctl}" "${m_modp}" "${irqbal}" \
                             "${m_nicall}" "${m_irq}" "${m_xps}" "${m_rfs}" \
                             "${m_coa}" "${m_ring}" \
                             "${m_xuiaff}" "${no_xuiaff}" "${m_sysd}" "${no_sysd}" \
                             "${m_grub}" "${m_disable_rtmp}" "${m_rss}" "${m_sinit}")

  # Header precisa de NIC + topologia/plano resolvidos para popular o box.
  # Silencia stdout do ensure_plan (so o log "auto --irqs=N") para nao
  # poluir o visual antes do box -- o valor ja vai aparecer em config.
  # So abre o menu interativo se ha TTY de fato: com stderr descartado o menu
  # sumiria mas o `read </dev/tty` continuaria bloqueando (apply travado sem
  # nenhuma saida). Sem TTY seguimos silenciosos -- ensure_nic/do_* falham
  # depois com mensagem clara.
  if [ -z "${NIC}" ] && [ -t 0 ] && [ -t 2 ]; then NIC="$(prompt_nic || true)"; fi
  [ "${NUM_CCX}" -gt 0 ] || ensure_plan >/dev/null
  echo
  header_box

  if [ "${mode_all}" -eq 1 ]; then
    ensure_nic   # falha cedo se NIC nao informada (antes de mexer em sysctl)
    # Re-check do hw com NIC conhecida (1a chamada antes de prompt_nic nao
    # tinha NIC, entao o driver nao foi validado). Se driver != ice, bloqueia
    # aqui antes de qualquer mudanca real.
    [ "${touches_hw}" -eq 1 ] && require_hw_supported
    ensure_plan
    segregate_leaves_no_app_cpu && die "$(segregate_empty_msg)"
    # irqbalance PRIMEIRO: ativo, ele reescreve smp_affinity segundos depois do
    # pinning; so "enabled", volta no boot. stop + disable antes de tocar em
    # qualquer coisa garante que nada do que vem abaixo seja desfeito.
    do_irqbalance off
    # --sysctl-init substitui a fase de sysctl: gera o arquivo do template e
    # ja aplica/verifica/trava. Sem ele, do_sysctl so aplica o que o operador
    # escreveu em ${SYSCTL_TARGET}.
    if [ "${m_sinit}" -eq 1 ]; then
      do_sysctl_init "${m_sinit_force}"
    else
      do_sysctl
    fi
    do_modprobe
    do_nic_all
    if [ "${no_xuiaff}" -eq 1 ]; then
      log "skip xui-affinity (--no-xui-affinity)"
    else
      do_xui_affinity
    fi
    if [ "${no_sysd}" -eq 1 ] && [ ! -f "${SERVICE_DST}" ]; then
      log "skip systemd (--no-systemd e nao ha units previas)"
    else
      # --no-systemd so evita INSTALAR persistencia nova; se ja existe, e
      # sempre sincronizada (copia canonica, units, enable) -- persistencia defasada
      # e bug, nao escolha. Seguro sob a propria unit (compara antes de escrever).
      do_systemd_install
    fi
    [ "${m_disable_rtmp}" -eq 1 ] && do_disable_nginx_rtmp
    # --grub tambem vale em --all: antes ele so era honrado no ramo nao-all,
    # entao `apply --all --grub` contava a fase (count_phases) mas NUNCA
    # escrevia isolcpus/nohz_full em /etc/default/grub (falha silenciosa).
    if [ "${m_grub}" -eq 1 ]; then
      [ "${no_xuiaff}" -eq 1 ] && die "--grub com --no-xui-affinity: isolcpus sem CPUAffinity casado quebra o host"
      do_grub
    fi
    apply_summary
    return 0
  fi

  # Mesma guarda do ramo --all: aqui tambem se chega a do_xui_affinity.
  segregate_leaves_no_app_cpu && die "$(segregate_empty_msg)"
  if [ "${m_sinit}" -eq 1 ]; then
    do_sysctl_init "${m_sinit_force}"     # ja faz apply + verificacao + chattr +i
  else
    [ "${m_sysctl}"  -eq 1 ] && do_sysctl
  fi
  [ "${m_modp}"    -eq 1 ] && do_modprobe
  [ -n "${irqbal}" ]       && do_irqbalance "${irqbal}"
  # Re-check do hw apos NIC ser conhecida (driver). So se a invocacao toca hw.
  if [ "${touches_hw}" -eq 1 ] && [ -n "${NIC}" ]; then
    require_hw_supported
  fi
  if [ "${m_nicall}" -eq 1 ]; then
    do_nic_all
  else
    [ "${m_irq}"   -eq 1 ] && { ensure_plan; do_queues; do_irq; }
    [ "${m_xps}"   -eq 1 ] && { ensure_plan; do_xps; }
    [ "${m_rfs}"   -eq 1 ] && { ensure_plan; do_rfs; }
    [ "${m_coa}"   -eq 1 ] && do_coalesce
    [ "${m_ring}"  -eq 1 ] && do_ring
    [ "${m_rss}"   -eq 1 ] && { ensure_plan; do_queues; do_rss; }
  fi
  [ "${m_xuiaff}" -eq 1 ] && [ "${no_xuiaff}" -eq 0 ] && do_xui_affinity
  [ "${m_grub}"   -eq 1 ] && do_grub
  [ "${m_disable_rtmp}" -eq 1 ] && do_disable_nginx_rtmp
  if [ "${m_sysd}" -eq 1 ] && [ "${no_sysd}" -eq 0 ]; then
    do_systemd_install
  fi
  apply_summary
}

# Imprime box final com resumo do estado da NIC + tally.
# Se nao houve NIC ou plano (apply --sysctl puro, etc.), mostra box minimo.
apply_summary() {
  if [ -z "${NIC}" ] || [ ! -e "/sys/class/net/${NIC}" ] || [ "${QUEUES}" -le 0 ]; then
    final_box "apply concluido (sem NIC tuning -- so configs)"
    log "rode '${0##*/} validate' para checagem completa"
    return 0
  fi
  local line1="combined=${QUEUES}" line2 line3
  local rx tx
  rx=$(ethtool -g "${NIC}" 2>/dev/null | awk '/Current hardware/{f=1} f && /^RX:/{print $2; exit}')
  tx=$(ethtool -g "${NIC}" 2>/dev/null | awk '/Current hardware/{f=1} f && /^TX:/{print $2; exit}')
  [ -n "$rx" ] && line1="${line1}  ring=${rx}/${tx}"
  line2="IRQs=${QUEUES} pinadas (CCX-aware)  RPS=off  RFS=$([ "${RFS_PER_QUEUE}" -le 0 ] && echo off || echo "${RFS_PER_QUEUE}/q")"
  local irqb; irqb=$(systemctl is-active irqbalance 2>&1 | head -1)
  line3="irqbalance=${irqb}"
  final_box "${line1}" "${line2}" "${line3}"
  log "rode '${0##*/} validate' para checagem completa"
}

# Conta fases ativas para o numerador de '[N/M] titulo'.
# Args (na ordem): mode_all m_sysctl m_modp irqbal m_nicall m_irq m_xps m_rfs m_coa m_ring m_xuiaff no_xuiaff m_sysd no_sysd m_grub m_disable_rtmp m_rss m_sinit
count_phases() {
  local mode_all=$1 m_sysctl=$2 m_modp=$3 irqbal="$4"
  local m_nicall=$5 m_irq=$6 m_xps=$7 m_rfs=$8 m_coa=$9 m_ring=${10}
  local m_xuiaff=${11} no_xuiaff=${12} m_sysd=${13} no_sysd=${14}
  local m_grub=${15:-0} m_disable_rtmp=${16:-0} m_rss=${17:-0} m_sinit=${18:-0}
  local total=0
  # xui-affinity agora roda 3 secoes: CPUAffinity systemd + cron drop-in + nginx affinity.
  if [ "${mode_all}" -eq 1 ]; then
    # 3 fases fixas + as 7 de do_nic_all (numero acompanha do_nic_all()):
    total=$((3 + 7))   # sysctl modprobe irqbalance
                       # + queues RSS ring IRQ+XPS+RPS coalesce napi offloads
    [ "${no_xuiaff}" -eq 0 ] && total=$((total+3))   # xui-affinity = 3 fases (xuione + cron + nginx)
    [ "${no_sysd}"   -eq 0 ] && total=$((total+1))
    # --grub / --disable-rtmp sao opt-in mesmo em --all
    [ "${m_grub}"          -eq 1 ] && total=$((total+1))
    [ "${m_disable_rtmp}"  -eq 1 ] && total=$((total+1))
  else
    # --sysctl-init substitui a fase de --sysctl (nao soma duas vezes)
    if [ "${m_sinit}" -eq 1 ]; then
      total=$((total+1))
    else
      [ "${m_sysctl}" -eq 1 ] && total=$((total+1))
    fi
    [ "${m_modp}"    -eq 1 ] && total=$((total+1))
    [ -n "${irqbal}" ]       && total=$((total+1))
    if [ "${m_nicall}" -eq 1 ]; then
      # numero acompanha do_nic_all()
      total=$((total+7))   # queues RSS ring IRQ+XPS+RPS coalesce napi offloads
    else
      [ "${m_irq}"   -eq 1 ] && total=$((total+2))   # do_queues + do_irq
      [ "${m_xps}"   -eq 1 ] && total=$((total+1))
      [ "${m_rfs}"   -eq 1 ] && total=$((total+1))
      [ "${m_coa}"   -eq 1 ] && total=$((total+1))
      [ "${m_ring}"  -eq 1 ] && total=$((total+1))
      [ "${m_rss}"   -eq 1 ] && total=$((total+2))   # do_queues + do_rss
    fi
    [ "${m_xuiaff}" -eq 1 ] && [ "${no_xuiaff}" -eq 0 ] && total=$((total+3))   # xui-affinity = 3 fases
    [ "${m_grub}"          -eq 1 ] && total=$((total+1))
    [ "${m_disable_rtmp}"  -eq 1 ] && total=$((total+1))
    [ "${m_sysd}"          -eq 1 ] && [ "${no_sysd}" -eq 0 ] && total=$((total+1))
  fi
  echo "$total"
}

# Imprime o plano calculado sem aplicar nada
cmd_plan() {
  warn_hw_if_unsupported
  ensure_plan
  # Avisa (sem die -- 'plan' e read-only e existe justamente para diagnosticar)
  segregate_leaves_no_app_cpu && warn "$(segregate_empty_msg)"
  local per_ccx=$((TARGET_IRQS / NUM_CCX_ACTIVE))
  local mode_label
  if [ "${CACHE_FIRST}" = "1" ]; then
    mode_label="$(c_mag "cache-first")  $(c_dim "(1 IRQ por CCX, max isolamento L3)")"
  else
    mode_label="$(c_blu "ccx-aware")  $(c_dim "(${per_ccx} IRQs por CCX)")"
  fi

  # Box header
  echo
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  printf '  %sPlano de tuning%s   %s%s%s\n' "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$ESC_RST"
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"

  # Resumo
  box_kv "NIC"          "$(c_bld "${NIC:-<sem NIC -- so topologia>}")"
  if [ -n "${RESERVED_CCX_LIST}" ]; then
    box_kv "CCXes"      "$(c_bld "${NUM_CCX_ACTIVE}/${NUM_CCX}") ativos  $(c_dim "(CCX") $(c_yel "${RESERVED_CCX_LIST}")$(c_dim " reservado p/ kernel)")"
    box_kv "reserved"   "$(c_yel "CPUs ${RESERVED_CPUS_LIST}")  $(c_dim "→ housekeeping (timer tick, RCU, kworkers)")"
  else
    box_kv "CCXes"      "$(c_bld "${NUM_CCX_ACTIVE}/${NUM_CCX}") ativos"
  fi
  box_kv "modo"         "${mode_label}"
  box_kv "queues"       "$(c_bld ${QUEUES})  $(c_dim "(=") $(c_bld --irqs ${TARGET_IRQS})$(c_dim ", ${per_ccx} por CCX ativo)")"
  box_kv "IRQ CPUs"     "$(c_bld "$(compact_range ${IRQ_CPUS_ARR[*]})")"
  box_kv "APP CPUs"     "$(c_bld "${APP_CPUS_LIST}")"

  # Distribuicao por CCX (tabela)
  echo
  printf '  %sDistribuicao por CCX%s\n' "$ESC_BLD" "$ESC_RST"
  printf '  %s%-7s %-22s %-22s %s%s\n' "$ESC_DIM" "CCX" "physicos" "SMT siblings" "alocacao" "$ESC_RST"
  printf '  %s%s%s\n' "$ESC_DIM" "$(printf '%.0s─' $(seq 1 66))" "$ESC_RST"
  local i ordered phys_arr smt_arr k
  for i in $(seq 0 $((NUM_CCX-1))); do
    if [ "${CCX_RESERVED[$i]}" = "1" ]; then
      printf '  %-7s %-22s %-22s %s%s%s\n' \
        "$(c_yel ${i})" "[${CCX_PHYS_ARR[$i]}]" "[${CCX_SMT_ARR[$i]}]" \
        "$ESC_YEL" "● RESERVADO (kernel)" "$ESC_RST"
      continue
    fi
    read -ra phys_arr <<< "${CCX_PHYS_ARR[$i]}"
    read -ra smt_arr  <<< "${CCX_SMT_ARR[$i]}"
    ordered=("${phys_arr[@]}" "${smt_arr[@]}")
    local picked=""
    for k in $(seq 0 $((per_ccx-1))); do picked="$picked${ordered[$k]} "; done
    printf '  %-7s %-22s %-22s %s%s%s%s%s\n' \
      "$(c_grn ${i})" "[${CCX_PHYS_ARR[$i]}]" "[${CCX_SMT_ARR[$i]}]" \
      "$ESC_DIM" "IRQ → " "$ESC_RST$ESC_BLD" "${picked%% }" "$ESC_RST"
  done

  # Sugestao GRUB (so se ha reserva)
  if [ -n "${RESERVED_CPUS_LIST}" ]; then
    local data_plane
    data_plane="$(compact_range $(expand_range "${APP_CPUS_LIST}") ${IRQ_CPUS_ARR[*]})"
    echo
    printf '  %s%s%s  %sGRUB cmdline sugerido%s   %s(isolamento agressivo, opt-in via apply --grub)%s\n' \
      "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST" "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
    if [ "${ISOLCPUS_DOMAIN}" = "1" ]; then
      printf '    %sisolcpus%s=managed_irq,domain,%s%s%s\n' "$ESC_GRN" "$ESC_RST" "$ESC_BLD" "${data_plane}" "$ESC_RST"
    else
      printf '    %sisolcpus%s=managed_irq,%s%s%s   %s(sem domain; --isolcpus-domain p/ ativar)%s\n' "$ESC_GRN" "$ESC_RST" "$ESC_BLD" "${data_plane}" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
    fi
    if [ "${NOHZ_FULL}" = "1" ]; then
      printf '    %snohz_full%s=%s%s%s\n'                  "$ESC_GRN" "$ESC_RST" "$ESC_BLD" "${data_plane}" "$ESC_RST"
    fi
    printf '    %srcu_nocbs%s=%s%s%s\n'                    "$ESC_GRN" "$ESC_RST" "$ESC_BLD" "${data_plane}" "$ESC_RST"
    printf '    %sirqaffinity%s=%s%s%s\n'                  "$ESC_GRN" "$ESC_RST" "$ESC_BLD" "${RESERVED_CPUS_LIST}" "$ESC_RST"
  fi

  echo
  printf '  %sPara aplicar:%s  %s./xuione-tune.sh' "$ESC_DIM" "$ESC_RST" "$ESC_GRN"
  [ "${CACHE_FIRST}" = "1" ]    && printf ' --cache-first'
  [ -n "${RESERVED_CCX_LIST}" ] && printf ' --reserve-ccx %s' "${RESERVED_CCX_LIST}"
  [ "${ISOLCPUS_DOMAIN}" = "1" ] && printf ' --isolcpus-domain'
  [ "${NOHZ_FULL}" = "1" ] && printf ' --nohz-full'
  [ "${NGINX_PIN_MODE}" != "spread" ] && printf ' --nginx-pin-mode %s' "${NGINX_PIN_MODE}"
  [ "${SEGREGATE_NETWORK}" = "1" ] && printf ' --segregate-network'
  printf ' --nic IFACE apply%s\n' "$ESC_RST"
  echo
}

cmd_rollback() {
  require_root
  warn_hw_if_unsupported
  require_no_ccdnet_conflict "rollback"

  # Cabecalho
  echo
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  printf '  %sROLLBACK%s   %s%s%s\n' "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$ESC_RST"
  printf '  %sreverte TODAS as mudancas para o estado original%s\n' "$ESC_DIM" "$ESC_RST"
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"

  # 1. Systemd units (xuione-net-tune.service/path)
  section "rollback: systemd units"
  do_systemd_uninstall

  # 2. irqbalance volta a ON
  section "rollback: irqbalance on"
  do_irqbalance on

  # 3. NIC: combined NAO e mexido (mesma decisao do xuione-ccd-net.sh:revert).
  # `ethtool -L` causa reset do driver -- ~5k conexoes caem, ~3min de storm de
  # reconexao (ver README). O rollback e digitado justamente durante incidente,
  # com o servidor ja degradado, e o Pre-set maximum NAO e o valor pre-tuning:
  # redimensionar levaria a NIC para um estado em que ela nunca esteve.
  # NIC aqui e so para DUAS leituras informativas -- nada e alterado. Por isso
  # NADA de ensure_nic: sem --nic e sem TTY ele daria die e abortaria o
  # rollback no meio (units ja removidas, irqbalance ja religado), deixando os
  # passos 4-10 por fazer. Resolucao best-effort e segue o baile.
  section "rollback: ethtool -L combined (NAO alterado)"
  if [ -z "${NIC}" ] && [ -t 0 ] && [ -t 2 ]; then NIC="$(prompt_nic || true)"; fi
  if [ -z "${NIC}" ] || [ ! -e "/sys/class/net/${NIC}" ]; then
    warn "NIC nao informada/ausente -- pulando leitura informativa de combined queues"
    warn "  combined NAO e alterado pelo rollback de qualquer forma; as demais reversoes seguem"
  else
    local cur_combined max_combined
    cur_combined=$(ethtool -l "${NIC}" 2>/dev/null | awk '/Current hardware/{f=1} f && /Combined:/{print $2; exit}')
    max_combined=$(ethtool -l "${NIC}" 2>/dev/null | awk '/Pre-set maximums/{f=1} f && /Combined:/{print $2; exit}')
    log "combined atual=${cur_combined:-?} (max do hw=${max_combined:-?})"
    warn "combined queues NAO foi alterado (evita reset do driver em producao)"
    warn "  se quiser mesmo redimensionar, em janela de manutencao: ethtool -L ${NIC} combined ${max_combined:-64}"
  fi

  # 4. sysctl: /etc/sysctl.conf NAO e alterado (fonte unica do operador).
  # So o que o apply criou por fora do arquivo e desfeito (modules-load.d do
  # nf_conntrack + arquivos de /etc/sysctl.d desativados por fonte unica).
  section "rollback: sysctl (arquivo MANTIDO; desfaz so o que o apply criou)"
  do_sysctl_remove

  # 5. modprobe blacklist irdma
  section "rollback: blacklist irdma"
  log "removendo ${MODPROBE_DST} (efeito no proximo boot)"
  run "rm -f ${MODPROBE_DST}"

  # 6. CPUAffinity= em xuione.service
  section "rollback: CPUAffinity= em ${XUI_UNIT}"
  if [ -f "${XUI_UNIT}" ] && grep -q "^CPUAffinity=" "${XUI_UNIT}"; then
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "  $(c_cya '[dry-run]') sed -i '/^CPUAffinity=/d' ${XUI_UNIT}; systemctl daemon-reload"
    else
      cp -a "${XUI_UNIT}" "${XUI_UNIT}.bak.rollback.$(date +%Y%m%d-%H%M%S)"
      sed -i '/^CPUAffinity=/d' "${XUI_UNIT}"
      systemctl daemon-reload
      ok "CPUAffinity= removido de ${XUI_UNIT}"
    fi
  else
    log "nada a remover em ${XUI_UNIT}"
  fi

  # 7. cron drop-in (NOVO)
  section "rollback: cron drop-in"
  do_remove_cron_affinity

  # 8. nginx affinity block (NOVO)
  section "rollback: nginx affinity block"
  do_remove_nginx_affinity_block

  # 9. nginx_rtmp re-habilitar (NOVO)
  section "rollback: re-habilitar nginx_rtmp em ${XUI_SERVICE_SH}"
  do_enable_nginx_rtmp

  # 10. GRUB cmdline limpo (NOVO)
  section "rollback: GRUB cmdline (isolcpus/nohz_full/rcu_nocbs/irqaffinity)"
  do_remove_grub_isolation

  # Avisos finais
  echo
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  printf '  %s %sROLLBACK CONCLUIDO%s   %s\n' "$(c_grn "$SYM_OK")" "$ESC_GRN" "$ESC_RST" "$(date '+%H:%M:%S')"
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  echo
  warn "xuione.service NAO foi reiniciado -- 'systemctl restart xuione' quando seguro"
  if grep -qE 'isolcpus=|nohz_full=|rcu_nocbs=|irqaffinity=' /proc/cmdline; then
    warn "/proc/cmdline ainda tem flags de isolamento (cmdline em uso != /etc/default/grub editado)"
    warn "REBOOT necessario para aplicar o cmdline limpo"
  fi
  if [ -f /home/xui/bin/nginx/conf/nginx.conf ] && \
     ! grep -q "^${NGINX_BLOCK_BEGIN}\$" /home/xui/bin/nginx/conf/nginx.conf 2>/dev/null; then
    warn "nginx precisa de 'nginx -s reload' para o bloco removido fazer efeito"
  fi
}

# Converte lista de CPUs (args) em string binaria MSB->LSB para nginx
# worker_cpu_affinity. Tamanho = cpu_mask_groups * 32 bits (cobre o nr_cpus
# reportado por /sys/devices/system/cpu/possible).
cpus_to_nginx_bitmask() {
  local groups bits c i out=""
  groups=$(cpu_mask_groups)
  bits=$((groups * 32))
  declare -A cpuset=()
  for c in "$@"; do cpuset[$c]=1; done
  for ((i=bits-1; i>=0; i--)); do
    if [ -n "${cpuset[$i]:-}" ]; then out="${out}1"; else out="${out}0"; fi
  done
  echo "$out"
}

# Ajusta worker_processes e worker_cpu_affinity em nginx.conf para refletir
# o plano atual:
#   worker_processes      = quantidade de CPUs em APP_CPUS_LIST
#   worker_cpu_affinity   = "auto <bitmask binario>"
#
# Estrategia idempotente:
#   1. Remove bloco delimitado anterior (entre marcadores)
#   2. Remove linhas avulsas worker_processes/worker_cpu_affinity (caso
#      tenham sido inseridas por patch manual ou versao antiga do script)
#   3. Insere novo bloco delimitado logo apos a primeira linha "user X;"
#      (ou no topo se nao houver "user")
NGINX_BLOCK_BEGIN="# === BEGIN xuione-tune-nginx ==="
NGINX_BLOCK_END="# === END xuione-tune-nginx ==="
# Bloco do script IRMAO (xuione-ccd-net.sh). O awk abaixo precisa reconhece-lo:
# ele removia as diretivas worker_processes/worker_cpu_affinity de dentro do
# bloco alheio mas deixava os marcadores ORFAOS, e o ccd-net entao reinseria o
# seu -> flip-flop com 'nginx -s reload' de ~160 workers a cada disparo.
NGINX_CCDNET_BEGIN="# === BEGIN xuione-ccd-net ==="
NGINX_CCDNET_END="# === END xuione-ccd-net ==="
# nginx_touch_block_date <arquivo> <timestamp>
# Reescreve SO a linha "# Gerado por xuione-tune.sh em <data>" do bloco
# ${NGINX_BLOCK_BEGIN}..${NGINX_BLOCK_END}, in-place e de forma atomica
# (tmp no mesmo diretorio + mv), preservando dono/grupo/modo -- o nginx.conf
# pertence ao usuario xui. Se o bloco existir SEM linha de data (versao antiga
# do script), a linha e INSERIDA logo apos o marcador BEGIN.
# NAO roda `nginx -t` e NAO pede reload: a mudanca e so de comentario.
nginx_touch_block_date() {
  local f="$1" ts="$2" tmp
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') atualizaria a data do bloco em ${f} para ${ts} (sem nginx -t, sem reload)"
    return 0
  fi
  tmp="$(mktemp "$(dirname "$f")/.nginx.conf.xuione.XXXXXX" 2>/dev/null)" || {
    warn "mktemp falhou em $(dirname "$f"); data do bloco nao atualizada"
    return 0
  }
  if awk -v B="${NGINX_BLOCK_BEGIN}" -v ts="${ts}" '
       BEGIN { ins=0; skipnext=0 }
       { l=$0; sub(/\r$/, "", l) }
       !ins && l==B {
         print B
         print "# Gerado por xuione-tune.sh em " ts
         ins=1; skipnext=1; next
       }
       skipnext {
         skipnext=0
         if (l ~ /^# Gerado por xuione-tune\.sh em /) next
       }
       { print }
     ' "$f" > "${tmp}" && [ -s "${tmp}" ] \
     && cmp -s <(grep -v '^# Gerado por ' "$f") <(grep -v '^# Gerado por ' "${tmp}"); then
    # (cmp: fora a linha de data, tmp BYTE-IGUAL ao original -- escrita parcial
    #  do awk por ENOSPC/EIO nao pode virar nginx.conf truncado com [OK])
    # dono/grupo/modo do original (arquivo do usuario xui)
    chown --reference="$f" "${tmp}" 2>/dev/null || true
    chmod --reference="$f" "${tmp}" 2>/dev/null || true
    if mv -f "${tmp}" "$f"; then
      ok "nginx.conf: conteudo inalterado; data do bloco atualizada para ${ts}; sem reload"
    else
      rm -f "${tmp}"
      warn "mv atomico falhou; data do bloco em ${f} nao atualizada"
    fi
  else
    rm -f "${tmp}"
    warn "awk falhou, saida vazia ou alteraria mais que a linha de data; bloco em ${f} nao carimbado (arquivo intacto)"
  fi
  return 0
}

# do_nginx_affinity [no_affinity]
#   $1 = "1" para forcar modo generico (so 'worker_processes auto;' sem mask)
#   sem $1 ou "0" = auto-decide:
#     - APP_CPUS == todos os online -> generico (nao ha restricao real)
#     - APP_CPUS subset estrito      -> plan-aware (worker_processes N + bitmask)
#
# A cada execucao:
#   1. Apaga bloco delimitado antigo
#   2. Apaga linhas avulsas worker_processes / worker_cpu_affinity
#   3. Reescreve 1 unica fonte de verdade (apos 'user', ou no topo)
do_nginx_affinity() {
  local force_no_affinity="${1:-0}"
  require_root
  ensure_plan
  local f="/home/xui/bin/nginx/conf/nginx.conf"
  section "nginx affinity: worker_processes + worker_cpu_affinity"
  if [ ! -f "$f" ]; then
    warn "nginx.conf ausente em $f -- pulando"
    return 0
  fi

  # nginx.conf gerenciado pelo script irmao: assumir sem opt-in explicito gera
  # ping-pong de reload entre os dois (cada lado ve o bloco do outro como
  # divergente e nunca converge).
  if grep -q "^${NGINX_CCDNET_BEGIN}\$" "$f" 2>/dev/null && [ "${NGINX_TAKEOVER}" -eq 0 ]; then
    warn "${f} tem bloco xuione-ccd-net -- PULANDO nginx affinity"
    warn "  use --nginx-takeover para assumir o arquivo, ou faca o rollback do outro script antes"
    return 0
  fi

  local app_cpus_arr=()
  read -ra app_cpus_arr <<< "$(expand_range "$APP_CPUS_LIST")"
  local app_count=${#app_cpus_arr[@]}
  local online_count; online_count=$(online_cpus | wc -w)

  # Auto-decisao: se APP_CPUS == todos os online, o pinning nao adiciona valor
  # (nginx ja pode usar todos). Cai no modo generico.
  local mode="spread"
  if [ "${force_no_affinity}" = "1" ]; then
    mode="generic-forced"
  elif [ "${app_count}" -ge "${online_count}" ]; then
    mode="generic-trivial"
  elif [ "${NGINX_PIN_MODE}" = "smt-irq" ]; then
    mode="smt-irq"
  fi

  # Monta as linhas a inserir + comentario explicativo
  local wp wa comment
  case "$mode" in
    spread)
      local app_mask; app_mask="$(cpus_to_nginx_bitmask "${app_cpus_arr[@]}")"
      wp="worker_processes ${app_count};"
      wa="worker_cpu_affinity auto ${app_mask};"
      comment="# APP_CPUS spread: ${APP_CPUS_LIST} (${app_count}/${online_count} cores)"
      log "modo: spread (APP_CPUS=${app_count}/${online_count})"
      log "  ${wp}"
      log "  ${wa}"
      log "  (mask len=${#app_mask} bits)"
      ;;
    smt-irq)
      # Modo smt-irq: nginx workers pinados APENAS nos pares SMT das queues NIC.
      # Cada worker compartilha L1d/L2 com a softirq RX da queue correspondente.
      # PHP-FPM/ffmpeg continuam com CPUAffinity= em APP_CPUS_LIST (todo o range)
      # via xuione.service drop-in -- nginx so reduz seu escopo aqui.
      [ "${#IRQ_CPUS_ARR[@]}" -gt 0 ] || die "do_nginx_affinity smt-irq: IRQ_CPUS_ARR vazio (compute_plan() faltando)"
      local nginx_cpus=() seen_cpu
      declare -A nginx_set=()
      for seen_cpu in "${IRQ_CPUS_ARR[@]}"; do
        if [ -z "${nginx_set[$seen_cpu]:-}" ]; then
          nginx_cpus+=("$seen_cpu"); nginx_set[$seen_cpu]=1
        fi
        local sib; sib="$(smt_sibling_of "$seen_cpu")"
        if [ -n "$sib" ] && [ -z "${nginx_set[$sib]:-}" ]; then
          nginx_cpus+=("$sib"); nginx_set[$sib]=1
        fi
      done
      local nginx_count=${#nginx_cpus[@]}
      local nginx_mask; nginx_mask="$(cpus_to_nginx_bitmask "${nginx_cpus[@]}")"
      # Ordena para log mais limpo (numerico)
      local nginx_list_sorted
      nginx_list_sorted="$(printf '%s\n' "${nginx_cpus[@]}" | sort -n | paste -sd,)"
      wp="worker_processes ${nginx_count};"
      wa="worker_cpu_affinity auto ${nginx_mask};"
      comment="# smt-irq: ${nginx_count} workers nos pares (IRQ + SMT sibling) das ${#IRQ_CPUS_ARR[@]} queues NIC; cpus=${nginx_list_sorted}"
      log "modo: smt-irq (${nginx_count} workers nos pares SMT das ${#IRQ_CPUS_ARR[@]} queues)"
      log "  ${wp}"
      log "  ${wa}"
      log "  cpus: ${nginx_list_sorted}"
      log "  (mask len=${#nginx_mask} bits)"
      ;;
    generic-trivial)
      wp="worker_processes auto;"
      wa=""
      comment="# Sem restricao de CPU para nginx (APP_CPUS=${app_count} == online_cpus=${online_count})"
      log "modo: generico (APP_CPUS == online; pinning nao agrega valor)"
      log "  ${wp}"
      log "  (worker_cpu_affinity OMITIDO -- nginx usa todos os CPUs disponiveis)"
      ;;
    generic-forced)
      wp="worker_processes auto;"
      wa=""
      comment="# Sem worker_cpu_affinity (forcado via --no-affinity)"
      log "modo: generico (forcado via --no-affinity)"
      log "  ${wp}"
      log "  (worker_cpu_affinity OMITIDO)"
      ;;
  esac

  # Idempotencia byte-level (portado de xuione-ccd-net.sh em 2026-05-14):
  # Simula o awk STRIP+INSERT em memoria, normaliza a linha "# Gerado por" e
  # compara byte a byte com o arquivo atual (tambem normalizado). Se ja bate,
  # PULA reload do nginx por completo (evita worker drain + spawn spurio).
  local _nginx_ts="STABLE_TIMESTAMP_PLACEHOLDER"
  local simulated
  simulated=$(awk -v B="${NGINX_BLOCK_BEGIN}" \
      -v E="${NGINX_BLOCK_END}" \
      -v B2="${NGINX_CCDNET_BEGIN}" \
      -v E2="${NGINX_CCDNET_END}" \
      -v wp="${wp}" \
      -v wa="${wa}" \
      -v cm="${comment}" \
      -v ts="${_nginx_ts}" '
    BEGIN { in_block=0; in_aff=0; inserted=0; nbuf=0 }
    { sub(/\r$/, "") }
    $0==B  { in_block=1; next }
    $0==E  { in_block=0; next }
    $0==B2 { in_block=1; next }
    $0==E2 { in_block=0; next }
    in_block { next }
    /^[[:space:]]*worker_processes[[:space:]]/ { next }
    /^[[:space:]]*worker_cpu_affinity[[:space:]]/ {
      if (!index($0, ";")) in_aff=1
      next
    }
    in_aff { if (index($0, ";")) in_aff=0; next }
    !inserted {
      buf[++nbuf] = $0
      if ($0 ~ /^user[[:space:]]/) {
        for (i=1; i<=nbuf; i++) print buf[i]
        print ""
        print B
        print "# Gerado por xuione-tune.sh em " ts
        print cm
        print wp
        if (wa != "") print wa
        print E
        nbuf=0
        inserted=1
      }
      next
    }
    { print }
    END {
      if (!inserted) {
        print B
        print "# Gerado por xuione-tune.sh em " ts
        print cm
        print wp
        if (wa != "") print wa
        print E
        print ""
        for (i=1; i<=nbuf; i++) print buf[i]
      }
    }
  ' "$f")
  # Normaliza CRLF do arquivo atual para o mesmo nivel da simulacao + remove
  # linha "# Gerado por" (que varia por timestamp).
  local current_norm
  current_norm=$(awk '{ sub(/\r$/, ""); print }' "$f" | sed '/^# Gerado por xuione-tune.sh em /d')
  local simulated_norm
  simulated_norm=$(printf '%s\n' "${simulated}" | sed '/^# Gerado por xuione-tune.sh em /d')
  if [ "$simulated_norm" = "$current_norm" ]; then
    # Conteudo IGUAL: nada de reescrever o bloco, nginx -t nem reload. So a
    # linha de data do bloco e atualizada (comentario), para o operador saber
    # quando o apply passou por aqui pela ultima vez.
    local now_ts; now_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    ok "${f}: bloco ja consolidado (modo=${mode}) [idempotente, sem reload]"
    nginx_touch_block_date "$f" "${now_ts}"
    return 0
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  $(c_cya '[dry-run]') strip bloco delimitado antigo + linhas avulsas worker_processes/worker_cpu_affinity"
    echo "  $(c_cya '[dry-run]') inserir novo bloco apos 'user' (ou no topo) [modo=${mode}]"
    return 0
  fi

  local bak="${f}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "$bak"
  log "backup em $bak"

  local tmp; tmp="$(mktemp)"
  awk -v B="${NGINX_BLOCK_BEGIN}" \
      -v E="${NGINX_BLOCK_END}" \
      -v B2="${NGINX_CCDNET_BEGIN}" \
      -v E2="${NGINX_CCDNET_END}" \
      -v wp="${wp}" \
      -v wa="${wa}" \
      -v cm="${comment}" \
      -v ts="$(date '+%Y-%m-%d %H:%M:%S')" '
    BEGIN { in_block=0; in_aff=0; inserted=0; nbuf=0 }

    # Normaliza CR final (XUI panel grava nginx.conf em CRLF; sem isso $0==B
    # falha porque "# === BEGIN ...===\r" != "# === BEGIN ...===" e o bloco
    # antigo nao e removido)
    { sub(/\r$/, "") }

    # Remove bloco delimitado antigo (nosso E o do xuione-ccd-net, senao os
    # marcadores dele ficariam orfaos com as diretivas removidas de dentro)
    $0==B  { in_block=1; next }
    $0==E  { in_block=0; next }
    $0==B2 { in_block=1; next }
    $0==E2 { in_block=0; next }
    in_block { next }

    # Remove linhas avulsas worker_processes
    /^[[:space:]]*worker_processes[[:space:]]/ { next }

    # Remove linhas avulsas worker_cpu_affinity (incluindo multi-linha)
    /^[[:space:]]*worker_cpu_affinity[[:space:]]/ {
      if (!index($0, ";")) in_aff=1
      next
    }
    in_aff { if (index($0, ";")) in_aff=0; next }

    # Antes de inserir: bufferiza ate encontrar 'user'
    !inserted {
      buf[++nbuf] = $0
      if ($0 ~ /^user[[:space:]]/) {
        for (i=1; i<=nbuf; i++) print buf[i]
        print ""
        print B
        print "# Gerado por xuione-tune.sh em " ts
        print cm
        print wp
        if (wa != "") print wa
        print E
        nbuf=0
        inserted=1
      }
      next
    }

    { print }

    END {
      if (!inserted) {
        print B
        print "# Gerado por xuione-tune.sh em " ts
        print cm
        print wp
        if (wa != "") print wa
        print E
        print ""
        for (i=1; i<=nbuf; i++) print buf[i]
      }
    }
  ' "$f" > "$tmp"

  # Guarda 1: awk abortou (disco cheio, OOM) -> NAO publicar arquivo truncado.
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    warn "awk produziu saida vazia; ${f} NAO alterado (backup ${bak} intacto)"
    return 0
  fi

  cat "$tmp" > "$f"   # cat > preserva inode/ownership/contexto
  rm -f "$tmp"

  # Guarda 2: sanity de conteudo -- exatamente 1 worker_processes.
  local post_wp; post_wp=$(count_matches "$f" '^[[:space:]]*worker_processes[[:space:]]')
  if [ ! -s "$f" ] || [ "${post_wp}" != "1" ]; then
    cp -a "$bak" "$f"
    die "escrita de ${f} falhou (worker_processes=${post_wp}); restaurado de ${bak}"
  fi

  # Guarda 3: `nginx -t` (mesma pratica de apply_nginx_conf no xuione-ccd-net).
  # Preferencia pelo binario do XUI: o do sistema tem outro prefix/include e
  # pode reprovar a conf do painel por falso positivo -- por isso so avisa.
  local nbin="" _b
  for _b in /home/xui/bin/nginx/sbin/nginx /usr/sbin/nginx; do
    if [ -x "$_b" ]; then nbin="$_b"; break; fi
  done
  if [ -z "${nbin}" ]; then
    warn "binario nginx nao encontrado; config gravada SEM validacao -- rode 'nginx -t' antes de qualquer reload"
  elif LC_ALL=C "$nbin" -t -c "$f" >/dev/null 2>&1; then
    ok "nginx config valida (${nbin} -t)"
  elif [ "${nbin}" = "/home/xui/bin/nginx/sbin/nginx" ]; then
    LC_ALL=C "$nbin" -t -c "$f" 2>&1 | tail -3 | sed 's/^/    /' || true
    cp -a "$bak" "$f"
    die "nginx -t falhou na config gerada; ${f} restaurado de ${bak}"
  else
    warn "nginx -t (binario do sistema, prefix diferente) reprovou ${f} -- pode ser falso positivo; verifique manualmente"
  fi

  case "$mode" in
    spread)          ok "${f}: ${wp}  +  worker_cpu_affinity bitmask (${app_count} cores espalhados)" ;;
    smt-irq)         ok "${f}: ${wp}  +  worker_cpu_affinity bitmask (pares IRQ+SMT, ${#IRQ_CPUS_ARR[@]} queues)" ;;
    generic-trivial) ok "${f}: ${wp}  (sem affinity -- APP_CPUS = todos os online)" ;;
    generic-forced)  ok "${f}: ${wp}  (sem affinity -- forcado via --no-affinity)" ;;
  esac
  log "Para aplicar:  /home/xui/bin/nginx/sbin/nginx -t && /home/xui/bin/nginx/sbin/nginx -s reload"
}

cmd_nginx_patch() {
  local apply=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply)  apply=1 ;;
      *) die "nginx-patch: flag desconhecida '$1' (use --apply)" ;;
    esac
    shift || break
  done
  # Diff continua livre; so a ESCRITA no nginx.conf precisa do guard.
  [ "${apply}" -eq 1 ] && require_no_ccdnet_conflict "nginx-patch --apply"
  local f="/home/xui/bin/nginx/conf/nginx.conf"
  local fhttp="/home/xui/bin/nginx/conf/ports/http.conf"
  local fhttps="/home/xui/bin/nginx/conf/ports/https.conf"

  cat <<'EOM'
=== Patch nginx (review antes de aplicar) ===

ESCOPO: este comando aplica APENAS os patches HLS-especificos (timeouts,
lingering, listen reuseport). A AFFINITY (worker_processes + worker_cpu_affinity)
foi consolidada em 'apply --xui-affinity' (junto com CPUAffinity= do systemd)
porque os dois precisam casar com o plano de IRQ -- veja '--help'.

ALVO PRINCIPAL: HLS desconectando. Causas em nginx.conf:
  - keepalive_timeout 10  (HLS segments de 5s precisam keepalive >= 60s)
  - lingering_close off   (causa TCPAbortOnData = segments truncados)
  - reset_timedout_connection on (RST em vez de FIN; agressivo demais)

/home/xui/bin/nginx/conf/nginx.conf:
  - worker_connections 16000;        --> 32768;
  - accept_mutex on;                 --> accept_mutex off;
  - keepalive_timeout 10;            --> keepalive_timeout 75;
  + keepalive_requests 1000;
  - lingering_close off;             --> lingering_close on;
  + lingering_timeout 30s;
  - reset_timedout_connection on;    --> reset_timedout_connection off;
  - sendfile_max_chunk 1m;           --> sendfile_max_chunk 512k;
  + output_buffers 4 256k;
  + postpone_output 1460;

/home/xui/bin/nginx/conf/ports/http.conf:
  - listen 80;                       --> listen 80 reuseport backlog=65535;

/home/xui/bin/nginx/conf/ports/https.conf:
  - listen 443 ssl http2;            --> listen 443 ssl http2 reuseport backlog=65535;
EOM

  if [ "${apply}" -eq 0 ]; then
    echo
    echo "Use:  $0 nginx-patch --apply         para aplicar HLS patches"
    echo "Para mexer em worker_processes/affinity: $0 ... apply --xui-affinity"
    return 0
  fi
  require_root
  if [ -f "$f" ]; then
    run "cp -a ${f} ${f}.bak.$(date +%s)"
    # worker_connections / accept_mutex / HLS-specific
    run "sed -i -E 's/worker_connections[[:space:]]+16000;/worker_connections 32768;/' ${f}"
    run "sed -i -E 's/accept_mutex[[:space:]]+on;/accept_mutex off;/' ${f}"
    # HLS-specific (CRITICOS)
    run "sed -i -E 's/^([[:space:]]*)keepalive_timeout[[:space:]]+10;/\\1keepalive_timeout 75;\\n\\1keepalive_requests 1000;/' ${f}"
    run "sed -i -E 's/^([[:space:]]*)lingering_close[[:space:]]+off;/\\1lingering_close on;\\n\\1lingering_timeout 30s;/' ${f}"
    run "sed -i -E 's/reset_timedout_connection[[:space:]]+on;/reset_timedout_connection off;/' ${f}"
    run "sed -i -E 's/sendfile_max_chunk[[:space:]]+1m;/sendfile_max_chunk 512k;\\n\\toutput_buffers 4 256k;\\n\\tpostpone_output 1460;/' ${f}"
  else warn "ausente: $f"; fi
  if [ -f "$fhttp" ]; then
    run "cp -a ${fhttp} ${fhttp}.bak.$(date +%s)"
    run "sed -i -E 's/^listen[[:space:]]+80;/listen 80 reuseport backlog=65535;/' ${fhttp}"
  else warn "ausente: $fhttp"; fi
  if [ -f "$fhttps" ]; then
    run "cp -a ${fhttps} ${fhttps}.bak.$(date +%s)"
    run "sed -i -E 's/^listen[[:space:]]+443[[:space:]]+ssl[[:space:]]+http2;/listen 443 ssl http2 reuseport backlog=65535;/' ${fhttps}"
  else warn "ausente: $fhttps"; fi
  log "patch aplicado. Validar e recarregar:"
  echo "  /home/xui/bin/nginx/sbin/nginx -t && /home/xui/bin/nginx/sbin/nginx -s reload"
}

cmd_help() {
  local nm="${0##*/}"

  # Cabecalho com box
  echo
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"
  printf '  %sxuione-tune%s   %stuning de rede 100G para XuiOne%s   %s(topology-aware)%s\n' \
    "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '%s' "$ESC_CYA"; hline "$BOX_DH"; printf '%s' "$ESC_RST"

  # USO
  echo
  printf '%sUSO%s\n' "$ESC_BLD" "$ESC_RST"
  printf '  %s%s%s [%sGLOBAIS%s] %s<comando>%s [%sFLAGS%s]\n' \
    "$ESC_GRN" "$nm" "$ESC_RST" "$ESC_BLU" "$ESC_RST" "$ESC_MAG" "$ESC_RST" "$ESC_YEL" "$ESC_RST"

  # COMANDOS
  echo
  printf '%s%s COMANDOS%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST"
  printf '  %s%-15s%s %s\n' "$ESC_MAG" "status"        "$ESC_RST" "info do estado atual (NIC, IRQ, sysctl, units)"
  printf '  %s%-15s%s %s\n' "$ESC_MAG" "plan"          "$ESC_RST" "imprime topologia + plano calculado (sem aplicar)"
  printf '  %s%-15s%s %s\n' "$ESC_MAG" "apply [flags]" "$ESC_RST" "aplica config (sem flags = --all)"
  printf '  %s%-15s%s %s\n' "$ESC_MAG" "validate"      "$ESC_RST" "PASS/FAIL de cada item + saude da rede"
  printf '  %s%-15s%s %s\n' "$ESC_MAG" "collect [TAG]" "$ESC_RST" "snapshot de metricas para arquivo"
  printf '  %s%-15s%s %s\n' "$ESC_MAG" "rollback"      "$ESC_RST" "desfaz TODAS as mudancas (units, CPUAffinity, cron drop-in,"
  printf '  %s%-15s%s %s\n' "$ESC_MAG" ""              "$ESC_RST" "  nginx block, GRUB, nginx_rtmp; sysctl.conf e MANTIDO)"
  printf '  %s%-15s%s %s\n' "$ESC_MAG" "nginx-patch"   "$ESC_RST" "patches HLS-especificos (timeouts, listen reuseport)"

  # FLAGS DO APPLY (5 tiers)
  echo
  printf '%s%s FLAGS DO %sapply%s%s   %s(5 tiers; cada tier alto incorpora os baixos)%s\n' \
    "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST$ESC_BLD" "$ESC_RST" "$ESC_CYA$ESC_RST" "$ESC_DIM" "$ESC_RST"

  printf '\n  %sTIER 1%s  %sNIC tuning%s   %s(independente)%s\n' \
    "$ESC_BLU$ESC_BLD" "$ESC_RST" "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--nic-all"   "$ESC_RST" "queues + rss + ring + irq/xps/rps + coalesce + napi-defer + offloads"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--irq"       "$ESC_RST" "queues + IRQ pinning (avisa se irqbalance ativo)"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--xps"       "$ESC_RST" "tx-N → {IRQ_CPUS[N], SMT sibling}"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--rfs"       "$ESC_RST" "RFS (default 0 = OFF; --rfs-per-queue N)"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--coalesce"  "$ESC_RST" "adaptive on, rx/tx-usecs=50, gro/gso/tso on"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--ring"      "$ESC_RST" "ring buffers RX/TX no maximo (8160 em E810)"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--rss"       "$ESC_RST" "ethtool -X equal QUEUES (rebuild da indir table)"

  printf '\n  %sTIER 2%s  %ssysctl / modprobe%s   %s(independente)%s\n' \
    "$ESC_BLU$ESC_BLD" "$ESC_RST" "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--sysctl"        "$ESC_RST" "aplica /etc/sysctl.conf (FONTE UNICA: nao reescreve o conteudo)"
  printf '    %s%-18s%s %s%s%s\n' "$ESC_GRN" ""               "$ESC_RST" "$ESC_DIM" "sysctl -p + confere chave a chave + chattr +i + boot link" "$ESC_RST"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--sysctl-init"   "$ESC_RST" "GERA /etc/sysctl.conf do template embutido (so se vazio/ausente)"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--sysctl-init-force" "$ESC_RST" "regera mesmo com conteudo (faz backup .bak.<script>.<ts> antes)"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--modprobe"      "$ESC_RST" "instala blacklist irdma"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--irqbalance on|off" "$ESC_RST" "controla servico irqbalance"

  printf '\n  %sTIER 3%s  %safinidade da aplicacao%s   %s(consumidor do TIER 1)%s\n' \
    "$ESC_BLU$ESC_BLD" "$ESC_RST" "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--xui-affinity"     "$ESC_RST" "CONSOLIDADO: CPUAffinity systemd + nginx affinity"
  printf '    %s%-18s%s %s%s%s\n' "$ESC_GRN" ""                  "$ESC_RST" "$ESC_DIM" "(systemd e nginx precisam casar com o plano de IRQ)" "$ESC_RST"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--no-xui-affinity"  "$ESC_RST" "em --all, NAO mexe em xuione.service nem nginx"

  printf '\n  %sTIER 4%s  %spersistencia%s   %s(boot/path-trigger)%s\n' \
    "$ESC_BLU$ESC_BLD" "$ESC_RST" "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--systemd"         "$ESC_RST" "instala xuione-net-tune.{service,path}"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--no-systemd"      "$ESC_RST" "nao instala persistencia NOVA (se ja existe, e sincronizada)"

  printf '\n  %sTIER 5%s  %sisolamento agressivo no kernel%s   %s(EXIGE REBOOT)%s\n' \
    "$ESC_RED$ESC_BLD" "$ESC_RST" "$ESC_BLD" "$ESC_RST" "$ESC_RED" "$ESC_RST"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--grub"            "$ESC_RST" "isolcpus + rcu_nocbs + irqaffinity (nohz_full so com --nohz-full)"
  printf '    %s%-18s%s %s%s%s\n' "$ESC_GRN" ""                  "$ESC_RST" "$ESC_DIM" "EXIGE --reserve-ccx; IMPLICA --xui-affinity" "$ESC_RST"

  printf '\n  %sEXTRAS (opt-in)%s\n' "$ESC_BLU$ESC_BLD" "$ESC_RST"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--disable-rtmp"    "$ESC_RST" "comenta nginx_rtmp em /home/xui/service"
  printf '    %s%-18s%s %s%s%s\n' "$ESC_GRN" ""                  "$ESC_RST" "$ESC_DIM" "(libera ~128 workers idle; revertivel via 'rollback')" "$ESC_RST"

  printf '\n  %sAGREGADOR%s\n' "$ESC_BLU$ESC_BLD" "$ESC_RST"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--all"             "$ESC_RST" "tiers 1+2+3+4 (NAO inclui --grub nem --disable-rtmp)"
  printf '    %s%-18s%s %s\n' "$ESC_GRN" "--all --grub"      "$ESC_RST" "tudo (runtime + reboot agendado)"

  # GLOBAIS
  echo
  printf '%s%s GLOBAIS%s   %s(antes do comando)%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--nic IFACE"          "$ESC_RST" "NIC alvo (interactivo se omitido)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--reserve-ccx LIST"   "$ESC_RST" "CCXes inteiros p/ housekeeping (ex: \"0\", \"0,5\")"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--cache-first"        "$ESC_RST" "1 IRQ por CCX ativo (max isolamento L3)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--isolcpus-domain"    "$ESC_RST" "adiciona flag 'domain' em isolcpus (opt-in, quebra balance de fork)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--nohz-full"          "$ESC_RST" "adiciona nohz_full= no cmdline (opt-in, confina kthreads/wq no CCX reservado)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--nginx-pin-mode MODE" "$ESC_RST" "MODE=spread (default) | smt-irq (workers nos pares IRQ+SMT)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--segregate-network"  "$ESC_RST" "exclui IRQ+SMT-siblings do CPUAffinity de xuione/cron (requer smt-irq)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--irqs N"             "$ESC_RST" "total de IRQs (default: auto, multiplo de NUM_CCX_ACTIVE)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--rfs-per-queue N"    "$ESC_RST" "RFS por fila (default 0 = OFF)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--restart"            "$ESC_RST" "reinicia cron.service quando o drop-in mudar (opt-in)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--nginx-takeover"     "$ESC_RST" "assume nginx.conf gerenciado por xuione-ccd-net.sh (opt-in)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--force-legacy"       "$ESC_RST" "roda mesmo com xuione-ccd-net instalado (script canonico)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--force-hw"           "$ESC_RST" "bypass validacao de hardware (sem garantias)"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "--dry-run"            "$ESC_RST" "apenas imprime acoes"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "-v / -q"              "$ESC_RST" "verbose [default] / quiet"
  printf '  %s%-22s%s %s\n' "$ESC_BLU" "-h / --help"          "$ESC_RST" "esta tela"

  # HARDWARE
  echo
  printf '%s%s HARDWARE SUPORTADO%s   %s(use --force-hw para bypass)%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s  %sCPU%s     AMD EPYC Zen 2/3/4/5 single-socket   %sex: 7702P, 7763, 9654, 9755%s\n' \
    "$ESC_GRN" "$SYM_OK" "$ESC_RST" "$ESC_BLD" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s  %sNIC%s     Intel E810 / E822 / E823 (driver %sice%s)\n' \
    "$ESC_GRN" "$SYM_OK" "$ESC_RST" "$ESC_BLD" "$ESC_RST" "$ESC_BLD" "$ESC_RST"
  printf '  %s%s%s  %sArch%s    x86_64 single-socket\n' \
    "$ESC_GRN" "$SYM_OK" "$ESC_RST" "$ESC_BLD" "$ESC_RST"
  printf '  %s%s%s  %sIntel Xeon%s, %smulti-socket%s, %sdrivers nao-ice%s (i40e, ixgbe, mlx5, bnxt), %sVMs sem MSI-X%s\n' \
    "$ESC_RED" "$SYM_FAIL" "$ESC_RST" "$ESC_DIM" "$ESC_RST" "$ESC_DIM" "$ESC_RST" "$ESC_DIM" "$ESC_RST" "$ESC_DIM" "$ESC_RST"

  # EXEMPLOS
  echo
  printf '%s%s EXEMPLOS%s\n' "$ESC_CYA" "$SYM_DIAMOND" "$ESC_RST"
  printf '\n  %s# Plano (NIC nao precisa)%s\n' "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s plan\n' "$ESC_GRN" "$nm" "$ESC_RST"
  printf '  %s%s%s --cache-first --reserve-ccx 0 plan\n' "$ESC_GRN" "$nm" "$ESC_RST"

  printf '\n  %s# Apply default (--all sem GRUB)%s\n' "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s --nic enp197s0f0np0 apply\n' "$ESC_GRN" "$nm" "$ESC_RST"

  printf '\n  %s# Cache-first + CCX reservado (recomendado em LB de streaming)%s\n' "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s --cache-first --reserve-ccx 0 --nic enp197s0f0np0 apply\n' "$ESC_GRN" "$nm" "$ESC_RST"

  printf '\n  %s# Tudo + isolamento GRUB (exige reboot)%s\n' "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s --cache-first --reserve-ccx 0 --nic enp197s0f0np0 apply --grub\n' "$ESC_GRN" "$nm" "$ESC_RST"

  printf '\n  %s# Outras%s\n' "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s --dry-run apply%s              # so imprime acoes%s\n' "$ESC_GRN" "$nm" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s --force-hw apply --sysctl%s    # so sysctl em hw nao testado%s\n' "$ESC_GRN" "$nm" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s apply --sysctl-init%s          # 1a vez: gera /etc/sysctl.conf do template%s\n' "$ESC_GRN" "$nm" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s apply --disable-rtmp%s         # desliga nginx_rtmp em /home/xui/service%s\n' "$ESC_GRN" "$nm" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s nginx-patch --apply%s          # patches HLS%s\n' "$ESC_GRN" "$nm" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  printf '  %s%s%s rollback%s                     # desfaz TUDO (incl. GRUB)%s\n' "$ESC_GRN" "$nm" "$ESC_RST" "$ESC_DIM" "$ESC_RST"
  echo
}

# ---------- parse de globais antes do comando ----------
# Hint para o operador: quando uma flag de subcomando aparece na posicao
# global, sugere o comando correto em vez do "flag desconhecida" genérico.
unknown_global_flag() {
  local flag="$1" cmd_hint="" suggest=""
  case "$flag" in
    --all|--sysctl|--sysctl-init|--sysctl-init-force|--modprobe|--nic-all|--irq|--xps|--rfs|--coalesce|--ring|--rss|\
    --systemd|--no-systemd|--xui-affinity|--no-xui-affinity|--irqbalance|\
    --grub|--disable-rtmp)
      cmd_hint="apply" ;;
    --apply)
      cmd_hint="nginx-patch" ;;
  esac
  {
    echo "[xuione-tune] $(c_red ERR): flag desconhecida na posicao global: ${flag}"
    if [ -n "$cmd_hint" ]; then
      # Reconstroi a linha como deveria ter sido digitada: pega tudo antes
      # do flag offending que ja foi parseado (NIC/TARGET_IRQS/etc.) so para
      # ilustracao do EXEMPLO. Mostrar bonitinho seria caro -- usa template.
      echo "[xuione-tune]      '${flag}' e flag do subcomando '${cmd_hint}'."
      echo "[xuione-tune]      Tente: $0 [globais] ${cmd_hint} ${flag} [outras flags]"
      echo "[xuione-tune]      Exemplo: $0 --nic IFACE --cache-first ${cmd_hint} ${flag}"
    else
      echo "[xuione-tune]      Use -h para ver flags globais validas."
    fi
  } >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --nic)            shift; NIC="${1:?}";;
    --irqs)           shift; TARGET_IRQS="${1:?}";;
    --rfs-per-queue)  shift; RFS_PER_QUEUE="${1:?}";;
    --reserve-ccx)    shift; RESERVED_CCX_LIST="${1:?}";;
    --cache-first)    CACHE_FIRST=1 ;;
    --isolcpus-domain) ISOLCPUS_DOMAIN=1 ;;
    --nohz-full)      NOHZ_FULL=1 ;;
    --nginx-pin-mode) shift
                      case "${1:?}" in
                        spread|smt-irq) NGINX_PIN_MODE="$1" ;;
                        *) die "--nginx-pin-mode: valor invalido '$1' (use: spread | smt-irq)" ;;
                      esac ;;
    --segregate-network) SEGREGATE_NETWORK=1 ;;
    --restart)        RESTART_SERVICES=1 ;;
    --nginx-takeover) NGINX_TAKEOVER=1 ;;
    --force-legacy)   FORCE_LEGACY=1 ;;
    --force-hw)       FORCE_HW=1 ;;
    --dry-run)        DRY_RUN=1 ;;
    --quiet|-q)       VERBOSE=0 ;;
    --verbose|-v)     VERBOSE=1 ;;
    -h|--help)        cmd_help; exit 0 ;;
    -*)               unknown_global_flag "$1" ;;
    *) break ;;
  esac
  shift
done

# Validacao de combinacoes invalidas (depois do parse completo)
if [ "${SEGREGATE_NETWORK}" = "1" ] && [ "${NGINX_PIN_MODE}" != "smt-irq" ]; then
  die "--segregate-network requer --nginx-pin-mode=smt-irq (sem nginx nos pares SMT,
       segregacao nao faz sentido -- os IRQ cores ficariam sem ninguem usando)"
fi

CMD="${1:-help}"
shift || true

case "${CMD}" in
  status)         cmd_status ;;
  validate)       cmd_validate ;;
  collect)        cmd_collect "${1:-snapshot}" ;;
  plan)           cmd_plan ;;
  apply)          cmd_apply "$@" ;;
  rollback)       cmd_rollback ;;
  nginx-patch)    cmd_nginx_patch "$@" ;;
  help|-h|--help) cmd_help ;;
  *) die "comando desconhecido: ${CMD} (use -h)" ;;
esac
