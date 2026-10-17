# Live session: the installer starts full screen on the first console.
# Other consoles (Ctrl+Alt+F2...) give a normal shell for troubleshooting.
[[ -f ~/.bashrc ]] && . ~/.bashrc

if [[ -z "$WAYLAND_DISPLAY" && "$(tty)" == /dev/tty1 ]]; then
    exec /usr/local/bin/celestia-installer
fi
