#!/usr/bin/env bash
# install_xanmod.sh - Prepara o sistema e instala o kernel XanMod v3
#
# Estratégia de segurança:
#   - Instala XanMod ANTES de remover kernels antigos (rollback bootável garantido)
#   - Blinda nomes de NIC contra renomeação pelo novo kernel (3 camadas):
#       1. systemd .link files congelam nome via MAC
#       2. Netplan reescrito com match: macaddress (se Netplan estiver em uso)
#       3. initramfs atualizado para .link valer desde o boot
#   - Rollback automático pós-boot: se rede não subir em 5min, restaura tudo
#     e força boot no kernel antigo via grub-reboot
#
# Compatível com Ubuntu/Debian usando Netplan e/ou /etc/network/interfaces.

set -euo pipefail

LOG="/var/log/install_xanmod.log"
exec > >(tee -a "$LOG") 2>&1

# Função padrão de erro: separada para que $LINENO seja avaliado no disparo
on_error_default() {
  echo "❌ ERRO na linha $1. Veja $LOG para detalhes." >&2
}
trap 'on_error_default $LINENO' ERR

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

########################################
# 1) Verificar execução como root
########################################
if [ "$EUID" -ne 0 ]; then
  echo "Este script precisa ser executado como root. Execute: sudo $0" >&2
  exit 1
fi

########################################
# 1.1) Verificar suporte a x86-64-v3 (AVX2/BMI2)
########################################
echo "==> Verificando suporte da CPU a x86-64-v3..."
REQUIRED_FLAGS=(avx avx2 bmi1 bmi2 fma f16c movbe xsave)
MISSING=()
for flag in "${REQUIRED_FLAGS[@]}"; do
  if ! grep -qw "$flag" /proc/cpuinfo; then
    MISSING+=("$flag")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "❌ CPU não suporta x86-64-v3. Flags ausentes: ${MISSING[*]}" >&2
  echo "   Use linux-xanmod-x64v2 ou linux-xanmod-x64v1 conforme sua CPU." >&2
  exit 1
fi
echo "   OK - CPU compatível com x64v3."

########################################
# 1.2) Detectar se já está rodando XanMod
########################################
RUNNING_KERNEL="$(uname -r)"
if echo "$RUNNING_KERNEL" | grep -qi xanmod; then
  echo "⚠️  Já está rodando kernel XanMod ($RUNNING_KERNEL). Continuando mesmo assim..."
fi

########################################
# 1.3) Ajustar timezone
########################################
if command -v timedatectl >/dev/null 2>&1; then
  echo "==> Ajustando timezone para America/Sao_Paulo..."
  timedatectl set-timezone America/Sao_Paulo || true
fi

########################################
# 2) Atualizar nameserver em /etc/resolv.conf
########################################
echo "==> Atualizando nameserver em /etc/resolv.conf..."
if [ -L /etc/resolv.conf ]; then
  echo "   ⚠️  /etc/resolv.conf é symlink (gerenciado por systemd-resolved/NetworkManager)."
  echo "      Edição direta pode não persistir. Pulando."
else
  cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S)"
  if grep -qE '^nameserver[[:space:]]+' /etc/resolv.conf; then
    sed -ri 's/^nameserver[[:space:]]+.*/nameserver 8.8.8.8/' /etc/resolv.conf
  else
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

########################################
# 3) Desativar SWAP
########################################
echo "==> Desativando SWAP..."
swapoff -a || true

echo "==> Comentando entradas de swap em /etc/fstab..."
cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
sed -ri '/^[^#].*\bswap\b/ s/^/#/' /etc/fstab

########################################
# 4) Desabilitar espera de rede no boot
########################################
echo "==> Desativando systemd-networkd-wait-online.service..."
systemctl disable --now systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true

########################################
# 5) Remover UFW e iptables
########################################
echo "==> Removendo UFW..."
apt-get remove --purge "${APT_OPTS[@]}" ufw || true

echo "==> Removendo iptables (atenção: pode afetar Docker/fail2ban)..."
apt-get remove --purge "${APT_OPTS[@]}" iptables || true

########################################
# 6) Atualizar pacotes
########################################
echo "==> Atualizando repositórios e pacotes..."
apt-get update
apt-get upgrade "${APT_OPTS[@]}"

########################################
# 6.1) Instalar ferramentas básicas + dependências da blindagem
########################################
echo "==> Instalando ferramentas básicas..."
apt-get install "${APT_OPTS[@]}" \
  nload htop net-tools wget gpg ca-certificates \
  iproute2 iputils-ping

########################################
# 7) Configurar repositório XanMod
########################################
echo "==> Configurando repositório XanMod..."
mkdir -p /etc/apt/keyrings
rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg

