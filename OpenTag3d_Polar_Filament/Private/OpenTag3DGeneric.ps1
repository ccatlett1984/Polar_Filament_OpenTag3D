# Building an OpenTag3D payload from hand-entered values, with no server lookup.
#
# The GUI's "New (generic vendor)" source calls this. It is also the seam a public
# New-OpenTag3DTag cmdlet would plug into: Get-OpenTag3DFieldMap gives the parameter
# name for every spec field, and ConvertTo-OpenTag3DValueTable turns a $PSBoundParameters
# hashtable into the value table New-OpenTag3DGenericPayload expects.

# Payload sizes. Core covers 0x00-0x6F and Extended 0x00-0xBA, so each is one byte
# longer than the last address it holds.
$script:OpenTag3DCoreSize     = 0x70   # 112
$script:OpenTag3DExtendedSize = 0xBB   # 187

# Only the tag version is fixed on a hand-built tag: it describes the format, not the
# filament. The serial is the vendor's own batch id here, so unlike a Polar lookup - where
# it is the key the data came from - it is free to edit.
$script:OpenTag3DGenericReadOnly = @('tag_version')

# Cmdlet parameter names are derived from the field id (color_name -> ColorName); these
# would read badly derived, so they are named explicitly.
$script:OpenTag3DParamOverride = @{
    'td'         = 'TransmissionDistance'
    'data_url'   = 'DataUrl'
    'mfg_date'   = 'ManufactureDate'
    'mfg_time'   = 'ManufactureTime'
    'min_vso'    = 'MinVolumetricSpeed'
    'max_vso'    = 'MaxVolumetricSpeed'
    'target_vso' = 'TargetVolumetricSpeed'
    'mfi_temp'   = 'MfiTemp'
    'mfi_load'   = 'MfiLoad'
    'mfi_value'  = 'MfiValue'
}

function ConvertTo-OpenTag3DParamName {
    <#
    .SYNOPSIS
        Parameter name for a spec field id: 'color_name' -> 'ColorName'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Id)

    if ($script:OpenTag3DParamOverride.ContainsKey($Id)) { return $script:OpenTag3DParamOverride[$Id] }

    return (($Id -split '_' | ForEach-Object {
        if ($_.Length -eq 0) { '' } else { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) }
    }) -join '')
}

function Get-OpenTag3DFieldMap {
    <#
    .SYNOPSIS
        Every spec field as parameter name, id, section and type.
    .DESCRIPTION
        The bridge between a cmdlet's named parameters and the payload encoder. Ordered as
        the spec lays the fields out, so it also drives generated help and the GUI form.
    #>
    [CmdletBinding()]
    param()

    foreach ($f in $script:OpenTag3DFields) {
        [pscustomobject]@{
            Parameter = ConvertTo-OpenTag3DParamName -Id $f.Id
            Id        = $f.Id
            Name      = $f.Name
            Type      = $f.Type
            Unit      = if ($f.Unit) { $f.Unit } else { '' }
            Section   = if ($f.Ext) { 'Extended' } else { 'Core' }
            ReadOnly  = ($f.Id -in $script:OpenTag3DGenericReadOnly)
        }
    }
}

function ConvertTo-OpenTag3DValueTable {
    <#
    .SYNOPSIS
        Turns bound cmdlet parameters into a value table keyed by spec field id.
    .DESCRIPTION
        Pass $PSBoundParameters. Anything that is not a field parameter - TagType, Format,
        OutputDir and so on - is ignored, so the caller does not have to filter first.
    .PARAMETER Parameter
        Parameter name to value, e.g. @{ PrintTemp = '215 C'; Manufacturer = 'Acme' }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable]$Parameter)

    $byName = @{}
    foreach ($f in Get-OpenTag3DFieldMap) { $byName[$f.Parameter] = $f.Id }

    $values = @{}
    foreach ($key in $Parameter.Keys) {
        if (-not $byName.ContainsKey($key)) { continue }
        $v = $Parameter[$key]
        if ($null -eq $v) { continue }
        $values[$byName[$key]] = "$v"
    }
    return $values
}

function Get-OpenTag3DPayloadSize {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('Core','Extended')] [string]$Mode)

    if ($Mode -eq 'Core') { $script:OpenTag3DCoreSize } else { $script:OpenTag3DExtendedSize }
}

