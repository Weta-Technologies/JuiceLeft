# Security Policy

## Reporting a vulnerability

Please report security problems **privately**: on GitHub, open the repository's **Security** tab and choose
**Report a vulnerability** (<https://github.com/Weta-Technologies/JuiceLeft/security/advisories/new>). Don't open a public issue
for a security problem.

Include what you found, how to reproduce it, and the JuiceLeft and macOS versions. You'll get an acknowledgement as soon as
possible, and a fix will be released through the normal releases page.

## Verifying a download

Official builds are signed with Apple Developer ID certificates issued to **Weta Technologies Limited (3SYP5AP3FD)**, which
owns and publishes JuiceLeft, and notarized by Apple. Updates are also signed with the update-signing key
(`cyborgfingers.pub`) and JuiceLeft refuses any update that fails that check. To check a copy yourself:

```sh
pkgutil --check-signature JuiceLeft.pkg                            # Developer ID Installer: WETA TECHNOLOGIES LIMITED (3SYP5AP3FD)
codesign -dv --verbose=2 /Applications/JuiceLeft.app 2>&1 | grep Authority   # Developer ID Application: WETA TECHNOLOGIES LIMITED (3SYP5AP3FD)
spctl -a -vv /Applications/JuiceLeft.app                                   # source=Notarized Developer ID
```

If a copy is signed by anyone else, don't run it, and please report where you found it.

## Supported versions

Only the latest release on <https://github.com/Weta-Technologies/JuiceLeft/releases> receives security fixes.

## Scope

Reporting a vulnerability does not grant any licence to the Software beyond the JuiceLeft licence agreement (LICENSE).
