########################################
# 11.5) Blindagem de NICs contra renomeação pelo novo kernel
########################################

echo "==> Blindando configuração de NICs contra renomeação..."

NETPLAN_DIR="/etc/netplan"
LINK_DIR="/etc/systemd/network"
BACKUP_DIR="/root/network-backup-$(date +%Y%m%d-%H%M%S)"
ROLLBACK_SCRIPT="/usr/local/sbin/network-rollback.sh"
ROLLBACK_SERVICE="/etc/systemd/system/network-rollback.service"
ROLLBACK_TIMER="/etc/systemd/system/network-rollback.timer"
ROLLBACK_FLAG="/var/lib/network-rollback-state"
GRUB_DEFAULT_BACKUP="$BACKUP_DIR/grub-default.txt"

# Garante dependências (Python + ruamel) antes de tudo
echo "   Garantindo dependências (python3, python3-ruamel.yaml)..."
apt-get install "${APT_OPTS[@]}" python3 python3-ruamel.yaml >/dev/null 2>&1 || \
  apt-get install "${APT_OPTS[@]}" python3 python3-yaml

mkdir -p "$BACKUP_DIR" "$LINK_DIR" "$(dirname "$ROLLBACK_FLAG")"

# ---- Backup completo ----
echo "   Backup em: $BACKUP_DIR"
cp -a "$NETPLAN_DIR" "$BACKUP_DIR/netplan" 2>/dev/null || mkdir -p "$BACKUP_DIR/netplan"
cp -a "$LINK_DIR"    "$BACKUP_DIR/systemd-network" 2>/dev/null || mkdir -p "$BACKUP_DIR/systemd-network"
ip link show > "$BACKUP_DIR/ip-link-pre.txt"
ip addr show > "$BACKUP_DIR/ip-addr-pre.txt"
ip route show > "$BACKUP_DIR/routes-pre.txt"

# Salva kernel atual como fallback de boot do GRUB
RUNNING_KERNEL_FOR_ROLLBACK="$(uname -r)"
echo "$RUNNING_KERNEL_FOR_ROLLBACK" > "$GRUB_DEFAULT_BACKUP"

