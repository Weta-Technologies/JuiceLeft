# JuiceLeft Privacy Policy

_Last updated: 26 September 2026_

JuiceLeft is made by [CyborgFingers](https://github.com/CyborgFingers). In short: **JuiceLeft collects nothing.**

- No accounts, analytics, tracking, advertising or crash reporting.
- The only network activity is **checking for updates**: JuiceLeft asks GitHub for its latest release (a standard web
  request, like visiting the releases page — no account, no identifiers, nothing about you or your Mac beyond what any
  web request carries), and downloads an update only when you click **Update Now**. You can turn update checks off in
  the app's settings. Updates are verified with CyborgFingers' signing key before they are installed. Its optional Apple Intelligence tips are generated entirely on your Mac by Apple's on-device model; nothing leaves your Mac.
- Links you click (for example to GitHub) open in your web browser.
- Nothing is sold, rented or shared — there is nothing to share.

## What stays on your Mac

- Your settings, in `~/Library/Preferences/io.github.cyborgfingers.juiceleft.plist`.
- Battery history for the forecast and health coach (battery level, battery watts, charger on/off, and a daily line of cycle count and health), in `~/Library/Application Support/JuiceLeft/history.json` — a few hundred KB at most. It contains no app names, files or personal information.
- If you use energy modes or the charging light: small request files in `/Library/Application Support/JuiceLeft/`, read only by JuiceLeft's own helper.
- The power-use list reads which of your apps are using the processor while the panel is open; it is shown, never stored or sent.

This data never leaves your Mac. You can delete it at any time (see the README's Uninstall section).

## Permissions JuiceLeft may ask for

- **Administrator password** — only if you use energy modes or the charging light, to install the helper.
- **Notifications** — optional, for low-battery and charging alerts.
- **Login item** — so JuiceLeft starts when you log in; you can turn this off.

## Children

JuiceLeft collects no personal information from anyone, including children.

## Changes to this policy

If this policy ever changes, the new version will be published here before the release it applies to and mentioned in
that release's notes.

## Contact

Open an issue at <https://github.com/CyborgFingers/JuiceLeft/issues>.
