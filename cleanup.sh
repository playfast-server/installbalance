#!/bin/bash
# =============================================================================
# cleanup-services.sh
#
# Desativa services desnecessários e remove pacotes inúteis em servidor de
# streaming dedicado (Xui One).
#
# NÃO MEXE EM:
#   - GRUB / cmdline do kernel
#   - netplan / cloud-init / systemd-networkd / systemd-resolved
#   - netfilter / iptables / nftables / conntrack / libs de netfilter
#   - sysctl / mlnx_tune / driver Mellanox
#   - HPC / OpenMPI / compiladores (necessários para OFED --hpc)
#   - CPU governor / IRQ affinity / performance tuning
#     (esses ficam por conta do script de tuning Mellanox)
#   - intel-microcode (necessário para errata/mitigations em CPUs Intel)
#   - udisks2 (preservado — pode ser dependência de ferramentas de storage)
#
# Uso: sudo ./cleanup-services.sh
# =============================================================================

set -u

if [[ $EUID -ne 0 ]]; then
    echo "❌ Execute como root" >&2
    exit 1
fi

# ---------- Helpers ----------

# Verifica se uma unit (service/timer/socket) existe no sistema
unit_exists() {
    systemctl list-unit-files --no-pager --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | grep -Fxq "$1"
}

stop_disable_mask() {
    local svc="$1"
    if unit_exists "$svc"; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        systemctl mask "$svc" 2>/dev/null || true
        echo "   ✓ $svc"
    fi
}

# Para um service E seu timer correspondente, se existirem
stop_disable_mask_pair() {
    local base="$1"
    stop_disable_mask "${base}.timer"
    stop_disable_mask "${base}.service"
}

purge_if_installed() {
    local pkg="$1"
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        local rc=0
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "$pkg" >/tmp/cleanup-purge.log 2>&1 || rc=$?
        if (( rc == 0 )); then
            echo "   ✓ purge: $pkg"
        else
            echo "   ⚠️  purge falhou: $pkg (ver /tmp/cleanup-purge.log)"
        fi
    fi
}

# Verifica se LXD tem containers (sem casar com header da tabela vazia)
lxd_has_containers() {
    if ! command -v lxc >/dev/null 2>&1; then
        return 1
    fi
    # Usar formato CSV — fica vazio se sem containers, sem header
    local count
    count=$(lxc list --format=csv 2>/dev/null | wc -l)
    (( count > 0 ))
}

echo "=================================================================="
echo "🧹 Limpeza de services e pacotes — Xui One"
echo "=================================================================="
echo ""

# Verifica estado inicial do xuione (fail-fast)
if systemctl list-unit-files --no-pager 2>/dev/null | grep -q '^xuione.service'; then
    if systemctl is-active --quiet xuione.service; then
        echo "Estado inicial: xuione.service ATIVO"
    else
        echo "⚠️  AVISO: xuione.service NÃO está ativo no início."
        echo "    Continue apenas se for proposital. Pressione Ctrl+C para abortar"
        echo "    ou aguarde 5 segundos para prosseguir..."
        sleep 5
    fi
else
    echo "ℹ️  xuione.service não instalado (continuando mesmo assim)"
fi
echo ""

# =============================================================================
# 1. SERVICES — Hardware ausente
# =============================================================================
echo "━━ 1. Hardware ausente ━━"
stop_disable_mask ModemManager.service
stop_disable_mask bolt.service
echo ""

# =============================================================================
# 2. SERVICES — Telemetria Ubuntu
# =============================================================================
echo "━━ 2. Telemetria Ubuntu ━━"
stop_disable_mask apport.service
stop_disable_mask motd-news.service
stop_disable_mask ubuntu-advantage.service
stop_disable_mask kerneloops.service
stop_disable_mask whoopsie.service
echo ""

# =============================================================================
# 3. SERVICES — Updates automáticos
# =============================================================================
echo "━━ 3. Updates automáticos ━━"
stop_disable_mask unattended-upgrades.service
stop_disable_mask packagekit.service
echo ""

