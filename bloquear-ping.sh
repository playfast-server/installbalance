#!/usr/bin/env bash
# =============================================================
#  bloquear-ping.sh
#  Cria um serviço systemd que bloqueia respostas a ping (ICMP echo)
#  em IPv4 e IPv6 no Ubuntu 24.04.
#
#  Uso:
#    sudo ./bloquear-ping.sh instalar     -> cria, habilita e inicia o serviço
#    sudo ./bloquear-ping.sh remover      -> para, desabilita e remove o serviço
#    sudo ./bloquear-ping.sh status       -> mostra o estado atual
# =============================================================

set -euo pipefail

# Configurações (definidas aqui mesmo, sem arquivo externo)
NOME_SERVICO="bloquear-ping"
ARQUIVO_SERVICO="/etc/systemd/system/${NOME_SERVICO}.service"

verificar_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Erro: execute como root (use sudo)."
        exit 1
    fi
}

instalar() {
    verificar_root
    echo ">> Criando o serviço em ${ARQUIVO_SERVICO}..."

    cat > "$ARQUIVO_SERVICO" <<'EOF'
[Unit]
Description=Bloqueia respostas a ping (ICMP echo) em IPv4 e IPv6
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/sysctl -w net.ipv4.icmp_echo_ignore_all=1
ExecStart=-/usr/sbin/sysctl -w net.ipv6.icmp.echo_ignore_all=1
ExecStop=/usr/sbin/sysctl -w net.ipv4.icmp_echo_ignore_all=0
ExecStop=-/usr/sbin/sysctl -w net.ipv6.icmp.echo_ignore_all=0

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$ARQUIVO_SERVICO"

    echo ">> Recarregando o systemd..."
    systemctl daemon-reload

    echo ">> Habilitando e iniciando o serviço..."
    systemctl enable --now "${NOME_SERVICO}.service"

    echo ">> Pronto! Ping bloqueado."
    status
}

remover() {
    verificar_root
    echo ">> Parando e desabilitando o serviço..."
    systemctl disable --now "${NOME_SERVICO}.service" 2>/dev/null || true

    echo ">> Removendo ${ARQUIVO_SERVICO}..."
    rm -f "$ARQUIVO_SERVICO"
    systemctl daemon-reload

    echo ">> Pronto! Ping liberado novamente."
    status
}

status() {
    echo
    echo "Serviço: $(systemctl is-active "${NOME_SERVICO}.service" 2>/dev/null || echo inativo)"
    echo "Habilitado no boot: $(systemctl is-enabled "${NOME_SERVICO}.service" 2>/dev/null || echo nao)"
    echo "IPv4 icmp_echo_ignore_all = $(sysctl -n net.ipv4.icmp_echo_ignore_all)"
    echo "IPv6 icmp.echo_ignore_all = $(sysctl -n net.ipv6.icmp.echo_ignore_all 2>/dev/null || echo 'n/d')"
    echo "(1 = bloqueado, 0 = liberado)"
}

case "${1:-}" in
    instalar) instalar ;;
    remover)  remover ;;
    status)   status ;;
    *)
        echo "Uso: sudo $0 {instalar|remover|status}"
        exit 1
        ;;
esac
