# OpenTag3D data structure, per the spec at https://opentag3d.info/spec.json
# All integers unsigned big-endian; strings UTF-8 unless the field says ASCII;
# temperatures stored in Celsius divided by 5.

$script:OpenTag3DSpecVersion = 1003   # the version this parser was written against

# Fields the editor shows but never lets you change. The serial identifies the spool and is
# what the lookup keys on; the tag version describes the format, not the filament.
$script:OpenTag3DReadOnly = @('tag_version','serial')

# Unit strings are built from char codes rather than written literally: Windows PowerShell 5.1
# reads BOM-less .ps1 files using the ANSI codepage, which turns a literal UTF-8 degree sign
# into 'A-circumflex degree'. Escapes keep this file pure ASCII and render correctly anywhere.
$script:Deg  = "$([char]0x00B0)C"        # degrees Celsius
$script:Um   = "$([char]0x00B5)m"        # micrometres
$script:Cm3  = "g/cm$([char]0x00B3)"     # grams per cubic centimetre
$script:Mm3s = "mm$([char]0x00B3)/s"     # cubic millimetres per second

$script:OpenTag3DFields = @(
    # --- Core: 0x00 - 0x6F ---
    @{ Id='tag_version';         Name='Tag Version';          Start=0x00; Length=2; Type='version' }
    @{ Id='material';            Name='Material';             Start=0x02; Length=5; Type='utf8' }
    @{ Id='material_mod';        Name='Material Modifiers';   Start=0x07; Length=5; Type='utf8' }
    @{ Id='manufacturer';        Name='Manufacturer';         Start=0x1B; Length=16; Type='utf8' }
    @{ Id='color_name';          Name='Color Name';           Start=0x2B; Length=32; Type='utf8' }
    @{ Id='color_1';             Name='Color 1';              Start=0x4B; Length=4; Type='rgba' }
    @{ Id='color_2';             Name='Color 2';              Start=0x50; Length=4; Type='rgba' }
    @{ Id='color_3';             Name='Color 3';              Start=0x54; Length=4; Type='rgba' }
    @{ Id='color_4';             Name='Color 4';              Start=0x58; Length=4; Type='rgba' }
    @{ Id='diameter';            Name='Target Diameter';      Start=0x5C; Length=2; Type='int'; Scale=0.001; Unit='mm' }
    @{ Id='weight';              Name='Target Weight';        Start=0x5E; Length=2; Type='int'; Unit='g' }
    @{ Id='print_temp';          Name='Print Temperature';    Start=0x60; Length=1; Type='int'; Scale=5; Unit=$script:Deg }
    @{ Id='bed_temp';            Name='Bed Temperature';      Start=0x61; Length=1; Type='int'; Scale=5; Unit=$script:Deg }
    @{ Id='density';             Name='Density';              Start=0x62; Length=2; Type='int'; Scale=0.001; Unit=$script:Cm3 }
    @{ Id='td';                  Name='Transmission Distance'; Start=0x64; Length=2; Type='int'; Scale=0.1; Unit='mm' }

    # --- Extended: 0x70 - 0xBA ---
    @{ Id='data_url';            Name='Online Data URL';      Start=0x70; Length=32; Type='ascii'; Ext=$true }
    @{ Id='serial';              Name='Serial / Batch ID';    Start=0x90; Length=16; Type='utf8'; Ext=$true }
    @{ Id='mfg_date';            Name='Manufacture Date';     Start=0xA0; Length=4; Type='date'; Ext=$true }
    @{ Id='mfg_time';            Name='Manufacture Time';     Start=0xA4; Length=3; Type='time'; Ext=$true }
    @{ Id='spool_core_diameter'; Name='Spool Core Diameter';  Start=0xA7; Length=1; Type='int'; Unit='mm'; Ext=$true }
    @{ Id='mfi_temp';            Name='MFI Temp';             Start=0xA8; Length=1; Type='int'; Scale=5; Unit=$script:Deg; Ext=$true }
    @{ Id='mfi_load';            Name='MFI Load';             Start=0xA9; Length=1; Type='int'; Scale=10; Unit='g'; Ext=$true }
    @{ Id='mfi_value';           Name='MFI Value';            Start=0xAA; Length=1; Type='int'; Scale=10; Unit='g/10min'; Ext=$true }
    @{ Id='tolerance';           Name='Measured Tolerance';   Start=0xAB; Length=1; Type='int'; Unit=$script:Um; Ext=$true }
    @{ Id='empty_spool_weight';  Name='Empty Spool Weight';   Start=0xAC; Length=2; Type='int'; Unit='g'; Ext=$true }
    @{ Id='measured_weight';     Name='Measured Weight';      Start=0xAE; Length=2; Type='int'; Unit='g'; Ext=$true }
    @{ Id='measured_length';     Name='Measured Length';      Start=0xB0; Length=2; Type='int'; Unit='m'; Ext=$true }
    @{ Id='max_dry_temp';        Name='Max Dry Temp';         Start=0xB2; Length=1; Type='int'; Scale=5; Unit=$script:Deg; Ext=$true }
    @{ Id='dry_time';            Name='Dry Time';             Start=0xB3; Length=1; Type='int'; Unit='hr'; Ext=$true }
    @{ Id='min_print_temp';      Name='Min Print Temp';       Start=0xB4; Length=1; Type='int'; Scale=5; Unit=$script:Deg; Ext=$true }
    @{ Id='max_print_temp';      Name='Max Print Temp';       Start=0xB5; Length=1; Type='int'; Scale=5; Unit=$script:Deg; Ext=$true }
    @{ Id='min_bed_temp';        Name='Min Bed Temp';         Start=0xB6; Length=1; Type='int'; Scale=5; Unit=$script:Deg; Ext=$true }
    @{ Id='max_bed_temp';        Name='Max Bed Temp';         Start=0xB7; Length=1; Type='int'; Scale=5; Unit=$script:Deg; Ext=$true }
    @{ Id='min_vso';             Name='Min Volumetric Speed'; Start=0xB8; Length=1; Type='int'; Unit=$script:Mm3s; Ext=$true }
    @{ Id='max_vso';             Name='Max Volumetric Speed'; Start=0xB9; Length=1; Type='int'; Unit=$script:Mm3s; Ext=$true }
    @{ Id='target_vso';          Name='Target Volumetric Speed'; Start=0xBA; Length=1; Type='int'; Unit=$script:Mm3s; Ext=$true }
)

