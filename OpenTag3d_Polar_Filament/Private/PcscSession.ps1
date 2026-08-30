# PC/SC interop over winscard.dll (Windows). Loaded once per session.

if (-not ('OpenTag3D.PcscNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace OpenTag3D {

    // Windows: winscard.dll, Unicode entry points, DWORD is 32-bit, handles are HANDLE-sized.
    [StructLayout(LayoutKind.Sequential)]
    public struct SCARD_IO_REQUEST {
        public int dwProtocol;
        public int cbPciLength;
    }

    // pcsc-lite on Linux: LONG/DWORD are C long, so 64-bit on LP64. The PCI struct is
    // therefore 16 bytes here against 8 on Windows - it cannot be shared.
    [StructLayout(LayoutKind.Sequential)]
    public struct SCARD_IO_REQUEST_LP64 {
        public long dwProtocol;
        public long cbPciLength;
    }

    // macOS PCSC framework: DWORD is uint32_t even on 64-bit, unlike Linux.
    [StructLayout(LayoutKind.Sequential)]
    public struct SCARD_IO_REQUEST_MAC {
        public int dwProtocol;
        public int cbPciLength;
    }

    public static class PcscConst {
        public const int SCARD_SCOPE_USER      = 0;
        public const int SCARD_SHARE_SHARED    = 2;
        public const int SCARD_SHARE_EXCLUSIVE = 1;
        public const int SCARD_PROTOCOL_T0     = 1;
        public const int SCARD_PROTOCOL_T1     = 2;
        public const int SCARD_LEAVE_CARD      = 0;
    }

    public static class PcscNative {
        [DllImport("winscard.dll", SetLastError = true)]
        public static extern int SCardEstablishContext(int dwScope, IntPtr r1, IntPtr r2, out IntPtr phContext);

        [DllImport("winscard.dll", CharSet = CharSet.Unicode, EntryPoint = "SCardListReadersW")]
        public static extern int SCardListReaders(IntPtr hContext, string mszGroups, char[] mszReaders, ref int pcchReaders);

        [DllImport("winscard.dll", CharSet = CharSet.Unicode, EntryPoint = "SCardConnectW")]
        public static extern int SCardConnect(IntPtr hContext, string szReader, int dwShareMode,
                                              int dwPreferredProtocols, out IntPtr phCard, out int pdwActiveProtocol);

        [DllImport("winscard.dll")]
        public static extern int SCardTransmit(IntPtr hCard, ref SCARD_IO_REQUEST pioSendPci,
                                               byte[] pbSendBuffer, int cbSendLength,
                                               IntPtr pioRecvPci, byte[] pbRecvBuffer, ref int pcbRecvLength);

        [DllImport("winscard.dll")]
        public static extern int SCardDisconnect(IntPtr hCard, int dwDisposition);

        [DllImport("winscard.dll")]
        public static extern int SCardReleaseContext(IntPtr hContext);
    }

    // pcsc-lite exports ANSI names only - there is no SCardListReadersW - and reader lists
    // come back as a NUL-separated char multi-string rather than wide chars.
    public static class PcscNativeLinux {
        const string LIB = "libpcsclite.so.1";

        [DllImport(LIB)]
        public static extern long SCardEstablishContext(long dwScope, IntPtr r1, IntPtr r2, out long phContext);

        [DllImport(LIB, CharSet = CharSet.Ansi)]
        public static extern long SCardListReaders(long hContext, byte[] mszGroups, byte[] mszReaders, ref long pcchReaders);

        [DllImport(LIB, CharSet = CharSet.Ansi)]
        public static extern long SCardConnect(long hContext, string szReader, long dwShareMode,
                                               long dwPreferredProtocols, out long phCard, out long pdwActiveProtocol);

        [DllImport(LIB)]
        public static extern long SCardTransmit(long hCard, ref SCARD_IO_REQUEST_LP64 pioSendPci,
                                                byte[] pbSendBuffer, long cbSendLength,
                                                IntPtr pioRecvPci, byte[] pbRecvBuffer, ref long pcbRecvLength);

        [DllImport(LIB)]
        public static extern long SCardDisconnect(long hCard, long dwDisposition);

        [DllImport(LIB)]
        public static extern long SCardReleaseContext(long hContext);
    }

    // Same API as Linux, but DWORD stays 32-bit, so the widths differ throughout.
    public static class PcscNativeMac {
        const string LIB = "/System/Library/Frameworks/PCSC.framework/PCSC";

        [DllImport(LIB)]
        public static extern int SCardEstablishContext(int dwScope, IntPtr r1, IntPtr r2, out int phContext);

        [DllImport(LIB, CharSet = CharSet.Ansi)]
        public static extern int SCardListReaders(int hContext, byte[] mszGroups, byte[] mszReaders, ref int pcchReaders);

        [DllImport(LIB, CharSet = CharSet.Ansi)]
        public static extern int SCardConnect(int hContext, string szReader, int dwShareMode,
                                              int dwPreferredProtocols, out int phCard, out int pdwActiveProtocol);

        [DllImport(LIB)]
        public static extern int SCardTransmit(int hCard, ref SCARD_IO_REQUEST_MAC pioSendPci,
                                               byte[] pbSendBuffer, int cbSendLength,
                                               IntPtr pioRecvPci, byte[] pbRecvBuffer, ref int pcbRecvLength);

        [DllImport(LIB)]
        public static extern int SCardDisconnect(int hCard, int dwDisposition);

        [DllImport(LIB)]
        public static extern int SCardReleaseContext(int hContext);
    }
}
'@
}

