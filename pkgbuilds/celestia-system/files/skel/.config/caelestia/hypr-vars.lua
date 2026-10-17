-- Overrides for ~/.config/hypr/variables.lua (default apps, keybinds, looks).
-- Celestia ships no VS Codium, so the editor key opens micro in the terminal.
-- Celestia has no swap (zram only), so hibernation is unavailable: the sleep key
-- (Super+Shift+L) and gesture use plain suspend instead of suspend-then-hibernate.
return {
    editor          = "foot -e micro",
    sleepGestureCmd = "systemctl suspend",
}
