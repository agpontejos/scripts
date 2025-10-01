#!/bin/bash

set -e

echo "Installing WireGuard auto-start service..."

if [ "$EUID" -ne 0 ]; then 
   echo "Please run as root (use sudo)"
   exit 1
fi

# Create init.d service for Ubuntu 16.04
cat > /etc/init.d/wireguard << 'SCRIPT_END'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          wireguard
# Required-Start:    $network $remote_fs $syslog
# Required-Stop:     $network $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: WireGuard VPN
# Description:       WireGuard VPN tunnel from /etc/wireguard/wg0.conf
### END INIT INFO

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
DESC="WireGuard VPN"
NAME=wireguard
CONFIG=/etc/wireguard/wg0.conf

# Exit if config doesn't exist
[ -f "$CONFIG" ] || exit 0

# Load init functions
. /lib/lsb/init-functions

case "$1" in
  start)
    log_daemon_msg "Starting $DESC" "$NAME"
    /usr/local/bin/wg-start > /var/log/wireguard-start.log 2>&1
    if [ $? -eq 0 ]; then
        log_end_msg 0
    else
        log_end_msg 1
        echo "Check /var/log/wireguard-start.log for details"
    fi
    ;;
  stop)
    log_daemon_msg "Stopping $DESC" "$NAME"
    /usr/local/bin/wg-stop
    log_end_msg $?
    ;;
  restart|force-reload)
    $0 stop
    sleep 1
    $0 start
    ;;
  status)
    /usr/local/bin/wg-status
    ;;
  *)
    echo "Usage: service wireguard {start|stop|restart|status}" >&2
    exit 3
    ;;
esac

exit 0
SCRIPT_END

chmod +x /etc/init.d/wireguard
update-rc.d wireguard defaults

echo ""
echo "Service installation complete!"
echo ""
echo "Service commands:"
echo "  Start:   service wireguard start"
echo "  Stop:    service wireguard stop"
echo "  Status:  service wireguard status"
echo "  Restart: service wireguard restart"
echo ""
echo "Auto-start on boot: ENABLED"
echo ""
echo "To start the service now:"
echo "  service wireguard start"