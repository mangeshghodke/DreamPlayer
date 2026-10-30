# libsmb2 object code (LGPL-2.1)

This directory holds the **object code** of libsmb2, which DreamPlayer links
statically into the iOS app.

libsmb2 is licensed under the GNU Lesser General Public License v2.1, and
LGPL-2.1 §6(a) requires the object code of a statically linked library to
accompany the work, so that the user can modify the library and relink it.
(LGPL-3.0 has an "App Store exception" that removes this obligation;
libsmb2 is 2.1, which does not have one.)

`libsmb2-objects.zip` is **generated** by `ios/libsmb2_build.sh` at build
time and is therefore not committed. It contains:

- `obj/` — every libsmb2 translation unit compiled to arm64 Mach-O
- `source/` — the complete libsmb2 sources that build was compiled from
- `LICENCE-LGPL-2.1.txt` + `COPYING` — the license and the copyright notice
- `RELINK.txt` — how to relink a modified libsmb2

The app copies the archive into its own Documents directory on first use, so
it is reachable through the Files app under **On My iPad → DreamPlayer**, and
the *Open-source licenses* screen in Settings points at it.

The build fails if the archive is missing or suspiciously small — an iOS
build that ships without it would quietly break the license.
