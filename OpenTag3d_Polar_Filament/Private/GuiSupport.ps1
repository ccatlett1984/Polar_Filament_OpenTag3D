# Support for Show-OpenTag3DGui: response writing, request dispatch, and the page itself.

function Write-HttpResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$ContentType,
        [Parameter(Mandatory)] [string]$Body
    )
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $Context.Response.ContentType     = $ContentType
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.Headers.Add('Cache-Control','no-store')
        $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Context.Response.OutputStream.Close()
    }
    catch {
        # Client went away, or the listener already answered (e.g. 411 on a bodyless POST).
        # Normal for a web server; never worth taking the UI down for.
        Write-Verbose "Could not send response: $($_.Exception.Message)"
    }
}

function Invoke-OpenTag3DGuiAction {
    <#
    .SYNOPSIS
        Runs one export or write on behalf of the UI and returns a result object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('export','write','read','load','apply')] [string]$Action,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Body,
        [Parameter(Mandatory)] [bool]$CanWrite
    )

    if ([string]::IsNullOrWhiteSpace($Body)) { return @{ ok = $false; message = 'Empty request.' } }
    try { $r = $Body | ConvertFrom-Json }
    catch { return @{ ok = $false; message = 'Malformed request.' } }

    # --- load: fetch or read a payload and return it as editable fields ---
    if ($Action -eq 'load') {
        try {
            if ($r.source -eq 'tag') {
                if (-not $CanWrite) { return @{ ok = $false; message = 'No PC/SC reader available.' } }
                $p = @{}
                if ($r.readerName) { $p.ReaderName = $r.readerName }
                $tag = Read-OpenTag3DTag @p -Raw
                $payload = $tag.PayloadBytes
            }
            else {
                if ([string]::IsNullOrWhiteSpace($r.serial)) { return @{ ok = $false; message = 'Enter a spool serial.' } }
                $mode = if ($r.mode) { $r.mode } elseif ($r.tagType -eq 'NTAG213') { 'Core' } else { 'Extended' }
                $img  = Export-OpenTag3DPayload -TagType $r.tagType -Serial $r.serial -Mode $mode -Format Ndef -OutputDir ([IO.Path]::GetTempPath()) -InformationAction SilentlyContinue -WarningAction SilentlyContinue 6>&1 | Out-Null
                # Re-read what was just written, then clean it up: the lookup only serves files.
                $file = Join-Path ([IO.Path]::GetTempPath()) "$($r.serial.ToUpperInvariant())-$($r.tagType)-$mode-Ndef.bin"
                $payload = Get-OpenTag3DNdefPayload -UserMemory ([IO.File]::ReadAllBytes($file))
                Remove-Item $file -Force -ErrorAction SilentlyContinue
            }

            $decoded = ConvertFrom-OpenTag3DPayload -Payload $payload
            $editable = foreach ($f in $script:OpenTag3DFields) {
                $row = $decoded.Fields | Where-Object Id -eq $f.Id
                @{
                    id       = $f.Id
                    name     = $f.Name
                    value    = if ($row) { "$($row.Value)" } else { '' }
                    section  = if ($f.Ext) { 'Extended' } else { 'Core' }
                    type     = $f.Type
                    unit     = if ($f.Unit) { $f.Unit } else { '' }
                    readonly = ($f.Id -in $script:OpenTag3DReadOnly)
                }
            }
            return @{
                ok         = $true
                fields     = @($editable)
                payloadHex = ([BitConverter]::ToString($payload) -replace '-')
                title      = (@($decoded.material, $decoded.material_mod, $decoded.color_name) | Where-Object { $_ }) -join " $([char]0x00B7) "
            }
        }
        catch { return @{ ok = $false; message = $_.Exception.Message } }
    }

    # --- apply: encode edited values and either save or write ---
    if ($Action -eq 'apply') {
        try {
            if ([string]::IsNullOrWhiteSpace($r.payloadHex)) { return @{ ok = $false; message = 'Nothing loaded to save.' } }
            $hex  = $r.payloadHex
            $base = [byte[]]::new($hex.Length / 2)
            for ($i = 0; $i -lt $base.Length; $i++) { $base[$i] = [Convert]::ToByte($hex.Substring($i*2,2),16) }

            # Read-only fields are enforced here, not just disabled in the browser: a hand-made
            # request must not be able to rewrite the serial.
            $values = @{}
            foreach ($kv in $r.values.PSObject.Properties) {
                if ($kv.Name -in $script:OpenTag3DReadOnly) { continue }
                $values[$kv.Name] = $kv.Value
            }

            # NTAG213 holds Core only; cut the payload at 0x70. Anything populated above that
            # address is lost, so say what will go and require an explicit confirmation.
            $truncate = if ($r.tagType -eq 'NTAG213') { 112 } else { 0 }
            if ($truncate) {
                $encoded  = ConvertTo-OpenTag3DPayload -BasePayload $base -Values $values -WarningAction SilentlyContinue
                $all      = @(ConvertFrom-OpenTag3DPayload -Payload $encoded | Select-Object -ExpandProperty Fields)
                $dropping = @($all | Where-Object { $_.Section -eq 'Extended' })
                $keeping  = @($all | Where-Object { $_.Section -eq 'Core' })
                if ($dropping.Count -and -not $r.confirmTruncate) {
                    return @{
                        ok      = $false
                        confirm = 'truncate'
                        message = "NTAG213 stores OpenTag3D Core only. These $($keeping.Count) field(s) are all that will be kept:"
                        keeping = @($keeping | ForEach-Object { @{ name = $_.Name; value = "$($_.Value)" } })
                        dropped = $dropping.Count
                    }
                }
            }
            $payload = ConvertTo-OpenTag3DPayload -BasePayload $base -Values $values -TruncateTo $truncate -WarningAction SilentlyContinue

            $record = New-OpenTag3DNdefRecord -Payload $payload
            $image  = New-OpenTag3DImage -Data $record -TagType $r.tagType -Format Ndef

            if ($r.target -eq 'tag') {
                if (-not $CanWrite) { return @{ ok = $false; message = 'No PC/SC reader available.' } }
                $p = @{ Bytes = $image }
                if ($r.readerName) { $p.ReaderName = $r.readerName }
                $text = (Write-OpenTag3DTag @p 6>&1 3>&1 | Out-String).Trim()
                return @{ ok = $true; message = if ($text) { $text } else { 'Written.' } }
            }

            $dir = if ($r.outputDir) { $r.outputDir } else { Get-OpenTag3DDefaultOutputDir }
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                return @{ ok = $false; message = "Output directory not found: $dir" }
            }
            # Name from the untruncated payload: an NTAG213 cut at 0x70 has no serial field.
            $decoded = ConvertFrom-OpenTag3DPayload -Payload $base
            $name = if ($decoded.serial) { $decoded.serial } else { 'opentag3d' }
            $path = Join-Path $dir "$name-$($r.tagType)-Edited-Ndef.bin"
            [IO.File]::WriteAllBytes($path, $image)
            return @{ ok = $true; message = "Wrote $($image.Length) bytes to $path" }
        }
        catch { return @{ ok = $false; message = $_.Exception.Message } }
    }

    if ($Action -eq 'read') {
        if (-not $CanWrite) { return @{ ok = $false; message = 'No PC/SC reader available.' } }
        try {
            $p = @{}
            if ($r.readerName) { $p.ReaderName = $r.readerName }
            $tag = Read-OpenTag3DTag @p
            return @{
                ok     = $true
                fields = @($tag.Fields | ForEach-Object { @{ name = $_.Name; value = "$($_.Value)"; section = $_.Section } })
                color  = "$($tag.color_1)"
                title  = (@($tag.material, $tag.material_mod, $tag.color_name) | Where-Object { $_ }) -join " $([char]0x00B7) "
            }
        }
        catch { return @{ ok = $false; message = $_.Exception.Message } }
    }

    if ([string]::IsNullOrWhiteSpace($r.serial)) {
        return @{ ok = $false; message = 'Enter a spool serial.' }
    }
    if ($Action -eq 'write' -and -not $CanWrite) {
        return @{ ok = $false; message = 'No PC/SC reader available.' }
    }

    $p = @{
        TagType = $r.tagType
        Serial  = $r.serial
        Format  = $r.format
    }
    if ($r.mode) { $p.Mode = $r.mode }   # blank means "let the cmdlet default per tag type"

    if ($Action -eq 'write') {
        $p.WriteToTag = $true
        if ($r.readerName) { $p.ReaderName = $r.readerName }
    }
    elseif ($r.outputDir) {
        $p.OutputDir = $r.outputDir
    }

    try {
        # Write-Host output from the cmdlets goes to the information stream; capture it for the page.
        $text = (Export-OpenTag3DPayload @p 6>&1 3>&1 | Out-String).Trim()
        return @{ ok = $true; message = if ($text) { $text } else { 'Done.' } }
    }
    catch {
        return @{ ok = $false; message = $_.Exception.Message }
    }
}

