#!/usr/bin/env bash
# mellanox-tune-single.sh — Variante single-NIC do Bloco A.
# Usa TODAS as CPUs online (sem split) numa única NIC Mellanox (sem bond).
# Referência: /root/mellanox_tunning/xui-lb-pinning-plan.md
#
# Diferenças vs. mellanox-tune-bond.sh:
#   - SEM bond: opera em UMA NIC direto (--nic <name>, obrigatório).
#   - SEM split de CPUs: máscara = todas as CPUs online (ou filtro NUMA-local da NIC).
#   - Queue count = min(nproc-elegíveis, max combined da NIC); --queues N para override.
#   - 1 só ExecStart de cleanup/pin/etc no unit (sem "slave0 + slave1").
#   - Unit: mlx-irq-pin-single.service (nome distinto pra não colidir com a bond-version).
#
# Uso:
#   ./mellanox-tune-single.sh --nic eth0            # IRQ pin + ring/coalesce/offloads (defaults on); CPUs/queues auto
#   ./mellanox-tune-single.sh --nic eth0 --queues 24
#   ./mellanox-tune-single.sh --nic eth0 --cpus '0-47'
#   ./mellanox-tune-single.sh --nic eth0 --no-numa-filter   # CPUs online globais (ignora NUMA da NIC)
#   ./mellanox-tune-single.sh --nic eth0 --xps              # + XPS espelhando IRQ
#   ./mellanox-tune-single.sh --nic eth0 --rps              # + RPS espelhando IRQ
#   ./mellanox-tune-single.sh --nic eth0 --arfs             # + aRFS (ntuple on + rps_flow_cnt)
#   ./mellanox-tune-single.sh --nic eth0 --no-ring-max      # pula ethtool -G rx/tx max
#   ./mellanox-tune-single.sh --nic eth0 --no-coalesce      # pula ethtool -C adaptive-rx/tx on
#   ./mellanox-tune-single.sh --nic eth0 --no-offloads      # pula ethtool -K lso/gro/gso on
#   ./mellanox-tune-single.sh --nic eth0 --no-qdisc         # pula regeneração do qdisc das tx queues
#   ./mellanox-tune-single.sh --nic eth0 --xps --rps --arfs
#   ./mellanox-tune-single.sh --nic eth0 --dry-run          # simula
#   ./mellanox-tune-single.sh --nic eth0 --no-systemd       # runtime only, sem persistir
#   ./mellanox-tune-single.sh --nic eth0 --rollback         # reverte tudo
#
# Fluxo (idempotente, numa única NIC):
#   1. ethtool -L combined=MAX  → expõe todas as filas pré-existentes
#   2. CLEANUP TOTAL via helper: IRQ smp_affinity → default, rps/xps/rps_flow_cnt=0, ntuple off
#   3. ethtool -L combined=<target>  → reduz para o calculado
#   4. ethtool -G iface rx <ring_max> tx <ring_max>   → ring buffer no máximo (default ON)
#   5. ethtool -C iface adaptive-rx on adaptive-tx on → coalesce dinâmico (default ON)
#   6. ethtool -K iface lso on gro on gso on          → offloads (default ON, fallback p/ 'tso')
#   7. tc qdisc: regenera o qdisc de cada tx queue (default ON) — ethtool -L deixa as
#      filas recém-ativadas com pfifo_fast, sem pacing FQ, degradando BBR nelas
#   8. IRQ affinity round-robin nativo (helper `pin-irq`) com TODAS as CPUs do range
#   9. Condicionais (--xps/--rps/--arfs)
#  10. Systemd unit mlx-irq-pin-single.service baked com o mesmo flag-set
#
# Auto-detect de CPUs (sem --cpus):
#   1. cpu list online (/sys/devices/system/cpu/online).
#   2. Se NIC tem numa_node>=0 e existe /sys/devices/system/node/nodeN/cpulist: intersecção.
#      Desabilite com --no-numa-filter.
#
# Filosofia: usa o host inteiro para uma NIC (full-CPU model). Para servidor com 1 link
# único (não bond) e MUITOS CCXs/cores, espalhar IRQ em todos garante throughput máximo
# sem cross-NIC concerns. Co-location ainda é preservada porque IRQ→app fica no mesmo CCX
# por causa do scheduler de Linux (não anti-pinning, sem proibições explícitas).
#
# IRQ pinning: implementação NATIVA no helper (subcomando `pin-irq`), sem clone do
# repositório Mellanox/mlnx-tools. A lógica de distribuição é a mesma do
# set_irq_affinity_cpulist.sh upstream (round-robin: IRQ i -> cpus[i % n_cpus]),
# reimplementada a partir dele + common_irq_affinity.sh.
#
# Helper auxiliar: /usr/local/sbin/xui-lb-mlx-helper.sh (mesmo da bond-version, compartilhado).
#
# Requer: root, NIC Mellanox (mlx5_core), ethtool, tc (iproute2), python3, systemd.

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
SYSTEMD_UNIT="/etc/systemd/system/mlx-irq-pin-single.service"
HELPER_PATH="/usr/local/sbin/xui-lb-mlx-helper.sh"
ARFS_FLOW_ENTRIES=32768
ARFS_PER_QUEUE_FLOW_CNT=32768

