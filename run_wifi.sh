#!/bin/sh
#
# run_wifi.sh
# This script manages Wi-Fi interfaces (AP/STA mode) independent of
# USB host connection state.
#
# Behavior:
#   1. On every boot/power-on, the board always starts in AP mode.
#   2. In STA mode, if the station fails to connect (or connects but has
#      no internet) for STA_FAIL_TIMEOUT seconds, it automatically falls
#      back to AP mode.
#

WLAN_CONFIG_FILE="/etc/g3-wlan.config"

source /etc/g3-createwificonfig.sh

source /etc/g3-wlan.config

SLEEP_INTERVAL=5
HOSTAPD_STARTUP_TIME=10
WPA_SUPPLICANT_STARTUP_TIME=10

# --- Fallback tuning ---
STA_FAIL_TIMEOUT=60      # seconds of no-connection/no-internet before falling back to AP
STA_FAIL_START_TIME=0    # 0 = timer not running
INTERNET_CHECK_HOST="8.8.8.8"

# --- LED indication ---
LED_NAME="wlanbt-led"
LED_PATH="/sys/class/leds/${LED_NAME}/brightness"
LED_LAST_STATE=""   # cache to avoid redundant writes every loop

led_on()
{
        if [ "$LED_LAST_STATE" != "on" ] && [ -w "$LED_PATH" ]; then
                echo 1 > "$LED_PATH"
                LED_LAST_STATE="on"
        fi
}

led_off()
{
        if [ "$LED_LAST_STATE" != "off" ] && [ -w "$LED_PATH" ]; then
                echo 0 > "$LED_PATH"
                LED_LAST_STATE="off"
        fi
}

# --- Device registration ---
# Runs once per "internet just became available" transition, not on
# every 5s loop pass. DEVICE_REGISTERED resets to 0 whenever STA goes
# down, so a later reconnect triggers registration again.
REGISTER_SCRIPT="/usr/bin/registerDevice.py"
REGISTER_SCRIPT_DIR="$(dirname "$REGISTER_SCRIPT")"
DEVICE_REGISTERED=0

register_device()
{
        if [ "$DEVICE_REGISTERED" == "1" ]; then
                return
        fi

        if [ ! -e "$REGISTER_SCRIPT" ]; then
                echo "[WARN] register_device: $REGISTER_SCRIPT not found"
                return
        fi

        # registerDevice.py doesn't exit after registering - it polls
        # forever until a start-flashing signal arrives. If a stale
        # instance from an earlier connect/disconnect cycle is still
        # alive, kill it first so we never end up with duplicates.
        OLD_PID=$(pgrep -f "$REGISTER_SCRIPT")
        if [ -n "$OLD_PID" ]; then
                echo "[INFO] register_device: killing stale instance(s) PID=${OLD_PID}"
                kill -9 ${OLD_PID}
        fi

        chmod +x "$REGISTER_SCRIPT" 2>/dev/null

        echo "[INFO] Internet available - running $REGISTER_SCRIPT"
        # registerDevice.py launches "start_flash.py" by relative name,
        # so cd into its directory first or that lookup fails once the
        # start signal actually arrives.
        ( cd "$REGISTER_SCRIPT_DIR" && exec python3 "$REGISTER_SCRIPT" >> /var/log/registerDevice.log 2>&1 ) &

        DEVICE_REGISTERED=1
}

# Check if the STA is connected to the AP
# Exit status of 0 - station is connected
# Exit status of !0 - station is not connected
is_wifi_sta_connected()
{
        iw dev ${WLAN_STA_IF} link | grep -q "Connected to"
}

does_wifi_sta_haveip()
{
        ip addr show ${WLAN_STA_IF} | grep -q "inet "
}

is_sta_connected()
{
        iw dev uap0 station dump | grep -q "Station"
}

is_wifi_supplicant_running()
{
        # Kill the wpa_supplicant process
        pgrep wpa_supplicant > /dev/null
}

is_wifi_sta_up()
{
        if [ "$(cat /sys/class/net/${WLAN_STA_IF}/operstate)" == "up" ]; then
                #echo "is_wifi_sta_up: STA state up"
                return 0
        else
                #echo "is_wifi_sta_up: STA state down"
                return 1
        fi
}

# Return: 0 - AP is up
#         1 - AP is not up
is_wifi_ap_up()
{
        if [ "$(cat /sys/class/net/${WLAN_AP_IF}/operstate)" == "up" ]; then
                #echo "is_wifi_ap_up: AP state up"
                return 0
        else
                #echo "is_wifi_ap_up: AP state down"
                return 1
        fi
}

# Return: 0 - internet reachable via STA interface
#         1 - no internet
check_internet()
{
        ping -I ${WLAN_STA_IF} -c 1 -W 2 ${INTERNET_CHECK_HOST} > /dev/null 2>&1
}

stop_wifi_ap()
{
        # Reset interface before switching mode
        ip link set $WLAN_AP_IF down

        # Kill the hostapd process
        PID=$(pgrep hostapd)
        if [ $? == 0 ]; then
                echo "stop_wifi_ap: hostapd PIDs=${PID}"
                kill -9 ${PID}
        fi

        # TODO: Do we need to stop the DHCP Server when AP is brought down
}