function Get-PcscPlatform {
    <#
    .SYNOPSIS
        Which PC/SC implementation this host uses: Windows, Linux or macOS.
    #>
    if ($PSVersionTable.PSVersion.Major -lt 6) { return 'Windows' }
    if ($IsWindows) { return 'Windows' }
    if ($IsMacOS)   { return 'macOS' }
    if ($IsLinux)   { return 'Linux' }
    throw "Unrecognised platform; no PC/SC implementation known."
}

function Get-PcscErrorText {
    param([long]$Code)
    # pcsc-lite and winscard share the SCARD_* numbering. The L suffixes matter: PowerShell
    # parses a bare 0x8010002E as a negative Int32, which would never match the masked value.
    $c = $Code -band 0xFFFFFFFFL
    switch ($c) {
        0x8010000CL { 'No tag on the reader. Place the tag and try again.' }
        0x8010000FL { 'Reader is in use exclusively by another process.' }
        0x80100017L { 'Reader is unavailable or in use by another process.' }
        0x8010001DL { 'The PC/SC service is not running. On Linux start pcscd; on Windows start the Smart Card service.' }
        0x8010002EL { 'No readers available. Check the reader is plugged in and the service can see it.' }
        0x8010006AL { 'Access denied by the PC/SC service. On Linux this is usually polkit: add your user to the pcscd policy, or run pcscd --disable-polkit.' }
        0x80100069L { 'The tag was removed during the operation.' }
        0x80100066L { 'The tag was reset during the operation.' }
        default     { '0x{0:X8}' -f $c }
    }
}

