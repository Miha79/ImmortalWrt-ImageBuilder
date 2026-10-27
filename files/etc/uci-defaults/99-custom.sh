#!/bin/sh
# 99-custom.sh — скрипт, выполняемый при первой загрузке прошивки ImmortalWrt.
# Расположение в прошивке: /etc/uci-defaults/99-custom.sh
# Файл логов для отладки
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Запуск 99-custom.sh в $(date)" >>$LOGFILE

# Настройка правил брандмауэра по умолчанию для доступа к WebUI 
# Так как в этом проекте режим с одним портом использует DHCP, можно сразу выйти в интернет и зайти в веб-интерфейс.
# После настройки вы можете самостоятельно закрыть входящие данные на WAN в веб-интерфейсе.
# Как это сделать: Сеть -> Брандмауэр -> Входящие данные для зоны WAN -> выбрать "Отклонить" -> Сохранить и применить.
uci set firewall.@zone[1].input='ACCEPT'

# Настройка сопоставления имен хостов для решения проблем с подключением Android TV к сети
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# Проверка наличия файла настроек PPPoE (создается динамически в build.sh)
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Файл настроек PPPoE не найден. Пропускаем." >>$LOGFILE
else
    # Чтение данных PPPoE ($enable_pppoe, $pppoe_account, $pppoe_password)
    . "$SETTINGS_FILE"
fi

# 1. Получение списка всех физических интерфейсов
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        ifnames="$ifnames $iface_name"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

count=$(echo "$ifnames" | wc -w)
echo "Обнаруженные физические интерфейсы: $ifnames" >>$LOGFILE
echo "Количество интерфейсов: $count" >>$LOGFILE

# 2. Сопоставление интерфейсов WAN и LAN в зависимости от модели платы
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
echo "Обнаружена плата: $board_name" >>$LOGFILE

wan_ifname=""
lan_ifnames=""
# Особый случай для некоторых плат с обратным порядком портов
case "$board_name" in
    "radxa,e20c"|"friendlyarm,nanopi-r5c")
        wan_ifname="eth1"
        lan_ifnames="eth0"
        echo "Использование маппинга для $board_name: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
    *)
        # По умолчанию первый интерфейс — WAN, остальные — LAN
        wan_ifname=$(echo "$ifnames" | awk '{print $1}')
        lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)
        echo "Использование маппинга по умолчанию: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
esac

# 3. Настройка сети
if [ "$count" -eq 1 ]; then
    # Устройства с одним сетевым портом, режим DHCP
    uci set network.lan.proto='dhcp'
    uci delete network.lan.ipaddr
    uci delete network.lan.netmask
    uci delete network.lan.gateway
    uci delete network.lan.dns
    uci commit network
elif [ "$count" -gt 1 ]; then
    # Настройка устройств с несколькими сетевыми портами
    # Настройка WAN
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"
    uci set network.wan.proto='dhcp'

    # Настройка WAN6
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    uci set network.wan6.proto='dhcpv6'

    # Поиск секции br-lan
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    if [ -z "$section" ]; then
        echo "Ошибка: не удается найти устройство 'br-lan'." >>$LOGFILE
    else
        # Удаление старых портов
        uci -q delete "network.$section.ports"
        # Добавление интерфейсов в LAN
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        echo "Обновлены порты br-lan: $lan_ifnames" >>$LOGFILE
    fi

    # Установка статического IP для LAN
    uci set network.lan.proto='static'
    # Для устройств с несколькими портами можно изменить IP-адрес панели управления (задается в GitHub Action)
    uci set network.lan.netmask='255.255.255.0'
    
    # Настройка IP-адреса панели управления роутера
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        # IP-адрес, заданный пользователем в интерфейсе
        uci set network.lan.ipaddr=$CUSTOM_IP
        echo "Пользовательский IP роутера: $CUSTOM_IP" >> $LOGFILE
    else
        uci set network.lan.ipaddr='192.168.100.1'
        echo "IP роутера по умолчанию: 192.168.100.1" >> $LOGFILE
    fi

    # Настройка PPPoE
    echo "Значение enable_pppoe: $enable_pppoe" >>$LOGFILE
    if [ "$enable_pppoe" = "yes" ]; then
        echo "PPPoE включен, выполняется настройка..." >>$LOGFILE
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan6.proto='none'
        echo "Настройка PPPoE завершена." >>$LOGFILE
    else
        echo "PPPoE не включен." >>$LOGFILE
    fi

    uci commit network
fi

# Разрешить доступ к веб-терминалу через все сетевые порты
uci delete ttyd.@ttyd[0].interface

# Разрешить подключение по SSH через все сетевые порты
uci set dropbear.@dropbear[0].Interface=''
uci commit

# Установка информации об авторе сборки
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by wukongdaily"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# Если установлен luci-app-advancedplus (расширенные настройки), удалить вызов zsh во избежание ошибки /usb/bin/zsh: not found
if [ -f /usr/lib/lua/luci/controller/advancedplus.lua ]; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
    echo "Исправлено сообщение ttyd: /usb/bin/zsh: not found" >>$LOGFILE
fi

# Выполняется только при наличии luci-app-quickfile
if [ -f /usr/bin/quickfile ]; then
    uci set nginx.global.uci_enable='true'
    uci del nginx._lan 2>/dev/null
    uci del nginx._redirect2ssl 2>/dev/null

    uci add nginx server
    uci rename nginx.@server[-1]='_lan'

    uci set nginx._lan.server_name='_lan'
    uci add_list nginx._lan.listen='80 default_server'
    uci add_list nginx._lan.listen='[::]:80 default_server'
    uci add_list nginx._lan.include='conf.d/*.locations'
    uci set nginx._lan.access_log='off; # logd openwrt'

    uci commit nginx
    echo "Исправлена конфигурация nginx для quickfile" >>$LOGFILE
fi

# Если установлен dockerd, настроить правила брандмауэра для Docker
# Расширить диапазон подсетей '172.16.0.0/12'
# Чтобы порты различных контейнеров Docker беспрепятственно проходили через брандмауэр
if command -v dockerd >/dev/null 2>&1; then
    echo "Обнаружен Docker, настройка правил брандмауэра..."
    FW_FILE="/etc/config/firewall"

    # Удалить все зоны с именем docker
    uci delete firewall.docker

    # Получить все индексы forwarding в обратном порядке и удалить их
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        echo "Проверка индекса forwarding $idx: src=$src dest=$dest"
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            echo "Удаление forwarding @forwarding[$idx]"
            uci delete firewall.@forwarding[$idx]
        fi
    done
    # Применить удаление
    uci commit firewall

# Добавить новую конфигурацию zone + forwarding
cat <<EOF >>"$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF

else
    echo "Docker не обнаружен, пропуск настройки брандмауэра."
fi

# === ПРИНУДИТЕЛЬНАЯ НАСТРОЙКА WAN НА DHCP ===
# Гарантирует, что WAN будет получать настройки по DHCP (даже если случайно включен PPPoE)
uci set network.wan.proto='dhcp'
uci commit network

exit 0