function Get-OpenTag3DGuiHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]$CanWrite,
        [Parameter(Mandatory)] [string]$DefaultDir,
        [string]$PcscError
    )

    $page = @'
<!doctype html>
<meta charset="utf-8">
<title>OpenTag3D - Polar Filament</title>
<style>
  :root {
    color-scheme: light dark;
    --edge:#8883; --accent:#c2410c;
    --bg:#ffffff; --fg:#141414; --field:#ffffff; --field-fg:#141414;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#1b1b1d; --fg:#ececec; --field:#2a2a2e; --field-fg:#ececec; }
  }
  body { font:15px/1.5 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
         max-width:33rem; margin:3rem auto; padding:0 1.25rem;
         background:var(--bg); color:var(--fg); }
  h1 { font-size:1.3rem; margin:0 0 .25rem; letter-spacing:-.01em; }
  p.sub { margin:0 0 1.75rem; opacity:.65; font-size:.9rem; }
  fieldset { border:1px solid var(--edge); border-radius:8px; padding:1rem 1.1rem 1.2rem; margin:0 0 1.1rem; }
  legend { padding:0 .4rem; font-size:.8rem; text-transform:uppercase; letter-spacing:.07em; opacity:.6; }
  label { display:block; margin:.7rem 0 .2rem; font-size:.85rem; opacity:.8; }
  input,select { width:100%; box-sizing:border-box; padding:.5rem .6rem; font:inherit;
                 border:1px solid var(--edge); border-radius:6px;
                 background:var(--field); color:var(--field-fg); }
  /* Native option popups paint their own background, so set both explicitly or dark mode
     ends up white-on-white. */
  option { background:var(--field); color:var(--field-fg); }
  input::placeholder { color:var(--fg); opacity:.45; }
  input:focus,select:focus { outline:2px solid var(--accent); outline-offset:1px; }
  .row { display:flex; gap:.75rem; }
  .row > div { flex:1; }
  .actions { display:flex; gap:.6rem; margin-top:1.4rem; align-items:center; }
  button { padding:.55rem 1.1rem; font:inherit; border-radius:6px; border:1px solid var(--edge);
           background:var(--field); color:var(--field-fg); cursor:pointer; }
  button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
  button:disabled { opacity:.4; cursor:not-allowed; }
  #out { margin-top:1.3rem; padding:.8rem .9rem; border-radius:6px; border:1px solid var(--edge);
         background:var(--field); color:var(--field-fg);
         white-space:pre-wrap; font:13px ui-monospace,SFMono-Regular,Consolas,monospace; display:none; }
  #out.ok  { border-color:#16a34a88; }
  #out.err { border-color:#dc262688; }
  .note { font-size:.82rem; opacity:.7; margin:.6rem 0 0; }
  #stop { margin-left:auto; opacity:.55; font-size:.85rem; }
  #tag { margin-top:1.3rem; display:none; }
  #tag h2 { font-size:1rem; margin:0 0 .2rem; display:flex; align-items:center; gap:.5rem; }
  #tag .swatch { width:1rem; height:1rem; border-radius:3px; border:1px solid var(--edge); display:inline-block; }
  #tag table { width:100%; border-collapse:collapse; font-size:.86rem; }
  #tag th { text-align:left; font-weight:600; opacity:.55; font-size:.72rem; text-transform:uppercase;
            letter-spacing:.06em; padding:.9rem 0 .3rem; border-bottom:1px solid var(--edge); }
  #tag td { padding:.3rem .5rem .3rem 0; border-bottom:1px solid var(--edge); vertical-align:top; }
  #tag td.k { opacity:.7; width:45%; }
  .tabs { display:flex; gap:.4rem; margin:0 0 1.2rem; border-bottom:1px solid var(--edge); }
  .tab { border:none; border-bottom:2px solid transparent; border-radius:0; background:none;
         padding:.5rem .8rem; opacity:.6; font-size:.9rem; }
  .tab.active { opacity:1; border-bottom-color:var(--accent); font-weight:600; }
  .fgroup { margin:1.1rem 0 .2rem; font-size:.72rem; text-transform:uppercase; letter-spacing:.06em;
            opacity:.55; border-bottom:1px solid var(--edge); padding-bottom:.3rem; }
  .frow { display:flex; align-items:center; gap:.6rem; margin:.35rem 0; }
  .frow label { flex:0 0 45%; margin:0; font-size:.84rem; opacity:.85; }
  .frow input { flex:1; padding:.35rem .5rem; }
  .frow input[readonly] { opacity:.55; cursor:not-allowed; }
  .frow .sw { width:1.1rem; height:1.1rem; border-radius:3px; border:1px solid var(--edge); flex:0 0 auto; }
  #editOut { margin-top:1.2rem; padding:.8rem .9rem; border-radius:6px; border:1px solid var(--edge);
             background:var(--field); color:var(--field-fg); white-space:pre-wrap;
             font:13px ui-monospace,SFMono-Regular,Consolas,monospace; display:none; }
  #editOut.ok { border-color:#16a34a88; } #editOut.err { border-color:#dc262688; }
  #confirm { margin-top:1.2rem; padding:.9rem 1rem; border-radius:6px; border:1px solid #d9770688;
             background:var(--field); color:var(--field-fg); display:none; }
  #confirm h3 { margin:0 0 .4rem; font-size:.92rem; }
  #confirm ul { margin:.5rem 0 .9rem; padding-left:1.1rem; font:13px ui-monospace,SFMono-Regular,Consolas,monospace; }
  #confirm li { margin:.12rem 0; }
  #confirm .actions { margin-top:.8rem; }