function Get-PcscReader {
    <#
    .SYNOPSIS
        Lists PC/SC reader names visible to the smart card service.
    #>
    [CmdletBinding()]
    param()

    $platform = Get-PcscPlatform

    if ($platform -eq 'Windows') {
        $ctx = [IntPtr]::Zero
        $rc = [OpenTag3D.PcscNative]::SCardEstablishContext([OpenTag3D.PcscConst]::SCARD_SCOPE_USER, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$ctx)
        if ($rc -ne 0) { throw "SCardEstablishContext failed ($(Get-PcscErrorText $rc)). Is the Smart Card service running?" }
        try {
            $len = 0
            $rc = [OpenTag3D.PcscNative]::SCardListReaders($ctx, $null, $null, [ref]$len)
            if ($rc -ne 0) { throw "No PC/SC readers found ($(Get-PcscErrorText $rc))." }
            $buf = [char[]]::new($len)
            $rc = [OpenTag3D.PcscNative]::SCardListReaders($ctx, $null, $buf, [ref]$len)
            if ($rc -ne 0) { throw "SCardListReaders failed ($(Get-PcscErrorText $rc))." }
            (-join $buf).Split([char]0) | Where-Object { $_ }
        }
        finally { [void][OpenTag3D.PcscNative]::SCardReleaseContext($ctx) }
        return
    }

    # --- pcsc-lite: ANSI multi-string of NUL-separated names ---
    if ($platform -eq 'Linux') {
        $ctx = [long]0
        $rc = [OpenTag3D.PcscNativeLinux]::SCardEstablishContext([OpenTag3D.PcscConst]::SCARD_SCOPE_USER, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$ctx)
        if ($rc -ne 0) { throw "SCardEstablishContext failed ($(Get-PcscErrorText $rc))." }
        try {
            $len = [long]0
            $rc = [OpenTag3D.PcscNativeLinux]::SCardListReaders($ctx, $null, $null, [ref]$len)
            if ($rc -ne 0) { throw "No PC/SC readers found ($(Get-PcscErrorText $rc))." }
            $buf = [byte[]]::new($len)
            $rc = [OpenTag3D.PcscNativeLinux]::SCardListReaders($ctx, $null, $buf, [ref]$len)
            if ($rc -ne 0) { throw "SCardListReaders failed ($(Get-PcscErrorText $rc))." }
            [Text.Encoding]::UTF8.GetString($buf).Split([char]0) | Where-Object { $_ }
        }
        finally { [void][OpenTag3D.PcscNativeLinux]::SCardReleaseContext($ctx) }
        return
    }

    $ctx = 0
    $rc = [OpenTag3D.PcscNativeMac]::SCardEstablishContext([OpenTag3D.PcscConst]::SCARD_SCOPE_USER, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$ctx)
    if ($rc -ne 0) { throw "SCardEstablishContext failed ($(Get-PcscErrorText $rc))." }
    try {
        $len = 0
        $rc = [OpenTag3D.PcscNativeMac]::SCardListReaders($ctx, $null, $null, [ref]$len)
        if ($rc -ne 0) { throw "No PC/SC readers found ($(Get-PcscErrorText $rc))." }
        $buf = [byte[]]::new($len)
        $rc = [OpenTag3D.PcscNativeMac]::SCardListReaders($ctx, $null, $buf, [ref]$len)
        if ($rc -ne 0) { throw "SCardListReaders failed ($(Get-PcscErrorText $rc))." }
        [Text.Encoding]::UTF8.GetString($buf).Split([char]0) | Where-Object { $_ }
    }
    finally { [void][OpenTag3D.PcscNativeMac]::SCardReleaseContext($ctx) }
}