stop_wifi_sta()
{
        # Reset interface before switching mode
        ip link set $WLAN_STA_IF down

        # Kill the wpa_supplicant process
        PID=$(pgrep wpa_supplicant)
        if [ $? == 0 ]; then
                echo "stop_wifi_sta: wpa_supplicant PIDs=${PID}"
                kill -9 ${PID}
        fi

        # Kill the udhcpc process
        PID=$(ps | grep "[u]dhcpc" | grep "$WLAN_STA_IF" | awk '{print $1}')
        if [ -n "$PID" ]; then
                echo "stop_wifi_sta: udhcpc PID=${PID}"
                kill -9 ${PID}
        else
                echo "No udhcpc running on ${WIFI_STA_IF}"
        fi

        # Kill any running registerDevice.py monitoring loop
        REG_PID=$(pgrep -f "$REGISTER_SCRIPT")
        if [ -n "$REG_PID" ]; then
                echo "stop_wifi_sta: killing registerDevice.py PID=${REG_PID}"
                kill -9 ${REG_PID}
        fi

        # Reset the fallback timer and registration flag whenever STA is torn down
        STA_FAIL_START_TIME=0
        DEVICE_REGISTERED=0
}

function stop_wifi()
{
        if is_wifi_ap_up; then
                stop_wifi_ap
        fi

        if is_wifi_supplicant_running; then
                stop_wifi_sta
        fi
}

# Function to run hostapd (AP mode)
function start_wifi_ap()
{
        if is_wifi_supplicant_running; then
                #echo "wifi station is still running"
                stop_wifi_sta
        fi

        if is_wifi_ap_up; then
                #echo "[DEBUG] WiFi: hostapd running..."
                return 0 #returns success Do nothing
        else
                source ${HOSTAPD_CONF}
                echo "WiFi: Starting hostapd ${ssid}..."
                ip addr flush dev uap0
                ifconfig $WLAN_AP_IF up
                ip addr flush dev uap0
                # Assign static IP for AP mode
                ip addr add ${WLAN_AP_IP}/24 dev $WLAN_AP_IF
                hostapd -i $WLAN_AP_IF $HOSTAPD_CONF -B
                sleep ${HOSTAPD_STARTUP_TIME}
        fi
}

function start_wifi_sta()
{
        if is_wifi_ap_up; then
                #echo "AP is still running"
                stop_wifi_ap
        fi

        if is_wifi_supplicant_running; then
                #echo "[DEBUG] Wi-Fi: wpa_supplicant running..."
                return 0 #returns success Do nothing
        else
                echo "WiFI: Starting wpa_supplicant ... "
                ifconfig ${WLAN_STA_IF} up

                wpa_supplicant -i ${WLAN_STA_IF} -B -c ${WPA_SUPPLICANT_CONF}
                sleep $WPA_SUPPLICANT_STARTUP_TIME

                if [ ${WLAN_STA_IP_MODE} == "Auto" ]; then
                        # Obtain an IP address via DHCP
                        udhcpc -b -i $WLAN_STA_IF
                else
                        # Setup the IP address statically
                        ip addr add ${WLAN_STA_IP}/24 dev $WLAN_STA_IF
                fi
        fi
}

# Checks current STA health (link + internet). If it has been unhealthy
# for STA_FAIL_TIMEOUT seconds, flip the config file back to AP mode.
# The actual mode switch happens on the next loop iteration via the
# existing "config changed" detection block below.
check_sta_and_fallback()
{
        if is_wifi_sta_connected && does_wifi_sta_haveip && check_internet; then
                if [ $STA_FAIL_START_TIME != 0 ]; then
                        echo "[INFO] STA connection healthy again, clearing fallback timer"
                fi
                STA_FAIL_START_TIME=0
                led_on
                register_device
                return
        fi

        led_off

        NOW=$(date +%s)
        if [ $STA_FAIL_START_TIME == 0 ]; then
                STA_FAIL_START_TIME=$NOW
                echo "[INFO] STA not connected / no internet - fallback timer started"
                return
        fi

        ELAPSED=$((NOW - STA_FAIL_START_TIME))
        echo "[INFO] STA unhealthy for ${ELAPSED}s (timeout ${STA_FAIL_TIMEOUT}s)"

        if [ $ELAPSED -ge $STA_FAIL_TIMEOUT ]; then
                echo "[WARN] STA fallback timeout reached - switching WLAN_MODE to AP"
                sed -i 's/^WLAN_MODE=.*/WLAN_MODE="AP"/' ${WLAN_CONFIG_FILE}
                STA_FAIL_START_TIME=0
        fi
}

NET_PID=$(pgrep NetworkManager)
kill "$NET_PID"

# --- Force AP mode on every boot / service start ---
# Regardless of whatever mode was saved from the previous run, always
# come up in AP mode. The while-loop below will pick this up as a
# "config changed" event on its first pass and bring AP up.
echo "[INFO] Boot: forcing WLAN_MODE=AP"
sed -i 's/^WLAN_MODE=.*/WLAN_MODE="AP"/' ${WLAN_CONFIG_FILE}

LAST_MODIFIED_TIME=0

while true; do
        MODIFIED_TIME=$(stat -c %Y ${WLAN_CONFIG_FILE})

        if [ $MODIFIED_TIME != $LAST_MODIFIED_TIME ]; then
                echo "Wi-Fi Config changed! Restarting Wi-Fi..."
                LAST_MODIFIED_TIME=$MODIFIED_TIME

                source ${WLAN_CONFIG_FILE}

                stop_wifi
                run_wifi_config
        fi

        if [ $WLAN_MODE = "AP" ]; then
                #echo "Starting AP..."
                start_wifi_ap
                led_off
        elif [ $WLAN_MODE = "STA" ]; then
                #echo "Starting STA"
                start_wifi_sta
                check_sta_and_fallback
        fi

        sleep $SLEEP_INTERVAL
done
