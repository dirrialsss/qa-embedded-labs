#!/usr/bin/env bash
# Лаб. №2 ARP, варіант 2 — повністю автоматичний прогін. Сюкало Д.С., ІО-34
IFACE=$(ip route | awk '/default/ {print $5; exit}')
TARGET="${1:-$(ip route | awk '/default/ {print $3; exit}')}"
FAKE_MAC="02:00:00:00:00:01"
LOG="$HOME/lab2_arp.log"

step() { clear; echo "=================== $1 ==================="; echo; }
hold() { echo; echo "   ...пауза $1 с"; sleep "$1"; }
ws_start() { pkill -x wireshark 2>/dev/null; sleep 1
  sg wireshark -c "wireshark -i $IFACE -k -Y '$1' >/dev/null 2>&1 &"; sleep 12; }
ws_stop() { pkill -x wireshark 2>/dev/null; sleep 2; }
run() { echo "diana_siukalo@ubuntu-kpi:~\$ $*"; eval "$@"; echo; }

exec > >(tee -a "$LOG") 2>&1
sudo -v || exit 1
( while true; do sudo -n true; sleep 50; done ) & KEEP=$!

step "0. Встановлення Wireshark та net-tools"
echo "wireshark-common wireshark-common/install-setuid boolean true" | sudo debconf-set-selections
run sudo apt-get update -qq
run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireshark net-tools
run sudo adduser \$USER wireshark
run "grep wireshark /etc/group"
hold 15

step "1. Мережеві параметри"
run whoami; run hostname; run date
run ip a show $IFACE
run ip route
echo "Цільовий пристрій (роутер/шлюз): $TARGET"
hold 15

step "2. Wireshark: ICMP (ping google.com)"
ws_start "icmp"
run ping -c 6 google.com
hold 15
ws_stop

step "3. Отримання MAC за IP: очищення ARP-кешу"
run sudo arp -d $TARGET
run arp -a
hold 12
ws_start "arp"
run ping -c 4 $TARGET
hold 15
ws_stop

step "4. Оновлення ARP-таблиці після ARP Reply"
run arp -a
run ip neigh show $TARGET
MAC=$(ip neigh show $TARGET | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}')
echo "Отримана MAC-адреса: $MAC"
hold 15

step "5. ВАРІАНТ 2: статичний запис (ARP-TC-01)"
run sudo arp -d $TARGET
run sudo arp -s $TARGET $MAC
run arp -a
hold 12
ws_start "arp"
run ping -c 5 $TARGET
hold 15
ws_stop
step "5. ВАРІАНТ 2: результат (ARP-TC-01)"
run arp -a
echo "У Wireshark з фільтром arp за час ping немає жодного 'Who has $TARGET'"
run sudo arp -d $TARGET
hold 10

step "6. ARP-TC-02: статичний запис з НЕПРАВИЛЬНОЮ MAC"
run sudo arp -s $TARGET $FAKE_MAC
run arp -a
hold 10
ws_start "arp || icmp"
run ping -c 5 -W 1 $TARGET
hold 15
ws_stop
step "6. ARP-TC-02: відновлення"
run sudo arp -d $TARGET
run ping -c 3 $TARGET
run arp -a
hold 15

step "ГОТОВО"
run date
kill $KEEP 2>/dev/null
echo "Лог: $LOG"
