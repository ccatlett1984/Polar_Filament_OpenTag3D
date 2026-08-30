function Export-OpenTag3DPayload {
<#
.SYNOPSIS
    Builds a full NTAG21x memory image from a Polar Filament OpenTag3D spool lookup.

.DESCRIPTION
    Fetches the OpenTag3D payload for a spool serial and wraps it in a complete tag dump:
    UID / BCC / static lock / capability container at the front, user memory in the middle,
    dynamic lock and configuration pages at the end.

    By default the payload is wrapped as an NDEF message (NDEF TLV containing a MIME record
    of type application/opentag3d, followed by a terminator TLV) so readers report the tag as
    NFC Forum Type 2 with a readable record. Use -Format Raw to place the bare payload at
    page 4 with no NDEF structure.

    The image is per-spool, not per-tag. Pages 0-2 carry a neutral placeholder UID: real UIDs
    are factory-programmed and read-only, and Write-OpenTag3DTag never writes them.

    Output is 180 bytes for NTAG213, 540 for NTAG215 and 924 for NTAG216.

    -Mode defaults per tag type: Core for NTAG213, Extended for NTAG215 and NTAG216. NTAG213
    has only 144 bytes of user memory, which the Extended payload cannot fit, so asking for
    Extended on an NTAG213 warns and falls back to Core.

.PARAMETER TagType
    Target chip. Determines user memory size, total dump size and capability container.

.PARAMETER Serial
    Spool serial number, e.g. 50017-FYG5. Normalised to upper case - the server rejects
    lower-case serials with HTTP 403. Accepts pipeline input.

.PARAMETER Mode
    Core (smaller payload) or Extended (full field set). Defaults to Core for NTAG213 and
    Extended for NTAG215/NTAG216. Extended is not possible on NTAG213.

.PARAMETER Format
    Ndef (default) wraps the payload in an NDEF TLV. Raw writes the unwrapped payload.

.PARAMETER OutputDir
    Destination folder. Defaults to the Downloads folder on Windows and the home directory on
    Linux and macOS, falling back to the current location if that path is unavailable.

.PARAMETER WriteToTag
    Write the image straight to a tag on a PC/SC reader instead of saving a .bin file.
    Cannot be combined with -OutputDir.

.PARAMETER ReaderName
    With -WriteToTag: substring of the reader name. Defaults to the first 'ACR122' match.


.EXAMPLE
    Export-OpenTag3DPayload -TagType NTAG215 -Serial 50017-FYG5

    Saves 50017-FYG5-NTAG215-Extended-Ndef.bin in the current directory. -Mode defaults to
    Extended on an NTAG215, so the file holds the full field set wrapped as NDEF.

.EXAMPLE
    Export-OpenTag3DPayload -TagType NTAG213 -Serial 50017-FYG5 -WriteToTag

    Fetches the Core payload (the only one that fits an NTAG213) and writes it straight to the
    tag on the reader, with no .bin file on disk.

.EXAMPLE
    Export-OpenTag3DPayload -TagType NTAG216 -Serial 50017-FYG5 -Format Raw -OutputDir D:\tags

    Writes the unwrapped payload to page 4 instead of an NDEF message. Readers will not report
    an NDEF record; use this only for tools that parse the raw OpenTag3D bytes themselves.

.EXAMPLE
    '50017-FYG5','50018-ABC1' | ForEach-Object {
        Export-OpenTag3DPayload -TagType NTAG215 -Serial $_ -OutputDir D:\tags
        Start-Sleep -Seconds 3
    }

    Batches several spools to disk. The server rate limits back-to-back lookups with HTTP 429,
    so pace the requests; write the tags afterwards from the saved files.

.LINK
    https://opentag3d.info
#>
    [CmdletBinding(PositionalBinding = $false, SupportsShouldProcess, DefaultParameterSetName = 'ToFile')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('NTAG213','NTAG215','NTAG216')]
        [string]$TagType,

        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Serial,

        [Parameter()]
        [ValidateSet('Core','Extended')]
        [string]$Mode,

        [Parameter()]
        [ValidateSet('Ndef','Raw')]
        [string]$Format = 'Ndef',

        [Parameter(ParameterSetName = 'ToFile')]
        [string]$OutputDir,

        [Parameter(Mandatory, ParameterSetName = 'ToTag')]
        [switch]$WriteToTag,

        [Parameter(ParameterSetName = 'ToTag')]
        [string]$ReaderName
    )
    process {
        # The server's checksum is case-sensitive; lower case is rejected with 403.
        $Serial = $Serial.ToUpperInvariant()

        # Default per tag type; NTAG213's 144 bytes of user memory cannot hold Extended (214).
        if (-not $PSBoundParameters.ContainsKey('Mode')) {
            $Mode = if ($TagType -eq 'NTAG213') { 'Core' } else { 'Extended' }
            Write-Verbose "Mode not specified; defaulting to $Mode for $TagType."
        }
        elseif ($TagType -eq 'NTAG213' -and $Mode -eq 'Extended') {
            Write-Warning "NTAG213 cannot hold the Extended payload; using Core instead."
            $Mode = 'Core'
        }

        $spec = Get-OpenTag3DTagSpec -TagType $TagType

        if ($PSCmdlet.ParameterSetName -eq 'ToFile') {
            if (-not $PSBoundParameters.ContainsKey('OutputDir')) {
                $OutputDir = Get-OpenTag3DDefaultOutputDir
                Write-Verbose "No -OutputDir given; using $OutputDir"
            }
            $OutputDir = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputDir)
            if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
                throw "Output directory not found: $OutputDir"
            }
        }

        # --- fetch payload (ndef export = MIME record, bin export = bare payload) ---
        $srcFormat = if ($Format -eq 'Ndef') { 'ndef' } else { 'bin' }
        $url  = "https://pfil.us/opentag3d.php?id=$Serial&mode=$($Mode.ToLower())&format=$srcFormat"
        $temp = [IO.Path]::GetTempFileName()
        try {
            Write-Verbose "Fetching $url"
            Invoke-WebRequest $url -UseBasicParsing -OutFile $temp -ErrorAction Stop
            $data = [IO.File]::ReadAllBytes($temp)
        }
        catch {
            $detail = $_.Exception.Message
            if ($detail -match 'rate limit' -or $detail -match '429') {
                throw "Lookup for '$Serial' is rate limited by the server. Wait a few seconds and retry; add Start-Sleep between serials when batching."
            }
            if ($detail -match '403') {
                throw "Server rejected serial '$Serial' (invalid checksum). Check the serial is correct and complete."
            }
            throw "Lookup for '$Serial' failed: $detail"
        }
        finally { Remove-Item $temp -Force -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue }

        if ($data.Length -eq 0) { throw "Empty $Mode payload returned for serial '$Serial'." }

        $image = New-OpenTag3DImage -Data $data -TagType $TagType -Format $Format

        Write-Verbose "Payload $($data.Length) bytes -> $($image.Length)-byte $TagType image"

        if ($PSCmdlet.ParameterSetName -eq 'ToTag') {
            $writeArgs = @{ Bytes = $image }
            if ($ReaderName) { $writeArgs.ReaderName = $ReaderName }
            Write-OpenTag3DTag @writeArgs
        }
        else {
            $path = Join-Path $OutputDir "$Serial-$TagType-$Mode-$Format.bin"
            if ($PSCmdlet.ShouldProcess($path, "Write $($spec.TotalSize)-byte $TagType image")) {
                Write-Host "Wrote $($spec.TotalSize) bytes to $path"
                [IO.File]::WriteAllBytes($path, $image)
            }
        }
    }
}
