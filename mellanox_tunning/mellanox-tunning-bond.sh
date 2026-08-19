#!/usr/bin/env bash
# mellanox-tune-bond.sh — Bloco A do plano de pinning: aplica IRQ affinity
# (+ opcionalmente XPS/RPS/aRFS) + persistência systemd no LB do XUI.one.
# Sem dependências externas: o pinning é nativo (helper `pin-irq`), não baixa nada.
# Referência: /root/mellanox_tunning/xui-lb-pinning-plan.md
#
# Uso:
#   ./mellanox-tune-bond.sh                              # IRQ pin + ring/coalesce/offloads (defaults on); RPS/XPS/aRFS OFF
#   ./mellanox-tune-bond.sh --xps                        # + XPS espelhando IRQ por tx queue (Mellanox)
#   ./mellanox-tune-bond.sh --rps                        # + RPS espelhando IRQ por rx queue
#   ./mellanox-tune-bond.sh --arfs                       # + aRFS (ntuple on + rps_flow_cnt)
#   ./mellanox-tune-bond.sh --xps --rps --arfs           # combina os 3 (independentes)
#   ./mellanox-tune-bond.sh --no-ring-max                # pula ethtool -G rx/tx max
#   ./mellanox-tune-bond.sh --no-coalesce                # pula ethtool -C adaptive-rx/tx on
#   ./mellanox-tune-bond.sh --no-offloads                # pula ethtool -K lso/gro/gso on
#   ./mellanox-tune-bond.sh --no-qdisc                   # pula a regeneração do qdisc das tx queues
#   ./mellanox-tune-bond.sh --dry-run                    # mostra o que faria, sem escrever
#   ./mellanox-tune-bond.sh --bond bond0                 # nome do bond (default bond0)
#   ./mellanox-tune-bond.sh --queues N                   # override do combined queues por slave
#   ./mellanox-tune-bond.sh --slave0-cpus 'lista'        # override do cpulist do slave 0
#   ./mellanox-tune-bond.sh --slave1-cpus 'lista'        # override do cpulist do slave 1
#   ./mellanox-tune-bond.sh --no-systemd                 # aplica em runtime, não persiste
#   ./mellanox-tune-bond.sh --rollback                   # reverte tudo
#
# Fluxo de aplicação (idempotente, em ambos os slaves):
#   1. ethtool -L combined=MAX  → expõe todas as filas pré-existentes
#   2. CLEANUP TOTAL:
#        - smp_affinity de todos os mlx5_comp* ← /proc/irq/default_smp_affinity
#        - rps_cpus de TODAS as rx queues = 0
#        - xps_cpus de TODAS as tx queues = 0
#        - rps_flow_cnt de TODAS as rx queues = 0
#        - ethtool -K ntuple off (aRFS off)
#        - sysctl net.core.rps_sock_flow_entries = 0
#   3. ethtool -L combined=<target>  → reduz para o calculado
#   4. ethtool -G iface rx <ring_max> tx <ring_max>   → ring buffer no máximo (default ON)
#   5. ethtool -C iface adaptive-rx on adaptive-tx on → coalesce dinâmico (default ON)
#   6. ethtool -K iface lso on gro on gso on          → offloads (default ON, fallback p/ 'tso')
#   7. tc qdisc: regenera o qdisc de cada tx queue (default ON) — ethtool -L deixa as
#      filas recém-ativadas com pfifo_fast, sem pacing FQ, degradando BBR nelas
#   8. IRQ affinity round-robin nativo (helper `pin-irq`, sem mlnx-tools)
#   9. Condicionais (default OFF, ativadas por flag):
#        --xps  → xps_cpus[tx-N] = smp_affinity[mlx5_compN]  (per-queue, Mellanox)
#        --rps  → rps_cpus[rx-N] = smp_affinity[mlx5_compN]  (per-queue, Mellanox)
#        --arfs → ntuple on + rps_sock_flow_entries=32768 + rps_flow_cnt=32768/queue
#  10. Systemd unit baked com o MESMO flag-set (sobrevive a reboot).
#
# Auto-detect (sem flags --slave*-cpus / --queues):
#   1. Lê CCXs únicos via /sys/.../cache/index3/shared_cpu_list.
#   2. Filtra pela NUMA local da NIC (se /sys/class/net/<i>/device/numa_node ≥ 0).
#   3. Distribui CCXs em blocos contíguos entre os N slaves do bond.
#      → Garante L1/L2/L3 disjuntos entre NICs e nenhum SMT sibling cruzando NICs.
#   4. Queue count por NIC = min(qtd logical CPUs no split, max combined da NIC).
#   5. Fallbacks: sem L3 → split por core físico; mais slaves que CCXs → degrada com warn.
#
# Filosofia: co-location (NÃO anti-pinning). live.php é I/O-bound — ganho vem do cache quente.
# RPS/XPS/aRFS são OFF por default porque RSS hw + IRQ pinning já cobrem o caminho;
# habilite-os só sob evidência de ganho (ex.: hash LACP assimétrico, app que muda CPU).
#
# IRQ pinning: implementação NATIVA no helper (subcomando `pin-irq`), sem clone do
# repositório Mellanox/mlnx-tools. A lógica de distribuição é a mesma do
# set_irq_affinity_cpulist.sh upstream (round-robin: IRQ i -> cpus[i % n_cpus]),
# reimplementada a partir dele + common_irq_affinity.sh.
#
# Helper auxiliar deployado: /usr/local/sbin/xui-lb-mlx-helper.sh
#   Usado tanto neste script (install-time) quanto pelo systemd unit (boot-time).
#
# Requer: root, bond LACP, NICs Mellanox (mlx5_core), ethtool, tc (iproute2), python3, systemd.

set -euo pipefail

# O auto-detect de topologia roda em heredocs de python3. Sem isto, o python usa o encoding do
# LOCALE para o stdout: num host com LANG=*.ISO-8859-1 (ou qualquer locale latin-1), um simples
# travessao numa mensagem de warning derruba o script com UnicodeEncodeError no meio do
# preflight. Fixar o encoding torna o comportamento independente do locale do host.
# (Os blocos python tambem sao mantidos ASCII-only, para o texto seguir legivel num terminal
# que nao seja UTF-8.)
export PYTHONIOENCODING=utf-8

# ---------------- config ----------------

STAMP="$(date +%Y-%m-%d-%H%M%S)"
BACKUP_DIR="/root/backups"
SYSTEMD_UNIT="/etc/systemd/system/mlx-irq-pin.service"
HELPER_PATH="/usr/local/sbin/xui-lb-mlx-helper.sh"
ARFS_FLOW_ENTRIES=32768          # net.core.rps_sock_flow_entries quando --arfs
ARFS_PER_QUEUE_FLOW_CNT=32768    # rps_flow_cnt por rx queue quando --arfs

BOND="bond0"
# Vazios = auto-detect; preenchidos por flag = override manual.
SLAVES=()
SLAVE0_CPUS=""
SLAVE1_CPUS=""
QUEUES=""            # se setado via --queues N, força N em ambos slaves
# QUEUES_S0/QUEUES_S1 são calculados internamente em resolve_topology a partir do
# n_cpus de cada slave (--slave0-cpus / --slave1-cpus) e do max-combined da NIC.
QUEUES_S0=""
QUEUES_S1=""
PERSIST=1
DRY_RUN=0
PRINT_HELPER=0     # --print-helper: emite o helper embutido e sai
PRINT_TOPOLOGY=0   # --print-topology: imprime a topologia detectada e sai
ROLLBACK=0
APPLY_XPS=0
APPLY_RPS=0
APPLY_ARFS=0
APPLY_RING_MAX=1     # default ON; --no-ring-max desabilita
APPLY_COALESCE=1     # default ON; --no-coalesce desabilita
APPLY_OFFLOADS=1     # default ON; --no-offloads desabilita
APPLY_QDISC=1        # default ON; --no-qdisc desabilita (regenera qdisc das tx queues)

# ---------------- helpers ----------------

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

run() {
  if (( DRY_RUN )); then
    printf '\033[1;90m    DRY: %s\033[0m\n' "$*"
  else
    eval "$@"
  fi
}

# Imprime header até a primeira linha não-comentada (robusto a expansões do header).
usage() { sed -n '/^#/!q; 2,$p' "$0"; }

# Aborta se a próxima palavra de uma flag --foo está ausente ou começa com "--".
need_arg() {
  local flag="$1" val="${2-}"
  [[ -n "$val" && "$val" != --* ]] || { err "flag $flag requer um valor"; usage; exit 1; }
}

# Normaliza e VALIDA um cpulist antes de qualquer uso. Roda no parsing de flags, logo
# também vale em --dry-run — ao contrário da validação do helper, que só acontece no
# pin-irq, isto é, depois de todo o fluxo destrutivo.
# Sem isto: ' 0-11, 24-35' com espaço vira dois argumentos no eval do run() e no ExecStart
# (pina metade das CPUs, em silêncio); '5-2' e '0-63' passam batido; 'abc' vaza um traceback
# do Python vindo de count_cpus_in_list.
normalize_cpulist() {
  local name="$1" raw="$2" l t a b c
  l="${raw//[[:space:]]/}"
  [[ -n "$l" ]] || { printf ''; return 0; }
  [[ "$l" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] \
    || { err "$name: cpulist inválido '$raw' (esperado algo como 0-11,24-35)"; exit 1; }
  local IFS=','
  local -a toks=("$l")
  read -r -a toks <<< "${l//,/ }"
  unset IFS
  for t in "${toks[@]}"; do
    a="${t%%-*}"; b="${t##*-}"
    (( 10#$a <= 10#$b )) || { err "$name: range invertido '$t' em '$raw'"; exit 1; }
    for (( c=10#$a; c<=10#$b; c++ )); do
      [[ -d "/sys/devices/system/cpu/cpu${c}" ]] \
        || { err "$name: CPU ${c} não existe (host tem $(nproc --all 2>/dev/null || echo '?') CPUs)"; exit 1; }
      # cpu0 costuma não expor 'online'; ausência = online.
      if [[ -r "/sys/devices/system/cpu/cpu${c}/online" ]]; then
        [[ "$(cat "/sys/devices/system/cpu/cpu${c}/online")" == "1" ]] \
          || { err "$name: CPU ${c} está offline"; exit 1; }
      fi
    done
  done
  printf '%s' "$l"
}

# ---------------- args ----------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)              DRY_RUN=1 ;;
    --bond)                 need_arg "$1" "${2-}"; BOND="$2"; shift ;;
    --slave0-cpus)          need_arg "$1" "${2-}"; SLAVE0_CPUS="$2"; shift ;;
    --slave1-cpus)          need_arg "$1" "${2-}"; SLAVE1_CPUS="$2"; shift ;;
    --queues)               need_arg "$1" "${2-}"; QUEUES="$2"; shift ;;
    --no-systemd)           PERSIST=0 ;;
    --rollback)             ROLLBACK=1 ;;
    --xps)                  APPLY_XPS=1 ;;
    --rps)                  APPLY_RPS=1 ;;
    --arfs)                 APPLY_ARFS=1 ;;
    --no-ring-max)          APPLY_RING_MAX=0 ;;
    --no-coalesce)          APPLY_COALESCE=0 ;;
    --no-offloads)          APPLY_OFFLOADS=0 ;;
    --no-qdisc)             APPLY_QDISC=0 ;;
    --print-helper)         PRINT_HELPER=1 ;;
    --print-topology)       PRINT_TOPOLOGY=1 ;;
    -h|--help)              usage; exit 0 ;;
    *) err "arg desconhecido: $1"; usage; exit 1 ;;
  esac
  shift
done

# --print-helper é só leitura: dispensa root. O dispatch em si acontece no início de
# main(), depois que emit_helper() já foi definida.
(( PRINT_HELPER )) || (( PRINT_TOPOLOGY )) || (( EUID == 0 )) || { err "rode como root."; exit 1; }

# Normalização/validação antes de QUALQUER uso (inclusive em --dry-run).
SLAVE0_CPUS=$(normalize_cpulist --slave0-cpus "$SLAVE0_CPUS")
SLAVE1_CPUS=$(normalize_cpulist --slave1-cpus "$SLAVE1_CPUS")
[[ -z "$QUEUES" || "$QUEUES" =~ ^[1-9][0-9]*$ ]] || { err "--queues '${QUEUES}' não é inteiro positivo"; exit 1; }

# ---------------- helpers de máscara ----------------

count_cpus_in_list() {
  python3 - "$1" <<'PY'
import sys
spec = sys.argv[1]
n = 0
for t in spec.split(','):
    t = t.strip()
    if not t: continue
    if '-' in t:
        a, b = map(int, t.split('-'))
        n += b - a + 1
    else:
        n += 1
print(n)
PY
}

# Retorna 1 se cpulist (arg1) tem CPUs FORA do NUMA cpulist (arg2). Imprime os extras.
# Uso: extras=$(cpus_outside_numa "0-23" "24-47"); ret=$?
cpus_outside_numa() {
  python3 - "$1" "$2" <<'PY'
import sys
def cpus_in(spec):
    out = set()
    for tok in spec.split(','):
        tok = tok.strip()
        if not tok: continue
        if '-' in tok:
            a,b = map(int, tok.split('-'))
            out |= set(range(a,b+1))
        else:
            out.add(int(tok))
    return out
user = cpus_in(sys.argv[1])
node = cpus_in(sys.argv[2])
extras = sorted(user - node)
if extras:
    # formata em ranges
    ranges = []; i = 0
    while i < len(extras):
        j = i
        while j+1 < len(extras) and extras[j+1] == extras[j]+1: j += 1
        ranges.append(f"{extras[i]}-{extras[j]}" if j>i else f"{extras[i]}")
        i = j+1
    print(",".join(ranges))
    sys.exit(1)
else:
    sys.exit(0)
PY
}