function Connect-PcscCard {
    [CmdletBinding()]
    param(
        [string]$ReaderName,
        [switch]$Exclusive
    )

    $platform = Get-PcscPlatform
    $readers  = @(Get-PcscReader)
    if (-not $readers) { throw "No PC/SC readers detected." }

    if ($ReaderName) {
        $reader = $readers | Where-Object { $_ -like "*$ReaderName*" } | Select-Object -First 1
        if (-not $reader) { throw "Reader matching '$ReaderName' not found. Available: $($readers -join '; ')" }
    }
    else {
        $reader = $readers | Where-Object { $_ -match 'ACR122' } | Select-Object -First 1
        if (-not $reader) {
            $reader = $readers[0]
            Write-Warning "No ACR122 reader found; using '$reader'."
        }
    }

    $share = if ($Exclusive) { [OpenTag3D.PcscConst]::SCARD_SHARE_EXCLUSIVE } else { [OpenTag3D.PcscConst]::SCARD_SHARE_SHARED }
    $want  = [OpenTag3D.PcscConst]::SCARD_PROTOCOL_T0 -bor [OpenTag3D.PcscConst]::SCARD_PROTOCOL_T1

    switch ($platform) {
        'Windows' {
            $ctx = [IntPtr]::Zero
            $rc = [OpenTag3D.PcscNative]::SCardEstablishContext([OpenTag3D.PcscConst]::SCARD_SCOPE_USER, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$ctx)
            if ($rc -ne 0) { throw "SCardEstablishContext failed ($(Get-PcscErrorText $rc))." }
            $card = [IntPtr]::Zero; $proto = 0
            $rc = [OpenTag3D.PcscNative]::SCardConnect($ctx, $reader, $share, $want, [ref]$card, [ref]$proto)
            if ($rc -ne 0) {
                [void][OpenTag3D.PcscNative]::SCardReleaseContext($ctx)
                throw "Connect to '$reader' failed: $(Get-PcscErrorText $rc)"
            }
            $pci = New-Object OpenTag3D.SCARD_IO_REQUEST
            $pci.dwProtocol = $proto; $pci.cbPciLength = 8
        }
        'Linux' {
            $ctx = [long]0
            $rc = [OpenTag3D.PcscNativeLinux]::SCardEstablishContext([OpenTag3D.PcscConst]::SCARD_SCOPE_USER, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$ctx)
            if ($rc -ne 0) { throw "SCardEstablishContext failed ($(Get-PcscErrorText $rc))." }
            $card = [long]0; $proto = [long]0
            $rc = [OpenTag3D.PcscNativeLinux]::SCardConnect($ctx, $reader, $share, $want, [ref]$card, [ref]$proto)
            if ($rc -ne 0) {
                [void][OpenTag3D.PcscNativeLinux]::SCardReleaseContext($ctx)
                throw "Connect to '$reader' failed: $(Get-PcscErrorText $rc)"
            }
            $pci = New-Object OpenTag3D.SCARD_IO_REQUEST_LP64
            $pci.dwProtocol = $proto; $pci.cbPciLength = 16   # sizeof(SCARD_IO_REQUEST) on LP64
        }
        'macOS' {
            $ctx = 0
            $rc = [OpenTag3D.PcscNativeMac]::SCardEstablishContext([OpenTag3D.PcscConst]::SCARD_SCOPE_USER, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$ctx)
            if ($rc -ne 0) { throw "SCardEstablishContext failed ($(Get-PcscErrorText $rc))." }
            $card = 0; $proto = 0
            $rc = [OpenTag3D.PcscNativeMac]::SCardConnect($ctx, $reader, $share, $want, [ref]$card, [ref]$proto)
            if ($rc -ne 0) {
                [void][OpenTag3D.PcscNativeMac]::SCardReleaseContext($ctx)
                throw "Connect to '$reader' failed: $(Get-PcscErrorText $rc)"
            }
            $pci = New-Object OpenTag3D.SCARD_IO_REQUEST_MAC
            $pci.dwProtocol = $proto; $pci.cbPciLength = 8
        }
    }

    [pscustomobject]@{
        Platform = $platform
        Reader   = $reader
        Context  = $ctx
        Card     = $card
        Protocol = $proto
        Pci      = $pci
    }
}

function Invoke-PcscApdu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [byte[]]$Apdu,
        [int]$ReceiveLength = 258
    )

    $recv = [byte[]]::new($ReceiveLength)
    $pci  = $Session.Pci

    switch ($Session.Platform) {
        'Windows' {
            $len = $recv.Length
            $rc = [OpenTag3D.PcscNative]::SCardTransmit($Session.Card, [ref]$pci, $Apdu, $Apdu.Length, [IntPtr]::Zero, $recv, [ref]$len)
        }
        'Linux' {
            $len = [long]$recv.Length
            $rc = [OpenTag3D.PcscNativeLinux]::SCardTransmit($Session.Card, [ref]$pci, $Apdu, $Apdu.Length, [IntPtr]::Zero, $recv, [ref]$len)
        }
        'macOS' {
            $len = [int]$recv.Length
            $rc = [OpenTag3D.PcscNativeMac]::SCardTransmit($Session.Card, [ref]$pci, $Apdu, $Apdu.Length, [IntPtr]::Zero, $recv, [ref]$len)
        }
    }

    if ($rc -ne 0) {
        throw "SCardTransmit failed ($(Get-PcscErrorText $rc)) for APDU $((($Apdu | ForEach-Object { $_.ToString('X2') }) -join ' '))"
    }
    if ($len -lt 2) { throw "Short response from reader." }

    $sw1 = $recv[$len - 2]
    $sw2 = $recv[$len - 1]
    $data = if ($len -gt 2) { $recv[0..($len - 3)] } else { [byte[]]@() }

    [pscustomobject]@{
        Data    = [byte[]]$data
        SW      = '{0:X2}{1:X2}' -f $sw1, $sw2
        Success = ($sw1 -eq 0x90 -and $sw2 -eq 0x00)
    }
}

