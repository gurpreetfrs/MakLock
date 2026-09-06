**Original repo:** https://github.com/dutkiewiczmaciej/MakLock

Huge thank you to the original dev for creating a free and open-source tool bridging the final gap for total security for your Mac. Thank you Mak.

This is an unofficial fork with fixes for macOS Tahoe and some security hardening. Everything below is on the `tahoe-fixes` branch.

# What's new?

## Bug fixes

- App no longer quits when closing the About window. The window was released twice on close, killing the process. (upstream #47)
- "Require authentication on app switch" now works. The setting existed but nothing read it. With it on, an unlocked app re-locks as soon as you switch away from it. (upstream #51)
- "Require authentication on app launch" can be turned off and on without issues now.
- Apps that stayed running after closing their last window (Messages, for example) wouldn't re-lock when reopened. Fixed — see "Closing and minimising" below.

## Security changes

- **Waiting out the prompt no longer unlocks the app.** In the official build, if you left the lock prompt for 60 seconds it dismissed itself and left the app open and unlocked in the foreground, so anyone could bypass the lock by waiting. Now, when the prompt times out, the app is hidden (it keeps running, nothing is closed or lost) and re-locks the moment it's clicked again. The panic key (`Cmd + Opt + Shift + Ctrl + U`) does the same: it gets you out of a stuck prompt but never grants access.

- **Closing and minimising re-locks.** Closing an app's last window (red X, Cmd+W) or minimising it (yellow minus) now ends its session, so reopening it from the Dock prompts again. Previously it didn't. macOS doesn't notify apps when another app's window closes, so MakLock checks the window server twice a second (window positions only, no permissions needed) while a protected app is running. When a protected app is frontmost with no visible windows, its session ends; the next window that appears is locked. Hiding with Cmd+H is deliberately exempt, and nothing runs while no protected app is open. Battery impact is minimal, comparable to the clock in your menu bar.

- **Protected apps are blurred when they're in the background.** If a protected app is open but not the one you're using, its windows are frosted over so nothing is readable around the edges of whatever's in front. The blur sits directly behind the app you're actually using, so it never gets in your way, and it clears the instant you click back into the protected app (which then locks, or doesn't, depending on your app-switch setting). If the corner radius of the blur looks off against your apps, it's tunable:

  ```bash
  defaults write com.makmak.MakLock BlurCornerRadius 14
  ```

  then quit and reopen MakLock. `defaults delete com.makmak.MakLock BlurCornerRadius` restores the default.

## Changed

- Accent colour is now macOS system blue instead of gold. It follows light and dark mode automatically.

## Removed

- Automatic updates are disabled. The official build checked the original developer's update feed daily (and for some reason showed a duplicate update). This fork removes that, so it can't replace itself with the official build, which would reintroduce the bugs above. I use this app daily, so if something breaks in a future macOS update I'm likely to fix it quickly, fingers crossed. For updates, come back to this repo's Releases page.

# Requirements

- macOS 13 or later. Tested on macOS Tahoe 26.6.2.
- Apple Silicon and Intel both work.

# Install

1. Download `MakLock.dmg` from the [Releases page](https://github.com/gurpreetfrs/MakLock/releases).
2. Open the DMG and drag **MakLock** onto the **Applications** shortcut.
3. Open MakLock from your Applications folder. It runs in the menu bar (look for the lock icon at the top right of your screen); there's no Dock icon.
4. If you're new to MakLock, an onboarding window walks you through setting a backup password and choosing apps to protect.

Releases are signed with a Developer ID certificate and notarized by Apple, so macOS opens them without warnings or workarounds. Each release also shows a SHA-256 digest next to the DMG; `shasum -a 256 ~/Downloads/MakLock.dmg` should match it.

If you already have the official MakLock installed, quit it from its menu bar icon first, delete it from Applications, then follow the steps above. Your protected-apps list and settings carry over.

macOS will ask for Bluetooth permission on first launch. That's only used for the Apple Watch unlock feature; decline it if you don't use that.

# Help

- **Authentication won't work / prompt is stuck:** wait 60 seconds for it to dismiss itself, or press `Cmd + Opt + Shift + Ctrl + U`. Either way the app is hidden, not unlocked; use your backup password when you try again.
- **Locked out entirely:** open Terminal (MakLock never locks it) and run `pkill -x MakLock`.
- **Uninstall:** quit MakLock, delete it from Applications, then `defaults delete com.makmak.MakLock` to remove settings. The backup password is stored in Keychain Access under "MakLock" if you want that gone too.
- **Bugs:** open an issue on this repo, not the original. Please say which macOS version you're on.

---

Tested on macOS Tahoe 26.6.2 and working. All core functions work; I can't confirm the Apple Watch unlock since I'm too lazy to 🫩.

MIT licensed, same as the original. The original copyright notice is in the LICENSE file.