function Get-OpenTag3DNdefPayload {
    <#
    .SYNOPSIS
        Extracts the application/opentag3d payload from tag user memory.
    .PARAMETER UserMemory
        Bytes starting at page 4 (the NDEF TLV), or a full 180/540/924-byte tag image.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [byte[]]$UserMemory)

    # Accept a full dump as well as a user-memory slice.
    if ($UserMemory.Length -in 180,540,924) {
        $UserMemory = $UserMemory[16..($UserMemory.Length - 21)]
    }

    if ($UserMemory.Length -lt 4) { throw "Not enough data to contain an NDEF message." }
    if ($UserMemory[0] -ne 0x03) {
        throw ("No NDEF TLV at page 4 (found 0x{0:X2}). The tag may be unformatted, or hold raw data rather than NDEF." -f $UserMemory[0])
    }

    # TLV length: one byte, or 0xFF followed by two bytes.
    if ($UserMemory[1] -eq 0xFF) {
        $msgLen = ([int]$UserMemory[2] -shl 8) -bor $UserMemory[3]
        $i = 4
    }
    else {
        $msgLen = $UserMemory[1]
        $i = 2
    }
    if ($i + $msgLen -gt $UserMemory.Length) { throw "NDEF message length ($msgLen) runs past the end of user memory." }

    # NDEF record: flags, type length, payload length, type, payload.
    $flags   = $UserMemory[$i]
    $tnf     = $flags -band 0x07
    $short   = ($flags -band 0x10) -ne 0
    $typeLen = $UserMemory[$i + 1]
    $j = $i + 2

    if ($short) { $payLen = $UserMemory[$j]; $j += 1 }
    else {
        $payLen = ([int]$UserMemory[$j] -shl 24) -bor ([int]$UserMemory[$j+1] -shl 16) -bor ([int]$UserMemory[$j+2] -shl 8) -bor $UserMemory[$j+3]
        $j += 4
    }
    if (($flags -band 0x08) -ne 0) { $j += 1 }   # ID length present

    $type = [Text.Encoding]::ASCII.GetString($UserMemory[$j..($j + $typeLen - 1)])
    $j += $typeLen

    if ($tnf -ne 0x02 -or $type -ne 'application/opentag3d') {
        throw "Tag holds an NDEF record of type '$type', not application/opentag3d."
    }
    if ($j + $payLen -gt $UserMemory.Length) { throw "Record payload runs past the end of user memory." }

    return ,[byte[]]$UserMemory[$j..($j + $payLen - 1)]
}

