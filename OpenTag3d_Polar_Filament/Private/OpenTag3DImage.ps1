# Builds a full NTAG21x memory image from an OpenTag3D record or payload.
# Shared by Export-OpenTag3DPayload and the GUI's edit screen.

function Get-OpenTag3DTagSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('NTAG213','NTAG215','NTAG216')] [string]$TagType)

    # UserSize = writable user memory, TotalSize = full dump incl. header + config pages
    switch ($TagType) {
        'NTAG213' { @{ UserSize = 144; TotalSize = 180; CC = 0x12 } }
        'NTAG215' { @{ UserSize = 504; TotalSize = 540; CC = 0x3E } }
        'NTAG216' { @{ UserSize = 888; TotalSize = 924; CC = 0x6D } }
    }
}

function New-OpenTag3DNdefRecord {
    <#
    .SYNOPSIS
        Wraps an OpenTag3D payload in an application/opentag3d MIME record.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [byte[]]$Payload)

    $type = [Text.Encoding]::ASCII.GetBytes('application/opentag3d')

    if ($Payload.Length -lt 256) {
        # MB | ME | SR | TNF 0x02 (MIME media)
        $header = [byte[]]@(0xD2, [byte]$type.Length, [byte]$Payload.Length)
    }
    else {
        $header = [byte[]]@(0xC2, [byte]$type.Length,
                            [byte](($Payload.Length -shr 24) -band 0xFF),
                            [byte](($Payload.Length -shr 16) -band 0xFF),
                            [byte](($Payload.Length -shr 8)  -band 0xFF),
                            [byte]($Payload.Length -band 0xFF))
    }
    return ,[byte[]]($header + $type + $Payload)
}

function New-OpenTag3DImage {
    <#
    .SYNOPSIS
        Builds a complete tag image around an NDEF record or a raw payload.
    .PARAMETER Data
        For -Format Ndef, the full NDEF record. For -Format Raw, the bare payload.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [byte[]]$Data,
        [Parameter(Mandatory)] [ValidateSet('NTAG213','NTAG215','NTAG216')] [string]$TagType,
        [Parameter(Mandatory)] [ValidateSet('Ndef','Raw')] [string]$Format
    )

    $spec = Get-OpenTag3DTagSpec -TagType $TagType

    if ($Format -eq 'Ndef') {
        # NDEF TLV: 0x03, length (1 byte, or 0xFF + 2 bytes if >254), message, 0xFE terminator
        $len = if ($Data.Length -lt 255) {
                    ,[byte]$Data.Length
               } else {
                    [byte[]]@(0xFF, [byte](([int]$Data.Length -shr 8) -band 0xFF), [byte]($Data.Length -band 0xFF))
               }
        $content = [byte[]]@(0x03) + $len + $Data + [byte[]]@(0xFE)
    }
    else { $content = $Data }

    if ($content.Length -gt $spec.UserSize) {
        throw "Content is $($content.Length) bytes - exceeds $TagType user memory ($($spec.UserSize))."
    }

    $image = [byte[]]::new($spec.TotalSize)

    # --- pages 0-2: placeholder UID with valid BCCs, internal, static lock bytes ---
    # Real UIDs are factory-programmed and read-only; these pages exist so the file is a
    # structurally valid dump, not because they are ever written to a tag.
    $u = [byte[]]@(0x04,0x00,0x00,0x00,0x00,0x00,0x00)      # 0x04 = NXP manufacturer
    [Array]::Copy($u, 0, $image, 0, 3)
    $image[3]  = 0x88 -bxor $u[0] -bxor $u[1] -bxor $u[2]   # BCC0
    [Array]::Copy($u, 3, $image, 4, 4)
    $image[8]  = $u[3] -bxor $u[4] -bxor $u[5] -bxor $u[6]  # BCC1
    $image[9]  = 0x48                                       # internal
    $image[10] = 0x00                                       # static lock 0
    $image[11] = 0x00                                       # static lock 1

    # --- page 3: capability container ---
    $image[12] = 0xE1
    $image[13] = 0x10
    $image[14] = [byte]$spec.CC
    $image[15] = 0x00

    # --- pages 4+: user memory ---
    $userStart = 16                        # page 4
    $userEnd   = $spec.TotalSize - 20      # first byte of the dynamic lock page
    [Array]::Copy($content, 0, $image, $userStart, $content.Length)

    # --- explicitly zero the remainder of user memory ---
    $padStart  = $userStart + $content.Length
    $padLength = $userEnd - $padStart
    if ($padLength -gt 0) {
        [Array]::Clear($image, $padStart, $padLength)
        Write-Verbose "Padded $padLength bytes with 0x00 (offset $padStart to $($userEnd - 1))"
    }

    # --- final 5 pages: dynamic lock + CFG0 + CFG1 + PWD + PACK (factory defaults) ---
    $trailer = [byte[]]@(
        0x00,0x00,0x00,0xBD,   # dynamic lock bytes
        0x04,0x00,0x00,0xFF,   # CFG0: MIRROR, RFUI, MIRROR_PAGE, AUTH0
        0x00,0x05,0x00,0x00,   # CFG1: ACCESS, RFUI
        0xFF,0xFF,0xFF,0xFF,   # PWD
        0x00,0x00,0x00,0x00    # PACK + RFUI
    )
    [Array]::Copy($trailer, 0, $image, $spec.TotalSize - 20, 20)

    return ,[byte[]]$image
}