# ---- Cleanup function: chamada se algo falhar no meio ----
blindagem_cleanup_on_error() {
  local rc=$?
  echo "   ⚠️  Erro durante blindagem (rc=$rc). Restaurando estado original..." >&2
  rm -f "$LINK_DIR"/10-persist-*.link 2>/dev/null || true
  if [ -d "$BACKUP_DIR/netplan" ]; then
    rm -f "$NETPLAN_DIR"/*.yaml "$NETPLAN_DIR"/*.yml 2>/dev/null || true
    cp -a "$BACKUP_DIR/netplan/." "$NETPLAN_DIR/" 2>/dev/null || true
  fi
  return $rc
}

# ---- Coleta de NICs físicas ----
declare -A NIC_MAC
PHYSICAL_NICS=()

while IFS= read -r iface; do
  case "$iface" in
    lo|docker*|veth*|br-*|virbr*|tun*|tap*|wg*|bond*|vlan*|vxlan*|*.[0-9]*) continue ;;
  esac
  [ -e "/sys/class/net/$iface/device" ] || continue

  mac="$(cat "/sys/class/net/$iface/address" 2>/dev/null || true)"
  [[ -z "$mac" || "$mac" == "00:00:00:00:00:00" ]] && continue

  NIC_MAC["$iface"]="$mac"
  PHYSICAL_NICS+=("$iface")
done < <(ls /sys/class/net/)

if [ "${#PHYSICAL_NICS[@]}" -eq 0 ]; then
  echo "   ⚠️  Nenhuma NIC física detectada. Pulando blindagem."
else
  echo "   NICs físicas detectadas:"
  for nic in "${PHYSICAL_NICS[@]}"; do
    echo "      $nic -> ${NIC_MAC[$nic]}"
  done

  # Habilita cleanup automático se der erro daqui pra frente
  trap blindagem_cleanup_on_error ERR

  # ---- Camada 1: .link files ----
  echo "   [1/3] Gerando systemd .link files..."
  for nic in "${PHYSICAL_NICS[@]}"; do
    mac="${NIC_MAC[$nic]}"
    link_file="$LINK_DIR/10-persist-${nic}.link"
    cat > "$link_file" <<EOF
# Gerado em $(date -Iseconds) - congela "$nic" via MAC $mac
[Match]
MACAddress=$mac

[Link]
Name=$nic
NamePolicy=
EOF
    chmod 644 "$link_file"
    echo "      criado: $link_file"
  done

  # ---- Camada 2: Netplan via Python (parsing seguro) ----
  echo "   [2/3] Reescrevendo Netplan com match por MAC..."

  python3 - "$NETPLAN_DIR" "${PHYSICAL_NICS[@]}" <<'PYEOF'
import os, sys, glob, shutil

try:
    from ruamel.yaml import YAML
    yaml_handler = YAML()
    yaml_handler.preserve_quotes = True
    yaml_handler.indent(mapping=2, sequence=4, offset=2)
    USE_RUAMEL = True
except ImportError:
    import yaml as pyyaml
    USE_RUAMEL = False

netplan_dir = sys.argv[1]
physical_nics = sys.argv[2:]

nic_mac = {}
for nic in physical_nics:
    try:
        with open(f"/sys/class/net/{nic}/address") as f:
            nic_mac[nic] = f.read().strip().lower()
    except FileNotFoundError:
        pass

def load(path):
    with open(path) as f:
        if USE_RUAMEL:
            return yaml_handler.load(f)
        return pyyaml.safe_load(f)

def dump(data, path):
    with open(path, 'w') as f:
        if USE_RUAMEL:
            yaml_handler.dump(data, f)
        else:
            pyyaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)

modified_count = 0
for path in sorted(glob.glob(os.path.join(netplan_dir, "*.yaml")) +
                   glob.glob(os.path.join(netplan_dir, "*.yml"))):
    try:
        data = load(path)
    except Exception as e:
        print(f"      [WARN] não foi possível parsear {path}: {e}", file=sys.stderr)
        continue

    if not data or 'network' not in data:
        continue
    net = data['network']
    eth = net.get('ethernets')
    if not eth:
        continue

    changed = False
    for ifname in list(eth.keys()):
        conf = eth[ifname]
        if conf is None:
            conf = {}
            eth[ifname] = conf

        # Já tem match por MAC? pula
        existing_match = conf.get('match') if isinstance(conf, dict) or hasattr(conf, 'get') else None
        if existing_match and 'macaddress' in existing_match:
            continue

        # Só converte se o nome bate com NIC física conhecida
        if ifname in nic_mac:
            mac = nic_mac[ifname]
            conf['match'] = {'macaddress': mac}
            conf['set-name'] = ifname
            changed = True
            print(f"      {os.path.basename(path)}: {ifname} -> match macaddress {mac}")

    if changed:
        shutil.copy2(path, path + ".bak-prexanmod")
        dump(data, path)
        modified_count += 1

print(f"      Netplan atualizado: {modified_count} arquivo(s)")
PYEOF

  # ---- Camada 3: validação ----
  echo "   [3/3] Validando configuração..."

  if ! netplan generate 2>/tmp/netplan-err.log; then
    echo "   ❌ netplan generate falhou:" >&2
    cat /tmp/netplan-err.log >&2
    false  # dispara o trap ERR
  fi

  # Valida MACs do Netplan via Python (parsing real, sem grep)
  python3 - "$NETPLAN_DIR" "${PHYSICAL_NICS[@]}" <<'PYEOF'
import os, sys, glob

try:
    from ruamel.yaml import YAML
    loader = YAML(typ='safe').load
except ImportError:
    import yaml
    loader = yaml.safe_load

netplan_dir = sys.argv[1]
physical_nics = sys.argv[2:]

hw_macs = set()
for nic in physical_nics:
    try:
        with open(f"/sys/class/net/{nic}/address") as f:
            hw_macs.add(f.read().strip().lower())
    except FileNotFoundError:
        pass

declared_macs = set()
for path in glob.glob(os.path.join(netplan_dir, "*.yaml")) + \
            glob.glob(os.path.join(netplan_dir, "*.yml")):
    try:
        with open(path) as f:
            data = loader(f)
    except Exception:
        continue
    if not data:
        continue
    eth = (data.get('network') or {}).get('ethernets') or {}
    for ifname, conf in eth.items():
        if not isinstance(conf, dict):
            continue
        match = conf.get('match') or {}
        mac = match.get('macaddress')
        if mac:
            declared_macs.add(mac.lower())

missing = declared_macs - hw_macs
if missing:
    print(f"❌ MACs no Netplan ausentes no hardware: {missing}", file=sys.stderr)
    sys.exit(1)
print(f"      OK: {len(declared_macs)} MAC(s) declarado(s) batem com hardware")
PYEOF

  # Atualiza initramfs (após XanMod já estar instalado, então -k all funciona)
  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k all 2>&1 | tail -5
  fi

  # Sucesso: limpa o trap
  trap - ERR
  echo "   ✅ Blindagem aplicada com sucesso."
fi

# ---- Rollback automático pós-boot ----
echo "==> Instalando rollback automático pós-boot..."

# Script de rollback. Heredoc QUOTED ('EOF') = sem expansão. Substituições explícitas via sed.
cat > "$ROLLBACK_SCRIPT" <<'ROLLBACK_EOF'
#!/usr/bin/env bash
# Rollback automático: se rede não subir após XanMod, restaura tudo e força boot no kernel antigo.
set -u
LOG=/var/log/network-rollback.log
exec >> "$LOG" 2>&1

echo "[$(date -Iseconds)] verificação pós-boot iniciada"

BACKUP_DIR="__BACKUP_DIR__"
OLD_KERNEL="__OLD_KERNEL__"
FLAG="__ROLLBACK_FLAG__"

# Idempotência: se já validamos um boot OK, não fazer nada
if [ -f "$FLAG" ] && grep -q '^ok$' "$FLAG" 2>/dev/null; then
  echo "[$(date -Iseconds)] boot já validado anteriormente, saindo"
  exit 0
fi

# Aguarda systemd-networkd estabilizar (até 60s adicionais)
for i in $(seq 1 12); do
  if ip -4 route show default 2>/dev/null | grep -q .; then
    break
  fi
  sleep 5
done

# Verifica rota default + conectividade real (ping no gateway)
GW="$(ip -4 route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
if [ -n "$GW" ] && ping -c 2 -W 2 "$GW" >/dev/null 2>&1; then
  echo "[$(date -Iseconds)] OK: rota default ($GW) + conectividade. Marcando como validado."
  echo "ok" > "$FLAG"
  systemctl disable network-rollback.timer >/dev/null 2>&1 || true
  exit 0
fi

echo "[$(date -Iseconds)] FALHA: rede não funcional, executando rollback completo"
echo "rolling-back" > "$FLAG"

# Restaura Netplan
if [ -d "$BACKUP_DIR/netplan" ]; then
  rm -f /etc/netplan/*.yaml /etc/netplan/*.yml 2>/dev/null || true
  cp -a "$BACKUP_DIR/netplan/." /etc/netplan/ 2>/dev/null || true
fi

# Remove .link files que criamos
rm -f /etc/systemd/network/10-persist-*.link 2>/dev/null || true

# Restaura .link files originais
if [ -d "$BACKUP_DIR/systemd-network" ]; then
  cp -a "$BACKUP_DIR/systemd-network/." /etc/systemd/network/ 2>/dev/null || true
fi

# Força próximo boot no kernel antigo via grub-reboot (one-shot)
if command -v grub-reboot >/dev/null 2>&1 && [ -n "$OLD_KERNEL" ]; then
  # Encontra entrada do GRUB que corresponde ao kernel antigo
  ENTRY=$(awk -F"'" '/menuentry / {print $2}' /boot/grub/grub.cfg 2>/dev/null | grep -F "$OLD_KERNEL" | head -1)
  if [ -n "$ENTRY" ]; then
    grub-reboot "Advanced options for Ubuntu>$ENTRY" 2>/dev/null || \
    grub-reboot "$ENTRY" 2>/dev/null || true
    echo "[$(date -Iseconds)] grub-reboot configurado para: $ENTRY"
  fi
fi

update-initramfs -u 2>/dev/null || true

echo "[$(date -Iseconds)] rollback aplicado, reiniciando em 1 min"
shutdown -r +1 "Rollback de rede aplicado pelo network-rollback.service"
ROLLBACK_EOF

# Substitui placeholders com valores reais
sed -i \
  -e "s|__BACKUP_DIR__|$BACKUP_DIR|g" \
  -e "s|__OLD_KERNEL__|$RUNNING_KERNEL_FOR_ROLLBACK|g" \
  -e "s|__ROLLBACK_FLAG__|$ROLLBACK_FLAG|g" \
  "$ROLLBACK_SCRIPT"

chmod +x "$ROLLBACK_SCRIPT"

# Service
cat > "$ROLLBACK_SERVICE" <<'EOF'
[Unit]
Description=Rollback automático de rede pós-XanMod
After=network.target systemd-networkd.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/network-rollback.sh
RemainAfterExit=no
EOF

# Timer: dispara 5min após network-online (não após boot puro)
cat > "$ROLLBACK_TIMER" <<'EOF'
[Unit]
Description=Aciona rollback de rede após estabilização

[Timer]
OnBootSec=5min
AccuracySec=10s
Unit=network-rollback.service
RemainAfterElapse=yes

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable network-rollback.timer
echo "   Timer ativo: validação em 5min, rollback se falhar."