IFACE=""          # obrigatório via --nic
CPUS=""           # vazio = auto-detect (online ∩ NUMA-local da NIC)
QUEUES=""         # vazio = auto (min(|CPUs|, max-combined))
NUMA_FILTER=1     # 1 = filtra por NUMA da NIC; 0 = ignora (CPUs online globais)
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

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"   >&2; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"   >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"   >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*"   >&2; }

run() {
  if (( DRY_RUN )); then
    printf '\033[1;90m    DRY: %s\033[0m\n' "$*" >&2
  else
    eval "$@"
  fi
}

usage() { sed -n '/^#/!q; 2,$p' "$0"; }

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
    --nic)                  need_arg "$1" "${2-}"; IFACE="$2"; shift ;;
    --cpus)                 need_arg "$1" "${2-}"; CPUS="$2"; shift ;;
    --queues)               need_arg "$1" "${2-}"; QUEUES="$2"; shift ;;
    --no-numa-filter)       NUMA_FILTER=0 ;;
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

(( PRINT_HELPER )) || (( PRINT_TOPOLOGY )) || [[ -n "$IFACE" ]] || { err "--nic <nome> é obrigatório (ex.: --nic eth0)"; usage; exit 1; }

# --print-helper é só leitura: dispensa root. O dispatch em si acontece no início de
# main(), depois que emit_helper() já foi definida.
(( PRINT_HELPER )) || (( PRINT_TOPOLOGY )) || (( EUID == 0 )) || { err "rode como root."; exit 1; }

# Normalização/validação antes de QUALQUER uso (inclusive em --dry-run).
CPUS=$(normalize_cpulist --cpus "$CPUS")
[[ -z "$QUEUES" || "$QUEUES" =~ ^[1-9][0-9]*$ ]] || { err "--queues '${QUEUES}' não é inteiro positivo"; exit 1; }

# ---------------- máscara ----------------

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

# ---------------- auto-detect cpus ----------------

# Emite, em JSON, a topologia detectada + a lista de CPUs escolhida para a NIC.
# Consumido por preflight() e por --print-topology.
topology_json() {
  python3 - "$IFACE" "$NUMA_FILTER" <<'PY'
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

iface = sys.argv[1]
numa_filter = sys.argv[2] == "1"
t = detect_topology()
online = _cpus_in(t["online"])
note = ""
numa = -1

if not online:
    print(json.dumps({"cpus": "", "numa": -1,
                      "note": "nenhuma CPU online detectada", "topology": t}))
    sys.exit(0)

chosen = online
if numa_filter:
    v = _read(f'/sys/class/net/{iface}/device/numa_node')
    try: numa = int(v)
    except (TypeError, ValueError): numa = -1
    if numa >= 0:
        node = _cpus_in(t["numa_nodes"].get(str(numa), ""))
        inter = online & node
        if inter:
            chosen = inter
        else:
            note = f"NUMA{numa} sem CPUs online - usando todas as online"
            numa = -1
    else:
        note = "NIC reporta numa_node=-1 (NPS=1 ou indefinido) - usando todas as online"

# Quantos dominios de cache o cpulist escolhido cobre (informativo).
covered = [d for d in t["domains"] if _cpus_in(d) & chosen]
partial = [d for d in covered if not (_cpus_in(d) <= chosen)]
if partial:
    note = (note + " | " if note else "") + \
           f"{len(partial)} dominio(s) de {t['domain_label']} ficam PARCIALMENTE cobertos"

res = {"cpus": _fmt(chosen), "numa": numa, "note": note,
       "domains_covered": len(covered), "topology": t}
if os.environ.get("TOPO_MODE") == "render":
    extra = ["selecao para a NIC %s:" % iface,
             "  cpus=%s" % res["cpus"],
             "  numa da NIC=%s   dominios de %s cobertos=%s de %s" % (
                 numa, t["domain_label"], len(covered), len(t["domains"]))]
    if partial:
        extra.append("  [!] %s dominio(s) ficam PARCIALMENTE cobertos: %s" % (
            len(partial), ", ".join(partial)))
    if note:
        extra.append("  [!] %s" % note)
    print(render_topology(t, extra))
else:
    print(json.dumps(res))
PY
}