# =============================================================================
# 4. SERVICES — Snap (verifica LXD primeiro)
# =============================================================================
echo "━━ 4. Snap ━━"
HAS_LXD=0
if lxd_has_containers; then
    HAS_LXD=1
    echo "   ⚠️  LXD tem containers ativos — snapd NÃO será removido"
fi

if (( HAS_LXD == 0 )); then
    # Remove snaps em ordem (lxd, core20, depois snapd)
    if command -v snap >/dev/null 2>&1; then
        for snap_name in lxd core20 core snapd; do
            if snap list "$snap_name" >/dev/null 2>&1; then
                if snap remove "$snap_name" 2>/dev/null; then
                    echo "   ✓ snap removido: $snap_name"
                fi
            fi
        done
    fi
    stop_disable_mask snapd.service
    stop_disable_mask snapd.socket
    stop_disable_mask snapd.seeded.service
fi
echo ""

# =============================================================================
# 5. TIMERS + SERVICES de manutenção (parear timer e service)
# =============================================================================
echo "━━ 5. Timers + services de manutenção/updates ━━"
stop_disable_mask_pair apt-daily
stop_disable_mask_pair apt-daily-upgrade
stop_disable_mask_pair motd-news
stop_disable_mask_pair fwupd-refresh
stop_disable_mask_pair update-notifier-download
stop_disable_mask_pair update-notifier-motd
stop_disable_mask_pair man-db
stop_disable_mask ua-timer.timer
echo ""

# Mantidos: fstrim.timer (TRIM SSD), e2scrub_all.timer (scrub ext4),
#           logrotate.timer, systemd-tmpfiles-clean.timer (limpa /tmp),
#           phpsessionclean.timer (Xui PHP), certbot.timer (Let's Encrypt)

# =============================================================================
# 5b. SERVICES — Substituídos pelo tuning Mellanox/Intel ou journald
# =============================================================================
# - irqbalance: substituído pelo IRQ pinning manual do nic_tune.sh (conflita
#               com a afinidade fixa configurada por NUMA/RSS).
# - rsyslog:    duplicaria os logs do systemd-journald (overhead de I/O em
#               servidor de streaming com alta vazão).
echo "━━ 5b. Services substituídos (irqbalance, rsyslog) ━━"
stop_disable_mask irqbalance.service
stop_disable_mask rsyslog.service
echo ""

# =============================================================================
# 6. PACOTES — Hardware ausente / telemetria
# =============================================================================
echo "━━ 6. Pacotes — hardware ausente / telemetria ━━"
purge_if_installed modemmanager
purge_if_installed bolt
purge_if_installed apport
purge_if_installed apport-symptoms
purge_if_installed popularity-contest
purge_if_installed ubuntu-advantage-tools
purge_if_installed whoopsie
purge_if_installed kerneloops
echo ""

# =============================================================================
# 7. PACOTES — Updates automáticos
# =============================================================================
echo "━━ 7. Pacotes — updates automáticos ━━"
purge_if_installed unattended-upgrades
echo ""

