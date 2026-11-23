#!/bin/bash
# Лабораторна 3 (DHCP). Запуск: sudo bash lab3.sh
# PC1 - сама VM (DHCP-сервер + маршрутизатор), PC2 / PC3 / PC4 - мережеві простори імен.
[ "$(id -u)" = 0 ] || { echo "Запусти через sudo"; exit 1; }
H=http://10.0.2.2:8765; U=${SUDO_USER:-root}; W=/run/lab3; E=/home/$U/lab3_out
export LANG=C.UTF-8
mkdir -p $W/hooks $W/nohooks $E; chmod 755 $W
UIDN=$(id -u "$U")
asuser(){ runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UIDN DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UIDN/bus "$@"; }

echo "### Встановлення пакетів"
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
export DEBIAN_FRONTEND=noninteractive
{ command -v dhcpd && command -v tshark && command -v wireshark && command -v traceroute && command -v curl; } >/dev/null || { apt-get update && apt-get install -y isc-dhcp-server isc-dhcp-client net-tools traceroute wireshark tshark tcpdump curl iproute2 iputils-ping; } || { echo "apt не спрацював"; exit 1; }
usermod -aG wireshark "$U"

OLDIDLE=$(asuser gsettings get org.gnome.desktop.session idle-delay 2>/dev/null | awk '{print $2}')
asuser gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null
OLDFWD=$(sysctl -n net.ipv4.ip_forward)
[ -f /etc/dhcp/dhcpd.conf.lab3bak ] || cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.lab3bak
[ -f /etc/default/isc-dhcp-server.lab3bak ] || cp /etc/default/isc-dhcp-server /etc/default/isc-dhcp-server.lab3bak

cleanup(){
  systemctl stop isc-dhcp-server 2>/dev/null; systemctl disable isc-dhcp-server >/dev/null 2>&1
  pkill -f dhcpd-pc4 2>/dev/null; pkill -x tcpdump 2>/dev/null; pkill -u "$U" -x wireshark 2>/dev/null
  pkill -f dhclient-lab3 2>/dev/null
  for n in pc2 pc3 pc4; do ip netns del $n 2>/dev/null; done
  ip link del br-lab 2>/dev/null; ip link del pc3-link 2>/dev/null
  sysctl -qw net.ipv4.ip_forward=$OLDFWD
  [ -n "$OLDIDLE" ] && asuser gsettings set org.gnome.desktop.session idle-delay "$OLDIDLE" 2>/dev/null
}
trap cleanup EXIT
for n in pc2 pc3 pc4; do ip netns del $n 2>/dev/null; done; ip link del br-lab 2>/dev/null; ip link del pc3-link 2>/dev/null
pkill -f dhcpd-pc4 2>/dev/null; pkill -f dhclient-lab3 2>/dev/null

# --- стенд
ip link add br-lab type bridge; ip link set br-lab up
for n in pc2 pc4; do
  ip netns add $n; ip link add p-$n type veth peer name eth0 netns $n
  ip link set p-$n master br-lab up; ip -n $n link set lo up; ip -n $n link set eth0 up
done
ip netns add pc3; ip link add pc3-link type veth peer name eth0 netns pc3
ip addr add 10.20.0.1/24 dev pc3-link; ip link set pc3-link up
ip -n pc3 link set lo up; ip -n pc3 link set eth0 up; ip -n pc3 addr add 10.20.0.2/24 dev eth0; ip -n pc3 route add default via 10.20.0.1
sysctl -qw net.ipv4.ip_forward=1
echo 'make_resolv_conf(){ :; }' > $W/hooks/zz; chmod 755 $W/hooks $W/nohooks
cat > /etc/dhcp/dhclient-lab3.conf <<'C'
send host-name = gethostname();
request subnet-mask, broadcast-address, routers, domain-name, domain-name-servers;
timeout 20;
retry 60;
C