# --print-topology: imprime a topologia detectada (CPU, caches, NUMA, dominios de cache)
# e o split/selecao que o auto-detect faria, depois sai. Diagnostico independente do resto do
# fluxo: serve para conferir, num servidor novo, se o kernel expoe L3/CCX ANTES de aplicar.
print_topology() {
  TOPO_MODE=render topology_json
}

# ---------------- preflight ----------------

ethtool_combined_current() { { ethtool -l "$1" 2>/dev/null || true; } | awk '/Combined:/{c=$2} END{print c}'; }
ethtool_combined_max()     { { ethtool -l "$1" 2>/dev/null || true; } | awk '/Combined:/ && !seen++ {print $2}'; }

preflight() {
  log "pré-flight"
  command -v ethtool   >/dev/null || { err "ethtool não instalado (apt install ethtool)"; exit 1; }
  command -v python3   >/dev/null || { err "python3 ausente"; exit 1; }
  command -v systemctl >/dev/null || { err "systemctl ausente"; exit 1; }
  if ! command -v tc >/dev/null; then
    warn "'tc' (iproute2) ausente — correção de qdisc das tx queues desabilitada"
    APPLY_QDISC=0
  fi

  [[ -d "/sys/class/net/${IFACE}" ]] || { err "interface ${IFACE} não existe"; exit 1; }
  # Exige PCI device: rejeita lo/bond-master/bridge/dummy/etc — fazer ethtool -L neles dá erro indecifrável.
  [[ -L "/sys/class/net/${IFACE}/device" ]] || {
    err "${IFACE} não tem device PCI (provavelmente loopback/bond-master/bridge/virtual) — esta variante exige NIC física"
    exit 1
  }
  local drv
  drv=$(basename "$(readlink "/sys/class/net/${IFACE}/device/driver" 2>/dev/null)" 2>/dev/null || echo "?")
  [[ "$drv" == "mlx5_core" ]] || warn "${IFACE} usa driver '${drv}' (esperado mlx5_core) — script segue, mas mirror-xps/rps dependem de IRQs nomeadas mlx5_comp*"
  if [[ -e "/sys/class/net/${IFACE}/master" ]]; then
    warn "${IFACE} é slave de um bond — esta variante single-NIC não é ideal em bond. Use mellanox-tune-bond.sh para LACP."
  fi

  if [[ -z "$CPUS" ]]; then
    log "auto-detect de CPUs (online ∩ NUMA-local da NIC, com --no-numa-filter pra ignorar NUMA)"
    local tj
    tj=$(topology_json) || { err "auto-detect de topologia falhou"; exit 1; }
    local cpus_line numa_line note_line topo_line
    cpus_line=$(TJ="$tj" python3 -c 'import json,os; print(json.loads(os.environ["TJ"])["cpus"])')
    numa_line=$(TJ="$tj" python3 -c 'import json,os; print(json.loads(os.environ["TJ"])["numa"])')
    note_line=$(TJ="$tj" python3 -c 'import json,os; print(json.loads(os.environ["TJ"])["note"])')
    topo_line=$(TJ="$tj" python3 -c 'import json,os
d=json.loads(os.environ["TJ"])["topology"]
print("%s cores / %s logical, SMT=%s, %s socket(s), %s NUMA, %s %s(s) [%s]" % (
  d.get("n_cores","?"), d.get("n_online","?"), "on" if d.get("smt") else "off",
  d.get("n_sockets","?"), d.get("n_numa","?"), len(d.get("domains") or []),
  d.get("domain_label","?"), d.get("domain_source","?")))')
    [[ -n "$cpus_line" ]] || { err "auto-detect retornou CPU list vazia"; exit 1; }
    CPUS="$cpus_line"
    ok "topologia: ${topo_line}"
    ok "CPUs auto-detectadas: ${CPUS} (numa=${numa_line})"
    [[ -n "$note_line" ]] && warn "auto-detect: ${note_line}"
    TJ="$tj" python3 -c 'import json,os
for w in json.loads(os.environ["TJ"])["topology"].get("warnings",[]):
    print("\033[1;33m[!]\033[0m topologia: " + w)' >&2
  fi

  # Sanity check ANTES do cálculo: NIC precisa ter combined channels (mlx5_core).
  # Se a NIC reporta Combined max == 0, é provável que use RX/TX separados (mlx4_en) —
  # nesse caso o usuário deve rodar mellanox-tune-mlx4.sh em vez deste.
  local cmaxq
  cmaxq=$(ethtool_combined_max "$IFACE")
  if [[ -z "$cmaxq" || "$cmaxq" == "0" ]]; then
    err "${IFACE}: ethtool reporta Combined max=${cmaxq:-vazio}. Esta NIC não usa combined channels."
    err "  → Se driver=mlx4_en (ConnectX-3), use: ./mellanox-tune-mlx4.sh --nic ${IFACE}"
    err "  → Caso contrário, valide com: ethtool -l ${IFACE}"
    exit 1
  fi

  if [[ -z "$QUEUES" ]]; then
    local n_cpus
    n_cpus=$(count_cpus_in_list "$CPUS")
    QUEUES=$(( n_cpus < cmaxq ? n_cpus : cmaxq ))
    ok "queues calculado: min(|CPUs|=${n_cpus}, max-combined=${cmaxq}) = ${QUEUES}"
  fi

  # Sanity check FINAL — nunca aplicar 0 queues, mesmo via --queues 0 manual.
  (( QUEUES > 0 )) || { err "QUEUES=${QUEUES} (<=0). Aborto para evitar derrubar filas."; exit 1; }

  ok "iface=${IFACE} CPUs=${CPUS} queues=${QUEUES}"

  local n_cpus
  n_cpus=$(count_cpus_in_list "$CPUS")
  if (( QUEUES < n_cpus )); then
    warn "${IFACE}: ${QUEUES} queues < ${n_cpus} logical CPUs — IRQs só vão pinar nas primeiras ${QUEUES} CPUs do range"
  fi
}

# ---------------- backup ----------------

backup_state() {
  log "backup do estado atual em ${BACKUP_DIR}"
  run "mkdir -p '${BACKUP_DIR}'"
  run "cp -a /proc/interrupts '${BACKUP_DIR}/interrupts.pre-pin-single-${STAMP}.txt'"
  run "${HELPER_PATH} show-irq '${IFACE}' > '${BACKUP_DIR}/affinity.${IFACE}.pre-pin-single-${STAMP}.txt' 2>&1 || true"
  run "systemctl is-enabled irqbalance > '${BACKUP_DIR}/irqbalance.pre-pin-single-${STAMP}.txt' 2>&1 || true"
  ok "backup completo"
}

# ---------------- irqbalance ----------------

stop_irqbalance() {
  # `systemctl list-unit-files X` retorna 0 mesmo se X não existe — não serve como check.
  # Usar `systemctl cat` que retorna não-zero se a unit não existe.
  if systemctl cat irqbalance.service &>/dev/null; then
    log "desabilitando irqbalance (sobrescreve afinidade a cada ~10s)"
    run "systemctl disable --now irqbalance || true"
    ok "irqbalance off"
  else
    warn "irqbalance não instalado — nada a parar"
  fi
}

# ---------------- ethtool combined queues ----------------

set_queues_to_max() {
  # Ver comentário na variante bond: o bounce alvo->max->alvo só faz sentido quando existe
  # fila acima do alvo para o cleanup alcançar.
  log "expondo filas herdadas antes do cleanup (só quando há algo acima do alvo)"
  local cur maxq
  cur=$(ethtool_combined_current "$IFACE")
  maxq=$(ethtool_combined_max "$IFACE")
  if [[ -z "$maxq" ]]; then
    warn "${IFACE}: ethtool não reportou max combined — pulando set-to-max"
    return
  fi
  if [[ "$cur" == "$QUEUES" ]]; then
    ok "${IFACE} já em Combined=${QUEUES} (alvo) — sem bounce"
    return
  fi
  if [[ "$cur" == "$maxq" ]]; then
    ok "${IFACE} já em Combined=${maxq} (max), sem mudança"
    return
  fi
  log "${IFACE}: Combined ${cur:-?} → ${maxq} (max, temporário para o cleanup)"
  run "ethtool -L ${IFACE} combined ${maxq}"
  run "sleep 2"
}

apply_queue_count() {
  log "ajustando combined queues para ${QUEUES} em ${IFACE}"
  local cur
  cur=$(ethtool_combined_current "$IFACE")
  if [[ -z "$cur" ]]; then
    warn "${IFACE}: ethtool não reporta Combined: (NIC sem multi-queue?) — pulando set"
    return
  fi
  if [[ "$cur" == "$QUEUES" ]]; then
    ok "${IFACE} já em Combined=${QUEUES}, sem mudança"
    return
  fi
  log "${IFACE}: Combined ${cur} → ${QUEUES}"
  if (( DRY_RUN )); then
    printf '\033[1;90m    DRY: ethtool -L %s combined %s\033[0m\n' "$IFACE" "$QUEUES" >&2
    return
  fi
  # ethtool -L pode falhar com EINVAL se QUEUES < mínimo do driver. Capturar stderr
  # e dar mensagem útil em vez de abortar com set -e.
  local err_log="/tmp/xui-ethtool-err.$$"
  if ! ethtool -L "$IFACE" combined "$QUEUES" 2>"$err_log"; then
    local emsg; emsg=$(cat "$err_log" 2>/dev/null)
    err "${IFACE}: ethtool -L combined ${QUEUES} falhou — ${emsg}"
    err "  Causa provável: ${QUEUES} é abaixo do mínimo aceito pelo driver/firmware mlx5."
    err "  → Aumente CPUs em --cpus (mais CPUs = mais queues), ou use --queues N maior."
    err "  Estado atual da NIC: Combined=${cur} (continua nesse valor)."
    rm -f "$err_log"
    exit 1
  fi
  rm -f "$err_log"
  sleep 2
}

# Ver comentário equivalente na variante bond.
STATE_DIRTY=0

on_exit() {
  local rc=$?
  (( rc != 0 )) || return 0
  (( ! DRY_RUN )) || return 0
  (( STATE_DIRTY )) || return 0
  err "ABORTO (rc=${rc}) depois do cleanup — repinando IRQs para não deixar a NIC sem afinidade"
  if [[ -x "${HELPER_PATH}" ]]; then
    "${HELPER_PATH}" pin-irq "${IFACE:-}" "${CPUS:-}" || true
  fi
  err "  irqbalance continua DESABILITADO (por design). Revise o estado com: $0 --dry-run --nic ${IFACE:-<iface>}"
}
trap on_exit EXIT

# ---------------- cleanup total ----------------

cleanup_existing_state() {
  log "CLEANUP TOTAL — IRQ, RPS, XPS, aRFS em ${IFACE}"
  run "${HELPER_PATH} cleanup ${IFACE}"
  run "${HELPER_PATH} cleanup-global"
  STATE_DIRTY=1
  ok "estado limpo"
}

# ---------------- ring size, coalesce, offloads ----------------

# ethtool -g (idêntico em layout ao -l): pre-set max + current. section=max|current ; channel=RX|TX.
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
  log "ajustando ring size de ${IFACE} ao máximo"
  run "${HELPER_PATH} ring-max ${IFACE}"
}