</style>

<h1>OpenTag3D &mdash; Polar Filament</h1>
<p class="sub">Look up a spool, save a tag image, or write a tag.</p>

<nav class="tabs">
  <button class="tab active" data-screen="main">Fetch &amp; write</button>
  <button class="tab" data-screen="edit">View &amp; edit</button>
</nav>

<section id="screen-edit" hidden>
  <fieldset>
    <legend>Load data</legend>
    <label for="eSerial">Spool serial</label>
    <input id="eSerial" placeholder="50017-FYG5" autocomplete="off">
    <div class="row">
      <div>
        <label for="eTagType">Tag type</label>
        <select id="eTagType">
          <option>NTAG213</option>
          <option selected>NTAG215</option>
          <option>NTAG216</option>
        </select>
      </div>
      <div>
        <label for="eReader">Reader (blank = first ACR122)</label>
        <input id="eReader" placeholder="ACR122" autocomplete="off">
      </div>
    </div>
    <div class="actions">
      <button class="primary" id="loadSerial">Load from serial</button>
      <button id="loadTag">Load from tag</button>
    </div>
    <p class="note" id="editNote"></p>
  </fieldset>

  <form id="editForm" hidden autocomplete="off">
    <fieldset>
      <legend id="editLegend">Tag data</legend>
      <div id="editFields"></div>
      <label for="eOutputDir">Output folder (blank = __DEFAULTDIR__)</label>
      <input id="eOutputDir" placeholder="__DEFAULTDIR__" autocomplete="off">
      <div class="actions">
        <button class="primary" id="applySave" type="button">Save image</button>
        <button id="applyWrite" type="button">Write to tag</button>
        <button id="revert" type="button">Revert</button>
      </div>
    </fieldset>
  </form>
  <div id="confirm">
    <h3 id="confirmTitle"></h3>
    <div id="confirmBody"></div>
    <div class="actions">
      <button class="primary" id="confirmGo" type="button">Continue anyway</button>
      <button id="confirmCancel" type="button">Cancel</button>
    </div>
  </div>
  <div id="editOut"></div>
