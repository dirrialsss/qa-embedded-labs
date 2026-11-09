#!/usr/bin/env bash
# Лабораторна робота №2 — ARP. Варіант 2 (20 % 3 = 2).
# Запуск:  bash lab2_arp.sh <IP_цільового_пристрою> [інтерфейс]
# Приклад: bash lab2_arp.sh 192.168.1.5 enp0s3
# Wireshark тримай відкритим паралельно (фільтр: arp || icmp) — скріни робиш на паузах.

TARGET="$1"
IFACE="${2:-$(ip route | awk '/default/ {print $5; exit}')}"
FAKE_MAC="02:00:00:00:00:01"
LOG="$HOME/lab2_arp_$(date +%Y%m%d_%H%M).log"

if [ -z "$TARGET" ]; then
  echo "Вкажи IP цільового пристрою (телефон / друга VM): bash lab2_arp.sh 192.168.1.5"; exit 1
fi

pause() { echo; read -rp ">>> СКРІН: $1. Натисни Enter, щоб продовжити..." _; echo; }
step()  { echo; echo "================ $1 ================"; }

exec > >(tee -a "$LOG") 2>&1
echo "Користувач: $(whoami)@$(hostname)   Дата: $(date)"
echo "Інтерфейс: $IFACE   Ціль: $TARGET"

step "0. Підготовка"
command -v arp >/dev/null || sudo apt-get install -y net-tools
command -v wireshark >/dev/null || {
  sudo add-apt-repository -y ppa:wireshark-dev/stable
  sudo apt-get update
  sudo apt-get install -y wireshark
  sudo dpkg-reconfigure wireshark-common
  sudo adduser "$USER" wireshark
  echo "Wireshark встановлено. Перезайди в систему (logout/login) і запусти скрипт ще раз."; exit 0
}
grep wireshark /etc/group
ip a show "$IFACE"
pause "ip a + група wireshark"

step "1. Отримання MAC за відомою IP (динамічний ARP)"
sudo arp -d "$TARGET" 2>/dev/null
arp -a
pause "arp -a ДО ping (запису для $TARGET немає). Запусти захоплення у Wireshark"
ping -c 4 "$TARGET"
pause "Wireshark: 'Who has $TARGET? Tell ...' та '$TARGET is at ...'"

step "2. Оновлення ARP-таблиці після ARP-reply"
arp -a
ip neigh show "$TARGET"
MAC=$(ip neigh show "$TARGET" | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}')
echo "Отримана MAC-адреса: $MAC"
[ -z "$MAC" ] && { echo "MAC не отримано — ціль не відповіла. Перевір мережу (Bridged Adapter, одна підмережа)."; exit 1; }
pause "arp -a ПІСЛЯ ping (з'явився запис $TARGET -> $MAC)"

step "3. ВАРІАНТ 2: статичний запис + ping (ARP-TC-01)"
sudo arp -d "$TARGET"
sudo arp -s "$TARGET" "$MAC"
arp -a
ip neigh show "$TARGET"
pause "arp -a з маркером PERM. Перезапусти захоплення у Wireshark, фільтр arp"
ping -c 5 "$TARGET"
pause "Wireshark з фільтром arp — ЖОДНОГО нового 'Who has $TARGET' від тебе; + вивід ping"
sudo arp -d "$TARGET"

step "4. Власний тест-кейс ARP-TC-02: статичний запис з НЕПРАВИЛЬНОЮ MAC"
sudo arp -s "$TARGET" "$FAKE_MAC"
arp -a
pause "arp -a: $TARGET -> $FAKE_MAC PERM. Перезапусти захоплення, фільтр: arp || icmp"
ping -c 5 -W 1 "$TARGET"
pause "ping: 100% packet loss; Wireshark: ICMP request на $FAKE_MAC, відповідей немає, ARP-запитів немає"
sudo arp -d "$TARGET"
ping -c 3 "$TARGET"
arp -a
pause "після видалення запису зв'язок відновився (ARP знову спрацював)"

step "5. Збереження історії"
date
echo "Лог збережено: $LOG"
pause "date + whoami (ім'я користувача і дата виконання)"