apply_coalesce_adaptive() {
  (( APPLY_COALESCE )) || { warn "coalesce adaptive desabilitado (--no-coalesce)"; return; }
  log "habilitando adaptive coalescing em ${IFACE}"
  run "${HELPER_PATH} coalesce ${IFACE}"
}

apply_offloads() {
  (( APPLY_OFFLOADS )) || { warn "offloads desabilitados (--no-offloads)"; return; }
  log "habilitando offloads lro/tso/gro/gso em ${IFACE}"
  # LRO=on aqui (NIC que TERMINA conexões, sem bond/forwarding). Se esta iface virar slave de
  # bond ou entrar em forwarding, o kernel força off e o ethtool -k mostra "[requested on]" —
  # cosmético e esperado. Ver a variante bond, que seta off explicitamente.
  run "${HELPER_PATH} offloads ${IFACE} on"
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
  log "verificando qdisc das tx queues em ${IFACE} (pacing FQ p/ BBR)"
  run "${HELPER_PATH} fix-qdisc ${IFACE}"
}

# ---------------- pinning ----------------

apply_pinning() {
  log "aplicando IRQ affinity em ${IFACE} usando CPUs=${CPUS}"
  run "${HELPER_PATH} pin-irq ${IFACE} ${CPUS}"
  ok "IRQs pinadas"
}

