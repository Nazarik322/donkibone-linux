-- Celestia additions to the caelestia Hyprland config.
-- This file is yours: caelestia updates never overwrite it.

-- Keyboard layouts chosen in the installer (default: English + Russian,
-- Alt+Shift switches like on Windows).
hl.config({
    input = {
        kb_layout  = "us,ru",
        kb_variant = "",
        kb_options = "grp:alt_shift_toggle",
    },
})

-- The session starts through autologin, so it is locked straight away and the
-- Caelestia lock screen works as the login screen.
hl.on("hyprland.start", function()
    hl.exec_cmd("/usr/lib/celestia/session-start")
end)
