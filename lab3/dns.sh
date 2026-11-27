#!/bin/bash
# Лабораторна 3: визначення DNS-сервера через Wireshark і перевірка option domain-name-servers.
# Запуск: sudo bash dns.sh
[ "$(id -u)" = 0 ] || { echo "Запусти через sudo"; exit 1; }
H=http://10.0.2.2:8765; U=${SUDO_USER:-root}; W=/run/lab3; E=/home/$U/lab3_out
UIDN=$(id -u "$U"); IF=enp0s3
export LANG=C.UTF-8
mkdir -p $W/hooks $W/nohooks $E; chmod 755 $W $W/hooks $W/nohooks
command -v nslookup >/dev/null || apt-get install -y dnsutils >/dev/null
OLDFWD=$(sysctl -n net.ipv4.ip_forward)

cleanup(){
  systemctl stop isc-dhcp-server 2>/dev/null; systemctl disable isc-dhcp-server >/dev/null 2>&1
  pkill -x tcpdump 2>/dev/null; pkill -u "$U" -x wireshark 2>/dev/null; pkill -f dhclient-lab3 2>/dev/null
  iptables -t nat -D POSTROUTING -s 192.168.100.0/24 -o $IF -j MASQUERADE 2>/dev/null
  ip netns del pc2 2>/dev/null; ip link del br-lab 2>/dev/null; rm -rf /etc/netns/pc2
  sysctl -qw net.ipv4.ip_forward=$OLDFWD; stty sane 2>/dev/null
}
trap cleanup EXIT

say(){ clear; printf '\e[1;33m===== %s =====\e[0m\n\n' "$1"; echo "##### $1" >> $E/dns_log.txt; }
c1(){ printf '\e[1;32m%s@%s (PC1)\e[0m$ sudo %s\n' "$U" "$(hostname)" "$1"; echo "PC1# $1" >> $E/dns_log.txt; bash -c "$1" 2>&1 | tee -a $E/dns_log.txt; echo; }
cu(){ printf '\e[1;32m%s@%s (PC1)\e[0m$ %s\n' "$U" "$(hostname)" "$1"; echo "PC1\$ $1" >> $E/dns_log.txt; runuser -u "$U" -- bash -c "$1" 2>&1 | tee -a $E/dns_log.txt; echo; }
in2(){ ip netns exec pc2 unshare -u -m bash -c 'hostname pc2-client; mount --bind /run/lab3/hooks /etc/dhcp/dhclient-enter-hooks.d; mount --bind /run/lab3/nohooks /etc/dhcp/dhclient-exit-hooks.d; '"$1"; }
c2(){ printf '\e[1;36mroot@pc2-client (PC2)\e[0m# %s\n' "${2:-$1}"; echo "PC2# $1" >> $E/dns_log.txt; in2 "$1" 2>&1 | tee -a $E/dns_log.txt; echo; }
shot(){ stty sane 2>/dev/null; sleep 2; curl -s --max-time 40 -X POST $H/shot/$1 >/dev/null; sleep 1; }
ws(){ # ws <інтерфейс> <фільтр>
  C=/tmp/lab3ws; rm -rf $C; mkdir -p $C
  printf 'gui.geometry_main_maximized: TRUE\n' > $C/recent; printf 'gui.update.enabled: FALSE\n' > $C/preferences; chown -R $U $C
  XA=$(ls /run/user/$UIDN/.mutter-Xwaylandauth* /run/user/$UIDN/gdm/Xauthority 2>/dev/null | head -1)
  setsid runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UIDN DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UIDN/bus sg wireshark -c "env WIRESHARK_CONFIG_DIR=$C DISPLAY=${DISPLAY:-:0} XAUTHORITY=$XA wireshark -k -i $1 -Y $2" </dev/null >/tmp/lab3ws.log 2>&1 &
  sleep 12
}
wsend(){ pkill -u "$U" -x wireshark; sleep 2; stty sane 2>/dev/null; }
: > $E/dns_log.txt

say "21. Визначення DNS-сервера: налаштування системи"
c1 "grep -v '^#' /etc/resolv.conf | sed '/^\$/d'"
c1 "resolvectl dns $IF"
shot 25_dns_conf

say "22. Визначення DNS-сервера у Wireshark"
tcpdump -q -i $IF -Z root -w $E/dns.pcap port 53 >/dev/null 2>&1 & TP=$!; sleep 1
ws $IF dns
resolvectl flush-caches
cu "curl -s -o /dev/null -w 'kpi.ua: HTTP %{http_code}\n' http://kpi.ua"
cu "curl -s -o /dev/null -w 'google.com: HTTP %{http_code}\n' http://google.com"
sleep 3; shot 26_ws_dns; wsend
sleep 1; kill $TP 2>/dev/null; wait $TP 2>/dev/null; chown $U: $E/dns.pcap
say "23. Аналіз DNS-запитів (tshark)"
c1 "tshark -r $E/dns.pcap -Y dns -T fields -e frame.number -e ip.src -e ip.dst -e dns.flags.response -e dns.qry.name -e dns.a 2>/dev/null | head -12"
DNS=$(tshark -r $E/dns.pcap -Y 'dns.flags.response==0' -T fields -e ip.dst 2>/dev/null | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
[ -n "$DNS" ] || DNS=10.0.2.3
echo "DNS-сервер, на який VM надсилає запити: $DNS" | tee -a $E/dns_log.txt; echo
shot 27_dns_tshark

say "24. DNS у dhcpd.conf та перевірка на клієнті"
ip netns del pc2 2>/dev/null; ip link del br-lab 2>/dev/null
ip link add br-lab type bridge; ip link set br-lab up; ip addr add 192.168.100.1/24 dev br-lab
ip netns add pc2; ip link add p-pc2 type veth peer name eth0 netns pc2
ip link set p-pc2 master br-lab up; ip -n pc2 link set lo up; ip -n pc2 link set eth0 up
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o $IF -j MASQUERADE
echo 'make_resolv_conf(){ :; }' > $W/hooks/zz
sed -i "s/^option domain-name-servers .*/option domain-name-servers $DNS, 8.8.8.8;/" /etc/dhcp/dhcpd.conf
: > /var/lib/dhcp/dhcpd.leases; rm -f /var/lib/dhcp/dhclient-lab3.leases
echo 'INTERFACESv4="br-lab"' > /etc/default/isc-dhcp-server; echo 'INTERFACESv6=""' >> /etc/default/isc-dhcp-server
c1 "grep domain-name-servers /etc/dhcp/dhcpd.conf"
c1 "systemctl restart isc-dhcp-server && systemctl is-active isc-dhcp-server"
c2 "dhclient -1 -cf /etc/dhcp/dhclient-lab3.conf -lf /var/lib/dhcp/dhclient-lab3.leases -pf /run/dhclient-lab3.pid eth0 && grep -m1 domain-name-servers /var/lib/dhcp/dhclient-lab3.leases" "dhclient eth0; grep domain-name-servers /var/lib/dhcp/dhclient.leases"
c2 "nslookup kpi.ua $DNS | tail -4"
shot 28_dns_client
cp /etc/dhcp/dhcpd.conf $E/dhcpd_dns.conf; chown -R $U: $E
for f in dns.pcap dns_log.txt dhcpd_dns.conf; do curl -s --max-time 30 -T "$E/$f" $H/up/$f >/dev/null; done
clear; echo "ГОТОВО. Копії файлів: $E"