# ---------------- XPS / RPS / aRFS condicionais ----------------

apply_xps_per_irq() {
  log "XPS per-queue espelhando IRQ"
  run "${HELPER_PATH} mirror-xps ${IFACE}"
  ok "XPS aplicado"
}

apply_rps_per_irq() {
  # Ver comentário na variante bond: com uma fila por CPU, RPS só adiciona overhead.
  if (( QUEUES >= $(count_cpus_in_list "$CPUS") )); then
    warn "--rps com filas (${QUEUES}) >= CPUs: cada fila já tem CPU própria, RPS só adiciona overhead"
    warn "  (útil quando o nº de filas é MENOR que o de CPUs do cpulist)"
  fi
  log "RPS per-queue espelhando IRQ"
  run "${HELPER_PATH} mirror-rps ${IFACE}"
  ok "RPS aplicado"
}

apply_arfs_all() {
  log "aRFS: rps_sock_flow_entries=${ARFS_FLOW_ENTRIES} + ntuple on + rps_flow_cnt=${ARFS_PER_QUEUE_FLOW_CNT}"
  run "${HELPER_PATH} arfs-global ${ARFS_FLOW_ENTRIES}"
  run "${HELPER_PATH} arfs ${IFACE} ${ARFS_PER_QUEUE_FLOW_CNT}"
  ok "aRFS aplicado"
}

