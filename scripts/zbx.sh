#!/bin/bash
# Instalacion de Zabbix (6.0 LTS en Ubuntu 20.04, 7.0 LTS en 22.04 y 24.04)
# Estudiante: Aaron Hernandez - Matricula 2025-0800
# Uso: sudo bash zbx.sh
set -e
[ "$EUID" -ne 0 ] && { echo "Usa: sudo bash zbx.sh"; exit 1; }
DBPASS="Zbx-Lab-2025x"
. /etc/os-release
case "$VERSION_ID" in
  20.04) ZV=6.0 ;;
  22.04|24.04) ZV=7.0 ;;
  *) echo "Ubuntu $VERSION_ID no soportado (usa 20.04, 22.04 o 24.04)"; exit 1 ;;
esac
export DEBIAN_FRONTEND=noninteractive

# Gestión (Cloud0) = la tarjeta con la ruta por defecto ahora; la otra es la LAN
MGMT=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
LAN=$(ip -o link show | awk -F': ' '$2!="lo"{print $2}' | grep -vx "$MGMT" | head -1)
[ -n "$MGMT" ] && [ -n "$LAN" ] || { echo "No detecto las 2 tarjetas: el nodo necesita 2 interfaces y la primera en Cloud0"; exit 1; }

apt-get update
apt-get install -y wget snmp mariadb-server

# Repositorio oficial de Zabbix
BASE="https://repo.zabbix.com/zabbix/${ZV}/ubuntu/pool/main/z/zabbix-release/"
DEB=$(wget -qO- "$BASE" | grep -o "zabbix-release_[^\"]*ubuntu${VERSION_ID}_all.deb" | sort -V | tail -1)
[ -n "$DEB" ] || { echo "No encontré el paquete del repositorio de Zabbix"; exit 1; }
wget -q "${BASE}${DEB}" -O /tmp/zbx.deb
dpkg -i /tmp/zbx.deb
apt-get update
apt-get install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent

# Base de datos (se puede repetir sin romper nada)
mysql -uroot <<EOF
create database if not exists zabbix character set utf8mb4 collate utf8mb4_bin;
create user if not exists zabbix@localhost identified by '${DBPASS}';
grant all privileges on zabbix.* to zabbix@localhost;
set global log_bin_trust_function_creators = 1;
EOF
TABLAS=$(mysql -uroot -N -e "select count(*) from information_schema.tables where table_schema='zabbix'")
if [ "$TABLAS" = "0" ]; then
  SQL=$(dpkg -L zabbix-sql-scripts | grep 'mysql/server.sql.gz')
  zcat "$SQL" | mysql --default-character-set=utf8mb4 -uzabbix -p"${DBPASS}" zabbix
fi
mysql -uroot -e "set global log_bin_trust_function_creators = 0;"

sed -i "s|^# DBPassword=.*|DBPassword=${DBPASS}|" /etc/zabbix/zabbix_server.conf
sed -i "s|# php_value date.timezone .*|php_value date.timezone America/Santo_Domingo|" /etc/zabbix/apache.conf || true
systemctl enable mariadb apache2 zabbix-server zabbix-agent
systemctl restart mariadb zabbix-server zabbix-agent apache2

# Red al final, para no cortar tu SSH a mitad de la instalación
mkdir -p /etc/cloud/cloud.cfg.d
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
mv /etc/netplan/50-cloud-init.yaml /root/50-cloud-init.yaml.bak 2>/dev/null || true
cat > /etc/netplan/01-lab.yaml <<EOF
network:
  version: 2
  ethernets:
    ${MGMT}:
      dhcp4: true
    ${LAN}:
      dhcp4: true
      dhcp4-overrides: {use-routes: false, use-dns: false}
EOF
chmod 600 /etc/netplan/01-lab.yaml
echo "Instalado. Aplicando red (si se corta el SSH, vuelve a entrar)..."
netplan apply
sleep 10
echo "Web: http://$(ip -4 -o addr show dev ${MGMT} | awk '{print $4}' | cut -d/ -f1)/zabbix"
ip -br a
