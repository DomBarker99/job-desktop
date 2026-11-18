# Goes to /etc/profile.d/desktop.sh. Lets a login shell (SSH, tmux) find the
# running desktop, so a program started there opens its window on it.
export DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/desktop-runtime
export XAUTHORITY="$XDG_RUNTIME_DIR/Xauthority"
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/system-bus"
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
if [ -r "$XDG_RUNTIME_DIR/session-bus.address" ]; then
    export DBUS_SESSION_BUS_ADDRESS="$(head -n 1 "$XDG_RUNTIME_DIR/session-bus.address")"
fi