TMPKEY="$(mktemp)"
trap 'rm -f "$TMPKEY"' EXIT

if ! wget -qO "$TMPKEY" https://dl.xanmod.org/archive.key; then
  echo "❌ Falha ao baixar a chave do XanMod." >&2
  exit 1
fi
if [ ! -s "$TMPKEY" ]; then
  echo "❌ Chave XanMod vazia ou corrompida." >&2
  exit 1
fi

gpg --batch --yes --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg < "$TMPKEY"
chmod 644 /etc/apt/keyrings/xanmod-archive-keyring.gpg

printf 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main\n' \
  > /etc/apt/sources.list.d/xanmod-release.list

########################################
# 8) Instalar kernel XanMod v3
########################################
echo "==> Instalando kernel XanMod v3..."
apt-get update
if ! apt-get install "${APT_OPTS[@]}" linux-xanmod-x64v3; then
  echo "❌ Falha ao instalar XanMod. Kernels antigos NÃO foram removidos." >&2
  exit 1
fi

########################################
# 9) Validar instalação do XanMod ANTES de prosseguir
########################################
echo "==> Validando instalação do XanMod..."
XANMOD_PKGS="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*xanmod*' 2>/dev/null | awk '/^ii/ {print $2}')"
if [ -z "$XANMOD_PKGS" ]; then
  echo "❌ Nenhum pacote linux-image-*xanmod* instalado. Abortando." >&2
  exit 1
fi
echo "   XanMod instalado: $XANMOD_PKGS"

if ! compgen -G "/boot/vmlinuz-*xanmod*" >/dev/null; then
  echo "❌ Imagem XanMod não encontrada em /boot. Abortando." >&2
  exit 1
fi

########################################
# 10) BLINDAGEM DE NICs (3 camadas)
########################################
echo "==> Blindando configuração de NICs contra renomeação..."

NETPLAN_DIR="/etc/netplan"
INTERFACES_FILE="/etc/network/interfaces"
LINK_DIR="/etc/systemd/network"
BACKUP_DIR="/root/network-backup-$(date +%Y%m%d-%H%M%S)"
ROLLBACK_SCRIPT="/usr/local/sbin/network-rollback.sh"
ROLLBACK_SERVICE="/etc/systemd/system/network-rollback.service"
ROLLBACK_TIMER="/etc/systemd/system/network-rollback.timer"
ROLLBACK_FLAG="/var/lib/network-rollback-state"

mkdir -p "$BACKUP_DIR" "$LINK_DIR" "$(dirname "$ROLLBACK_FLAG")"

# Detecta sistema(s) de configuração de rede em uso
HAS_NETPLAN=0
HAS_IFUPDOWN=0
if [ -d "$NETPLAN_DIR" ]; then
  if compgen -G "$NETPLAN_DIR/*.yaml" >/dev/null 2>&1 || \
     compgen -G "$NETPLAN_DIR/*.yml"  >/dev/null 2>&1; then
    HAS_NETPLAN=1
  fi
fi
if [ -f "$INTERFACES_FILE" ] && grep -qE '^\s*(iface|auto|allow-)' "$INTERFACES_FILE" 2>/dev/null; then
  HAS_IFUPDOWN=1
fi

echo "   Sistemas de rede detectados: Netplan=$HAS_NETPLAN, ifupdown=$HAS_IFUPDOWN"

# ---- Backup completo ----
echo "   Backup em: $BACKUP_DIR"
if [ -d "$NETPLAN_DIR" ]; then
  cp -a "$NETPLAN_DIR" "$BACKUP_DIR/netplan"
else
  mkdir -p "$BACKUP_DIR/netplan"
fi
if [ -f "$INTERFACES_FILE" ]; then
  cp -a "$INTERFACES_FILE" "$BACKUP_DIR/interfaces"
fi
if [ -d "$LINK_DIR" ]; then
  cp -a "$LINK_DIR" "$BACKUP_DIR/systemd-network"
else
  mkdir -p "$BACKUP_DIR/systemd-network"
fi
ip link show  > "$BACKUP_DIR/ip-link-pre.txt"
ip addr show  > "$BACKUP_DIR/ip-addr-pre.txt"
ip route show > "$BACKUP_DIR/routes-pre.txt"
echo "$RUNNING_KERNEL" > "$BACKUP_DIR/old-kernel.txt"

# Backup do grub.cfg para restauração de emergência
if [ -f /boot/grub/grub.cfg ]; then
  cp -a /boot/grub/grub.cfg "$BACKUP_DIR/grub.cfg.bak"
fi

