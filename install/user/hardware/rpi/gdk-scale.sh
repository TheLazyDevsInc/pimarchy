# A Pi usually drives ordinary 1x HDMI monitors, where the shipped GDK scale of
# 2 draws XWayland GTK apps twice too large. Lower only that, and only while
# monitors.lua still has the shipped value; the monitor scale stays "auto".
# omarchy-hyprland-monitor-scaling would ask the running compositor, and user
# setup may run before any session exists.
monitors_lua="$HOME/.config/hypr/monitors.lua"

if omarchy-hw-aarch64-rpi && [[ -f $monitors_lua ]] && grep -qx 'local omarchy_gdk_scale = 2' "$monitors_lua"; then
  echo "Detected a Raspberry Pi. Setting GDK scale to 1 for its HDMI monitors."
  sed -i 's/^local omarchy_gdk_scale = 2$/local omarchy_gdk_scale = 1/' "$monitors_lua"
fi