# ---------------- deploy helper ----------------
# Mesmo helper da bond-version; reusável entre as duas variantes.
# Se já existe e tem os subcomandos, não sobrescreve.
HELPER_VERSION=5   # bumpar quando o conteúdo do heredoc abaixo mudar; o grep abaixo casa por essa tag

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
  [[ -n "$ethtool_bin" ]] || { err "ethtool não encontrado no PATH"; return 1; }
  [[ -x "${HELPER_PATH}" ]] || { err "helper ${HELPER_PATH} ausente"; return 1; }

  if [[ -f "${SYSTEMD_UNIT}" ]]; then
    mkdir -p "${BACKUP_DIR}"
    cp -a "${SYSTEMD_UNIT}" "${BACKUP_DIR}/$(basename "${SYSTEMD_UNIT}").pre-${STAMP}" 2>/dev/null || true
  fi

  local features="IRQ"
  (( APPLY_RING_MAX )) && features="${features}+RING"
  (( APPLY_COALESCE )) && features="${features}+COAL"
  (( APPLY_OFFLOADS )) && features="${features}+OFF"
  (( APPLY_QDISC ))    && features="${features}+QDISC"
  (( APPLY_XPS ))      && features="${features}+XPS"
  (( APPLY_RPS ))      && features="${features}+RPS"
  (( APPLY_ARFS ))     && features="${features}+aRFS"

  # Toda a lógica vive no helper — nenhum ExecStart carrega '$', backslash ou /bin/sh -c: o
  # parser do systemd faz C-unescape mesmo dentro de aspas simples e expande $VAR, o que já
  # transformou a linha de ring buffer em no-op silencioso. Gate em assert_unit_clean().
  # Prefixo '-' = preparação tolerante a falha; só pin-irq fica sem, por ser o objetivo.
  local ring_lines="" coalesce_lines="" offload_lines=""
  if (( APPLY_RING_MAX )); then
    ring_lines=$'\n# Ring buffer no máximo\nExecStart=-'"${HELPER_PATH}"$' ring-max '"${IFACE}"
  fi
  if (( APPLY_COALESCE )); then
    coalesce_lines=$'\n# Coalesce adaptive\nExecStart=-'"${HELPER_PATH}"$' coalesce '"${IFACE}"
  fi
  if (( APPLY_OFFLOADS )); then
    offload_lines=$'\n# Offloads lro/tso/gro/gso=on\nExecStart=-'"${HELPER_PATH}"$' offloads '"${IFACE}"$' on'
  fi

  local qdisc_lines=""
  if (( APPLY_QDISC )); then
    qdisc_lines=$'\n# Qdisc das tx queues: ethtool -L deixa filas novas em pfifo_fast (sem pacing FQ)\nExecStart=-'"${HELPER_PATH}"$' fix-qdisc '"${IFACE}"
  fi

  local xps_lines="" rps_lines="" arfs_lines=""
  if (( APPLY_XPS )); then
    xps_lines=$'\n# XPS per-queue (--xps)\nExecStart=-'"${HELPER_PATH}"$' mirror-xps '"${IFACE}"
  fi
  if (( APPLY_RPS )); then
    rps_lines=$'\n# RPS per-queue (--rps)\nExecStart=-'"${HELPER_PATH}"$' mirror-rps '"${IFACE}"
  fi
  if (( APPLY_ARFS )); then
    arfs_lines=$'\n# aRFS global + per-iface (--arfs)\nExecStart=-'"${HELPER_PATH}"$' arfs-global '"${ARFS_FLOW_ENTRIES}"$'\nExecStart=-'"${HELPER_PATH}"$' arfs '"${IFACE}"$' '"${ARFS_FLOW_ENTRIES}"
  fi

  local dev0
  dev0=$(netdev_unit "$IFACE")

  cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=Mellanox single-NIC tuning: ${features} pin (${IFACE}=${CPUS}, queues=${QUEUES})
After=network-online.target
Wants=network-online.target
After=${dev0}
Conflicts=irqbalance.service
After=irqbalance.service
ConditionPathExists=/sys/class/net/${IFACE}
AssertPathExists=${HELPER_PATH}

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# 1) CLEANUP
ExecStart=-${HELPER_PATH} cleanup ${IFACE}
# 2) channels no target
ExecStart=-${ethtool_bin} -L ${IFACE} combined ${QUEUES}
ExecStart=/bin/sleep 2${ring_lines}${coalesce_lines}${offload_lines}${qdisc_lines}
# 3) Pinning das completion IRQs — sem '-': é o objetivo do unit.
ExecStart=${HELPER_PATH} pin-irq ${IFACE} ${CPUS}${xps_lines}${rps_lines}${arfs_lines}

[Install]
WantedBy=multi-user.target
EOF

  assert_unit_clean || return 1

  systemctl daemon-reload
  systemctl enable mlx-irq-pin-single.service
  ok "unit armada para boot: $(systemctl is-enabled mlx-irq-pin-single.service)"
}

# ---------------- rollback ----------------