# Converte cpulist (ex: "0-23") em máscara no formato kernel /sys cpumask:
# grupos de 8 hex (32 bits cada) separados por vírgula, high word primeiro.
# Ex: 0-23  -> "00ffffff"
#     24-47 -> "0000ffff,ff000000"
# Aceita listas combinadas: "0-3,8,12-15".
# ---------------- auto-detect topologia ----------------

# Detecta CCXs (via L3 shared_cpu_list), filtra por NUMA da NIC, distribui CCXs
# contíguos por slave, calcula queue count = min(logical CPUs do split, max combined).
# Imprime JSON: {"slaves":[{"iface":..,"cpus":..,"queues":N,"ccxs":[...]}], "warnings":[...]}
# Emite, em JSON, a topologia detectada + o split proposto por slave.
# Consumido por resolve_topology() e por --print-topology.
topology_json() {
  local slaves_csv
  # Resolve os slaves sozinho quando chamado antes do preflight (--print-topology).
  if [[ -z "${SLAVES[*]:-}" && -f "/proc/net/bonding/${BOND}" ]]; then
    mapfile -t SLAVES < <(awk '/^Slave Interface:/{print $3}' "/proc/net/bonding/${BOND}" | sort)
  fi
  slaves_csv=$(IFS=,; echo "${SLAVES[*]:-}")
  python3 - "$slaves_csv" <<'PY'
import sys
# >>> TOPOLOGY_LIB v1 >>> bloco IDENTICO nos 3 scripts (verifique com --print-topology-src)
# Detector de topologia de CPU. Resolve o "dominio de cache" (CCX no AMD, LLC/cluster/die
# em geral) por uma cadeia de fontes, VALIDANDO cada uma antes de aceitar:
#   1. LLC real  - maior nivel de cache Unified/Data exposto (normalmente L3, cai p/ L2)
#   2. NUMA node - quando ha mais de um node e ele particiona mais fino que o socket
#   3. die       - die_cpus_list, quando mais fino que o socket
#   4. cluster   - cluster_cpus_list, so com cluster_id valido E mais grosso que um core
#   5. socket    - core_siblings_list
#   6. core      - thread_siblings_list (ultimo recurso; nao respeita fronteira de cache)
# Validacao aplicada a toda fonte: os dominios precisam PARTICIONAR exatamente o conjunto de
# CPUs online (sem sobreposicao, sem faltar CPU). Fonte que nao particiona e descartada com
# warning, e a cadeia continua - assim um sysfs incompleto degrada em vez de mentir.
# SYSFS_ROOT permite apontar para uma arvore de fixtures em teste.
import os, glob, json

SYSFS = os.environ.get("TOPO_SYSFS_ROOT", "") or ""
def _p(path): return SYSFS + path

def _read(path):
    try:
        with open(_p(path)) as f: return f.read().strip()
    except Exception: return None

def _cpus_in(spec):
    out = set()
    if not spec: return out
    for tok in spec.split(','):
        tok = tok.strip()
        if not tok: continue
        if '-' in tok:
            a, b = tok.split('-')[:2]
            try: out |= set(range(int(a), int(b) + 1))
            except ValueError: pass
        elif tok.isdigit():
            out.add(int(tok))
    return out

def _fmt(cpus):
    if not cpus: return ""
    a = sorted(cpus); r = []; i = 0
    while i < len(a):
        j = i
        while j + 1 < len(a) and a[j + 1] == a[j] + 1: j += 1
        r.append(f"{a[i]}-{a[j]}" if j > i else f"{a[i]}")
        i = j + 1
    return ",".join(r)

def _online():
    s = _read('/sys/devices/system/cpu/online')
    if s: return _cpus_in(s)
    out = set()
    for d in glob.glob(_p('/sys/devices/system/cpu/cpu[0-9]*')):
        n = d.rsplit('cpu', 1)[1]
        if n.isdigit(): out.add(int(n))
    return out

def _cpuinfo():
    txt = _read('/proc/cpuinfo') or ''
    ven = mod = ''
    for line in txt.splitlines():
        if not ven and line.startswith('vendor_id'): ven = line.split(':', 1)[1].strip()
        elif not mod and line.startswith('model name'): mod = line.split(':', 1)[1].strip()
        if ven and mod: break
    return ven, mod

def _caches(online):
    """Todos os niveis de cache vistos, agrupados por shared_cpu_list."""
    levels = {}
    for c in sorted(online):
        base = f'/sys/devices/system/cpu/cpu{c}/cache'
        for idx in sorted(glob.glob(_p(f'{base}/index[0-9]*')),
                          key=lambda p: int(p.rsplit('index', 1)[1])):
            rel = idx[len(SYSFS):] if SYSFS else idx
            lv = _read(f'{rel}/level'); ty = _read(f'{rel}/type') or ''
            if not lv or not lv.isdigit(): continue
            if ty.lower() == 'instruction': continue      # I-cache nao define dominio
            shared = _read(f'{rel}/shared_cpu_list')
            if not shared: continue
            lv = int(lv)
            e = levels.setdefault(lv, {"level": lv, "type": ty,
                                       "size": _read(f'{rel}/size'), "domains": []})
            if shared not in e["domains"]: e["domains"].append(shared)
    return [levels[k] for k in sorted(levels)]

def _partitions(domains, online):
    """A fonte particiona exatamente as CPUs online?"""
    seen = set(); total = 0
    for d in domains:
        s = _cpus_in(d) & online
        if not s: return False
        if s & seen: return False        # sobreposicao
        seen |= s; total += len(s)
    return seen == online and total == len(online)

def _group_by(attr_file, online):
    """Agrupa CPUs online pelo conteudo de topology/<attr_file>, preservando a ordem."""
    doms = []
    for c in sorted(online):
        v = _read(f'/sys/devices/system/cpu/cpu{c}/topology/{attr_file}')
        if not v: return []
        if v not in doms: doms.append(v)
    return doms

def detect_topology():
    online = _online()
    ven, model = _cpuinfo()
    t = {"vendor": ven, "model": model, "online": _fmt(online), "n_online": len(online),
         "warnings": [], "caches": [], "numa_nodes": {}, "domains": [],
         "domain_source": None, "domain_label": None}
    if not online:
        t["warnings"].append("nenhuma CPU online detectada")
        return t

    # --- identidades por CPU ---
    threads = _group_by('thread_siblings_list', online)
    sockets = _group_by('core_siblings_list', online) or _group_by('package_cpus_list', online)
    t["n_cores"] = len(threads) if threads else len(online)
    t["threads_per_core"] = round(len(online) / len(threads), 2) if threads else 1
    t["smt"] = bool(threads) and len(online) > len(threads)
    t["n_sockets"] = len(sockets) if sockets else 1

    dies = _group_by('die_cpus_list', online)
    t["n_dies"] = len(dies) if dies else t["n_sockets"]

    # --- NUMA ---
    nodes = {}
    for nd in sorted(glob.glob(_p('/sys/devices/system/node/node[0-9]*')),
                     key=lambda p: int(p.rsplit('node', 1)[1])):
        nid = int(nd.rsplit('node', 1)[1])
        cl = _read((nd[len(SYSFS):] if SYSFS else nd) + '/cpulist')
        s = _cpus_in(cl) & online
        if s: nodes[nid] = s
    t["numa_nodes"] = {str(k): _fmt(v) for k, v in sorted(nodes.items())}
    t["n_numa"] = len(nodes)

    # --- caches ---
    t["caches"] = [{"level": c["level"], "type": c["type"], "size": c["size"],
                    "n_domains": len(c["domains"]), "domains": c["domains"]}
                   for c in _caches(online)]

    # --- cadeia de fontes para o dominio de cache ---
    cands = []
    for c in reversed(t["caches"]):                    # do maior nivel para o menor
        if c["level"] >= 2:
            cands.append((f'L{c["level"]}', c["domains"]))
    if len(nodes) > 1:
        cands.append(('NUMA', [_fmt(v) for v in nodes.values()]))
    if dies and len(dies) > t["n_sockets"]:
        cands.append(('die', dies))
    cl_id = _read('/sys/devices/system/cpu/cpu0/topology/cluster_id')
    if cl_id is not None and cl_id.strip() not in ('65535', '-1', ''):
        clusters = _group_by('cluster_cpus_list', online)
        # so vale se for MAIS GROSSO que um core fisico (senao e o proprio SMT sibling)
        if clusters and threads and len(clusters) < len(threads):
            cands.append(('cluster', clusters))
    if sockets and len(sockets) > 1:
        cands.append(('socket', sockets))
    if threads:
        cands.append(('core', threads))

    for src, doms in cands:
        if not doms: continue
        if not _partitions(doms, online):
            t["warnings"].append(f"fonte '{src}' nao particiona as CPUs online - descartada")
            continue
        # Recortar pelo conjunto ONLINE: shared_cpu_list/die_cpus_list vem do hardware e
        # inclui CPUs offline (nosmt, maxcpus=, isolcpus com hotplug). Sem isto o auto-detect
        # devolveria um cpulist com CPU offline, e o pin-irq abortaria la na frente.
        clipped = []
        for d in doms:
            s = _cpus_in(d) & online
            if s: clipped.append(_fmt(s))
        if len(clipped) != len(doms):
            t["warnings"].append(f"fonte '{src}': dominios vazios apos filtrar CPUs offline")
        t["domain_source"] = src
        t["domains"] = clipped
        break

    if not t["domains"]:
        t["warnings"].append("nenhuma fonte de topologia utilizavel - usando uma CPU por dominio")
        t["domain_source"] = "cpu"
        t["domains"] = [str(c) for c in sorted(online)]

    # rotulo legivel do dominio
    src = t["domain_source"]
    amd = 'AMD' in (ven or '') or 'AuthenticAMD' in (ven or '')
    if src.startswith('L') and src[1:].isdigit():
        t["domain_label"] = 'CCX' if (amd and src == 'L3') else f'{src} domain'
    else:
        t["domain_label"] = {'NUMA': 'NUMA node', 'die': 'die/CCD', 'cluster': 'cluster',
                             'socket': 'socket', 'core': 'core fisico', 'cpu': 'CPU'}.get(src, src)
    if src in ('core', 'cpu', 'socket'):
        t["warnings"].append(
            f"dominio derivado de '{src}': o split NAO respeita fronteira de cache. "
            "Se este for um EPYC/multi-CCX, passe as CPUs manualmente "
            "(--slave0-cpus/--slave1-cpus, ou --cpus na variante single)")
    return t

def render_topology(t, extra=None):
    """Tabela legivel da topologia detectada (usada por --print-topology)."""
    L = []
    L.append(f"CPU:       {t.get('model') or '?'}   [{t.get('vendor') or '?'}]")
    L.append(f"online:    {t.get('online')}  ({t.get('n_online')} logical, "
             f"{t.get('n_cores','?')} cores, SMT={'on' if t.get('smt') else 'off'}"
             f" @ {t.get('threads_per_core','?')} thr/core)")
    L.append(f"pacote:    {t.get('n_sockets','?')} socket(s), {t.get('n_dies','?')} die(s), "
             f"{t.get('n_numa','?')} NUMA node(s)")
    for nid, cl in (t.get('numa_nodes') or {}).items():
        L.append(f"  NUMA {nid}:  {cl}")
    if t.get('caches'):
        L.append("caches:")
        for c in t['caches']:
            L.append(f"  L{c['level']} {c['type']:<11} {str(c['size'] or '?'):>8}"
                     f"  -> {c['n_domains']} dominio(s)")
    L.append(f"dominio de cache: {t.get('domain_label')}  (fonte: {t.get('domain_source')})"
             f"  -> {len(t.get('domains') or [])} dominio(s)")
    for i, d in enumerate(t.get('domains') or []):
        L.append(f"  [{i}] {d}")
    for w in (t.get('warnings') or []):
        L.append(f"  [!] {w}")
    if extra:
        L.extend(extra)
    return "\n".join(L)
# <<< TOPOLOGY_LIB <<<

slaves = [s for s in sys.argv[1].split(',') if s]
t = detect_topology()
warnings = list(t["warnings"])
domains = list(t["domains"])

if not domains:
    print(json.dumps({"error": "nenhum dominio de CPU detectado", "warnings": warnings,
                      "topology": t}))
    sys.exit(0)

if not slaves:
    # --print-topology sem bond resolvido: mostra so a topologia da maquina.
    if os.environ.get("TOPO_MODE") == "render":
        print(render_topology(t, ["(nenhum slave de bond resolvido - split nao calculado)"]))
    else:
        print(json.dumps({"warnings": warnings, "topology": t, "slaves": []}))
    sys.exit(0)

# NUMA da NIC: fonte unica e' /sys/class/net/<iface>/device/numa_node.
nic = []
for iface in slaves:
    v = _read(f'/sys/class/net/{iface}/device/numa_node')
    try: numa = int(v)
    except (TypeError, ValueError): numa = -1
    nic.append({"iface": iface, "numa": numa})

node_cpus = {int(k): _cpus_in(v) for k, v in t["numa_nodes"].items()}

def domains_for(numa, iface):
    """Dominios que cabem inteiros dentro do NUMA da NIC."""
    if numa < 0 or numa not in node_cpus:
        return domains                      # NPS=1 / indefinido: todos servem
    nset = node_cpus[numa]
    sub = [d for d in domains if _cpus_in(d) <= nset]
    if sub:
        return sub
    warnings.append(f"{iface}: numa_node={numa} mas nenhum dominio cabe nesse node - "
                    "usando todos (split cross-NUMA)")
    return domains

n = len(slaves)
local = [domains_for(ni["numa"], ni["iface"]) for ni in nic]

if all(d == local[0] for d in local):
    pool = local[0]
    if len(pool) < n:
        warnings.append(f"{n} slaves mas apenas {len(pool)} dominio(s) de "
                        f"{t['domain_label']} - os slaves VAO COMPARTILHAR o mesmo dominio "
                        "(sobreposicao total de cache; considere --slave0-cpus/--slave1-cpus)")
        splits = [[pool[i % len(pool)]] for i in range(n)]
    else:
        per = len(pool) // n
        splits = [pool[i*per:(i+1)*per] if i < n - 1 else pool[i*per:] for i in range(n)]
else:
    splits = local          # NUMA distinto por NIC: cada uma fica no seu

out = {"warnings": warnings, "topology": t, "slaves": []}
for i, iface in enumerate(slaves):
    cpus = set()
    for d in splits[i]:
        cpus |= _cpus_in(d)
    out["slaves"].append({"iface": iface, "numa": nic[i]["numa"], "ccxs": splits[i],
                          "cpus": _fmt(cpus), "n_logical": len(cpus)})

if os.environ.get("TOPO_MODE") == "render":
    extra = ["split proposto por slave:"]
    for s in out["slaves"]:
        extra.append("  %-20s numa=%-3s cpus=%-24s (%s logical)" % (
            s["iface"], s["numa"], s["cpus"], s["n_logical"]))
        for d in s["ccxs"]:
            extra.append("      dominio %s" % d)
    # so os warnings do SPLIT: os da topologia ja saem no bloco acima
    for w in warnings:
        if w not in t["warnings"]:
            extra.append("  [!] %s" % w)
    print(render_topology(t, extra))
else:
    print(json.dumps(out))
PY
}