</section>

<section id="screen-main">

<fieldset>
  <legend>Spool</legend>
  <label for="serial">Serial</label>
  <input id="serial" placeholder="50017-FYG5" autofocus autocomplete="off">
  <div class="row">
    <div>
      <label for="tagType">Tag type</label>
      <select id="tagType">
        <option>NTAG213</option>
        <option selected>NTAG215</option>
        <option>NTAG216</option>
      </select>
    </div>
    <div>
      <label for="mode">Mode</label>
      <select id="mode">
        <option value="">Default for tag type</option>
        <option value="Core">Core</option>
        <option value="Extended">Extended</option>
      </select>
    </div>
    <div>
      <label for="format">Format</label>
      <select id="format">
        <option value="Ndef" selected>NDEF</option>
        <option value="Raw">Raw</option>
      </select>
    </div>
  </div>
</fieldset>

<fieldset>
  <legend>Destination</legend>
  <label for="outputDir">Output folder (blank = __DEFAULTDIR__)</label>
  <input id="outputDir" placeholder="__DEFAULTDIR__" autocomplete="off">
  <label for="readerName">Reader name, for writing (blank = first ACR122)</label>
  <input id="readerName" placeholder="ACR122" autocomplete="off">
  <div class="actions">
    <button class="primary" id="save">Save image</button>
    <button id="write">Write tag</button>
    <button id="read">Read tag</button>
    <button id="stop">Stop server</button>
  </div>
  <p class="note" id="writeNote"></p>
