#!/usr/bin/env bash
# install_xanmod.sh - Prepara o sistema e instala o kernel XanMod v3
#
# ATENÇÃO: Este script remove TODOS os kernels existentes antes de instalar
# o XanMod. Se a instalação do XanMod falhar, o servidor ficará sem kernel
# bootável. NÃO REINICIE em caso de falha.
#
# Compatível com Ubuntu/Debian.

set -euo pipefail
IFS=$'\n\t'

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
# 5) Atualizar pacotes
########################################
echo "==> Atualizando repositórios e pacotes..."
apt-get update
apt-get upgrade "${APT_OPTS[@]}"

########################################
# 5.1) Instalar ferramentas básicas
########################################
echo "==> Instalando ferramentas básicas..."
apt-get install "${APT_OPTS[@]}" \
  nload htop net-tools wget gpg ca-certificates

########################################
# 6) Configurar repositório XanMod
########################################
echo "==> Configurando repositório XanMod..."
mkdir -p /etc/apt/keyrings
rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg

TMPKEY="$(mktemp)"
trap 'rm -f "$TMPKEY"' EXIT

if ! wget --timeout=30 --tries=2 -qO "$TMPKEY" https://dl.xanmod.org/archive.key; then
  echo "❌ Falha ao baixar a chave do XanMod (timeout ou rede)." >&2
  exit 1
fi
if [ ! -s "$TMPKEY" ]; then
  echo "❌ Chave XanMod vazia ou corrompida." >&2
  exit 1
fi

gpg --batch --yes --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg < "$TMPKEY"
chmod 644 /etc/apt/keyrings/xanmod-archive-keyring.gpg
rm -f "$TMPKEY"
trap - EXIT

printf 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main\n' \
  > /etc/apt/sources.list.d/xanmod-release.list

########################################
# 7) Remover TODOS os kernels antes da instalação do XanMod
########################################
echo "==> Removendo todos os kernels instalados..."

mapfile -t ALL_KERNELS < <(
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 'linux-headers-*' 'linux-modules-*' 2>/dev/null \
    | awk '/^ii/ {print $2}' \
    | grep -vE '^(linux-image|linux-headers)$' || true
)

if [ "${#ALL_KERNELS[@]}" -gt 0 ]; then
  echo "   Removendo: ${ALL_KERNELS[*]}"
  if ! apt-get remove --purge "${APT_OPTS[@]}" "${ALL_KERNELS[@]}"; then
    echo "❌ Falha ao remover kernels existentes. Abortando." >&2
    exit 1
  fi
else
  echo "   Nenhum kernel encontrado para remover."
fi

########################################
# 8) Instalar kernel XanMod v3
########################################
echo "==> Verificando espaço em /boot..."
BOOT_FREE_MB=$(df -BM --output=avail /boot 2>/dev/null | awk 'NR==2 {gsub("M",""); print $1}')
if [ -n "${BOOT_FREE_MB:-}" ] && [ "$BOOT_FREE_MB" -lt 250 ]; then
  echo "❌ Espaço em /boot insuficiente: ${BOOT_FREE_MB}MB livres (mínimo 250MB)." >&2
  exit 1
fi
echo "   /boot tem ${BOOT_FREE_MB:-?}MB livres."

echo "==> Instalando kernel XanMod v3..."
apt-get update
if ! apt-get install "${APT_OPTS[@]}" linux-xanmod-x64v3; then
  echo "❌ Falha ao instalar XanMod. ATENÇÃO: nenhum kernel está instalado!" >&2
  echo "   NÃO REINICIE o servidor. Investigue e instale um kernel manualmente." >&2
  exit 1
fi

########################################
# 9) Validar instalação do XanMod
########################################
echo "==> Validando instalação do XanMod..."
XANMOD_PKGS="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*xanmod*' 2>/dev/null | awk '/^ii/ {print $2}')"
if [ -z "$XANMOD_PKGS" ]; then
  echo "❌ Nenhum pacote linux-image-*xanmod* instalado." >&2
  echo "   ATENÇÃO: nenhum kernel pode estar disponível. NÃO REINICIE." >&2
  exit 1
fi
echo "   XanMod instalado: $XANMOD_PKGS"

if ! compgen -G "/boot/vmlinuz-*xanmod*" >/dev/null; then
  echo "❌ Imagem XanMod não encontrada em /boot." >&2
  echo "   ATENÇÃO: NÃO REINICIE o servidor." >&2
  exit 1
fi

########################################
# 10) Limpeza final
########################################
echo "==> Limpeza final..."
apt-get autoremove --purge "${APT_OPTS[@]}"
apt-get autoclean "${APT_OPTS[@]}"

########################################
# Conclusão
########################################
INSTALLED_XANMOD="$(find /boot -maxdepth 1 -name 'vmlinuz-*xanmod*' -printf '%f\n' 2>/dev/null | sed 's|^vmlinuz-||' | sort -V | tail -1)"

cat <<EOF

✅ Instalação concluída!

   Kernel atual (em execução): $RUNNING_KERNEL
   Kernel XanMod instalado:    ${INSTALLED_XANMOD:-não detectado}
   Log da instalação:          $LOG

⚠️  Após o reboot:
   1. Valide com:  uname -r && ip -br link && ip route
   2. Se a rede não subir, será necessário acesso fora-de-banda
      (console KVM/IPMI) para corrigir manualmente

   Reiniciar agora:  sudo reboot

EOF