# =============================================================================
# 8. PACOTES — Snap
# =============================================================================
if (( HAS_LXD == 0 )); then
    echo "━━ 8. Pacotes — snap ━━"
    purge_if_installed snapd
    rm -rf /var/cache/snapd /root/snap /var/lib/snapd 2>/dev/null
    rm -rf /home/*/snap 2>/dev/null
    echo ""
fi

# =============================================================================
# 9. PACOTES — Outros irrelevantes
# =============================================================================
echo "━━ 9. Pacotes — irrelevantes ━━"
purge_if_installed byobu
purge_if_installed irqbalance
purge_if_installed rsyslog
echo ""

# =============================================================================
# 10. PACOTES — Todos os kernels que não estão em uso
# =============================================================================
echo "━━ 10. Kernels antigos (todos exceto o em uso) ━━"
CURRENT_KERNEL=$(uname -r)
echo "   Kernel atual: $CURRENT_KERNEL (preservado)"

# Coleta todas as VERSÕES de kernel instaladas (linux-image-X.Y.Z-NNN-flavor),
# excluindo meta-pacotes (linux-image-generic, linux-image-generic-hwe-*).
# Glob 'linux-image-[0-9]*' já filtra meta-pacotes (não começam com dígito).
mapfile -t OLD_KERNELS < <(
    dpkg -l 'linux-image-[0-9]*' 2>/dev/null \
        | awk '/^ii/{print $2}' \
        | grep -Fxv "linux-image-${CURRENT_KERNEL}"
)

# Coleta também versões soltas (modules/headers sem o linux-image correspondente)
# Isso captura "lixo" deixado por upgrades anteriores
mapfile -t ORPHAN_VERSIONS < <(
    {
        dpkg -l 'linux-modules-[0-9]*'       2>/dev/null | awk '/^ii/{print $2}' | sed 's/^linux-modules-//'
        dpkg -l 'linux-modules-extra-[0-9]*' 2>/dev/null | awk '/^ii/{print $2}' | sed 's/^linux-modules-extra-//'
        dpkg -l 'linux-headers-[0-9]*'       2>/dev/null | awk '/^ii/{print $2}' | sed 's/^linux-headers-//'
        dpkg -l 'linux-image-[0-9]*'         2>/dev/null | awk '/^ii/{print $2}' | sed 's/^linux-image-//'
        dpkg -l 'linux-hwe-[0-9.]*-headers-[0-9]*' 2>/dev/null | awk '/^ii/{print $2}' | sed 's/^linux-hwe-[0-9.]*-headers-//'
    } | sort -u | grep -Fxv "$CURRENT_KERNEL"
)

if (( ${#OLD_KERNELS[@]} == 0 && ${#ORPHAN_VERSIONS[@]} == 0 )); then
    echo "   Nenhum kernel antigo para remover"
else
    # Loop principal: para cada versão antiga, remove TUDO que existe dela
    declare -A SEEN_VERSIONS=()
    for kimg in "${OLD_KERNELS[@]}"; do
        ver="${kimg#linux-image-}"
        SEEN_VERSIONS["$ver"]=1
    done
    for ver in "${ORPHAN_VERSIONS[@]}"; do
        SEEN_VERSIONS["$ver"]=1
    done

    for ver in "${!SEEN_VERSIONS[@]}"; do
        # Defesa em profundidade: nunca remove o kernel atual
        if [[ "$ver" == "$CURRENT_KERNEL" ]]; then
            continue
        fi
        echo "   removendo versão: $ver"
        purge_if_installed "linux-image-${ver}"
        purge_if_installed "linux-image-${ver}-dbg"
        purge_if_installed "linux-modules-${ver}"
        purge_if_installed "linux-modules-extra-${ver}"
        purge_if_installed "linux-headers-${ver}"
        purge_if_installed "linux-tools-${ver}"
        purge_if_installed "linux-cloud-tools-${ver}"
        purge_if_installed "linux-buildinfo-${ver}"
        # linux-headers-X.Y.Z-NNN (sufixo sem -generic/-aws/etc)
        if [[ "$ver" == *-generic ]]; then
            purge_if_installed "linux-headers-${ver%-generic}"
            # HWE backports (Ubuntu)
            base_ver="${ver%-generic}"
            kver="${base_ver%-*}"   # ex: 5.15.0
            kmajor="${kver%.*}"     # ex: 5.15
            purge_if_installed "linux-hwe-${kmajor}-headers-${base_ver}"
            purge_if_installed "linux-hwe-${kmajor}-tools-${base_ver}"
        fi
    done

    # Limpa /lib/modules/<versão> e /boot/* que ficaram órfãos
    echo ""
    echo "   Limpando arquivos órfãos em /boot e /lib/modules..."
    for d in /lib/modules/*/; do
        modver=$(basename "$d")
        if [[ "$modver" != "$CURRENT_KERNEL" ]] && ! dpkg -l "linux-modules-${modver}" 2>/dev/null | grep -q '^ii'; then
            echo "   rm -rf /lib/modules/${modver}"
            rm -rf "$d"
        fi
    done
    for f in /boot/vmlinuz-* /boot/initrd.img-* /boot/config-* /boot/System.map-*; do
        [[ -e "$f" ]] || continue
        bver=$(basename "$f" | sed -E 's/^(vmlinuz|initrd\.img|config|System\.map)-//')
        if [[ "$bver" != "$CURRENT_KERNEL" ]] && ! dpkg -l "linux-image-${bver}" 2>/dev/null | grep -q '^ii'; then
            echo "   rm $f"
            rm -f "$f"
        fi
    done

    # Atualiza grub.cfg para remover entradas de kernels removidos
    if command -v update-grub >/dev/null 2>&1; then
        echo "   Rodando update-grub para limpar entradas de boot..."
        update-grub 2>&1 | tail -3
    fi