say(){ clear; printf '\e[1;33m===== %s =====\e[0m\n\n' "$1"; echo "##### $1" >> $E/log.txt; }
c1(){ printf '\e[1;32m%s@%s (PC1)\e[0m$ sudo %s\n' "$U" "$(hostname)" "$1"; echo "PC1# $1" >> $E/log.txt; bash -c "$1" 2>&1 | tee -a $E/log.txt; echo; }
in2(){ ip netns exec pc2 unshare -u -m bash -c 'hostname pc2-client; mount --bind /run/lab3/hooks /etc/dhcp/dhclient-enter-hooks.d; mount --bind /run/lab3/nohooks /etc/dhcp/dhclient-exit-hooks.d; '"$1"; }
c2(){ printf '\e[1;36mroot@pc2-client (PC2)\e[0m# %s\n' "${2:-$1}"; echo "PC2# $1" >> $E/log.txt; in2 "$1" 2>&1 | tee -a $E/log.txt; echo; }
cu(){ printf '\e[1;32m%s@%s (PC1)\e[0m$ %s
' "$U" "$(hostname)" "$1"; runuser -u "$U" -- bash -c "$1" 2>&1 | tee -a $E/log.txt; echo; }
shot(){ stty sane 2>/dev/null; sleep 2; curl -s --max-time 40 -X POST $H/shot/$1 >/dev/null; sleep 1; }
cap(){ tcpdump -q -i br-lab -Z root -w $E/$1.pcap >/dev/null 2>&1 & TP=$!; sleep 1; }
capend(){ sleep 1; kill $TP 2>/dev/null; wait $TP 2>/dev/null; chown $U: $E/*.pcap; }
ws(){
  C=/tmp/lab3ws; rm -rf $C; mkdir -p $C
  printf 'gui.geometry_main_x: 80\ngui.geometry_main_y: 60\ngui.geometry_main_width: 1200\ngui.geometry_main_height: 720\ngui.geometry_main_maximized: TRUE\n' > $C/recent
  printf 'gui.update.enabled: FALSE\ngui.ask_unsaved: FALSE\n' > $C/preferences
  chown -R $U $C
  XA=$(ls /run/user/$UIDN/.mutter-Xwaylandauth* /run/user/$UIDN/gdm/Xauthority 2>/dev/null | head -1)
  WD=$(ls /run/user/$UIDN 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -1)
  Q="WIRESHARK_CONFIG_DIR=$C DISPLAY=${DISPLAY:-:0} XAUTHORITY=$XA"
  [ -n "$WD" ] && Q="$Q WAYLAND_DISPLAY=$WD"
  setsid runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UIDN DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UIDN/bus sg wireshark -c "env $Q wireshark -k -i br-lab -Y $1" </dev/null >/tmp/lab3ws.log 2>&1 &
  sleep 12
}
wsend(){ pkill -u "$U" -x wireshark; sleep 2; stty sane 2>/dev/null; }
conf_ok(){ cat > /etc/dhcp/dhcpd.conf <<'C'
authoritative;
default-lease-time 600;
max-lease-time 7200;
option subnet-mask 255.255.255.0;
option broadcast-address 192.168.100.255;
option routers 192.168.100.1;
option domain-name-servers 192.168.100.1, 8.8.8.8;
option domain-name "mydomain.example";

subnet 192.168.100.0 netmask 255.255.255.0 {
  range 192.168.100.10 192.168.100.20;
}
C
}
wipe(){ systemctl stop isc-dhcp-server; pkill -f dhclient-lab3; sleep 1; rm -f /var/lib/dhcp/dhclient-lab3.leases; : > /var/lib/dhcp/dhcpd.leases; rm -f /var/lib/dhcp/dhcpd.leases~; ip -n pc2 addr flush dev eth0; ip -n pc2 route flush table main 2>/dev/null; systemctl reset-failed isc-dhcp-server 2>/dev/null; }
DC='dhclient -1 -v -cf /etc/dhcp/dhclient-lab3.conf -lf /var/lib/dhcp/dhclient-lab3.leases -pf /run/dhclient-lab3.pid eth0'
: > $E/log.txt

say "1. Мережеві параметри PC1"
cu "whoami; hostname; date; lsb_release -ds"; c1 "ip -br -4 addr"; c1 "ip -br link show br-lab"; shot 01_env

say "2. Статичне налаштування IP"
c1 "ip addr add 192.168.100.1/24 dev br-lab"
c2 "ip addr add 192.168.100.50/24 dev eth0"; c2 "ip -4 addr show eth0"; c2 "ip route"; c2 "ping -c 3 192.168.100.1"; shot 02_static
in2 "ip addr flush dev eth0"; rm -f /var/lib/dhcp/dhcpd-pc4.leases

say "3. Налаштування DHCP-сервера"
echo 'INTERFACESv4="br-lab"' > /etc/default/isc-dhcp-server; echo 'INTERFACESv6=""' >> /etc/default/isc-dhcp-server
wipe; conf_ok
c1 "cat /etc/default/isc-dhcp-server"; c1 "cat /etc/dhcp/dhcpd.conf"; c1 "dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>&1 | tail -4"; shot 03_conf

say "4. Запуск DHCP-сервера"
c1 "systemctl restart isc-dhcp-server"; sleep 2
c1 "systemctl status isc-dhcp-server --no-pager -l | cut -c1-130"; shot 04_status

say "5. Динамічне отримання IP (PC2)"
cap dora; ws dhcp
c2 "$DC" "dhclient -v eth0"; sleep 3; shot 05_ws_dora; wsend; capend; shot 06_dhclient
say "6. Результат на PC2 та файл dhcpd.leases"
c2 "ip -4 addr show eth0"; c2 "ip route"; c1 "grep -vE '^#|^\$' /var/lib/dhcp/dhcpd.leases"; shot 07_leases
say "7. Параметри DHCPACK (tshark)"
c1 "tshark -r $E/dora.pcap -Y dhcp 2>/dev/null"; c1 "tshark -r $E/dora.pcap -Y dhcp.option.dhcp==5 -V 2>/dev/null | grep -E 'Your .client|Option: |Renewal Time|Lease Time:|DHCP Server Identifier:|Router:|Subnet Mask:|Domain Name Server:|Domain Name:' | head -30"; shot 08_ack

say "7а. Звільнення адреси та повторне отримання"
cap release
c2 "${DC/-1 -v/-r -v}" "dhclient -r -v eth0"; c2 "ip -br -4 addr show eth0"; pkill -f dhclient-lab3; sleep 1; rm -f /var/lib/dhcp/dhclient-lab3.leases; c2 "$DC" "dhclient -v eth0"; capend; c1 "journalctl -u isc-dhcp-server --no-pager -o cat | grep ^DHCP | tail -5"; shot 08b_release

say "8. ping: шлюз, інша підмережа, Інтернет"
cap icmp; ws icmp
c2 "ping -c 3 192.168.100.1"; c2 "ping -c 3 10.20.0.2"; shot 09_ws_icmp; wsend; capend
c1 "ping -c 3 8.8.8.8"; shot 10_ping
say "9. traceroute"
c2 "traceroute -n -w 1 10.20.0.2"; c1 "traceroute -I -n -w 1 -q 1 -m 12 8.8.8.8"; shot 11_trace
say "10. Таблиці маршрутизації"
c1 "ip route"; c1 "route -n"; c2 "ip route"; c2 "ip route get 10.20.0.2"; c1 "ip route get 8.8.8.8"; shot 12_routes

say "11. Troubleshooting 1: немає шлюзу за замовчуванням"
c2 "ip route del default"; c2 "ping -c 2 -W 1 10.20.0.2"; c2 "ip route"; c2 "ip route add default via 192.168.100.1"; c2 "ping -c 2 -W 1 10.20.0.2"; shot 13_ts1
say "12. Troubleshooting 2: вимкнено ip_forward на PC1"
c1 "sysctl -w net.ipv4.ip_forward=0"; c2 "ping -c 2 -W 1 10.20.0.2"; c2 "traceroute -n -w 1 -q 1 -m 3 10.20.0.2"; c1 "sysctl -w net.ipv4.ip_forward=1"; c2 "ping -c 2 -W 1 10.20.0.2"; shot 14_ts2

say "13. ВАРІАНТ 2: у dhcpd.conf не вказано range"
wipe; sed -i '/^ *range /d' /etc/dhcp/dhcpd.conf; cp /etc/dhcp/dhcpd.conf $E/dhcpd_norange.conf
c1 "sed -n '/^subnet/,\$p' /etc/dhcp/dhcpd.conf"; c1 "dhcpd -t -cf /etc/dhcp/dhcpd.conf >/dev/null 2>&1; echo exit code: \$?"
T0=$(date '+%Y-%m-%d %H:%M:%S')
c1 "systemctl restart isc-dhcp-server"; sleep 2; c1 "systemctl is-active isc-dhcp-server"; c1 "journalctl -u isc-dhcp-server --no-pager -o cat --since '$T0' | tail -12 | cut -c1-120"; shot 15_norange_conf
say "14. ВАРІАНТ 2: спроба отримати адресу"
cap norange; ws dhcp
c2 "$DC" "dhclient -v eth0"; shot 16_ws_norange; wsend; capend
c2 "ip -br addr show eth0"; shot 17_norange_client
say "15. ВАРІАНТ 2: журнал сервера"
c1 "journalctl -u isc-dhcp-server --no-pager -o short --since '$T0' | grep -iE 'DHCP(DISC|OFF|REQ|ACK)|free' | tail -14 | cut -c1-140"; c1 "grep -c ^lease /var/lib/dhcp/dhcpd.leases"; shot 18_norange_log
say "16. ВАРІАНТ 2: виправлення і повторна перевірка"
wipe; conf_ok; c1 "grep range /etc/dhcp/dhcpd.conf"; c1 "systemctl restart isc-dhcp-server"; sleep 2; cap fixed
c2 "$DC" "dhclient -v eth0"; capend; c2 "ip -4 addr show eth0"; c2 "ping -c 2 10.20.0.2"; shot 19_fixed

say "17. Конфлікт двох DHCP-серверів"
wipe; ip -n pc4 addr add 192.168.100.253/24 dev eth0
cat > /etc/dhcp/dhcpd-pc4.conf <<'C'
default-lease-time 600;
max-lease-time 7200;
ping-check false;
option subnet-mask 255.255.255.0;
option routers 192.168.100.254;

subnet 192.168.100.0 netmask 255.255.255.0 {
  range 192.168.100.200 192.168.100.210;
}
C
: > /var/lib/dhcp/dhcpd.leases-pc4
systemctl restart isc-dhcp-server; sleep 2
( ip netns exec pc4 dhcpd -d -4 -cf /etc/dhcp/dhcpd-pc4.conf -lf /var/lib/dhcp/dhcpd.leases-pc4 -pf /run/dhcpd.pid eth0 2>&1 | cat > $W/pc4.log ) &
sleep 3
c1 "cat /etc/dhcp/dhcpd-pc4.conf"; c1 "systemctl is-active isc-dhcp-server"; c1 "tail -5 $W/pc4.log"; shot 20_two_servers
say "18. Конфлікт: клієнт отримує адресу"
cap conflict; ws dhcp
c2 "$DC" "dhclient -v eth0"; sleep 2; shot 21_ws_conflict; wsend; capend
c2 "ip -4 addr show eth0"; c2 "ip route"; c2 "ping -c 2 -W 1 10.20.0.2"; shot 22_conflict_client
say "19. Конфлікт: аналіз захоплення"
c1 "tshark -r $E/conflict.pcap -Y dhcp -T fields -e frame.number -e frame.time_relative -e ip.src -e dhcp.option.dhcp -e dhcp.ip.your -e dhcp.option.dhcp_server_id -e dhcp.option.router 2>/dev/null"; c1 "tail -12 $W/pc4.log"; shot 23_conflict_tshark
say "20. Конфлікт: усунення"
pkill -f dhcpd-pc4; wipe; systemctl restart isc-dhcp-server; sleep 2; echo "Другий сервер (PC4) зупинено"; echo
c2 "$DC" "dhclient -v eth0"; c2 "ip route"; c2 "ping -c 2 -W 1 10.20.0.2"; shot 24_conflict_fixed

cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd-pc4.conf /etc/default/isc-dhcp-server $W/pc4.log /var/lib/dhcp/dhcpd.leases $E/ 2>/dev/null
cp /tmp/lab3ws.log $E/; chown -R $U: $E
for f in $E/*; do curl -s --max-time 30 -T "$f" $H/up/$(basename "$f") >/dev/null; done
clear; echo "ГОТОВО. Копії файлів: $E"