</fieldset>

<div id="out"></div>
<div id="tag"></div>
</section>

<script>
  const CAN_WRITE = __CANWRITE__;
  const $ = id => document.getElementById(id);
  const out = $('out');

  if (!CAN_WRITE) {
    $('write').disabled = true;
    $('read').disabled  = true;
    $('writeNote').textContent = 'Tag reading and writing unavailable: __PCSCERROR__ Saving an image still works.';
  }

  function payload() {
    return {
      serial:     $('serial').value.trim(),
      tagType:    $('tagType').value,
      mode:       $('mode').value,
      format:     $('format').value,
      outputDir:  $('outputDir').value.trim(),
      readerName: $('readerName').value.trim()
    };
  }

  function show(ok, msg) {
    out.style.display = 'block';
    out.className = ok ? 'ok' : 'err';
    out.textContent = msg;
  }

  function renderTag(data) {
    const t = $('tag');
    const sections = ['Core', 'Extended'];
    let html = '<h2>';
    if (data.color) html += '<span class="swatch" style="background:' + data.color.split(' ')[0] + '"></span>';
    html += (data.title || 'Tag contents') + '</h2><table>';
    for (const sec of sections) {
      const rows = (data.fields || []).filter(f => f.section === sec);
      if (!rows.length) continue;
      html += '<tr><th colspan="2">' + sec + '</th></tr>';
      for (const f of rows) {
        html += '<tr><td class="k">' + f.name + '</td><td>' + f.value + '</td></tr>';
      }
    }
    t.innerHTML = html + '</table>';
    t.style.display = 'block';
  }

  async function run(action, btn) {
    const buttons = [$('save'), $('write'), $('read')];
    buttons.forEach(b => b.disabled = true);
    show(true, 'Working...');
    try {
      const res = await fetch('/api/' + action, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload())
      });
      const data = await res.json();
      if (action === 'read' && data.ok) {
        out.style.display = 'none';
        renderTag(data);
      } else {
        $('tag').style.display = 'none';
        show(data.ok, data.message);
      }
    } catch (e) {
      show(false, 'Request failed: ' + e.message);
    } finally {
      buttons.forEach(b => b.disabled = false);
      if (!CAN_WRITE) { $('write').disabled = true; $('read').disabled = true; }
    }
  }

  // Heartbeat: the server stops when this stops arriving, so closing the tab shuts it down.
  const beat = () => fetch('/api/ping', {
    method:'POST', headers:{'Content-Type':'application/json'}, body:'{}'
  }).catch(() => {});
  beat();
  setInterval(beat, 3000);

  // Fires on close AND on reload; the server waits a moment for a reloaded page to resume
  // the heartbeat before acting on it.
  addEventListener('pagehide', () => {
    navigator.sendBeacon('/api/bye', new Blob(['{}'], { type:'application/json' }));
  });

  $('save').onclick  = () => run('export');
  $('write').onclick = () => run('write');
  $('read').onclick  = () => run('read');
  $('serial').addEventListener('keydown', e => { if (e.key === 'Enter') run('export'); });

  // ---- tabs ----
  document.querySelectorAll('.tab').forEach(t => {
    t.onclick = () => {
      document.querySelectorAll('.tab').forEach(x => x.classList.toggle('active', x === t));
      $('screen-main').hidden = t.dataset.screen !== 'main';
      $('screen-edit').hidden = t.dataset.screen !== 'edit';
    };
  });

  // ---- edit screen ----
  let loaded = null;   // { fields, payloadHex }

  if (!CAN_WRITE) {
    $('loadTag').disabled = true;
    $('applyWrite').disabled = true;
    $('editNote').textContent = 'Tag access unavailable: __PCSCERROR__ Loading from a serial still works.';
  }

  function eshow(ok, msg) {
    const o = $('editOut');
    o.style.display = 'block';
    o.className = ok ? 'ok' : 'err';
    o.textContent = msg;
  }

  function renderEditor(data) {
    loaded = data;
    $('editLegend').textContent = data.title || 'Tag data';
    const host = $('editFields');
    host.innerHTML = '';
    let section = null;
    for (const f of data.fields) {
      if (f.section !== section) {
        section = f.section;
        const h = document.createElement('div');
        h.className = 'fgroup';
        h.textContent = section;
        host.appendChild(h);
      }
      const row = document.createElement('div');
      row.className = 'frow';
      const lab = document.createElement('label');
      lab.textContent = f.name + (f.unit ? ' (' + f.unit + ')' : '');
      lab.htmlFor = 'f_' + f.id;
      const inp = document.createElement('input');
      inp.id = 'f_' + f.id;
      inp.dataset.fid = f.id;
      inp.value = f.value;
      if (f.readonly) { inp.readOnly = true; inp.tabIndex = -1; }
      row.appendChild(lab);
      row.appendChild(inp);
      if (f.type === 'rgba') {
        const sw = document.createElement('span');
        sw.className = 'sw';
        const paint = () => { sw.style.background = (inp.value.split(' ')[0] || 'transparent'); };
        inp.addEventListener('input', paint);
        paint();
        row.appendChild(sw);
      }
      host.appendChild(row);
    }
    $('editForm').hidden = false;
    $('confirm').style.display = 'none';
    eshow(true, 'Loaded. Edit any field, then save or write.');
  }

  function collect() {
    const values = {};
    document.querySelectorAll('#editFields input').forEach(i => { values[i.dataset.fid] = i.value; });
    return values;
  }

  async function post(url, body) {
    const res = await fetch(url, {
      method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)
    });
    return res.json();
  }

  async function load(source) {
    const btns = [$('loadSerial'), $('loadTag')];
    btns.forEach(b => b.disabled = true);
    eshow(true, 'Loading...');
    try {
      const data = await post('/api/load', {
        source, serial: $('eSerial').value.trim(),
        tagType: $('eTagType').value, readerName: $('eReader').value.trim()
      });
      if (data.ok) renderEditor(data); else { $('editForm').hidden = true; eshow(false, data.message); }
    } catch (e) { eshow(false, 'Request failed: ' + e.message); }
    finally {
      btns.forEach(b => b.disabled = false);
      if (!CAN_WRITE) $('loadTag').disabled = true;
    }
  }

  function askConfirm(data, onYes) {
    $('confirmTitle').textContent = data.message;
    $('confirmBody').innerHTML =
      '<ul>' + (data.keeping || []).map(f =>
        '<li>' + f.name + (f.value ? ': ' + f.value : '') + '</li>').join('') + '</ul>' +
      '<div style="font-size:.85rem;opacity:.75">' + (data.dropped || 0) +
      ' extended field(s) will be discarded. To keep everything, choose NTAG215 or NTAG216.</div>';
    $('confirm').style.display = 'block';
    $('editOut').style.display = 'none';
    $('confirmGo').onclick = () => { $('confirm').style.display = 'none'; onYes(); };
    $('confirmCancel').onclick = () => {
      $('confirm').style.display = 'none';
      eshow(true, 'Cancelled. Nothing was saved or written.');
    };
  }

  async function apply(target, confirmTruncate) {
    if (!loaded) return;
    const btns = [$('applySave'), $('applyWrite'), $('revert')];
    btns.forEach(b => b.disabled = true);
    $('confirm').style.display = 'none';
    eshow(true, target === 'tag' ? 'Writing...' : 'Saving...');
    try {
      const data = await post('/api/apply', {
        target, tagType: $('eTagType').value, payloadHex: loaded.payloadHex,
        values: collect(), outputDir: $('eOutputDir').value.trim(),
        readerName: $('eReader').value.trim(),
        confirmTruncate: !!confirmTruncate
      });
      if (data.confirm === 'truncate') {
        askConfirm(data, () => apply(target, true));
      } else {
        eshow(data.ok, data.message);
      }
    } catch (e) { eshow(false, 'Request failed: ' + e.message); }
    finally {
      btns.forEach(b => b.disabled = false);
      if (!CAN_WRITE) $('applyWrite').disabled = true;
    }
  }

  $('loadSerial').onclick = () => load('serial');
  $('loadTag').onclick    = () => load('tag');
  $('applySave').onclick  = () => apply('file', false);
  $('applyWrite').onclick = () => apply('tag', false);
  $('revert').onclick     = () => { if (loaded) renderEditor(loaded); };
  $('eSerial').addEventListener('keydown', e => { if (e.key === 'Enter') load('serial'); });

  $('stop').onclick = async () => {
    await fetch('/api/stop', { method:'POST', headers:{'Content-Type':'application/json'}, body:'{}' }).catch(() => {});
    document.body.innerHTML = '<h1>Stopped</h1><p class="sub">You can close this tab.</p>';
  };
</script>
'@

    $reason = if ($PcscError) { $PcscError } else { 'No PC/SC reader detected.' }
    $page.Replace('__CANWRITE__', $CanWrite.ToString().ToLowerInvariant()).
          Replace('__DEFAULTDIR__', [Net.WebUtility]::HtmlEncode($DefaultDir)).
          Replace('__PCSCERROR__', [Net.WebUtility]::HtmlEncode($reason))
}