fi
echo ""

# =============================================================================
# 11. Marcar libs sensíveis como manuais (saem do autoremove)
# =============================================================================
# Protege contra apt autoremove acidentalmente remover libs de netfilter
# que podem ser usadas por mlnx_tune ou outras ferramentas
echo "━━ 11. Protegendo libs de netfilter contra autoremove ━━"
for pkg in libip6tc2 libnetfilter-conntrack3 libnfnetlink0 libnftnl11 \
           netfilter-persistent iptables nftables conntrack; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        apt-mark manual "$pkg" >/dev/null 2>&1
        echo "   ✓ $pkg marcado como manual"
    fi
done
echo ""

# =============================================================================
# 12. Limpeza apt
# =============================================================================
echo "━━ 12. Limpeza apt ━━"
apt-get clean 2>&1 | tail -1
echo ""

# NOTA: NÃO rodamos 'apt autoremove' porque ele tenta remover libs de netfilter

# =============================================================================
# 12b. Limpeza systemd (resíduos de services removidos)
# =============================================================================
echo "━━ 12b. Limpeza systemd ━━"

# Remove unit files órfãos do snap (deixados quando snapd foi removido)
SNAP_LEFTOVERS=$(find /etc/systemd /run/systemd /lib/systemd /var/lib/systemd \
    -name 'snap.*' -o -name 'snapd.*' 2>/dev/null)
if [[ -n "$SNAP_LEFTOVERS" ]]; then
    echo "$SNAP_LEFTOVERS" | while read -r f; do
        [[ -e "$f" ]] && rm -rf "$f" && echo "   removido: $f"
    done
fi

# Limpa estado "failed" de qualquer service que ficou pendurado
FAILED_BEFORE=$(systemctl list-units --type=service --state=failed --no-legend --no-pager 2>/dev/null | awk '{print $2}')
if [[ -n "$FAILED_BEFORE" ]]; then
    systemctl reset-failed 2>/dev/null || true
    echo "   reset-failed executado em $(echo "$FAILED_BEFORE" | wc -l) service(s)"
fi

# Recarrega systemd para refletir mudanças
systemctl daemon-reload 2>/dev/null || true
echo ""

# =============================================================================
# 13. Verificações finais
# =============================================================================
echo "=================================================================="
echo "📋 Verificação final"
echo "=================================================================="

echo ""
echo "Services failed:"
FAILED_COUNT=$(systemctl list-units --type=service --state=failed --no-legend --no-pager 2>/dev/null | wc -l)
if (( FAILED_COUNT == 0 )); then
    echo "   ✓ Nenhum service em estado failed"
else
    systemctl list-units --type=service --state=failed --no-legend --no-pager
fi
echo ""

echo "Status do xuione:"
if systemctl is-active --quiet xuione.service; then
    echo "   ✓ xuione.service ATIVO"
else
    echo "   ❌ xuione.service NÃO está ativo"
fi
echo ""

echo "Services rodando: $(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | wc -l)"
echo "Timers ativos:    $(systemctl list-timers --no-legend --no-pager 2>/dev/null | wc -l)"
echo ""

echo "Memória:"
free -h | awk '/^Mem:/{print "   " $3 " usado / " $2 " total"}'
echo ""

echo "Disco /:"
df -h / | awk 'NR==2{print "   " $3 " usado / " $2 " total (" $5 ")"}'
echo ""

echo "🎉 Limpeza concluída."
echo ""
echo "NOTA: GRUB, netplan, cloud-init, netfilter, sysctl e mlnx_tune"
echo "      foram preservados intactos."