# --print-topology: imprime a topologia detectada (CPU, caches, NUMA, dominios de cache)
# e o split/selecao que o auto-detect faria, depois sai. Diagnostico independente do resto do
# fluxo: serve para conferir, num servidor novo, se o kernel expoe L3/CCX ANTES de aplicar.
print_topology() {
  TOPO_MODE=render topology_json
}

# ---------------- pré-flight ----------------

# Garante que um binário (e, opcionalmente, seu pacote APT) esteja disponível.
# Em DRY-RUN, simula a instalação e segue.
preflight() {
  log "pré-flight"
  command -v ethtool  >/dev/null || { err "ethtool não instalado (apt install ethtool)"; exit 1; }
  command -v python3  >/dev/null || { err "python3 ausente (necessário para auto-detect e máscara)"; exit 1; }
  command -v systemctl >/dev/null || { err "systemctl ausente"; exit 1; }
  if ! command -v tc >/dev/null; then
    warn "'tc' (iproute2) ausente — correção de qdisc das tx queues desabilitada"
    APPLY_QDISC=0
  fi

  [[ -f "/proc/net/bonding/${BOND}" ]] || {
    err "bond '${BOND}' não existe em /proc/net/bonding/. Passe --bond <nome>."; exit 1;
  }

  # Ordena alfabeticamente: a ordem em /proc/net/bonding depende de quem subiu primeiro,
  # não é estável entre reboots. Ordenar garante slave0 sempre = ...f0np0, slave1 = ...f1np1.
  mapfile -t SLAVES < <(awk '/^Slave Interface:/{print $3}' "/proc/net/bonding/${BOND}" | sort)
  (( ${#SLAVES[@]} >= 2 )) || { err "bond ${BOND} tem menos de 2 slaves: ${SLAVES[*]}"; exit 1; }
  if (( ${#SLAVES[@]} > 2 )); then
    warn "bond ${BOND} tem ${#SLAVES[@]} slaves (${SLAVES[*]}); script só pina os 2 primeiros (${SLAVES[0]}, ${SLAVES[1]}) — slaves extras ficarão sem pinning"
  fi

  SLAVE0="${SLAVES[0]}"
  SLAVE1="${SLAVES[1]}"

  for s in "$SLAVE0" "$SLAVE1"; do
    [[ -d "/sys/class/net/$s" ]] || { err "interface $s não existe em /sys/class/net"; exit 1; }
    local drv
    drv=$(basename "$(readlink "/sys/class/net/$s/device/driver" 2>/dev/null)" 2>/dev/null || echo "?")
    [[ "$drv" == mlx5_core ]] || warn "$s usa driver '$drv' (esperado mlx5_core) — script segue mesmo assim"
  done

  # Auto-detect só se NÃO veio override de --slave*-cpus ou --queues.
  resolve_topology

  ok "bond=${BOND}"
  ok "  slave0=${SLAVE0} CPUs=${SLAVE0_CPUS} queues=${QUEUES_S0}"
  ok "  slave1=${SLAVE1} CPUs=${SLAVE1_CPUS} queues=${QUEUES_S1}"


  # Coerência queues vs logical CPUs do split — warn only, o pinning round-robin tolera.
  local n0 n1
  n0=$(count_cpus_in_list "$SLAVE0_CPUS")
  n1=$(count_cpus_in_list "$SLAVE1_CPUS")
  if (( QUEUES_S0 < n0 )); then warn "slave0: ${QUEUES_S0} queues < ${n0} logical CPUs — IRQs só pinarão nas primeiras ${QUEUES_S0} CPUs"; fi
  if (( QUEUES_S1 < n1 )); then warn "slave1: ${QUEUES_S1} queues < ${n1} logical CPUs — IRQs só pinarão nas primeiras ${QUEUES_S1} CPUs"; fi
}

# Resolve SLAVE0_CPUS / SLAVE1_CPUS / QUEUES.
# Roda auto-detect só pra preencher o que FALTA. Em seguida, recalcula n_logical
# dos valores FINAIS (pra que QUEUES respeite overrides via --slave*-cpus).
resolve_topology() {
  # Auto-detect roda se PELO MENOS um dos cpulists ainda está vazio.
  # (Se ambos overrides foram passados, autodetect é dispensável; QUEUES é calculado
  # depois usando os valores finais.)
  local need_auto=0
  [[ -z "$SLAVE0_CPUS" || -z "$SLAVE1_CPUS" ]] && need_auto=1

  if (( need_auto )); then
    log "auto-detect de topologia (cpulist faltando para algum slave)"
    local json
    json=$(topology_json)
    if ! TOPO_JSON="$json" python3 -c 'import json,os; d=json.loads(os.environ["TOPO_JSON"]); raise SystemExit(1 if "error" in d else 0)' 2>/dev/null; then
      err "auto-detect falhou: $json"; exit 1
    fi

    # Imprimir resumo da topologia detectada
    TOPO_JSON="$json" python3 - <<'PY'
import json, os
d = json.loads(os.environ["TOPO_JSON"])
tp = d.get("topology", {})
print("    CPU: %s | %s cores / %s logical | SMT=%s | %s socket(s) %s NUMA" % (
    tp.get("model", "?"), tp.get("n_cores", "?"), tp.get("n_online", "?"),
    "on" if tp.get("smt") else "off", tp.get("n_sockets", "?"), tp.get("n_numa", "?")))
print("    dominio de cache: %s x %s (fonte: %s)" % (
    len(tp.get("domains") or []), tp.get("domain_label", "?"), tp.get("domain_source", "?")))
for w in d.get("warnings", []):
    print(f"\033[1;33m[!]\033[0m topologia: {w}")
print("    split por slave:")
for s in d["slaves"]:
    ccxs = " | ".join(s["ccxs"])
    print(f"      {s['iface']:<20s} numa={s['numa']:>2} CCXs=[{ccxs}] CPUs={s['cpus']} ({s['n_logical']} logical)")
PY

    local auto_s0 auto_s1
    auto_s0=$(TOPO_JSON="$json" python3 -c 'import json,os; print(json.loads(os.environ["TOPO_JSON"])["slaves"][0]["cpus"])')
    auto_s1=$(TOPO_JSON="$json" python3 -c 'import json,os; print(json.loads(os.environ["TOPO_JSON"])["slaves"][1]["cpus"])')

    [[ -z "$SLAVE0_CPUS" ]] && SLAVE0_CPUS="$auto_s0"
    [[ -z "$SLAVE1_CPUS" ]] && SLAVE1_CPUS="$auto_s1"
  else
    log "topologia 100% via flags --slave0-cpus/--slave1-cpus (auto-detect skipado)"
  fi

  # SEMPRE conta n_logical a partir dos valores FINAIS de SLAVE0_CPUS/SLAVE1_CPUS,
  # não do auto-detect. Isso garante que --slave*-cpus override seja respeitado.
  local n_logical_s0 n_logical_s1
  n_logical_s0=$(count_cpus_in_list "$SLAVE0_CPUS")
  n_logical_s1=$(count_cpus_in_list "$SLAVE1_CPUS")

  # Resolve QUEUES_S0 e QUEUES_S1 automaticamente:
  #   - se --queues N foi passado: aplica N em ambos
  #   - senão: cada slave = min(n_cpus_do_slave, max-combined_do_slave)
  local maxq0 maxq1
  maxq0=$(ethtool_combined_max "$SLAVE0")
  maxq1=$(ethtool_combined_max "$SLAVE1")
  maxq0=${maxq0:-0}
  maxq1=${maxq1:-0}

  if [[ -n "$QUEUES" ]]; then
    QUEUES_S0="$QUEUES"
    QUEUES_S1="$QUEUES"
    ok "queues forçado via --queues: ${SLAVE0}=${QUEUES_S0}, ${SLAVE1}=${QUEUES_S1}"
  else
    QUEUES_S0=$(( n_logical_s0 < maxq0 ? n_logical_s0 : maxq0 ))
    QUEUES_S1=$(( n_logical_s1 < maxq1 ? n_logical_s1 : maxq1 ))
    ok "queues calculado: ${SLAVE0}=${QUEUES_S0} (cpus=${n_logical_s0}, max=${maxq0}); ${SLAVE1}=${QUEUES_S1} (cpus=${n_logical_s1}, max=${maxq1})"
  fi

  # Sanity ANTES de qualquer escrita: um QUEUES_S* inválido (0, negativo, vazio, acima do
  # max) só seria detectado pelo ethtool -L lá na frente, com a NIC já mexida e o irqbalance
  # já desabilitado. single/mlx4 já validavam isto; o bond não.
  local qv
  for qv in QUEUES_S0 QUEUES_S1; do
    [[ "${!qv}" =~ ^[0-9]+$ ]] || { err "${qv}='${!qv}' não é inteiro (max combined ilegível ou --queues inválido)"; exit 1; }
  done
  if (( QUEUES_S0 < 1 || QUEUES_S1 < 1 )); then
    err "queues resolvido para ${SLAVE0}=${QUEUES_S0} ${SLAVE1}=${QUEUES_S1} (precisa ser >= 1)."
    err "  Se 'max combined' saiu 0, esta NIC não usa combined channels — driver mlx4_en? use ./mellanox-tune-mlx4.sh"
    exit 1
  fi
  if (( QUEUES_S0 > maxq0 || QUEUES_S1 > maxq1 )); then
    err "queues acima do máximo do device: ${SLAVE0}=${QUEUES_S0}/${maxq0}, ${SLAVE1}=${QUEUES_S1}/${maxq1}"
    exit 1
  fi

  # Validação NUMA: warn (não-fatal). Se 2 slaves compartilham PCI controller mas
  # BIOS reporta NUMAs divergentes, validate_numa consolida via controller (pega
  # o menor) — corrige relatos errôneos do BIOS.
  validate_numa_for_slave "$SLAVE0" "$SLAVE0_CPUS"
  validate_numa_for_slave "$SLAVE1" "$SLAVE1_CPUS"
}

# Avisa (sem abortar) se cpulist tem CPUs fora do NUMA da NIC.
# Fonte única do NUMA: cat /sys/class/net/<iface>/device/numa_node.
validate_numa_for_slave() {
  local iface="$1" cpulist="$2"
  local numa nfile
  nfile="/sys/class/net/$iface/device/numa_node"
  [[ -f "$nfile" ]] || { warn "${iface}: sem ${nfile} — pulando validação NUMA"; return 0; }
  numa=$(cat "$nfile" 2>/dev/null || echo -1)
  if (( numa < 0 )); then
    warn "${iface}: numa_node=-1 (NPS=1 ou indefinido) — sem filtro NUMA aplicado"
    return 0
  fi
  local nc="/sys/devices/system/node/node${numa}/cpulist"
  [[ -f "$nc" ]] || { warn "${iface}: ${nc} ausente — pulando validação NUMA"; return 0; }
  local node_cpulist
  node_cpulist=$(cat "$nc")
  local extras
  if extras=$(cpus_outside_numa "$cpulist" "$node_cpulist"); then
    ok "${iface}: CPUs ${cpulist} dentro do NUMA ${numa} (${node_cpulist})"
  else
    warn "${iface}: cross-NUMA — cpulist=${cpulist} tem CPUs fora do NUMA${numa}: ${extras}"
    warn "  CPUs do NUMA${numa}: ${node_cpulist}"
  fi
}

# ---------------- backup ----------------

backup_state() {
  log "backup do estado atual em ${BACKUP_DIR}"
  run "mkdir -p '${BACKUP_DIR}'"
  run "cp -a /proc/interrupts '${BACKUP_DIR}/interrupts.pre-pin-${STAMP}.txt'"
  for s in "$SLAVE0" "$SLAVE1"; do
    run "${HELPER_PATH} show-irq '$s' > '${BACKUP_DIR}/affinity.${s}.pre-pin-${STAMP}.txt' 2>&1 || true"
  done
  run "systemctl is-enabled irqbalance > '${BACKUP_DIR}/irqbalance.pre-pin-${STAMP}.txt' 2>&1 || true"
  ok "backup completo"
}

# ---------------- irqbalance ----------------

stop_irqbalance() {
  # `systemctl list-unit-files X` retorna 0 mesmo se X não existe — não serve como
  # check. Usar `cat` que retorna não-zero se a unit não existe.
  if systemctl cat irqbalance.service &>/dev/null; then
    log "desabilitando irqbalance (sobrescreve afinidade a cada ~10s)"
    run "systemctl disable --now irqbalance || true"
    ok "irqbalance off"
  else
    warn "irqbalance não instalado — nada a parar"
  fi
}

# ---------------- ethtool combined queues ----------------

# Reduz combined queues de cada slave para casar com o número de logical CPUs pinadas.
# Importante: ethtool -L renumera todas as IRQs do device — DEVE rodar antes do pinning.
# Em mlx5 a operação é runtime-friendly mas interrompe filas por ~50ms; fazemos um slave
# por vez com sleep para o LACP redistribuir tráfego no outro slave durante o hiccup.
# Lê o Combined atual (segunda ocorrência de "Combined:" em ethtool -l, em "Current hardware settings").
ethtool_combined_current() {
  { ethtool -l "$1" 2>/dev/null || true; } | awk '/Combined:/{c=$2} END{print c}'
}
ethtool_combined_max() {
  { ethtool -l "$1" 2>/dev/null || true; } | awk '/Combined:/ && !seen++ {print $2}'
}

set_queues_to_max() {
  # Subir ao MAX serve para expor filas herdadas de um run anterior antes do cleanup. Se a
  # NIC JÁ está no alvo, não há nada acima dele para limpar — e o bounce alvo->max->alvo
  # custa 2 reconfigurações de canais por slave (cada `ethtool -L` fecha e reabre todos os
  # canais do mlx5 sem derrubar o carrier, ou seja, sem failover do LACP: é perda pura).
  log "expondo filas herdadas antes do cleanup (só quando há algo acima do alvo)"
  local entry s q cur maxq
  for entry in "$SLAVE0:$QUEUES_S0" "$SLAVE1:$QUEUES_S1"; do
    s="${entry%:*}"; q="${entry#*:}"
    cur=$(ethtool_combined_current "$s")
    maxq=$(ethtool_combined_max "$s")
    if [[ -z "$maxq" ]]; then
      warn "$s: ethtool não reportou max combined — pulando set-to-max"
      continue
    fi
    if [[ "$cur" == "$q" ]]; then
      ok "$s já em Combined=${q} (alvo) — sem bounce"
      continue
    fi
    if [[ "$cur" == "$maxq" ]]; then
      ok "$s já em Combined=${maxq} (max), sem mudança"
      continue
    fi
    log "$s: Combined ${cur:-?} → ${maxq} (max, temporário para o cleanup)"
    run "ethtool -L $s combined ${maxq}"
    run "sleep 2"
  done
}

apply_queue_count() {
  log "ajustando combined queues por slave: ${SLAVE0}=${QUEUES_S0}, ${SLAVE1}=${QUEUES_S1}"
  local s q cur err_log
  err_log="/tmp/xui-ethtool-err.$$"
  for entry in "$SLAVE0:$QUEUES_S0" "$SLAVE1:$QUEUES_S1"; do
    s="${entry%:*}"
    q="${entry#*:}"
    cur=$(ethtool_combined_current "$s")
    if [[ "$cur" == "$q" ]]; then
      ok "$s já em Combined=${q}, sem mudança"
      continue
    fi
    log "$s: Combined ${cur:-?} → ${q}"
    if (( DRY_RUN )); then
      printf '\033[1;90m    DRY: ethtool -L %s combined %s\033[0m\n' "$s" "$q" >&2
      continue
    fi
    # ethtool -L pode falhar com EINVAL se 'q' está abaixo do mínimo do driver.
    # Capturar stderr e dar mensagem útil em vez de abortar com set -e.
    if ! ethtool -L "$s" combined "$q" 2>"$err_log"; then
      local emsg; emsg=$(cat "$err_log" 2>/dev/null)
      err "$s: ethtool -L combined ${q} falhou — ${emsg}"
      err "  Causa provável: ${q} é abaixo do mínimo aceito pelo driver/firmware mlx5."
      err "  → Aumente CPUs em --slave*-cpus (mais CPUs = mais queues), ou use --queues N maior."
      err "  Estado atual da NIC: Combined=${cur:-?} (continua nesse valor)."
      rm -f "$err_log"
      exit 1
    fi
    rm -f "$err_log"
    sleep 2
  done
}

# Marca que o estado da NIC já foi mexido de forma que um aborto deixaria pior do que antes
# (afinidade zerada, irqbalance desligado). Consumido pelo trap de EXIT.
STATE_DIRTY=0

# Um aborto entre o cleanup e o pinning deixa TODOS os IRQs em default_smp_affinity, com o
# irqbalance já desabilitado — pior do que o estado inicial. O trap repina com o cpulist
# resolvido, que é o melhor esforço possível sem reintroduzir o irqbalance (mantê-lo
# desligado é decisão explícita do projeto).
on_exit() {
  local rc=$?
  (( rc != 0 )) || return 0
  (( ! DRY_RUN )) || return 0
  (( STATE_DIRTY )) || return 0
  err "ABORTO (rc=${rc}) depois do cleanup — repinando IRQs para não deixar a NIC sem afinidade"
  if [[ -x "${HELPER_PATH}" ]]; then
    "${HELPER_PATH}" pin-irq "${SLAVE0:-}" "${SLAVE0_CPUS:-}" || true
    "${HELPER_PATH}" pin-irq "${SLAVE1:-}" "${SLAVE1_CPUS:-}" || true
  fi
  err "  irqbalance continua DESABILITADO (por design). Revise o estado com: $0 --dry-run"
}
trap on_exit EXIT

# ---------------- cleanup total ----------------

# Zera TODO o estado herdado de runs anteriores ou do driver default:
#   - smp_affinity dos IRQs mlx5_comp* → /proc/irq/default_smp_affinity
#   - rps_cpus de todas as rx queues = 0
#   - xps_cpus de todas as tx queues = 0
#   - rps_flow_cnt de todas as rx queues = 0
#   - ethtool -K ntuple off (aRFS off)
#   - sysctl net.core.rps_sock_flow_entries = 0
#
# Chamado APÓS set_queues_to_max (estado MÁX) para garantir que filas que vão sumir
# ao reduzir queues também sejam zeradas, evitando state stale se o usuário voltar a
# expandir queues no futuro.
cleanup_existing_state() {
  log "CLEANUP TOTAL — IRQ, RPS, XPS, aRFS em ambos os slaves"
  run "${HELPER_PATH} cleanup ${SLAVE0}"
  run "${HELPER_PATH} cleanup ${SLAVE1}"
  run "${HELPER_PATH} cleanup-global"
  STATE_DIRTY=1
  ok "estado limpo (pronto para aplicar)"
}

# ---------------- ring size, coalesce, offloads ----------------
# Aplicado por slave (loop), igual ao set_queues_to_max/apply_queue_count.

# ethtool -g layout: pre-set max + current. section=max|current ; channel=RX|TX.
ethtool_ring() {
  local iface="$1" section="$2" channel="$3"
  if [[ "$section" == "max" ]]; then
    { ethtool -g "$iface" 2>/dev/null || true; } | awk -v ch="${channel}:" '
      /Pre-set maximums:/ { in_max=1; next }
      /Current hardware settings:/ { in_max=0 }
      in_max && $1==ch && !seen++ { print $2 }
    '
  else
    { ethtool -g "$iface" 2>/dev/null || true; } | awk -v ch="${channel}:" '
      /Current hardware settings:/ { in_cur=1; next }
      in_cur && $1==ch && !seen++ { print $2 }
    '
  fi
}

apply_ring_max() {
  (( APPLY_RING_MAX )) || { warn "ring max desabilitado (--no-ring-max)"; return; }
  log "ajustando ring size ao máximo em ambos os slaves"
  run "${HELPER_PATH} ring-max ${SLAVE0}"
  run "${HELPER_PATH} ring-max ${SLAVE1}"
}

apply_coalesce_adaptive() {
  (( APPLY_COALESCE )) || { warn "coalesce adaptive desabilitado (--no-coalesce)"; return; }
  log "habilitando adaptive coalescing em ambos os slaves"
  run "${HELPER_PATH} coalesce ${SLAVE0}"
  run "${HELPER_PATH} coalesce ${SLAVE1}"
}

apply_offloads() {
  (( APPLY_OFFLOADS )) || { warn "offloads desabilitados (--no-offloads)"; return; }
  log "habilitando offloads em ambos os slaves (tso/gro/gso=on, lro=off — bond força off)"
  # LRO=off explícito: em slave de bond o kernel força off (dev_disable_lro em bond_enslave).
  # Setar off evita o "[requested on]" cosmético; o GRO (software) cobre o papel mantendo os
  # pacotes íntegros, que é o que forwarding exige.
  run "${HELPER_PATH} offloads ${SLAVE0} off"
  run "${HELPER_PATH} offloads ${SLAVE1} off"
}

# ---------------- qdisc das tx queues (pacing FQ p/ BBR) ----------------
# ethtool -L não recria os qdiscs das filas: mq_init() cria um qdisc filho por tx queue
# no instante em que o mq é anexado e só usa net.core.default_qdisc nos índices
# < real_num_tx_queues (get_default_qdisc_ops, net/sched/sch_generic.c) — os demais nascem
# pfifo_fast. Como este script SOBE as filas ao máximo e depois REDUZ ao target, toda fila
# ativada acima do valor que existia quando o mq foi anexado fica com pfifo_fast: sem
# pacing FQ, o BBR degrada exatamente nessas filas (perde o shaping por fluxo e passa a
# depender só do pacing interno do TCP).
# O helper detecta o descasamento e reanexa o root mq, regenerando todos os filhos com o
# net.core.default_qdisc vigente. É no-op quando já está correto.

apply_qdisc() {
  (( APPLY_QDISC )) || { warn "regeneração de qdisc desabilitada (--no-qdisc)"; return; }
  log "verificando qdisc das tx queues em ambos os slaves (pacing FQ p/ BBR)"
  # O qdisc do bond master é noqueue: o enfileiramento real acontece nos slaves.
  run "${HELPER_PATH} fix-qdisc ${SLAVE0}"
  run "${HELPER_PATH} fix-qdisc ${SLAVE1}"
}

# ---------------- pinning ----------------

apply_pinning() {
  log "aplicando IRQ affinity (implementação nativa, via helper)"
  run "${HELPER_PATH} pin-irq ${SLAVE0} ${SLAVE0_CPUS}"
  run "${HELPER_PATH} pin-irq ${SLAVE1} ${SLAVE1_CPUS}"
  ok "IRQs pinadas"
}

# ---------------- XPS / RPS / aRFS condicionais ----------------
# Cada um é aplicado SÓ se a flag correspondente foi passada. A distribuição segue
# o modelo Mellanox: cada queue N usa a smp_affinity do IRQ mlx5_compN — i.e., a
# máscara espelha onde a interrupção foi pinada. Garante 1:1 entre IRQ e steering.

apply_xps_per_irq() {
  log "XPS per-queue espelhando IRQ (modelo Mellanox)"
  run "${HELPER_PATH} mirror-xps ${SLAVE0}"
  run "${HELPER_PATH} mirror-xps ${SLAVE1}"
  ok "XPS aplicado"
}

apply_rps_per_irq() {
  # RPS redistribui o processamento de rx para OUTRA CPU. mirror-rps aponta rps_cpus[rx-N]
  # para a própria CPU do IRQ N, então quando há uma fila por CPU não há para onde
  # redistribuir: get_rps_cpu() não tem atalho para "destino == CPU atual" e cada pacote paga
  # enqueue_to_backlog + um ciclo extra de softirq, sem ganho.
  if (( QUEUES_S0 >= $(count_cpus_in_list "$SLAVE0_CPUS") && QUEUES_S1 >= $(count_cpus_in_list "$SLAVE1_CPUS") )); then
    warn "--rps com filas >= CPUs: cada fila já tem CPU própria, RPS só adiciona overhead"
    warn "  (útil quando o nº de filas é MENOR que o de CPUs do cpulist)"
  fi
  log "RPS per-queue espelhando IRQ (modelo Mellanox)"
  run "${HELPER_PATH} mirror-rps ${SLAVE0}"
  run "${HELPER_PATH} mirror-rps ${SLAVE1}"
  ok "RPS aplicado"
}

apply_arfs_all() {
  log "aRFS: rps_sock_flow_entries=${ARFS_FLOW_ENTRIES} + ntuple on + rps_flow_cnt=${ARFS_PER_QUEUE_FLOW_CNT}"
  run "${HELPER_PATH} arfs-global ${ARFS_FLOW_ENTRIES}"
  run "${HELPER_PATH} arfs ${SLAVE0} ${ARFS_PER_QUEUE_FLOW_CNT}"
  run "${HELPER_PATH} arfs ${SLAVE1} ${ARFS_PER_QUEUE_FLOW_CNT}"
  ok "aRFS aplicado"
}

# ---------------- deploy helper ----------------
# Escreve /usr/local/sbin/xui-lb-mlx-helper.sh com os subcomandos usados aqui e pela
# unit. Ter um único script faz com que install-time e boot-time apliquem EXATAMENTE
# a mesma sequência (sem divergência de lógica entre os dois caminhos).
# Bumpar quando o conteudo do heredoc abaixo mudar; o grep casa por essa tag.
# O helper e COMPARTILHADO com mellanox-tune-single.sh — o corpo do heredoc dos dois
# scripts precisa ser byte-identico, senao cada run sobrescreve o do outro.
HELPER_VERSION=5

# Emite o helper embutido em stdout. Separado de deploy_helper() para que --print-helper
# produza exatamente o mesmo conteúdo que é instalado, sem efeito colateral. Escreve em
# stdout (e não num caminho recebido) porque /dev/stdout não é gravável em todo contexto.
emit_helper() {
  cat <<'HELPER_EOF'
#!/usr/bin/env bash
# HELPER_VERSION=5
# Helper compartilhado por mellanox-tune-bond.sh e mellanox-tune-single.sh.
# Subcomandos:
#   cleanup <iface>            Zera smp_affinity dos IRQs mlx5_comp* da iface,
#                              rps_cpus, xps_cpus, rps_flow_cnt; ntuple off.
#   cleanup-global             sysctl net.core.rps_sock_flow_entries=0.
#   mirror-xps <iface>         xps_cpus[tx-N] = smp_affinity[mlx5_compN].
#   mirror-rps <iface>         rps_cpus[rx-N] = smp_affinity[mlx5_compN].
#   arfs <iface> [total]       ntuple on + rps_flow_cnt = total/n_rx_queues por fila
#                              (default total 32768; ver Documentation/networking/scaling.rst).
#   arfs-global [entries]      sysctl net.core.rps_sock_flow_entries (default 32768).
#   show-irq <iface>           Lista IRQ -> smp_affinity/cpu da NIC (snapshot; equivale
#                              ao show_irq_affinity.sh do mlnx-tools).
#   ring-max <iface>           ethtool -G rx/tx no máximo do device (idempotente).
#   coalesce <iface>           ethtool -C adaptive-rx/tx on (idempotente).
#   offloads <iface> <on|off>  ethtool -K tso/gro/gso on + lro conforme o 2o arg.
#   pin-irq <iface> <cpulist>  Distribui os IRQs de completion da NIC nas CPUs do
#                              cpulist, round-robin (substitui o set_irq_affinity_
#                              cpulist.sh do mlnx-tools — sem dependência externa).
#   fix-qdisc <iface> [kind]   Garante que TODAS as tx queues ativas usem o qdisc
#                              net.core.default_qdisc (default: le o sysctl). Necessario
#                              depois de ethtool -L: filas novas nascem pfifo_fast.

set -euo pipefail
ACTION="${1:-}"; IFACE="${2:-}"

cpulist_to_mask() {
  python3 - "$1" <<'PY'
import sys
spec = sys.argv[1]; bits = 0
for tok in spec.split(','):
    tok = tok.strip()
    if not tok: continue
    if '-' in tok:
        a, b = map(int, tok.split('-'))
        for i in range(a, b + 1): bits |= 1 << i
    else: bits |= 1 << int(tok)
n = max(1, (bits.bit_length() + 31) // 32)
print(','.join(format((bits >> (i * 32)) & 0xFFFFFFFF, '08x') for i in range(n - 1, -1, -1)))
PY
}

iface_bdf() {
  local target
  target=$(readlink -f "/sys/class/net/$1/device" 2>/dev/null) || return 1
  [[ -n "$target" ]] || return 1
  basename "$target"
}

irq_for_queue() {
  local iface="$1" qidx="$2" bdf
  bdf=$(iface_bdf "$iface") || return 1
  awk -v p="mlx5_comp${qidx}@pci:${bdf}" '$NF==p{sub(":",""); print $1; exit}' /proc/interrupts
}

require_iface() {
  [[ -n "$IFACE" ]] || { echo "iface required for action '$ACTION'" >&2; exit 1; }
  [[ -d "/sys/class/net/$IFACE" ]] || { echo "iface $IFACE not found" >&2; exit 1; }
}

# IRQs de completion da NIC, ordenados pelo ÍNDICE DA QUEUE (mlx5_compN) e não pelo número
# do IRQ. Mantém coerência com mirror-xps/mirror-rps, que mapeiam queue N -> mlx5_compN.
# (O upstream ordena por número de IRQ; nas NICs testadas a ordem coincide, mas quem manda
# é o índice.) Os mlx5_async* ficam de fora de propósito — são eventos de controle (cmd,
# page fault, EQ async), não fazem parte do data path.
# Comparação por substring exata, sem regex: o BDF tem '.' e ':' que exigiriam escape.
comp_irqs_for_iface() {
  local iface="$1" bdf
  bdf=$(iface_bdf "$iface") || return 1
  awk -v bdf="$bdf" '
    {
      name = $NF
      if (substr(name, 1, 9) != "mlx5_comp") next
      at = index(name, "@")
      if (at == 0) next
      idx = substr(name, 10, at - 10)
      if (idx !~ /^[0-9]+$/) next
      if (substr(name, at + 1) != ("pci:" bdf)) next
      irq = $1; sub(":", "", irq)
      printf "%d %s\n", idx, irq
    }
  ' /proc/interrupts | sort -n -k1,1 | awk '{print $2}'
}

# --- IRQ pinning nativo (substitui o set_irq_affinity_cpulist.sh do mlnx-tools) --------
# Reimplementação da lógica de set_irq_affinity_cpulist.sh + common_irq_affinity.sh
# (Mellanox/mlnx-tools — CPL-1.0 / BSD / GPL-2.0): expande o cpulist, descobre os IRQs da
# NIC e distribui round-robin, IRQ i -> cpus[i % n_cpus]. Mesma semântica de distribuição
# do upstream, sem precisar clonar o repositório.
# Diferenças propositais:
#   - Os IRQs vêm do BDF PCI da interface. O upstream tenta primeiro casar o NOME da
#     interface no /proc/interrupts, o que não funciona em mlx5 (o nome lá é
#     mlx5_compN@pci:<bdf>, sem o nome da netdev).
#   - Escreve em smp_affinity_list (aceita cpulist direto); só monta máscara hex e escreve
#     em smp_affinity se o kernel recusar a primeira forma.
#   - Valida que cada CPU pedida existe e está online ANTES de escrever (o upstream faz um
#     check parcial e continua, deixando IRQs sem pinar em silêncio).

# "0-3,8,10-11" -> uma CPU por linha.
expand_cpulist() {
  local spec="$1" tok a b i
  local -a out=() toks=()
  IFS=',' read -r -a toks <<< "$spec"
  for tok in "${toks[@]}"; do
    tok="${tok// /}"
    [[ -n "$tok" ]] || continue
    if [[ "$tok" == *-* ]]; then
      a="${tok%%-*}"; b="${tok##*-}"
      [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || { echo "cpulist inválido: '$tok'" >&2; return 1; }
      (( a <= b )) || { echo "cpulist inválido (range invertido): '$tok'" >&2; return 1; }
      for (( i=a; i<=b; i++ )); do out+=("$i"); done
    else
      [[ "$tok" =~ ^[0-9]+$ ]] || { echo "cpulist inválido: '$tok'" >&2; return 1; }
      out+=("$tok")
    fi
  done
  (( ${#out[@]} )) || { echo "cpulist vazio: '$spec'" >&2; return 1; }
  printf '%s\n' "${out[@]}"
}

# Equivalente ao show_irq_affinity.sh do mlnx-tools: usado para o snapshot pré-pinning.
show_irq_aff() {
  local iface="$1" irq
  local -a irqs=()
  mapfile -t irqs < <(comp_irqs_for_iface "$iface")
  (( ${#irqs[@]} )) || { echo "show-irq: nenhum IRQ encontrado para $iface" >&2; return 0; }
  for irq in "${irqs[@]}"; do
    printf '%s: %s (cpu %s)\n' "$irq" \
      "$(cat "/proc/irq/${irq}/smp_affinity" 2>/dev/null || echo '?')" \
      "$(cat "/proc/irq/${irq}/smp_affinity_list" 2>/dev/null || echo '?')"
  done
}

# --- coalesce adaptive ----------------------------------------------------------------
coalesce_adaptive() {
  local iface="$1" cur_rx cur_tx
  cur_rx=$({ ethtool -c "$iface" 2>/dev/null || true; } | awk '/^Adaptive RX:/ && !s++ {print $3}')
  cur_tx=$({ ethtool -c "$iface" 2>/dev/null || true; } | awk '/^Adaptive RX:/ && !s++ {print $5}')
  if [[ "$cur_rx" == "on" && "$cur_tx" == "on" ]]; then
    echo "coalesce: $iface já em adaptive RX=on TX=on"
    return 0
  fi
  # `ethtool -C` sai 80 ("no coalesce parameters changed, aborting") quando nada muda — por
  # isso o check acima, e por isso toda chamada é guardada.
  if ethtool -C "$iface" adaptive-rx on adaptive-tx on 2>/dev/null; then
    echo "coalesce: $iface adaptive RX=on TX=on"
  elif ethtool -C "$iface" adaptive-rx on 2>/dev/null; then
    echo "coalesce: $iface adaptive RX=on (driver sem adaptive-tx)"
  else
    echo "coalesce: $iface: driver não aceitou adaptive coalescing — pulando" >&2
  fi
  return 0
}

# --- offloads -------------------------------------------------------------------------
# $2 = estado do LRO: "off" em slave de bond (o kernel força off via dev_disable_lro() em
# bond_enslave; pedir "on" só produz o cosmético "[requested on]"), "on" em NIC que termina
# as conexões.
# NOTA: "lso" NÃO é nome de feature do ethtool (nem curto nem longo). Uma cadeia com "lso"
# falha INTEIRA, levando junto o lro/gro/gso que iam na mesma chamada.
offloads() {
  local iface="$1" lro="${2:-on}"
  [[ "$lro" == "on" || "$lro" == "off" ]] || { echo "offloads: 2o argumento deve ser on|off" >&2; return 1; }
  if ethtool -K "$iface" lro "$lro" tso on gro on gso on 2>/dev/null; then
    echo "offloads: $iface: lro=$lro tso=on gro=on gso=on"
  elif ethtool -K "$iface" tso on gro on gso on 2>/dev/null; then
    echo "offloads: $iface: tso=on gro=on gso=on (driver não expõe lro)" >&2
  else
    echo "offloads: $iface: ethtool -K falhou" >&2
  fi
  return 0
}

# --- ring buffer no máximo ------------------------------------------------------------
# Vive no helper (e não como `/bin/sh -c` dentro do unit) porque o parser de ExecStart do
# systemd aplica C-unescape MESMO dentro de aspas simples e expande $VAR: um awk embutido
# ali chega ao shell truncado e quebrado, o `|| true` engole o erro, e o unit reporta
# sucesso enquanto o ring nunca é aplicado. Regra: nenhum ExecStart pode conter $ ou \.
ring_max() {
  local iface="$1" rx tx
  rx=$({ ethtool -g "$iface" 2>/dev/null || true; } |
    awk '/Pre-set maximums:/{m=1;next} /Current hardware settings:/{m=0} m && $1=="RX:" && !s++ {print $2}')
  tx=$({ ethtool -g "$iface" 2>/dev/null || true; } |
    awk '/Pre-set maximums:/{m=1;next} /Current hardware settings:/{m=0} m && $1=="TX:" && !s++ {print $2}')
  if [[ ! "$rx" =~ ^[1-9][0-9]*$ || ! "$tx" =~ ^[1-9][0-9]*$ ]]; then
    echo "ring-max: $iface: ethtool -g não reportou máximos utilizáveis — pulando" >&2
    return 0
  fi
  local cur_rx cur_tx
  cur_rx=$({ ethtool -g "$iface" 2>/dev/null || true; } |
    awk '/Current hardware settings:/{c=1;next} c && $1=="RX:" && !s++ {print $2}')
  cur_tx=$({ ethtool -g "$iface" 2>/dev/null || true; } |
    awk '/Current hardware settings:/{c=1;next} c && $1=="TX:" && !s++ {print $2}')
  if [[ "$cur_rx" == "$rx" && "$cur_tx" == "$tx" ]]; then
    echo "ring-max: $iface já em RX=$rx TX=$tx (max)"
    return 0
  fi
  if ethtool -G "$iface" rx "$rx" tx "$tx" 2>/dev/null; then
    echo "ring-max: $iface: ring RX ${cur_rx:-?} -> $rx, TX ${cur_tx:-?} -> $tx"
  else
    echo "ring-max: $iface: 'ethtool -G rx $rx tx $tx' falhou" >&2
  fi
  return 0
}

pin_irq() {
  local iface="$1" cpulist="${2:-}"
  [[ -n "$cpulist" ]] || { echo "pin-irq: cpulist obrigatório (uso: pin-irq <iface> <cpulist>)" >&2; exit 1; }
  local -a cpus=() irqs=() online=()

  mapfile -t cpus < <(expand_cpulist "$cpulist")
  (( ${#cpus[@]} )) || { echo "pin-irq: cpulist '$cpulist' inválido ou vazio" >&2; exit 1; }

  mapfile -t online < <(expand_cpulist "$(cat /sys/devices/system/cpu/online 2>/dev/null || echo 0)")
  local online_set=" ${online[*]} " c
  for c in "${cpus[@]}"; do
    [[ "$online_set" == *" $c "* ]] || { echo "pin-irq: CPU $c não existe ou está offline" >&2; exit 1; }
  done

  mapfile -t irqs < <(comp_irqs_for_iface "$iface")
  (( ${#irqs[@]} )) || { echo "pin-irq: nenhum IRQ de completion encontrado para $iface" >&2; exit 1; }

  local i=0 irq cpu ok_n=0 fail_n=0
  for irq in "${irqs[@]}"; do
    cpu="${cpus[$(( i % ${#cpus[@]} ))]}"
    if echo "$cpu" > "/proc/irq/${irq}/smp_affinity_list" 2>/dev/null; then
      ok_n=$(( ok_n + 1 ))
    elif cpulist_to_mask "$cpu" > "/proc/irq/${irq}/smp_affinity" 2>/dev/null; then
      # Fallback para kernels/arquiteturas que só aceitam a máscara hex.
      ok_n=$(( ok_n + 1 ))
    else
      # IRQ managed pelo kernel (affinity read-only) ou vetor liberado no meio do caminho.
      echo "pin-irq: $iface: falhou ao pinar IRQ ${irq} -> CPU ${cpu}" >&2
      fail_n=$(( fail_n + 1 ))
    fi
    i=$(( i + 1 ))
  done
  echo "pin-irq: $iface: ${ok_n}/${#irqs[@]} IRQs pinados em [${cpulist}] (${#cpus[@]} CPUs, round-robin)"
  # Falha parcial não derruba o retorno: no boot isso abortaria os ExecStart seguintes do
  # unit (o outro slave, XPS/RPS, qdisc). O erro fica no journal via stderr acima.
  (( fail_n == 0 )) || echo "pin-irq: $iface: ${fail_n} IRQ(s) recusaram a escrita — ver acima" >&2
  return 0
}

# --- qdisc por tx queue (pacing FQ para BBR) ---------------------------------
# ethtool -L NÃO recria os qdiscs das filas. mq_init() cria um qdisc filho por tx queue
# no instante em que o mq é anexado, e só usa net.core.default_qdisc nos índices
# < real_num_tx_queues (get_default_qdisc_ops, net/sched/sch_generic.c); os índices acima
# nascem pfifo_fast. Quando o número de filas AUMENTA depois disso (ethtool -L), as filas
# recém-ativadas seguem com o pfifo_fast herdado — sem pacing FQ — e o BBR degrada
# justamente nessas filas. Correção: reanexar o qdisc raiz (mq) para regenerar os filhos
# com o default vigente.
# awk NAO pode usar `exit` aqui: sair antes do EOF fecha o pipe, o `tc` leva SIGPIPE e,
# com `set -o pipefail`, o status 141 derruba o helper inteiro dentro do `$( )`. O
# `|| true` cobre o caso de o `tc` falhar (iface removida no meio, por exemplo).
qdisc_root_kind() {
  { tc qdisc show dev "$1" 2>/dev/null || true; } |
    awk '$1=="qdisc" && $4=="root" && !seen++ {print $2}'
}
# tc lista como filhos do mq apenas as filas ATIVAS (índices < real_num_tx_queues).
qdisc_child_kinds() {
  { tc qdisc show dev "$1" 2>/dev/null || true; } |
    awk '$1=="qdisc" && $4=="parent" && $2!="clsact" && $2!="ingress"{print $2}'
}

fix_qdisc() {
  local iface="$1" want="${2:-}" root bad unsafe newroot n_bad
  command -v tc >/dev/null 2>&1 || { echo "fix-qdisc: 'tc' (iproute2) ausente — pulando" >&2; return 0; }
  [[ -n "$want" ]] || want=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  [[ -n "$want" ]] || { echo "fix-qdisc: net.core.default_qdisc vazio — pulando" >&2; return 0; }

  root=$(qdisc_root_kind "$iface")
  case "$root" in
    mq)         ;;
    # mqprio carrega num_tc/map/queues/hw; seus filhos nascem pfifo_fast por design, não a
    # partir de net.core.default_qdisc. Regenerar o root apagaria as traffic classes — e o
    # resultado ainda pareceria "OK". Fora do escopo deste script.
    mqprio)     echo "fix-qdisc: $iface root=mqprio (traffic classes configuradas) — não alterando" >&2; return 0 ;;
    "")         echo "fix-qdisc: $iface sem qdisc raiz — pulando" >&2; return 0 ;;
    noop)       echo "fix-qdisc: $iface root=noop (link down?) — pulando" >&2; return 0 ;;
    noqueue)    echo "fix-qdisc: $iface root=noqueue (device virtual, sem enfileiramento) — nada a fazer"; return 0 ;;
    "$want")    echo "fix-qdisc: $iface root=$want (device de fila única) — OK"; return 0 ;;
    pfifo_fast)
      # device de fila única que ficou com o pfifo_fast do driver: troca direto na raiz.
      if tc qdisc replace dev "$iface" root "$want" 2>/dev/null; then
        echo "fix-qdisc: $iface root pfifo_fast -> $want"
      else
        echo "fix-qdisc: $iface: falhou 'tc qdisc replace dev $iface root $want'" >&2
      fi
      return 0 ;;
    *)          echo "fix-qdisc: $iface root=$root (config customizada) — não alterando" >&2; return 0 ;;
  esac

  bad=$(qdisc_child_kinds "$iface" | grep -vx "$want" || true)
  if [[ -z "$bad" ]]; then
    echo "fix-qdisc: $iface OK — todas as tx queues ativas com $want"
    return 0
  fi
  # Só regenera se o que está nas filas for qdisc default do kernel. Shaping montado pelo
  # admin (htb/cake/tbf/netem/...) é preservado, só com aviso.
  unsafe=$(printf '%s\n' "$bad" | sort -u | grep -vxE 'pfifo_fast|pfifo|bfifo|fq|fq_codel|fq_pie|sfq|noqueue' || true)
  if [[ -n "$unsafe" ]]; then
    echo "fix-qdisc: $iface tem qdisc customizado nas filas ($(printf '%s' "$unsafe" | tr '\n' ' ')) — não alterando" >&2
    return 0
  fi
  n_bad=$(printf '%s\n' "$bad" | wc -l)
  echo "fix-qdisc: $iface: $n_bad tx queue(s) sem $want — reanexando root $root para regenerar"
  # 'tc qdisc replace root mq' vira no-op quando o mq atual já tem handle != 0 (o kernel
  # trata como change, e mq não implementa change). Del + reattach é o que regenera.
  tc qdisc del dev "$iface" root 2>/dev/null || true
  # Com o device UP, dev_activate() reanexa sozinho o default (mq + default_qdisc por fila
  # ativa). O add abaixo é fallback para os casos em que isso não acontece.
  newroot=$(qdisc_root_kind "$iface")
  case "$newroot" in
    mq|mqprio) ;;
    *) tc qdisc add dev "$iface" root mq 2>/dev/null || true ;;
  esac
  bad=$(qdisc_child_kinds "$iface" | grep -vx "$want" || true)
  if [[ -n "$bad" ]]; then
    # O mq regenera os filhos a partir de net.core.default_qdisc, não do 'want' pedido:
    # se os dois divergem, quem manda é o sysctl.
    echo "fix-qdisc: $iface: ainda há filas sem $want ($(printf '%s' "$bad" | sort -u | tr '\n' ' ')) — o mq regenera a partir de net.core.default_qdisc (=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')); ajuste o sysctl se quiser outro kind" >&2
    return 0
  fi
  echo "fix-qdisc: $iface OK — todas as tx queues ativas com $want"
}

case "$ACTION" in
  cleanup)
    require_iface
    bdf=$(iface_bdf "$IFACE") || { echo "cleanup: no PCI device for $IFACE" >&2; exit 1; }
    def=$(cat /proc/irq/default_smp_affinity 2>/dev/null || true)
    if [[ -n "$def" ]]; then
      awk -v p="mlx5_comp.*@pci:${bdf}" '$0 ~ p { sub(":", ""); print $1 }' /proc/interrupts \
        | while read -r irq; do
            echo "$def" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
          done
    fi
    for q in /sys/class/net/"$IFACE"/queues/rx-*/rps_cpus; do
      [[ -e "$q" ]] || continue
      echo 0 > "$q" 2>/dev/null || true
    done
    for q in /sys/class/net/"$IFACE"/queues/rx-*/rps_flow_cnt; do
      [[ -e "$q" ]] || continue
      echo 0 > "$q" 2>/dev/null || true
    done
    for q in /sys/class/net/"$IFACE"/queues/tx-*/xps_cpus; do
      [[ -e "$q" ]] || continue
      echo 0 > "$q" 2>/dev/null || true
    done
    ethtool -K "$IFACE" ntuple off 2>/dev/null || true
    ;;
  cleanup-global)
    sysctl -w net.core.rps_sock_flow_entries=0 >/dev/null
    ;;
  mirror-xps)
    require_iface
    for tx in /sys/class/net/"$IFACE"/queues/tx-*; do
      [[ -e "$tx/xps_cpus" ]] || continue
      q="${tx##*/tx-}"
      irq=$(irq_for_queue "$IFACE" "$q") || continue
      [[ -z "$irq" ]] && continue
      cpu=$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null) || continue
      mask=$(cpulist_to_mask "$cpu") || continue
      echo "$mask" > "$tx/xps_cpus" 2>/dev/null || true
    done
    ;;
  mirror-rps)
    require_iface
    for rx in /sys/class/net/"$IFACE"/queues/rx-*; do
      [[ -e "$rx/rps_cpus" ]] || continue
      q="${rx##*/rx-}"
      irq=$(irq_for_queue "$IFACE" "$q") || continue
      [[ -z "$irq" ]] && continue
      cpu=$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null) || continue
      mask=$(cpulist_to_mask "$cpu") || continue
      echo "$mask" > "$rx/rps_cpus" 2>/dev/null || true
    done
    ;;
  arfs)
    require_iface
    # $3 é o TOTAL global (net.core.rps_sock_flow_entries). Documentation/networking/scaling.rst
    # manda dividir por fila: rps_flow_cnt = rps_sock_flow_entries / n_rx_queues. Aplicar o
    # total em CADA fila superdimensiona a tabela por fila em n_queues vezes.
    total="${3:-32768}"
    [[ "$total" =~ ^[0-9]+$ ]] || { echo "arfs: total inválido '$total'" >&2; exit 1; }
    # ntuple pode não existir (firmware antigo). Não é fatal: --arfs é opt-in.
    ethtool -K "$IFACE" ntuple on 2>/dev/null || {
      echo "arfs: $IFACE não suporta ntuple-filters — aRFS não habilitado" >&2; exit 0; }
    nq=0
    for rx in /sys/class/net/"$IFACE"/queues/rx-*; do
      [[ -e "$rx/rps_flow_cnt" ]] || continue
      nq=$(( nq + 1 ))
    done
    (( nq > 0 )) || { echo "arfs: $IFACE sem rx queues — nada a fazer" >&2; exit 0; }
    per=$(( total / nq )); (( per > 0 )) || per=1
    for rx in /sys/class/net/"$IFACE"/queues/rx-*; do
      [[ -e "$rx/rps_flow_cnt" ]] || continue
      echo "$per" > "$rx/rps_flow_cnt" 2>/dev/null || true
    done
    echo "arfs: $IFACE: rps_flow_cnt=$per em $nq filas (total=$total)"
    ;;
  arfs-global)
    # $2 aqui é o número de entries (não iface) — a variável "IFACE" carrega valor
    # numérico para este subcomando (semântica posicional, não nominal).
    val="${IFACE:-32768}"
    [[ "$val" =~ ^[0-9]+$ ]] || { echo "arfs-global: entries inválido '$val'" >&2; exit 1; }
    sysctl -w net.core.rps_sock_flow_entries="$val" >/dev/null
    ;;
  show-irq)
    require_iface
    show_irq_aff "$IFACE"
    ;;
  coalesce)
    require_iface
    coalesce_adaptive "$IFACE"
    ;;
  offloads)
    require_iface
    offloads "$IFACE" "${3:-on}"
    ;;
  ring-max)
    require_iface
    ring_max "$IFACE"
    ;;
  pin-irq)
    require_iface
    pin_irq "$IFACE" "${3:-}"
    ;;
  fix-qdisc)
    require_iface
    fix_qdisc "$IFACE" "${3:-}"
    ;;
  *)
    echo "Usage: $0 {cleanup|cleanup-global|mirror-xps|mirror-rps|arfs|arfs-global|ring-max|coalesce|offloads|pin-irq|show-irq|fix-qdisc} [iface_or_value] [total|cpulist|qdisc|on|off]" >&2
    exit 1
    ;;
