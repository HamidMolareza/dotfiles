#!/bin/bash

# Set the temperature threshold (in Celsius) to trigger a warning
threshold=40

# Set the D-Bus session bus address
export DBUS_SESSION_BUS_ADDRESS=$(grep -z DBUS_SESSION_BUS_ADDRESS /proc/$(pgrep -u $LOGNAME gnome-session)/environ | cut -d= -f2-)

while true; do
    # Get the CPU temperature using sensors
    temperature=$(sensors | grep 'Package id 0' | awk '{print $4}' | cut -c 2-3)

    # Check if the temperature exceeds the threshold
    if [ "$temperature" -gt "$threshold" ]; then
        # Send a notification
        DISPLAY=:0 notify-send "High CPU Temperature Warning" "Current Temperature: $temperature°C\nThreshold: $threshold°C"
    fi

    # Wait for 5 minutes before checking again
    # sleep 300
    sleep 20
done
