**Original Repo** : https://github.com/dutkiewiczmaciej/MakLock
<div>huge thank you to the original dev for creating a free and open-source tool bridging the final gap for total security for your mac, thank you Mak.</div>

<h1>What's New?</h1>

<h2>Bug fixes</h2>

- App no longer quits when closing the About window. The About window was released twice on close, killing the process. (upstream #47)

- "Require authentication on app switch" now works. The setting existed but nothing read it. With it on, an unlocked app re-locks as soon as you switch away from it. (upstream #51)
  
- "Require authentication on app launch" can be turned off and on without issues now.

- Messages app wouldn't re-lock when it was re-opened/switched out of so that has been fixed

<h2>Security changes</h2>

- I found originally if you just waited out the automatic prompt closure when no authentication was registered the app would just remain open in the foreground allowing people to just wait out and bypass the lock entirely, this has been fixed, so if the prompt expires the app just closes and re-locks.

- Closing or minimising app's (via the red X or yellow -) also re-locks apps now, whereas previously it wouldn't do anything. In the previous build as macOS doesn't notify apps when another app's window closes, i've changed it so MakLock checks the window server twice a second (metadata only, no permissions) while a protected app is running. When an app is frontmost with no visible windows, its session ends; the next window that appears is locked. if a protected app is not running it will not run the two second checks. Battery-wise it's minimal impact, comparable to the clock in your system tray.

<h2>Removed</h2>

- Automatic updates are disabled. The official build checks the original developer's update feed daily which also for some reason showed a duplicate update. This fork removes that, so it can't replace itself with the official build (which would reintroduce the bugs above). I do use this app on a daily, so if something does break in a future update i'm likely to fix it by the next day fingers crossed. However for future releases you'll have to return to this repo.

<h2>Install</h2>

- Download MakLock.dmg from the Releases page.
- Open the DMG and drag MakLock onto the Applications shortcut.
- Open MakLock from your Applications folder. It runs in the menu bar — look for the lock icon at the top right of your screen. There's no Dock icon.
- If you're new to MakLock, an onboarding window walks you through setting a backup password and choosing apps to protect.

Releases are signed with a Developer ID certificate and notarized by Apple, so macOS opens them without any warnings or workarounds.

If you already have the official MakLock installed, quit it from its menu bar icon first, delete it from Applications, then follow the steps above. Your protected-apps list and settings carry over.

macOS will ask for Bluetooth permission on first launch. That's only used for the Apple Watch unlock feature; decline it if you don't use that.

<h2>Help?!?</h2>

- If for some reason the authentication doesn't work you can also either wait 60 seconds for the prompt to auto-dismiss itself or use Cmd + Opt + Shift + Ctrl + U to instantly terminate the prompt.

-------------------------------------------------

This has been tested on macOS Tahoe 26.6.2 (WORKING), all core functions work however i can't confirm if the apple watch unlock works since i don't actually own one.

