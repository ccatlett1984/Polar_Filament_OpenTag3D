# Polar Filament OpenTag3D

A PowerShell module for working with [OpenTag3D](https://opentag3d.info) NFC tags on
Polar Filament spools. It looks up spool data by serial, builds NTAG21x tag images,
reads and decodes existing tags, and writes tags through a PC/SC reader such as the
ACR122U. A local browser UI is included for anyone who would rather not use the console.

Not affiliated with Polar Filament or the OpenTag3D project.

## What it does

- **Look up a spool** by serial and fetch its OpenTag3D payload
- **Build a complete tag image** — 180 bytes (NTAG213), 540 (NTAG215) or 924 (NTAG216),
  including UID/lock/capability-container header and the configuration pages
- **Read a tag** and decode all 36 spec fields, or decode a saved `.bin` on any platform
- **Edit tag data** before writing, with per-field validation
- **Write to a tag** over PC/SC, verifying every page afterwards
- **Browser UI** covering all of the above

## Requirements

| | |
|---|---|
| PowerShell | 5.1 (Windows) or 7+ (any platform) |
| Reading/writing tags | A PC/SC reader — developed against an ACR122U |
| PC/SC service | Windows: Smart Card service. Linux: `pcscd` + `libpcsclite1` + `libccid`. macOS: built in |

Everything else — lookups, building images, decoding saved `.bin` files, the browser UI —
needs nothing beyond PowerShell. See [Platform support](#platform-support).

## Install

```powershell
git clone https://github.com/ccatlett1984/Polar_Filament_OpenTag3D.git
cd Polar_Filament_OpenTag3D
```

Copy the `OpenTag3d_Polar_Filament` folder into a directory on your `$env:PSModulePath`:

```powershell
# PowerShell 7
$dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'

# Windows PowerShell 5.1
$dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'

Copy-Item .\OpenTag3d_Polar_Filament -Destination $dest -Recurse -Force
Get-ChildItem -Recurse (Join-Path $dest 'OpenTag3d_Polar_Filament') | Unblock-File
```

Open a new session — the module autoloads, no `Import-Module` needed.

## Quick start

```powershell
# Save a tag image (defaults: Extended mode, NDEF format, Downloads or ~)
Export-OpenTag3DPayload -TagType NTAG215 -Serial 50017-FYG5

# Fetch and write to a tag in one step
Export-OpenTag3DPayload -TagType NTAG215 -Serial 50017-FYG5 -WriteToTag

# Write a saved image
Write-OpenTag3DTag -Path .\50017-FYG5-NTAG215-Extended-Ndef.bin

# Read the tag on the reader
Read-OpenTag3DTag | Select-Object material, color_name, print_temp, serial

# Decode a saved image (works on Linux and macOS too)
Read-OpenTag3DTag -Path .\tag.bin | Select-Object -ExpandProperty Fields | Format-Table

# Browser UI
Show-OpenTag3DGui
```

All parameters are name-only; nothing binds positionally.

## Commands

### `Export-OpenTag3DPayload`

Fetches a spool payload and builds a tag image, either to a file or straight to a tag.

| Parameter | Values | Notes |
|---|---|---|
| `-TagType` | `NTAG213` `NTAG215` `NTAG216` | Required |
| `-Serial` | e.g. `50017-FYG5` | Required; normalised to upper case; accepts pipeline input |
| `-Mode` | `Core` `Extended` | Defaults to `Core` for NTAG213, `Extended` otherwise |
| `-Format` | `Ndef` `Raw` | Default `Ndef` |
| `-OutputDir` | path | Defaults to Downloads (Windows) or `~` |
| `-WriteToTag` | switch | Write to a reader instead of a file |
| `-ReaderName` | substring | With `-WriteToTag`; defaults to the first `ACR122` |

`-OutputDir` and `-WriteToTag` are mutually exclusive.

### `Write-OpenTag3DTag`

Writes an existing image to a tag.

| Parameter | Values | Notes |
|---|---|---|
| `-Path` | path to `.bin` | Accepts pipeline input from `Get-ChildItem` |
| `-Bytes` | `byte[]` | In-memory image instead of a file |
| `-ReaderName` | substring | Defaults to the first `ACR122` |
| `-SkipBlankPages` | switch | Skips all-zero pages; faster on blank tags |

Always performed: the chip is identified with `GET_VERSION` and checked against the
image before anything is committed; the capability container on page 3 is written and
read back; user memory is read back and compared page by page.

### `Read-OpenTag3DTag`

Reads a tag, or decodes a saved image, and returns the decoded fields.

| Parameter | Values | Notes |
|---|---|---|
| `-Path` | path to `.bin` | Decode a saved image; works on any platform |
| `-ReaderName` | substring | Defaults to the first `ACR122` |
| `-Raw` | switch | Also return the payload bytes |

Every spec field is a property (`material`, `color_name`, `print_temp`, `serial`, …),
plus a `Fields` collection for display.

### `Show-OpenTag3DGui`

Starts a local browser UI on `http://localhost:8787/`.

| Parameter | Values | Notes |
|---|---|---|
| `-Port` | 1024–65535 | Default 8787 |
| `-NoBrowser` | switch | Print the URL instead of launching a browser |
| `-IdleTimeout` | seconds | Default 15; see below |
| `-KeepAlive` | switch | Never stop automatically |

The UI has two screens:

- **Fetch & write** — look up a serial, save an image, write a tag, read a tag
- **View & edit** — load data from a serial or a tag, edit any field, then save or write

The page sends a heartbeat every three seconds. Once the first one arrives, the server
shuts down if the heartbeat stops for `-IdleTimeout` seconds, so closing the tab stops
the server. A page reload is not treated as a close. The listener binds to localhost
only and has no authentication — fine on a desktop, not on a shared machine.

## Tag layout

Images are complete NTAG21x dumps:

| Region | NTAG213 | NTAG215 | NTAG216 |
|---|---|---|---|
| Header (pages 0–3) | 16 bytes | 16 bytes | 16 bytes |
| User memory (page 4 on) | 144 | 504 | 888 |
| Config pages (last 5) | 20 | 20 | 20 |
| **Total** | **180** | **540** | **924** |

Pages 0–2 hold a placeholder UID with valid BCCs, since real UIDs are factory-programmed
and read-only; they exist so the file is a structurally valid dump. Page 3 holds the
capability container (`E1 10 12/3E/6D 00`). The trailing configuration pages carry factory
defaults with password protection disabled.

By default the payload is wrapped as an NDEF message — an `application/opentag3d` MIME
record inside an NDEF TLV — so readers report the tag as NFC Forum Type 2 with a readable
record. `-Format Raw` writes the bare payload at page 4 instead.

NTAG213 holds only the OpenTag3D Core block (0x00–0x6F), so Extended data cannot fit.
Asking for Extended on an NTAG213 falls back to Core with a warning, and the edit screen
lists exactly which fields survive before writing.

## Platform support

| Feature | Windows | Linux | macOS |
|---|---|---|---|
| Look up a spool, build images | yes | yes | yes |
| Decode a saved `.bin` | yes | yes | yes |
| Browser UI | yes | yes | yes |
| Read a tag from a reader | yes | yes | yes\* |
| Write a tag | yes | yes | yes\* |

The PC/SC layer binds three separate implementations, because they are not
interface-compatible:

- **Windows** — `winscard.dll`, Unicode entry points, 32-bit `DWORD`
- **Linux** — `libpcsclite.so.1`, ANSI entry points only (there is no `SCardListReadersW`),
  and `DWORD`/`LONG` are C `long`, so 64-bit on LP64. `SCARD_IO_REQUEST` is 16 bytes here
  against 8 on Windows
- **macOS** — the PCSC framework: same ANSI API as Linux, but `DWORD` stays `uint32_t`

\* The macOS declarations follow the framework headers but have not been exercised against
a reader. Linux has been tested against `libpcsclite.so.1`; Windows is the primary target.

### Linux setup

```bash
sudo apt install pcscd libpcsclite1 libccid    # or the equivalent for your distro
sudo systemctl enable --now pcscd
```

The kernel NFC modules claim an ACR122U on plug-in and pcscd then cannot see it. Blacklist
them:

```bash
echo -e 'blacklist pn533_usb\nblacklist nfc' | sudo tee /etc/modprobe.d/blacklist-nfc.conf
```

then unplug and replug the reader.

## Troubleshooting

**`Failed to listen on prefix ... conflicts with an existing registration`**
Another instance is still holding the port, or an HTTP.sys reservation exists:

```powershell
Get-Process powershell, pwsh | Where-Object { $_.Id -ne $PID }
netsh http show urlacl | Select-String 8787
```

Remove a stale reservation from an elevated prompt with
`netsh http delete urlacl url=http://localhost:8787/`, or just use `-Port 8788`.

**HTTP 429 / "rate limited by the server"**
The lookup service throttles back-to-back requests. Add `Start-Sleep -Seconds 3` between
serials when batching, or fetch to files first and write the tags afterwards.

**`Invalid checksum` / HTTP 403**
The serial has a check digit, so a typo in either half is rejected rather than reported as
"not found". Verify the serial as printed on the spool.

**`Tag on the reader is an NTAG213 but this image is for an NTAG215`**
Exactly what it says — the chip was identified before writing. Rebuild with the right
`-TagType`.

**`No tag on the reader`**
Place the tag and retry.

**`No readers available` / `The PC/SC service is not running`**
On Windows, start the Smart Card service. On Linux, start `pcscd` and check the reader is
visible with `pcsc_scan`. If the reader is plugged in but invisible, blacklist the kernel
NFC modules as above.

**`Access denied by the PC/SC service` (Linux)**
polkit is refusing the client. Add your user to the pcscd policy, or run
`pcscd --disable-polkit` for a quick test.

**Odd `Â` characters in output**
Fixed in 1.4.0. Windows PowerShell 5.1 reads BOM-less `.ps1` files using the ANSI codepage,
which mangles UTF-8. All files are now pure ASCII with a UTF-8 BOM. If you see this, an old
copy of the module is still on `$env:PSModulePath` — delete it and reinstall.

## Notes

- The OpenTag3D field layout follows the published spec at
  [opentag3d.info/spec.json](https://opentag3d.info/spec.json). The parser targets version
  1.003: a newer minor version warns and parses anyway, a newer major version is refused.
- The serial and tag version are displayed but not editable, enforced server-side as well
  as in the UI.
- Page 3 is one-time programmable. The module only ever writes the capability container for
  the tag type it detected, and reads it back to confirm.
- Reading and writing touch user memory only. The UID and the lock/configuration pages on a
  physical tag are never modified.

## License

Choose a license before publishing — add a `LICENSE` file and reference it here.