function New-OpenTag3DBlankPayload {
    <#
    .SYNOPSIS
        A zero-filled payload of the right size, with the tag version stamped.
    .DESCRIPTION
        Every other field reads back as empty or zero, which the spec treats as "not
        supplied" - so a blank payload is a valid starting point to overwrite selectively.
    #>
    [CmdletBinding()]
    param([Parameter()] [ValidateSet('Core','Extended')] [string]$Mode = 'Extended')

    $payload = [byte[]]::new((Get-OpenTag3DPayloadSize -Mode $Mode))
    $payload[0] = [byte](([int]$script:OpenTag3DSpecVersion -shr 8) -band 0xFF)
    $payload[1] = [byte]($script:OpenTag3DSpecVersion -band 0xFF)
    return ,[byte[]]$payload
}

function New-OpenTag3DGenericPayload {
    <#
    .SYNOPSIS
        Builds an OpenTag3D payload from hand-entered values, with no lookup.
    .DESCRIPTION
        Values are keyed by spec field id and given in the same display form the parser
        produces: '1.75 mm', '215 C', '#14ADDB', '2026-04-03', '10:19:33'. Anything not
        supplied is left zeroed.

        The tag version is always stamped by the module, so a value supplied for it is
        ignored - it describes the format, not the filament.
    .PARAMETER Values
        Field id to value, e.g. @{ manufacturer = 'Acme'; material = 'PLA' }.
    .PARAMETER Mode
        Core (0x00-0x6F) or Extended (0x00-0xBA). Core is the only payload an NTAG213 holds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Values,
        [Parameter()] [ValidateSet('Core','Extended')] [string]$Mode = 'Extended'
    )

    $clean = @{}
    foreach ($key in $Values.Keys) {
        if ($key -in $script:OpenTag3DGenericReadOnly) { continue }
        $v = $Values[$key]
        if ($null -eq $v -or "$v".Trim().Length -eq 0) { continue }   # unset stays zeroed
        $clean[$key] = "$v"
    }

    $base = New-OpenTag3DBlankPayload -Mode $Mode
    return ,[byte[]](ConvertTo-OpenTag3DPayload -BasePayload $base -Values $clean)
}

function Get-OpenTag3DEditableField {
    <#
    .SYNOPSIS
        Turns a payload into the field list the GUI editor renders.
    .DESCRIPTION
        Shared by every source the editor loads from - a serial lookup, a tag, a blank form
        or a saved profile - so all four render and validate identically.

        Fields past the end of the payload are left out rather than shown as empty: a Core
        payload has nowhere to put them, and an editable box that silently discards what you
        type is worse than no box at all.
    .PARAMETER AllowSerial
        Let the serial be edited. True for a hand-built tag, where the serial is the vendor's
        own batch id; false for a Polar lookup, where it is the key the data came from.
    .PARAMETER BlankUnset
        Show an all-zero number or time as empty rather than '0' or '00:00:00'. On a hand-built
        tag every unset field reads back that way, and a form pre-filled with meaningless zeros
        invites writing them to the tag. Zero and empty encode identically, so nothing is lost.
        Off for data read from a lookup or a tag, where a stored zero is what the tag says.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [byte[]]$Payload,
        [switch]$AllowSerial,
        [switch]$BlankUnset
    )

    $decoded  = ConvertFrom-OpenTag3DPayload -Payload $Payload
    $readOnly = if ($AllowSerial) { $script:OpenTag3DGenericReadOnly } else { $script:OpenTag3DReadOnly }

    foreach ($f in $script:OpenTag3DFields) {
        if ($f.Start + $f.Length -gt $Payload.Length) { continue }
        $row   = $decoded.Fields | Where-Object Id -eq $f.Id
        $value = if ($row) { "$($row.Value)" } else { '' }
        if ($BlankUnset) {
            $raw = $decoded.($f.Id)
            if ($f.Type -eq 'int'  -and $raw -eq 0)          { $value = '' }
            if ($f.Type -eq 'time' -and $raw -eq '00:00:00') { $value = '' }
        }

        @{
            id       = $f.Id
            name     = $f.Name
            value    = $value
            section  = if ($f.Ext) { 'Extended' } else { 'Core' }
            type     = $f.Type
            unit     = if ($f.Unit) { $f.Unit } else { '' }
            readonly = ($f.Id -in $readOnly)
        }
    }
}