function ConvertFrom-OpenTag3DPayload {
    <#
    .SYNOPSIS
        Decodes an OpenTag3D payload into an object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [byte[]]$Payload)

    $get = {
        param($start, $len)
        if ($start + $len -gt $Payload.Length) { return $null }
        return $Payload[$start..($start + $len - 1)]
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $obj  = [ordered]@{}

    foreach ($f in $script:OpenTag3DFields) {
        $bytes = & $get $f.Start $f.Length
        if ($null -eq $bytes) { continue }

        $value   = $null
        $display = $null

        switch ($f.Type) {
            'version' {
                $raw = ([int]$bytes[0] -shl 8) -bor $bytes[1]
                $value = '{0}.{1:D3}' -f [math]::Floor($raw / 1000), ($raw % 1000)
                $display = $value
            }
            { $_ -in 'utf8','ascii' } {
                $enc = if ($f.Type -eq 'ascii') { [Text.Encoding]::ASCII } else { [Text.Encoding]::UTF8 }
                $s = $enc.GetString($bytes)
                $nul = $s.IndexOf([char]0)
                if ($nul -ge 0) { $s = $s.Substring(0, $nul) }
                $value = $s.Trim()
                if ([string]::IsNullOrEmpty($value)) { $value = $null }
                $display = $value
            }
            'rgba' {
                if (($bytes | Where-Object { $_ -ne 0 }).Count -eq 0) { $value = $null }   # transparent = unused
                else {
                    $value = '#{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2]
                    if ($bytes[3] -ne 255) { $value = "$value (alpha $($bytes[3]))" }
                }
                $display = $value
            }
            'date' {
                $y = ([int]$bytes[0] -shl 8) -bor $bytes[1]
                if ($y -ge 1990 -and $y -le 2200 -and $bytes[2] -ge 1 -and $bytes[2] -le 12 -and $bytes[3] -ge 1 -and $bytes[3] -le 31) {
                    $value   = '{0:D4}-{1:D2}-{2:D2}' -f $y, $bytes[2], $bytes[3]
                    $display = $value
                }
            }
            'time' {
                if ($bytes[0] -le 23 -and $bytes[1] -le 59 -and $bytes[2] -le 59) {
                    $value   = '{0:D2}:{1:D2}:{2:D2}' -f $bytes[0], $bytes[1], $bytes[2]
                    $display = "$value UTC"
                }
            }
            'int' {
                $raw = 0
                foreach ($b in $bytes) { $raw = ([int]$raw -shl 8) -bor $b }
                $value = if ($f.Scale) { [math]::Round($raw * $f.Scale, 3) } else { $raw }
                $display = if ($f.Unit) { "$value $($f.Unit)" } else { "$value" }
            }
        }

        $obj[$f.Id] = $value
        if ($null -ne $value) {
            $rows.Add([pscustomobject]@{
                Name    = $f.Name
                Id      = $f.Id
                Value   = $display
                Section = if ($f.Ext) { 'Extended' } else { 'Core' }
            })
        }
    }

    # Spec reader guidance: warn on a newer minor version, refuse a newer major one.
    if ($obj.tag_version) {
        $major = [int]($obj.tag_version -split '\.')[0]
        $mine  = [math]::Floor($script:OpenTag3DSpecVersion / 1000)
        if ($major -gt $mine) {
            throw "Tag uses OpenTag3D $($obj.tag_version); this parser understands major version $mine only."
        }
        $minor = [int]($obj.tag_version -split '\.')[1]
        if ($minor -gt ($script:OpenTag3DSpecVersion % 1000)) {
            Write-Warning "Tag uses OpenTag3D $($obj.tag_version), newer than the $([math]::Floor($script:OpenTag3DSpecVersion/1000)).$('{0:D3}' -f ($script:OpenTag3DSpecVersion % 1000)) this parser targets. Parsing anyway."
        }
    }

    $result = [pscustomobject]$obj
    $result | Add-Member -NotePropertyName Fields     -NotePropertyValue $rows.ToArray()
    $result | Add-Member -NotePropertyName PayloadSize -NotePropertyValue $Payload.Length
    return $result
}