do_rollback() {
  log "rollback"
  # Nota: `systemctl list-unit-files <name>` retorna 0 mesmo se a unit não existe.
  # Usamos `cat` no path da unit (retorna não-zero se ausente), e mascaramos erros do
  # `disable`/`enable` com `|| true` para não abortar via set -e.
  if [[ -f "${SYSTEMD_UNIT}" ]] || systemctl cat mlx-irq-pin-single.service &>/dev/null; then
    run "systemctl disable --now mlx-irq-pin-single.service || true"
    run "rm -f ${SYSTEMD_UNIT}"
    run "systemctl daemon-reload"
  fi
  if systemctl cat irqbalance.service &>/dev/null; then
    run "systemctl enable --now irqbalance || true"
    ok "irqbalance reativado"
  fi
  if [[ -n "${IFACE:-}" && -d "/sys/class/net/${IFACE}" ]]; then
    log "restaurando combined queues para o máximo em ${IFACE}"
    local maxq
    maxq=$(ethtool_combined_max "$IFACE")
    if [[ -n "$maxq" ]]; then
      run "ethtool -L ${IFACE} combined ${maxq}"
      run "sleep 2"
    fi
    if [[ -x "${HELPER_PATH}" ]]; then
      log "rollback: limpando RPS/XPS/aRFS via helper"
      run "${HELPER_PATH} cleanup ${IFACE}"
      run "${HELPER_PATH} cleanup-global"
      # Voltar as filas ao máximo (acima) reexpõe filas com pfifo_fast — regenerar aqui
      # devolve o net.core.default_qdisc em todas elas.
      if (( APPLY_QDISC )); then
        run "${HELPER_PATH} fix-qdisc ${IFACE}"
      fi
    else
      warn "helper ausente — limpe manualmente RPS/XPS/aRFS"
    fi
  else
    warn "iface não resolvida — pulando limpeza por iface"
  fi
  # Não remove o helper aqui; pode estar em uso pela bond-version. Remoção manual: rm ${HELPER_PATH}
  echo
  warn "o rollback NÃO reverte (por design, são estados benignos):"
  warn "  - ring size continua no máximo; coalesce continua adaptive; offloads não revertidos"
  warn "  - channels voltaram ao MÁXIMO do device, não ao valor anterior ao primeiro run"
  warn "  - smp_affinity dos IRQs voltou ao /proc/irq/default_smp_affinity, não ao original"
  ok "rollback aplicado"
}

# ---------------- validação ----------------