esac
HELPER_EOF
}

deploy_helper() {
  log "deployando helper em ${HELPER_PATH} (v${HELPER_VERSION})"
  if (( DRY_RUN )); then
    printf '\033[1;90m    DRY: instalar %s (helper v%s)\033[0m\n' "$HELPER_PATH" "$HELPER_VERSION" >&2
    return
  fi

  local tmp
  tmp=$(mktemp) || { err "mktemp falhou"; return 1; }
  emit_helper > "$tmp"

  # Comparação por CONTEÚDO, não pela tag de versão. A tag depende de disciplina humana e
  # não detecta dois cenários reais: (a) drift — mesma tag, corpo diferente entre os scripts
  # que compartilham o helper; (b) downgrade silencioso — rodar um script mais antigo depois
  # de um bump rebaixa o helper que a unit do outro usa no boot.
  if [[ -x "${HELPER_PATH}" ]] && cmp -s "$tmp" "${HELPER_PATH}"; then
    ok "helper já idêntico em ${HELPER_PATH} (v${HELPER_VERSION}) — reusando"
    rm -f "$tmp"
    return
  fi
  [[ -e "${HELPER_PATH}" ]] && warn "helper em ${HELPER_PATH} difere do embutido — sobrescrevendo"
  install -m 0755 "$tmp" "${HELPER_PATH}" || { err "falha ao instalar ${HELPER_PATH}"; rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  ok "helper deployado: ${HELPER_PATH} (v${HELPER_VERSION}, sha256 $(sha256sum "${HELPER_PATH}" | cut -c1-12))"
}

# ---------------- systemd ----------------

# Gate contra a classe de bug que manteve o ring buffer como no-op por meses: o parser de
# ExecStart do systemd aplica C-unescape MESMO dentro de aspas simples e expande $VAR, então
# qualquer awk/shell embutido chega mutilado ao processo — e um `|| true` no fim faz o unit
# reportar sucesso. Invariante: nenhum ExecStart carrega '$', backslash ou /bin/sh.
assert_unit_clean() {
  local bad
  bad=$(grep -n '^ExecStart=' "${SYSTEMD_UNIT}" 2>/dev/null | grep -E '\$|\\|/bin/sh' || true)
  if [[ -n "$bad" ]]; then
    err "unit gerada viola o invariante (ExecStart com \$, backslash ou /bin/sh):"
    printf '%s\n' "$bad" | sed 's/^/    /' >&2
    err "  toda lógica precisa morar no helper — corrija write_systemd_unit()"
    return 1
  fi
  if command -v systemd-analyze >/dev/null 2>&1; then
    local unit_base warns
    unit_base=$(basename "${SYSTEMD_UNIT}")
    # systemd-analyze também carrega as dependências: filtrar só o que é da nossa unit.
    warns=$(systemd-analyze verify "${SYSTEMD_UNIT}" 2>&1 | grep -F "${unit_base}" || true)
    [[ -z "$warns" ]] || {
      warn "systemd-analyze verify reclamou da unit:"
      printf '%s\n' "$warns" | sed 's/^/    /' >&2
    }
  fi
  ok "unit validada (ExecStart sem \$ / backslash / sh -c)"
  return 0
}

# Nome da unit .device correspondente a uma interface, para ordenação de boot.
# Sem systemd-escape disponível, cai no fallback textual (o mapeamento é direto para nomes
# de interface válidos, que não contêm os caracteres que exigiriam escaping).
netdev_unit() {
  if command -v systemd-escape >/dev/null 2>&1; then
    systemd-escape --path --suffix=device "/sys/subsystem/net/devices/$1"
  else
    printf 'sys-subsystem-net-devices-%s.device\n' "$1"
  fi
}

write_systemd_unit() {
  (( PERSIST )) || { warn "persistência systemd desabilitada (--no-systemd)"; return; }

  log "criando unit ${SYSTEMD_UNIT}"
  if (( DRY_RUN )); then
    printf '\033[1;90m    DRY: cat > %s\033[0m\n' "$SYSTEMD_UNIT" >&2
    return
  fi

  local ethtool_bin
  ethtool_bin=$(command -v ethtool)
  [[ -n "$ethtool_bin" ]] || { err "ethtool não encontrado no PATH; abortando unit"; return 1; }
  [[ -x "${HELPER_PATH}" ]] || { err "helper ${HELPER_PATH} ausente/non-exec; abortando unit"; return 1; }

  # Backup da unit anterior antes de sobrescrever (permite diff pós-mudança).
  if [[ -f "${SYSTEMD_UNIT}" ]]; then
    mkdir -p "${BACKUP_DIR}"
    cp -a "${SYSTEMD_UNIT}" "${BACKUP_DIR}/$(basename "${SYSTEMD_UNIT}").pre-${STAMP}" 2>/dev/null || true
  fi

  # Tag de features no Description e ExecStart condicionais por flag.
  local features="IRQ"
  (( APPLY_RING_MAX )) && features="${features}+RING"
  (( APPLY_COALESCE )) && features="${features}+COAL"
  (( APPLY_OFFLOADS )) && features="${features}+OFF"
  (( APPLY_QDISC ))    && features="${features}+QDISC"
  (( APPLY_XPS ))      && features="${features}+XPS"
  (( APPLY_RPS ))      && features="${features}+RPS"
  (( APPLY_ARFS ))     && features="${features}+aRFS"

  # Toda a lógica vive no helper — nenhum ExecStart carrega '$', backslash ou /bin/sh -c.
  # Motivo: o parser de ExecStart do systemd aplica C-unescape MESMO dentro de aspas simples
  # e expande $VAR, então um awk embutido chega truncado ao shell. Foi exatamente assim que a
  # linha de ring buffer virou no-op silencioso por meses. Ver o gate em validate().
  #
  # Prefixo '-' = "ignore falha e siga". Aplicado a tudo que é preparação: se uma etapa falhar
  # em boot, as seguintes ainda rodam. A ÚNICA sem '-' é pin-irq: ela é o objetivo do unit, e
  # xps/rps/arfs (que espelham a afinidade dela) não devem rodar sobre um pinning que falhou.
  local ring_lines="" coalesce_lines="" offload_lines=""
  if (( APPLY_RING_MAX )); then
    ring_lines=$'\n# Ring buffer no máximo\nExecStart=-'"${HELPER_PATH}"$' ring-max '"${SLAVE0}"$'\nExecStart=-'"${HELPER_PATH}"$' ring-max '"${SLAVE1}"
  fi
  if (( APPLY_COALESCE )); then
    coalesce_lines=$'\n# Coalesce adaptive\nExecStart=-'"${HELPER_PATH}"$' coalesce '"${SLAVE0}"$'\nExecStart=-'"${HELPER_PATH}"$' coalesce '"${SLAVE1}"
  fi
  if (( APPLY_OFFLOADS )); then
    offload_lines=$'\n# Offloads tso/gro/gso=on, lro=off (bond force)\nExecStart=-'"${HELPER_PATH}"$' offloads '"${SLAVE0}"$' off\nExecStart=-'"${HELPER_PATH}"$' offloads '"${SLAVE1}"$' off'
  fi

  # Regeneração do qdisc: precisa rodar DEPOIS do último ethtool -L do unit.
  local qdisc_lines=""
  if (( APPLY_QDISC )); then
    qdisc_lines=$'\n# Qdisc das tx queues: ethtool -L deixa filas novas em pfifo_fast (sem pacing FQ)\nExecStart=-'"${HELPER_PATH}"$' fix-qdisc '"${SLAVE0}"$'\nExecStart=-'"${HELPER_PATH}"$' fix-qdisc '"${SLAVE1}"
  fi

  local xps_lines="" rps_lines="" arfs_lines=""
  if (( APPLY_XPS )); then
    xps_lines=$'\n# XPS per-queue espelhando IRQ (--xps)\nExecStart=-'"${HELPER_PATH}"$' mirror-xps '"${SLAVE0}"$'\nExecStart=-'"${HELPER_PATH}"$' mirror-xps '"${SLAVE1}"
  fi
  if (( APPLY_RPS )); then
    rps_lines=$'\n# RPS per-queue espelhando IRQ (--rps)\nExecStart=-'"${HELPER_PATH}"$' mirror-rps '"${SLAVE0}"$'\nExecStart=-'"${HELPER_PATH}"$' mirror-rps '"${SLAVE1}"
  fi
  if (( APPLY_ARFS )); then
    arfs_lines=$'\n# aRFS global + per-iface (--arfs)\nExecStart=-'"${HELPER_PATH}"$' arfs-global '"${ARFS_FLOW_ENTRIES}"$'\nExecStart=-'"${HELPER_PATH}"$' arfs '"${SLAVE0}"$' '"${ARFS_FLOW_ENTRIES}"$'\nExecStart=-'"${HELPER_PATH}"$' arfs '"${SLAVE1}"$' '"${ARFS_FLOW_ENTRIES}"
  fi

  local dev0 dev1
  dev0=$(netdev_unit "$SLAVE0"); dev1=$(netdev_unit "$SLAVE1")

  cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=Mellanox NIC tuning: ${features} pin (${SLAVE0}=${SLAVE0_CPUS}/q=${QUEUES_S0}, ${SLAVE1}=${SLAVE1_CPUS}/q=${QUEUES_S1})
After=network-online.target
Wants=network-online.target
# As netdevs precisam existir antes de ethtool -L / pin-irq. network-online.target sozinho
# não garante isso quando quem satisfaz o target é o ifupdown e quem enslava é outro serviço.
After=${dev0} ${dev1}
# irqbalance repina IRQs; se ele voltar (reinstalação, dependência), não pode correr junto.
Conflicts=irqbalance.service
After=irqbalance.service
ConditionPathExists=/sys/class/net/${SLAVE0}
ConditionPathExists=/sys/class/net/${SLAVE1}
# Assert (não Condition): helper ausente deve virar unit 'failed' e visível, não um skip mudo.
AssertPathExists=${HELPER_PATH}

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# 1) CLEANUP: IRQ smp_affinity -> default, rps/xps/rps_flow_cnt = 0, ntuple off
ExecStart=-${HELPER_PATH} cleanup ${SLAVE0}
ExecStart=-${HELPER_PATH} cleanup ${SLAVE1}
# 2) combined no target por slave (renumera IRQs; precede o pinning)
ExecStart=-${ethtool_bin} -L ${SLAVE0} combined ${QUEUES_S0}
ExecStart=/bin/sleep 2
ExecStart=-${ethtool_bin} -L ${SLAVE1} combined ${QUEUES_S1}
ExecStart=/bin/sleep 2${ring_lines}${coalesce_lines}${offload_lines}${qdisc_lines}
# 3) Pinning das completion IRQs — sem '-': é o objetivo do unit, e o que vem depois
#    (xps/rps) espelha a afinidade que ele define.
ExecStart=${HELPER_PATH} pin-irq ${SLAVE0} ${SLAVE0_CPUS}
ExecStart=${HELPER_PATH} pin-irq ${SLAVE1} ${SLAVE1_CPUS}${xps_lines}${rps_lines}${arfs_lines}

[Install]
WantedBy=multi-user.target
EOF

  assert_unit_clean || return 1

  # Apenas `enable` (sem --now): o estado já foi aplicado em runtime pelo main(); o unit só
  # serve para re-aplicar no próximo boot. Evita double-apply (hiccup extra no LACP).
  systemctl daemon-reload
  systemctl enable mlx-irq-pin.service
  ok "unit armada para boot: $(systemctl is-enabled mlx-irq-pin.service)"
}

# ---------------- rollback ----------------

do_rollback() {
  log "rollback"
  # `systemctl list-unit-files X` retorna 0 mesmo se X não existe; usar `cat` em vez.
  # `|| true` no disable/enable evita abort em set -e se a unit estiver em estado raro.
  if [[ -f "${SYSTEMD_UNIT}" ]] || systemctl cat mlx-irq-pin.service &>/dev/null; then
    run "systemctl disable --now mlx-irq-pin.service || true"
    run "rm -f ${SYSTEMD_UNIT}"
    run "systemctl daemon-reload"
  fi
  if systemctl cat irqbalance.service &>/dev/null; then
    run "systemctl enable --now irqbalance || true"
    ok "irqbalance reativado"
  fi
  log "restaurando combined queues para o máximo do device em cada slave"
  for s in "$SLAVE0" "$SLAVE1"; do
    local maxq
    maxq=$(ethtool_combined_max "$s")
    if [[ -n "$maxq" ]]; then
      run "ethtool -L $s combined ${maxq}"
      run "sleep 2"
    fi
  done
  # Limpa RPS/XPS/aRFS/IRQ smp_affinity usando o helper (se ainda presente).
  if [[ -x "${HELPER_PATH}" ]]; then
    log "rollback: limpando RPS/XPS/aRFS via helper"
    run "${HELPER_PATH} cleanup ${SLAVE0}"
    run "${HELPER_PATH} cleanup ${SLAVE1}"
    run "${HELPER_PATH} cleanup-global"
    # Voltar as filas ao máximo (acima) reexpõe filas com pfifo_fast — regenerar antes de
    # remover o helper devolve o net.core.default_qdisc em todas elas.
    if (( APPLY_QDISC )); then
      run "${HELPER_PATH} fix-qdisc ${SLAVE0}"
      run "${HELPER_PATH} fix-qdisc ${SLAVE1}"
    fi
    # O helper é COMPARTILHADO com mellanox-tune-single.sh, cuja unit tem
    # AssertPathExists nele. Removê-lo às cegas faria aquela unit falhar no boot.
    # A unit deste script já foi removida acima, então quem sobrar é consumidor legítimo.
    if grep -rlsF -- "${HELPER_PATH}" /etc/systemd/system/ >/dev/null 2>&1; then
      warn "helper ${HELPER_PATH} ainda é referenciado por outra unit — mantendo"
    else
      run "rm -f ${HELPER_PATH}"
      ok "helper removido"
    fi
  else
    warn "helper ausente — limpe manualmente RPS/XPS/aRFS:"
    warn "  for q in /sys/class/net/${SLAVE0:-<slave0>}/queues/{rx,tx}-*/{rps,xps}_cpus; do echo 0 > \$q 2>/dev/null; done"
    warn "  ethtool -K ${SLAVE0:-<slave0>} ntuple off; ethtool -K ${SLAVE1:-<slave1>} ntuple off"
    warn "  sysctl -w net.core.rps_sock_flow_entries=0"
  fi
  echo
  warn "o rollback NÃO reverte (por design, são estados benignos):"
  warn "  - ring size continua no máximo; coalesce continua adaptive; offloads não revertidos"
  warn "  - combined foi ao MÁXIMO do device (não ao valor anterior ao primeiro run)"
  warn "  - smp_affinity dos IRQs voltou ao /proc/irq/default_smp_affinity, não ao valor original"
  ok "rollback aplicado"
}

# ---------------- validação ----------------

iface_pci_bdf() {
  local target
  target=$(readlink -f "/sys/class/net/$1/device" 2>/dev/null) || return 1
  [[ -n "$target" ]] || return 1
  basename "$target"
}

# `systemctl is-active/is-enabled` saem 0 só no estado "ativo/enabled", mas o stdout
# sempre carrega a string real (inactive, failed, disabled, masked, ...). Não use `|| echo n/a` —
# isso anexa "n/a" depois da string. Use `2>/dev/null; :` ou pipe `head -1`.
# Leitura do qdisc para o relatório de validação. Mesma precaução do helper: awk NUNCA
# usa `exit` num pipe — sair antes do EOF mata o `tc` com SIGPIPE e, com `set -o pipefail`,
# o status 141 derrubaria o script dentro do `$( )`.
qdisc_root_kind_v() {
  { tc qdisc show dev "$1" 2>/dev/null || true; } |
    awk '$1=="qdisc" && $4=="root" && !seen++ {print $2}'
}
# Histograma "N×kind" dos qdiscs das tx queues ativas (filhos do mq).
qdisc_hist_v() {
  { tc qdisc show dev "$1" 2>/dev/null || true; } |
    awk '$1=="qdisc" && $4=="parent" && $2!="clsact" && $2!="ingress"{print $2}' |
    sort | uniq -c | awk '{printf "%s×%s ", $1, $2} END{if (NR==0) printf "—"}'
}

sys_state() {
  local cmd="$1" name="$2"
  systemctl "$cmd" "$name" 2>/dev/null | head -1
  return 0
}

# Relatório de afinidade que CONFERE: imprime o nome do IRQ (distingue completion de
# controle), e fecha com um veredito "N/M dentro do cpulist esperado". Sem o veredito, a
# primeira linha do relatório era sempre o mlx5_async com CPUs 0-47 sob um cabeçalho
# "esperado ⊆ 0-11,24-35" — parecia erro e não era.
report_affinity() {
  local iface="$1" want="$2" bdf line irq name aff total=0 inside=0
  bdf=$(iface_pci_bdf "$iface") || bdf="?"
  local -a want_cpus=()
  [[ -n "$want" ]] && mapfile -t want_cpus < <(printf '%s' "$want" | tr ',' '\n' | while read -r tk; do
      [[ -n "$tk" ]] || continue
      if [[ "$tk" == *-* ]]; then seq "${tk%%-*}" "${tk##*-}"; else printf '%s\n' "$tk"; fi
    done)
  local want_set=" ${want_cpus[*]} "
  echo "── afinidade efetiva ${iface} (PCI ${bdf}, esperado ⊆ ${want:-?}) ──"
  while read -r line; do
    [[ -n "$line" ]] || continue
    irq="${line%% *}"; name="${line#* }"
    aff=$(cat "/proc/irq/${irq}/smp_affinity_list" 2>/dev/null) || aff="?"
    if [[ "$name" == *comp* || "$name" == "${iface}-"* ]]; then
      total=$(( total + 1 ))
      # "dentro" = todas as CPUs da afinidade pertencem ao cpulist pedido.
      local c ok_all=1
      for c in $(printf '%s' "$aff" | tr ',' ' '); do
        if [[ "$c" == *-* ]]; then ok_all=0; break; fi
        [[ "$want_set" == *" $c "* ]] || { ok_all=0; break; }
      done
      (( ok_all )) && inside=$(( inside + 1 ))
      printf "  IRQ %-5s %-28s -> CPUs %s%s\n" "$irq" "$name" "$aff" "$( (( ok_all )) || printf '   <-- FORA do esperado' )"
    else
      printf "  IRQ %-5s %-28s -> CPUs %s   (controle, não pinado por design)\n" "$irq" "$name" "$aff"
    fi
  done < <(grep -F "@pci:${bdf}" /proc/interrupts 2>/dev/null | awk '{ irq=$1; sub(":","",irq); print irq, $NF }')
  if (( ROLLBACK )); then
    printf "  veredito: %s/%s IRQs de completion dentro de [%s] (pós-rollback: espera-se 0 ou poucos)\n" "$inside" "$total" "${want:-?}"
  elif (( total > 0 && inside == total )); then
    printf "  veredito: %s/%s IRQs de completion dentro de [%s]  OK\n" "$inside" "$total" "$want"
  else
    printf "  veredito: %s/%s IRQs de completion dentro de [%s]  <-- DIVERGENTE\n" "$inside" "$total" "${want:-?}"
  fi
}

validate() {
  echo
  if (( ROLLBACK )); then
    log "VALIDAÇÃO (pós-rollback: afinidade volta a default_smp_affinity e queues ao máximo)"
  else
    log "VALIDAÇÃO"
  fi

  report_affinity "$SLAVE0" "$SLAVE0_CPUS"
  report_affinity "$SLAVE1" "$SLAVE1_CPUS"

  echo "── helper / scripts ──"
  printf "  helper: %s (exec=%s)\n" "$HELPER_PATH" "$([[ -x "$HELPER_PATH" ]] && echo yes || echo no)"

  echo "── combined queues por slave ──"
  local q e s
  for s in "$SLAVE0" "$SLAVE1"; do
    q=$(ethtool_combined_current "$s")
    if (( ROLLBACK )); then e=$(ethtool_combined_max "$s"); else
      [[ "$s" == "$SLAVE0" ]] && e="$QUEUES_S0" || e="$QUEUES_S1"; fi
    printf "  %s: Combined=%s (esperado %s)%s\n" "$s" "${q:-?}" "${e:-?}" \
      "$( [[ "$q" == "$e" ]] || printf '   <-- DIVERGENTE' )"
  done

  echo "── ring buffer vs máximo do device ──"
  local rr tr rmx tmx
  for s in "$SLAVE0" "$SLAVE1"; do
    rr=$(ethtool_ring "$s" current RX); tr=$(ethtool_ring "$s" current TX)
    rmx=$(ethtool_ring "$s" max RX);     tmx=$(ethtool_ring "$s" max TX)
    printf "  %s: RX=%s/%s TX=%s/%s%s\n" "$s" "${rr:-?}" "${rmx:-?}" "${tr:-?}" "${tmx:-?}" \
      "$( { (( APPLY_RING_MAX )) && ! (( ROLLBACK )) && [[ "$rr" != "$rmx" || "$tr" != "$tmx" ]]; } \
           && printf '   <-- ABAIXO DO MÁXIMO (a unit reaplicou no boot?)' )"
  done

  echo "── irqbalance ──"
  printf "  active=%s enabled=%s\n" \
    "$(sys_state is-active irqbalance)" \
    "$(sys_state is-enabled irqbalance)"

  echo "── unit mlx-irq-pin ──"
  printf "  active=%s enabled=%s\n" \
    "$(sys_state is-active mlx-irq-pin.service)" \
    "$(sys_state is-enabled mlx-irq-pin.service)"

  # XPS: o driver mlx5 auto-popula xps_cpus ao recriar as queues. Sem --xps o valor
  # esperado NÃO é zero — é o default do driver. Rotular "XPS=0" contradizia o README.
  echo "── RPS / XPS / aRFS por slave (RPS=$( (( APPLY_RPS )) && echo pedido || echo off), XPS=$( (( APPLY_XPS )) && echo pedido || echo 'auto do driver'), aRFS=$( (( APPLY_ARFS )) && echo pedido || echo off)) ──"
  for s in "$SLAVE0" "$SLAVE1"; do
    local nz_rps nz_xps xps_sample rps_sample arfs_state arfs_flow
    # `; true` no fim do loop garante que o subshell retorne 0 — sem isso, se a última
    # iter tem `[[ -n "$v" ]] && echo nz` em falso, pipefail propaga 1 e `set -e` aborta.
    nz_rps=$({ for q in "/sys/class/net/$s/queues/"rx-*/rps_cpus; do [[ -e "$q" ]] || continue; v=$(tr -d ',0' < "$q" 2>/dev/null); [[ -n "$v" ]] && echo nz; done; true; } | wc -l)
    nz_xps=$({ for q in "/sys/class/net/$s/queues/"tx-*/xps_cpus; do [[ -e "$q" ]] || continue; v=$(tr -d ',0' < "$q" 2>/dev/null); [[ -n "$v" ]] && echo nz; done; true; } | wc -l)
    xps_sample=$(cat "/sys/class/net/$s/queues/tx-0/xps_cpus" 2>/dev/null)
    rps_sample=$(cat "/sys/class/net/$s/queues/rx-0/rps_cpus" 2>/dev/null)
    arfs_state=$(ethtool -k "$s" 2>/dev/null | awk -F: '/ntuple-filters:/{gsub(/^ +| +$/,"",$2); print $2}')
    arfs_flow=$(cat "/sys/class/net/$s/queues/rx-0/rps_flow_cnt" 2>/dev/null)
    # Conta queues via glob em subshell (nullglob isolado para não vazar pro caller).
    local n_rxq n_txq
    n_rxq=$(shopt -s nullglob; a=("/sys/class/net/$s/queues/"rx-*); echo "${#a[@]}")
    n_txq=$(shopt -s nullglob; a=("/sys/class/net/$s/queues/"tx-*); echo "${#a[@]}")
    printf "  %s: rps_cpus nz=%s/%s (sample rx-0=%s) | xps_cpus nz=%s/%s (sample tx-0=%s) | ntuple=%s rps_flow_cnt[rx-0]=%s\n" \
      "$s" "$nz_rps" "$n_rxq" "$rps_sample" \
      "$nz_xps" "$n_txq" "$xps_sample" \
      "${arfs_state:-?}" "${arfs_flow:-?}"
  done
  printf "  global: net.core.rps_sock_flow_entries=%s (esperado %s)\n" \
    "$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)" \
    "$((APPLY_ARFS ? ARFS_FLOW_ENTRIES : 0))"

  echo "── coalesce adaptive ──"
  for s in "$SLAVE0" "$SLAVE1"; do
    # ethtool -c imprime "Adaptive RX: on  TX: on" em uma única linha.
    ethtool -c "$s" 2>/dev/null | awk -v iface="$s" '/^Adaptive RX:/ {
      printf "  %s: RX=%s TX=%s\n", iface, $3, $5
    }' || echo "  $s: (n/a)"
  done

  echo "── offloads ──"
  for s in "$SLAVE0" "$SLAVE1"; do
    echo "  ${s}:"
    ethtool -k "$s" 2>/dev/null | awk -F: '
      /^(tcp-segmentation-offload|generic-receive-offload|generic-segmentation-offload|large-receive-offload):/ {
        gsub(/^ +| +$/,"",$2); printf "    %-30s %s\n", $1, $2
      }' || echo "    (n/a)"
  done

  echo "── qdisc por tx queue (pacing p/ BBR) ──"
  printf "  net.core.default_qdisc=%s | net.ipv4.tcp_congestion_control=%s\n" \
    "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')" \
    "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  if command -v tc >/dev/null; then
    for s in "$BOND" "$SLAVE0" "$SLAVE1"; do
      printf "  %-18s root=%-10s filas: %s\n" "$s" \
        "$(qdisc_root_kind_v "$s")" "$(qdisc_hist_v "$s")"
    done
  else
    echo "  (tc ausente)"
  fi

  echo "── drops nas NICs (devem ficar estáveis após pinning) ──"
  for s in "$SLAVE0" "$SLAVE1"; do
    echo "  $s:"
    ethtool -S "$s" 2>/dev/null | grep -E "rx_discards|rx_missed|rx_buff_alloc_err" | sed 's/^/    /' || true
  done
  ok "validação impressa acima"
}