function ConvertTo-OpenTag3DPayload {
    <#
    .SYNOPSIS
        Writes edited field values back into an OpenTag3D payload.
    .DESCRIPTION
        Starts from the original payload and overwrites only the fields supplied, so reserved
        bytes and anything this parser does not model are preserved untouched.

        Values are given as a hashtable keyed by field id, in the same display form the parser
        produces: '1.75 mm', '215 C', '#14ADDB', '2026-04-03', '10:19:33'.
    .PARAMETER TruncateTo
        Optional payload length. Use 112 (0x70) to cut an Extended payload down to Core.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [byte[]]$BasePayload,
        [Parameter(Mandatory)] [hashtable]$Values,
        [int]$TruncateTo
    )

    $out = [byte[]]::new($BasePayload.Length)
    [Array]::Copy($BasePayload, $out, $BasePayload.Length)

    foreach ($f in $script:OpenTag3DFields) {
        if (-not $Values.ContainsKey($f.Id)) { continue }
        if ($f.Start + $f.Length -gt $out.Length) { continue }

        $v = "$($Values[$f.Id])".Trim()
        $bytes = [byte[]]::new($f.Length)   # zero filled; strings are null padded

        switch ($f.Type) {
            'version' {
                # Accept '1.003' or a bare 1003
                $n = if ($v -match '^(\d+)\.(\d+)$') { [int]$Matches[1] * 1000 + [int]$Matches[2] }
                     elseif ($v -match '^\d+$') { [int]$v } else { $null }
                if ($null -eq $n) { throw "Field '$($f.Name)': '$v' is not a version." }
                $bytes[0] = [byte](([int]$n -shr 8) -band 0xFF)
                $bytes[1] = [byte]($n -band 0xFF)
            }
            { $_ -in 'utf8','ascii' } {
                $enc = if ($f.Type -eq 'ascii') { [Text.Encoding]::ASCII } else { [Text.Encoding]::UTF8 }
                $raw = $enc.GetBytes($v)
                if ($raw.Length -gt $f.Length) {
                    Write-Warning "Field '$($f.Name)' truncated to $($f.Length) bytes."
                    $raw = $raw[0..($f.Length - 1)]
                }
                [Array]::Copy($raw, $bytes, $raw.Length)
            }
            'rgba' {
                if ([string]::IsNullOrWhiteSpace($v)) { }   # leave transparent black
                else {
                    $m = [regex]::Match($v, '#?([0-9A-Fa-f]{6})(?:\s*\(alpha\s*(\d+)\))?')
                    if (-not $m.Success) { throw "Field '$($f.Name)': '$v' is not a #RRGGBB colour." }
                    $hex = $m.Groups[1].Value
                    $bytes[0] = [Convert]::ToByte($hex.Substring(0,2),16)
                    $bytes[1] = [Convert]::ToByte($hex.Substring(2,2),16)
                    $bytes[2] = [Convert]::ToByte($hex.Substring(4,2),16)
                    $bytes[3] = if ($m.Groups[2].Success) { [byte][int]$m.Groups[2].Value } else { 255 }
                }
            }
            'date' {
                if ($v -match '^(\d{4})-(\d{2})-(\d{2})$') {
                    $y = [int]$Matches[1]
                    $bytes[0] = [byte](([int]$y -shr 8) -band 0xFF)
                    $bytes[1] = [byte]($y -band 0xFF)
                    $bytes[2] = [byte][int]$Matches[2]
                    $bytes[3] = [byte][int]$Matches[3]
                }
                elseif ($v) { throw "Field '$($f.Name)': expected YYYY-MM-DD, got '$v'." }
            }
            'time' {
                if ($v -match '^(\d{1,2}):(\d{2}):(\d{2})') {
                    $bytes[0] = [byte][int]$Matches[1]
                    $bytes[1] = [byte][int]$Matches[2]
                    $bytes[2] = [byte][int]$Matches[3]
                }
                elseif ($v) { throw "Field '$($f.Name)': expected HH:MM:SS, got '$v'." }
            }
            'int' {
                # Take the leading number only: units may contain digits (e.g. 'g/10min').
                $m = [regex]::Match($v, '^\s*(-?\d+(?:\.\d+)?)')
                $n = if ($m.Success) { [double]$m.Groups[1].Value } else { 0 }
                if ($f.Scale) { $n = $n / $f.Scale }
                $n = [int][math]::Round($n)
                $max = [math]::Pow(256, $f.Length) - 1
                if ($n -lt 0 -or $n -gt $max) {
                    throw "Field '$($f.Name)': $v is out of range for $($f.Length) byte(s)."
                }
                for ($i = $f.Length - 1; $i -ge 0; $i--) {
                    $bytes[$i] = [byte]($n -band 0xFF)
                    $n = [int]($n -shr 8)
                }
            }
        }
        [Array]::Copy($bytes, 0, $out, $f.Start, $f.Length)
    }

    if ($TruncateTo -and $TruncateTo -lt $out.Length) { $out = $out[0..($TruncateTo - 1)] }
    return ,[byte[]]$out
}
