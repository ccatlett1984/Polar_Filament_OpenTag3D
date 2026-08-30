# Changelog

## 1.5.0
- Tag reading and writing now work on Linux and macOS through pcsc-lite, not Windows only.
  Three native bindings are declared, since the ABIs differ: Unicode entry points and 32-bit
  `DWORD` on Windows, ANSI entry points with LP64 `DWORD`/`LONG` on Linux, ANSI with 32-bit
  `DWORD` on macOS
- Reader availability is now probed rather than inferred from the operating system, so the
  GUI enables tag buttons whenever a reader is reachable
- PC/SC status codes are translated to readable messages (no reader, no tag, service down,
  polkit refusal) instead of bare hex

## 1.4.0
- Added `Read-OpenTag3DTag` — reads a tag or decodes a saved image into all 36 spec fields
- Added a **View & edit** screen to the GUI: load from a serial or a tag, edit any field,
  then save or write. Serial and tag version are display-only, enforced server-side
- NTAG213 truncation now warns and lists the fields that will be kept before writing
- GUI stops automatically when the page is closed (heartbeat, with `-IdleTimeout`/`-KeepAlive`)
- Output defaults to Downloads on Windows (resolved from the registry, so OneDrive
  redirection is respected) and the home directory elsewhere
- Fixed `Â` appearing before degree and micro signs: source files are now pure ASCII with a
  UTF-8 BOM, and JSON responses declare `charset=utf-8`
- Fixed `-shl` on `[byte]` truncating to byte width, which broke the tag version and any
  NDEF message over 254 bytes
- Fixed unit stripping on values whose unit contains digits (`600 g/10min`)

## 1.3.0
- Added the browser UI (`Show-OpenTag3DGui`), cross-platform via `HttpListener`

## 1.2.0
- Added NTAG213 support, forced to Core mode
- `-Mode` became optional with per-tag defaults
- All parameters are name-only

## 1.1.0
- Added `Write-OpenTag3DTag` — writes an image to a tag over PC/SC
- Chip type confirmed with `GET_VERSION` before writing; user memory verified after

## 1.0.0
- Initial module: `Export-OpenTag3DPayload`