function Disconnect-PcscCard {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Session)

    switch ($Session.Platform) {
        'Windows' {
            if ($Session.Card -ne [IntPtr]::Zero) { [void][OpenTag3D.PcscNative]::SCardDisconnect($Session.Card, [OpenTag3D.PcscConst]::SCARD_LEAVE_CARD) }
            if ($Session.Context -ne [IntPtr]::Zero) { [void][OpenTag3D.PcscNative]::SCardReleaseContext($Session.Context) }
        }
        'Linux' {
            if ($Session.Card -ne 0) { [void][OpenTag3D.PcscNativeLinux]::SCardDisconnect($Session.Card, [OpenTag3D.PcscConst]::SCARD_LEAVE_CARD) }
            if ($Session.Context -ne 0) { [void][OpenTag3D.PcscNativeLinux]::SCardReleaseContext($Session.Context) }
        }
        'macOS' {
            if ($Session.Card -ne 0) { [void][OpenTag3D.PcscNativeMac]::SCardDisconnect($Session.Card, [OpenTag3D.PcscConst]::SCARD_LEAVE_CARD) }
            if ($Session.Context -ne 0) { [void][OpenTag3D.PcscNativeMac]::SCardReleaseContext($Session.Context) }
        }
    }
}

function Get-NtagType {
    <#
    .SYNOPSIS
        Identifies the chip on the reader as NTAG213/215/216.
    .DESCRIPTION
        Prefers GET_VERSION (0x60), passed through the reader with the PN532 InDataExchange
        pseudo-APDU. Byte 6 of the response is the storage size code: 0x0F = NTAG213,
        0x11 = NTAG215, 0x13 = NTAG216.

        Readers that do not accept the pseudo-APDU fall back to probing the last user page of
        each candidate with a plain READ BINARY, largest first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Session)

    # --- GET_VERSION via FF 00 00 00 04 D4 40 01 60 ---
    try {
        $r = Invoke-PcscApdu -Session $Session -Apdu ([byte[]]@(0xFF,0x00,0x00,0x00,0x04,0xD4,0x40,0x01,0x60)) -ReceiveLength 32
        if ($r.Success -and $r.Data.Length -ge 11 -and $r.Data[0] -eq 0xD5 -and $r.Data[1] -eq 0x41 -and $r.Data[2] -eq 0x00) {
            $version = $r.Data[3..10]
            $storage = $version[6]
            Write-Verbose ("GET_VERSION: " + (($version | ForEach-Object { $_.ToString('X2') }) -join ' '))
            switch ($storage) {
                0x0F { return @{ TagType = 'NTAG213'; UserSize = 144; TotalSize = 180; Method = 'GET_VERSION' } }
                0x11 { return @{ TagType = 'NTAG215'; UserSize = 504; TotalSize = 540; Method = 'GET_VERSION' } }
                0x13 { return @{ TagType = 'NTAG216'; UserSize = 888; TotalSize = 924; Method = 'GET_VERSION' } }
                default {
                    Write-Verbose ("Unrecognised storage size 0x{0:X2}; falling back to page probe." -f $storage)
                }
            }
        }
        else { Write-Verbose "GET_VERSION not supported by this reader/tag; falling back to page probe." }
    }
    catch { Write-Verbose "GET_VERSION failed ($($_.Exception.Message)); falling back to page probe." }

    # --- fallback: probe the last user page of each candidate, largest first ---
    $candidates = @(
        @{ TagType = 'NTAG216'; LastPage = 0xE1; UserSize = 888; TotalSize = 924 }
        @{ TagType = 'NTAG215'; LastPage = 0x81; UserSize = 504; TotalSize = 540 }
        @{ TagType = 'NTAG213'; LastPage = 0x27; UserSize = 144; TotalSize = 180 }
    )
    foreach ($c in $candidates) {
        $r = Invoke-PcscApdu -Session $Session -Apdu ([byte[]]@(0xFF,0xB0,0x00,[byte]$c.LastPage,0x04)) -ReceiveLength 16
        if ($r.Success) {
            Write-Verbose ("Page probe: 0x{0:X2} readable -> {1}" -f $c.LastPage, $c.TagType)
            return @{ TagType = $c.TagType; UserSize = $c.UserSize; TotalSize = $c.TotalSize; Method = 'page probe' }
        }
    }
    throw "Could not identify the tag as NTAG213, NTAG215 or NTAG216."
}
