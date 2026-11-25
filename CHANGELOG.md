# Changelog

## Unreleased

- Clicking inside the panel no longer closes it, so cards can be expanded. The surface height was never reported, so every click counted as outside.
- The expanded Wi-Fi card lists nearby networks. Tap one to join it; a secured network the Mac has not joined before asks for its password inline. Listing networks needs Location access.
- The expanded battery card has a Low Power Mode switch. Changing it asks for an administrator password and applies to both battery and power adapter.
- Clicking the icon now opens a panel with volume, Wi-Fi, and battery cards in place of the menu. Cards expand for details, and transitions use springs that respect Reduce Motion.
- The volume slider has 16 notches and snaps to the nearest step on release.
- The volume key HUD is now a compact island below the icon that expands into the panel when clicked.
- Quitting from the panel needs a 1-second press; `⌘Q` and the right-click menu still quit at once.
- When Accessibility access is missing, the panel explains why it is needed before asking.
- DuoIcon now follows macOS language preferences, with English and Korean interfaces and English as the fallback. Per-app language settings take effect after relaunch.
- Menus, status messages, settings, tooltips, and accessibility text use the selected language.
- Built apps keep their translations when moved or installed on another Mac.
- The README is available in English and explains language selection.
