# Changelog

## 1.5.1
- Reader names differ between platforms - Windows reports `ACS ACR122U PICC Interface 0`,
  pcsc-lite reports `ACS ACR122U 00 00` - so `-ReaderName` no longer requires a literal
  substring match. A name that does not match exactly falls back to a per-word score, and
  the error now lists the readers seen and suggests a shorter fragment
- Tag identification is more robust on Linux:
  - `GET_VERSION` is tried through both PN532 wrappers, `InDataExchange` and
    `InCommunicateThru`. The Linux CCID driver frequently rejects the first
  - the NDEF capability container at page 3 is used as a second method - a plain read of a
    page every NTAG has
  - the page probe now runs smallest chip first and resets the card between attempts. A
    read past the end of memory makes the tag NAK, which wedges the card on pcsc-lite and
    made every later probe fail as well
  - the failure message lists what was tried and the status word each attempt returned
- Install instructions now cover the Linux and macOS module path
  (`~/.local/share/powershell/Modules`); `Unblock-File` is Windows-only and is skipped
  elsewhere

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
