#!/bin/sh
uci set network.wan.proto='dhcp'
uci commit network
exit 0