iface_pci_bdf() {
  local target
  target=$(readlink -f "/sys/class/net/$1/device" 2>/dev/null) || return 1
  [[ -n "$target" ]] || return 1
  basename "$target"
}

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
    log "VALIDAÇÃO (post-rollback — afinidade volta a default_smp_affinity)"
  else
    log "VALIDAÇÃO"
  fi

  report_affinity "$IFACE" "$CPUS"

  echo "── helper / scripts ──"
  printf "  helper: %s (exec=%s)\n" "$HELPER_PATH" "$([[ -x "$HELPER_PATH" ]] && echo yes || echo no)"

  echo "── combined queues ──"
  local q
  q=$(ethtool_combined_current "$IFACE")
  printf "  %s: Combined=%s (esperado %s)\n" "$IFACE" "${q:-?}" "$QUEUES"

  echo "── irqbalance ──"
  printf "  active=%s enabled=%s\n" \
    "$(sys_state is-active irqbalance)" \
    "$(sys_state is-enabled irqbalance)"

  echo "── unit mlx-irq-pin-single ──"
  printf "  active=%s enabled=%s\n" \
    "$(sys_state is-active mlx-irq-pin-single.service)" \
    "$(sys_state is-enabled mlx-irq-pin-single.service)"

  echo "── RPS / XPS / aRFS (esperado: RPS=$((APPLY_RPS)) XPS=$((APPLY_XPS)) aRFS=$((APPLY_ARFS))) ──"
  local nz_rps nz_xps xps_sample rps_sample arfs_state arfs_flow
  # `; true` no fim do loop garante que o subshell sempre retorne 0 — sem isso, se a última
  # iteração tem `[[ -n "$v" ]] && echo nz` curto-circuitando em falso, o pipe falha com
  # pipefail e `set -e` aborta o script no command substitution.
  nz_rps=$({ for q in "/sys/class/net/$IFACE/queues/"rx-*/rps_cpus; do [[ -e "$q" ]] || continue; v=$(tr -d ',0' < "$q" 2>/dev/null); [[ -n "$v" ]] && echo nz; done; true; } | wc -l)
  nz_xps=$({ for q in "/sys/class/net/$IFACE/queues/"tx-*/xps_cpus; do [[ -e "$q" ]] || continue; v=$(tr -d ',0' < "$q" 2>/dev/null); [[ -n "$v" ]] && echo nz; done; true; } | wc -l)
  xps_sample=$(cat "/sys/class/net/$IFACE/queues/tx-0/xps_cpus" 2>/dev/null)
  rps_sample=$(cat "/sys/class/net/$IFACE/queues/rx-0/rps_cpus" 2>/dev/null)
  arfs_state=$(ethtool -k "$IFACE" 2>/dev/null | awk -F: '/ntuple-filters:/{gsub(/^ +| +$/,"",$2); print $2}')
  arfs_flow=$(cat "/sys/class/net/$IFACE/queues/rx-0/rps_flow_cnt" 2>/dev/null)
  local n_rxq n_txq
  n_rxq=$(shopt -s nullglob; a=("/sys/class/net/$IFACE/queues/"rx-*); echo "${#a[@]}")
  n_txq=$(shopt -s nullglob; a=("/sys/class/net/$IFACE/queues/"tx-*); echo "${#a[@]}")
  printf "  %s: rps_cpus nz=%s/%s (sample rx-0=%s) | xps_cpus nz=%s/%s (sample tx-0=%s) | ntuple=%s rps_flow_cnt[rx-0]=%s\n" \
    "$IFACE" "$nz_rps" "$n_rxq" "$rps_sample" \
    "$nz_xps" "$n_txq" "$xps_sample" \
    "${arfs_state:-?}" "${arfs_flow:-?}"
  printf "  global: net.core.rps_sock_flow_entries=%s (esperado %s)\n" \
    "$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)" \
    "$((APPLY_ARFS ? ARFS_FLOW_ENTRIES : 0))"

  echo "── ring buffer ──"
  local rr_cur tr_cur rr_max tr_max
  rr_cur=$(ethtool_ring "$IFACE" current RX); tr_cur=$(ethtool_ring "$IFACE" current TX)
  rr_max=$(ethtool_ring "$IFACE" max RX);     tr_max=$(ethtool_ring "$IFACE" max TX)
  printf "  %s: RX=%s/%s TX=%s/%s (current/max)\n" "$IFACE" "${rr_cur:-?}" "${rr_max:-?}" "${tr_cur:-?}" "${tr_max:-?}"

  echo "── coalesce adaptive ──"
  # ethtool -c imprime "Adaptive RX: on  TX: on" em uma única linha.
  ethtool -c "$IFACE" 2>/dev/null | awk '/^Adaptive RX:/ {
    # match "Adaptive RX: <v1>  TX: <v2>"
    rx=$3; tx=$5; printf "  RX=%s TX=%s\n", rx, tx
  }' || echo "  (n/a)"

  echo "── offloads ──"
  ethtool -k "$IFACE" 2>/dev/null | awk -F: '
    /^(tcp-segmentation-offload|generic-receive-offload|generic-segmentation-offload|large-receive-offload):/ {
      gsub(/^ +| +$/,"",$2); printf "  %-30s %s\n", $1, $2
    }' || echo "  (n/a)"

  echo "── qdisc por tx queue (pacing p/ BBR) ──"
  printf "  net.core.default_qdisc=%s | net.ipv4.tcp_congestion_control=%s\n" \
    "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')" \
    "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  if command -v tc >/dev/null; then
    printf "  %-18s root=%-10s filas: %s\n" "$IFACE" \
      "$(qdisc_root_kind_v "$IFACE")" "$(qdisc_hist_v "$IFACE")"
  else
    echo "  (tc ausente)"
  fi

  echo "── drops na NIC (devem ficar estáveis após pinning) ──"
  echo "  ${IFACE}:"
  ethtool -S "$IFACE" 2>/dev/null | grep -E "rx_discards|rx_missed|rx_buff_alloc_err" | sed 's/^/    /' || true
  ok "validação impressa acima"
}

# ---------------- main ----------------

main() {
  # Emite o helper embutido e sai. Serve para auditar a invariante "bond e single embutem o
  # MESMO helper" sem depender de sed frágil sobre o heredoc:
  #   diff <(./mellanox-tune-bond.sh --print-helper) <(./mellanox-tune-single.sh --print-helper)
  if (( PRINT_HELPER )); then emit_helper; exit 0; fi
  if (( PRINT_TOPOLOGY )); then print_topology; exit 0; fi

  log "mellanox-tune-single.sh — variante single-NIC, full-CPU"
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
  ok "single-NIC tuning aplicado (ou simulado, se --dry-run)."
  echo "  Observar 1–2h:"
  echo "    watch -d 'grep mlx5.*${IFACE} /proc/interrupts | head'"
  echo "    ethtool -S ${IFACE} | grep -E 'rx_discards|rx_missed'"
  echo "  Rollback:  $0 --rollback --nic ${IFACE}"
}

main "$@"