# Cleanup em caso de erro durante a blindagem
blindagem_cleanup_on_error() {
  local rc=$?
  echo "   ⚠️  Erro durante blindagem (rc=$rc). Restaurando estado original..." >&2
  rm -f "$LINK_DIR"/10-persist-*.link 2>/dev/null || true
  if [ "$HAS_NETPLAN" = "1" ] && [ -d "$BACKUP_DIR/netplan" ]; then
    rm -f "$NETPLAN_DIR"/*.yaml "$NETPLAN_DIR"/*.yml 2>/dev/null || true
    cp -a "$BACKUP_DIR/netplan/." "$NETPLAN_DIR/" 2>/dev/null || true
  fi
  if [ "$HAS_IFUPDOWN" = "1" ] && [ -f "$BACKUP_DIR/interfaces" ]; then
    cp -a "$BACKUP_DIR/interfaces" "$INTERFACES_FILE" 2>/dev/null || true
  fi
  return $rc
}

# ---- Coletar NICs físicas ativas ----
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

  # ---- Camada 2a: Netplan ----
  if [ "$HAS_NETPLAN" = "1" ]; then
    echo "   [2/3] Netplan detectado - validando configuração existente (sem alterar)..."
    if ! netplan generate 2>/tmp/netplan-err.log; then
      echo "   ⚠️  netplan generate retornou erro (config existente):" >&2
      cat /tmp/netplan-err.log >&2 || true
    fi
  fi

  # ---- Camada 2b: ifupdown (/etc/network/interfaces) ----
  if [ "$HAS_IFUPDOWN" = "1" ]; then
    echo "   [2/3] Adicionando hwaddress (MAC) em /etc/network/interfaces..."
    cp -a "$INTERFACES_FILE" "${INTERFACES_FILE}.bak-prexanmod"

    for nic in "${PHYSICAL_NICS[@]}"; do
      mac="${NIC_MAC[$nic]}"
      if grep -qE "^\s*iface\s+${nic}\s+" "$INTERFACES_FILE"; then
        # Verifica se já existe hwaddress para este iface
        if ! awk -v n="$nic" -v m="$mac" '
          /^[[:space:]]*iface[[:space:]]+/ { in_block = ($2 == n) ? 1 : 0 }
          in_block && /^[[:space:]]*hwaddress[[:space:]]+ether[[:space:]]+/ {
            if (tolower($3) == tolower(m)) found = 1
          }
          END { exit (found ? 0 : 1) }
        ' "$INTERFACES_FILE"; then
          sed -ri "/^[[:space:]]*iface[[:space:]]+${nic}[[:space:]]+/a\\    hwaddress ether ${mac}" "$INTERFACES_FILE"
          echo "      ${nic}: hwaddress ether ${mac} adicionado"
        fi
      fi
    done
  fi

  # ---- Camada 3: initramfs ----
  echo "   [3/3] Atualizando initramfs..."
  if command -v update-initramfs >/dev/null 2>&1; then
    # Pipe quebra pipefail: capturamos saída em arquivo e exibimos depois.
    # Failure aqui não deve disparar o trap de cleanup (warnings são comuns).
    if update-initramfs -u -k all > /tmp/initramfs.log 2>&1; then
      tail -5 /tmp/initramfs.log
    else
      echo "      ⚠️  update-initramfs retornou erro (pode ser warning não-fatal):"
      tail -10 /tmp/initramfs.log
      echo "      Continuando — .link files ainda funcionam fora do initramfs."
    fi
  fi

  # Restaura trap ERR padrão (não remove — caso erros aconteçam mais tarde)
  trap 'on_error_default $LINENO' ERR
  echo "   ✅ Blindagem aplicada com sucesso."
fi

########################################
# 11) Rollback automático pós-boot
########################################
echo "==> Instalando rollback automático pós-boot..."

cat > "$ROLLBACK_SCRIPT" <<'ROLLBACK_EOF'
#!/usr/bin/env bash
# Executado 5min após o boot. Se rede não funcional, restaura tudo
# e força próximo boot no kernel antigo via grub-reboot.
#
# Kill switch: criar /etc/network-rollback.disable cancela o rollback.
set -u
LOG=/var/log/network-rollback.log
exec >> "$LOG" 2>&1

BACKUP_DIR="__BACKUP_DIR__"
OLD_KERNEL="__OLD_KERNEL__"
FLAG="__ROLLBACK_FLAG__"
HAS_NETPLAN="__HAS_NETPLAN__"
HAS_IFUPDOWN="__HAS_IFUPDOWN__"
KILL_SWITCH="/etc/network-rollback.disable"

echo "[$(date -Iseconds)] verificação pós-boot iniciada (kernel: $(uname -r))"

# Kill switch manual: usuário pode desabilitar criando o arquivo
if [ -f "$KILL_SWITCH" ]; then
  echo "[$(date -Iseconds)] kill switch presente ($KILL_SWITCH), abortando rollback"
  echo "ok" > "$FLAG"
  systemctl disable network-rollback.timer >/dev/null 2>&1 || true
  exit 0
fi

# Idempotência: se já validamos um boot OK, sair
if [ -f "$FLAG" ] && grep -q '^ok$' "$FLAG" 2>/dev/null; then
  echo "[$(date -Iseconds)] boot já validado anteriormente, saindo"
  systemctl disable network-rollback.timer >/dev/null 2>&1 || true
  exit 0
fi

# Se a flag está em "rolling-back", significa que rollback foi acionado num boot
# anterior. Estamos agora no kernel antigo provavelmente. Apenas valida e marca ok.
if [ -f "$FLAG" ] && grep -q '^rolling-back$' "$FLAG" 2>/dev/null; then
  echo "[$(date -Iseconds)] estado pós-rollback detectado, validando rede atual"
  sleep 30
  if [ -n "$(ip -4 route show default 2>/dev/null)" ]; then
    echo "[$(date -Iseconds)] rede OK após rollback, marcando validado"
    echo "ok" > "$FLAG"
    systemctl disable network-rollback.timer >/dev/null 2>&1 || true
  fi
  exit 0
fi

# Detecta se estamos no kernel XanMod. Se não estamos, rollback não faz sentido
# (pode ser uma manutenção manual rebootando no kernel antigo).
CURRENT_KERNEL="$(uname -r)"
if ! echo "$CURRENT_KERNEL" | grep -qi xanmod; then
  echo "[$(date -Iseconds)] kernel atual não é XanMod ($CURRENT_KERNEL), rollback desnecessário"
  echo "ok" > "$FLAG"
  systemctl disable network-rollback.timer >/dev/null 2>&1 || true
  exit 0
fi

# Aguarda rede estabilizar (até 60s extras)
for _ in $(seq 1 12); do
  if [ -n "$(ip -4 route show default 2>/dev/null)" ]; then break; fi
  sleep 5
done

# Valida rota default + ping no gateway
GW="$(ip -4 route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
if [ -n "$GW" ] && ping -c 2 -W 2 "$GW" >/dev/null 2>&1; then
  echo "[$(date -Iseconds)] OK: rota default ($GW) + conectividade. Marcando validado."
  echo "ok" > "$FLAG"
  systemctl disable network-rollback.timer >/dev/null 2>&1 || true
  exit 0
fi

echo "[$(date -Iseconds)] FALHA: rede não funcional no XanMod, executando rollback"
echo "rolling-back" > "$FLAG"

# Restaura Netplan
if [ "$HAS_NETPLAN" = "1" ] && [ -d "$BACKUP_DIR/netplan" ]; then
  rm -f /etc/netplan/*.yaml /etc/netplan/*.yml 2>/dev/null || true
  cp -a "$BACKUP_DIR/netplan/." /etc/netplan/ 2>/dev/null || true
  echo "[$(date -Iseconds)] Netplan restaurado"
fi

# Restaura /etc/network/interfaces
if [ "$HAS_IFUPDOWN" = "1" ] && [ -f "$BACKUP_DIR/interfaces" ]; then
  cp -a "$BACKUP_DIR/interfaces" /etc/network/interfaces 2>/dev/null || true
  echo "[$(date -Iseconds)] /etc/network/interfaces restaurado"
fi

# Remove .link files que criamos
rm -f /etc/systemd/network/10-persist-*.link 2>/dev/null || true

# Restaura .link files originais
if [ -d "$BACKUP_DIR/systemd-network" ]; then
  cp -a "$BACKUP_DIR/systemd-network/." /etc/systemd/network/ 2>/dev/null || true
fi

# Força próximo boot no kernel antigo
GRUB_REBOOT_OK=0
if command -v grub-reboot >/dev/null 2>&1 && [ -n "$OLD_KERNEL" ]; then
  ENTRY=$(awk -F"'" '/^[[:space:]]*menuentry / {print $2}' /boot/grub/grub.cfg 2>/dev/null \
          | grep -F "$OLD_KERNEL" | head -1)
  if [ -n "$ENTRY" ]; then
    # Tenta com submenu primeiro (caminho mais comum no Ubuntu)
    if grub-reboot "Advanced options for Ubuntu>$ENTRY" 2>>"$LOG"; then
      echo "[$(date -Iseconds)] grub-reboot OK (submenu Ubuntu): $ENTRY"
      GRUB_REBOOT_OK=1
    elif grub-reboot "$ENTRY" 2>>"$LOG"; then
      echo "[$(date -Iseconds)] grub-reboot OK (raiz): $ENTRY"
      GRUB_REBOOT_OK=1
    else
      echo "[$(date -Iseconds)] ❌ grub-reboot falhou para entrada: $ENTRY"
    fi
  else
    echo "[$(date -Iseconds)] ⚠️  entrada do GRUB para $OLD_KERNEL não encontrada"
  fi
fi

# Se grub-reboot falhou, tenta restaurar grub.cfg do backup como último recurso
if [ "$GRUB_REBOOT_OK" = "0" ] && [ -f "$BACKUP_DIR/grub.cfg.bak" ]; then
  echo "[$(date -Iseconds)] tentando restaurar grub.cfg do backup como fallback"
  cp -a "$BACKUP_DIR/grub.cfg.bak" /boot/grub/grub.cfg 2>>"$LOG" || true
fi

update-initramfs -u 2>/dev/null || true

echo "[$(date -Iseconds)] rollback aplicado, reiniciando em 1 min"
shutdown -r +1 "Rollback de rede aplicado pelo network-rollback.service"
ROLLBACK_EOF

# Substitui placeholders
sed -i \
  -e "s|__BACKUP_DIR__|$BACKUP_DIR|g" \
  -e "s|__OLD_KERNEL__|$RUNNING_KERNEL|g" \
  -e "s|__ROLLBACK_FLAG__|$ROLLBACK_FLAG|g" \
  -e "s|__HAS_NETPLAN__|$HAS_NETPLAN|g" \
  -e "s|__HAS_IFUPDOWN__|$HAS_IFUPDOWN|g" \
  "$ROLLBACK_SCRIPT"

chmod +x "$ROLLBACK_SCRIPT"

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
echo "   Timer ativo: validação em 5min, rollback automático se falhar."

########################################
# 12) Remover kernels antigos (preservando XanMod e o em execução)
########################################
echo "==> Procurando kernels antigos para remover..."

mapfile -t OLD_KERNELS < <(
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 'linux-headers-*' 'linux-modules-*' 2>/dev/null \
    | awk '/^ii/ {print $2}' \
    | grep -v -- '-xanmod' \
    | grep -v "${RUNNING_KERNEL}$" \
    | grep -vE '^(linux-image|linux-headers)$' || true
)

if [ "${#OLD_KERNELS[@]}" -gt 0 ]; then
  echo "   Removendo: ${OLD_KERNELS[*]}"
  apt-get remove --purge "${APT_OPTS[@]}" "${OLD_KERNELS[@]}" || true
else
  echo "   Nenhum kernel antigo encontrado para remover."
fi

########################################
# 13) Limpeza final
########################################
echo "==> Limpeza final..."
apt-get autoremove --purge "${APT_OPTS[@]}"
apt-get autoclean "${APT_OPTS[@]}"

########################################
# 14) Atualizar GRUB
########################################
echo "==> Atualizando GRUB..."
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

########################################
# Conclusão
########################################
INSTALLED_XANMOD="$(find /boot -maxdepth 1 -name 'vmlinuz-*xanmod*' -printf '%f\n' 2>/dev/null | sed 's|^vmlinuz-||' | sort | tail -1)"

cat <<EOF

✅ Instalação concluída!

   Kernel atual (em execução): $RUNNING_KERNEL
   Kernel XanMod instalado:    ${INSTALLED_XANMOD:-não detectado}
   Backup de rede:             $BACKUP_DIR
   Log da instalação:          $LOG
   Log do rollback:            /var/log/network-rollback.log

🛡️  PROTEÇÕES ATIVAS:
   • .link files congelando nomes de NIC via MAC (camada principal)
   • /etc/network/interfaces com hwaddress (se aplicável)
   • Netplan: NÃO modificado (validação apenas)
   • initramfs atualizado
   • Rollback automático 5min pós-boot se rede não subir
     - Só dispara se kernel atual for XanMod
     - Kill switch: criar /etc/network-rollback.disable cancela

⚠️  Após o reboot:
   1. Aguarde no mínimo 7 minutos antes de assumir falha
      (5min do timer + 1min reboot do rollback + ~1min boot)
   2. Valide com:  uname -r && ip -br link && ip route
   3. Se for fazer manutenção que derruba a rede dentro dos 5min:
      sudo touch /etc/network-rollback.disable
   4. Se tudo OK, remova o backup:  rm -rf $BACKUP_DIR

   Reiniciar agora:  sudo reboot

EOF