# ---------------- main ----------------

main() {
  # Emite o helper embutido e sai. Serve para auditar a invariante "bond e single embutem o
  # MESMO helper" sem depender de sed frágil sobre o heredoc:
  #   diff <(./mellanox-tune-bond.sh --print-helper) <(./mellanox-tune-single.sh --print-helper)
  if (( PRINT_HELPER )); then emit_helper; exit 0; fi
  if (( PRINT_TOPOLOGY )); then print_topology; exit 0; fi

  log "mellanox-tune-bond.sh — Bloco A do plano de pinning"
  (( DRY_RUN )) && warn "DRY-RUN ATIVO: nada será escrito"
  log "flags: XPS=$((APPLY_XPS)) RPS=$((APPLY_RPS)) aRFS=$((APPLY_ARFS))"

  preflight

  if (( ROLLBACK )); then
    # Flags de apply não têm efeito no rollback; avisar em vez de fingir que foram aplicadas.
    if (( APPLY_XPS || APPLY_RPS || ${APPLY_ARFS:-0} )) || [[ -n "${QUEUES:-}" ]]; then
      warn "--rollback ignora --xps/--rps/--arfs/--queues"
    fi
    do_rollback
    validate
    exit 0
  fi

  deploy_helper
  backup_state
  stop_irqbalance
  set_queues_to_max
  cleanup_existing_state
  apply_queue_count
  apply_ring_max
  apply_coalesce_adaptive
  apply_offloads
  apply_qdisc
  apply_pinning
  (( APPLY_XPS ))  && apply_xps_per_irq
  (( APPLY_RPS ))  && apply_rps_per_irq
  (( APPLY_ARFS )) && apply_arfs_all
  write_systemd_unit
  validate

  echo
  ok "Bloco A aplicado (ou simulado, se --dry-run)."
  echo "  Próxima ação sugerida: observar 1–2h"
  echo "    watch -d 'grep mlx5.*enp /proc/interrupts | head'"
  echo "    ethtool -S ${SLAVE0} | grep -E 'rx_discards|rx_missed'"
  echo "    ethtool -S ${SLAVE1} | grep -E 'rx_discards|rx_missed'"
  echo "  Rollback:  $0 --rollback"
}

main "$@"
