# Tiny local web server for Bea's Play — needed so YouTube videos will play
# (YouTube blocks its player on pages opened straight from a file), and to
# relay Google Drive videos (Drive's download servers refuse to let browsers
# play the file directly, so we fetch it here and hand it over as video).
# Started automatically by "Start Beas Play.bat". No installs needed.

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 8420

# If an older copy of the server (from a different folder / old download) is
# still running, stop it — the folder you double-clicked should always win.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*server.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

# modern TLS for talking to Google (3072 = TLS1.2, 12288 = TLS1.3)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288 } catch {
  try { [Net.ServicePointManager]::SecurityProtocol = 3072 } catch {}
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try { $listener.Start() } catch { exit }

$mime = @{
  ".html" = "text/html; charset=utf-8"
  ".js"   = "text/javascript"
  ".css"  = "text/css"
  ".json" = "application/json"
  ".png"  = "image/png"
  ".jpg"  = "image/jpeg"
  ".jpeg" = "image/jpeg"
  ".gif"  = "image/gif"
  ".svg"  = "image/svg+xml"
  ".ico"  = "image/x-icon"
  ".mp3"  = "audio/mpeg"
  ".mp4"  = "video/mp4"
  ".mov"  = "video/mp4"
  ".woff" = "font/woff"
  ".woff2"= "font/woff2"
}

# Everything a request needs, run on its own thread — a long video stream
# must never block saving data or serving the page itself.
$handler = {
  param($ctx, $root, $mime)
  try {
    $ctx.Response.AddHeader("Cache-Control", "no-store")  # always fresh files
    $path = [System.Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath)
    if ($path -eq "/") { $path = "/index.html" }

    # the app POSTs its saved data here -> written to bea-data.json so the
    # admin content travels with the folder (and with GitHub)
    if ($ctx.Request.HttpMethod -eq "POST" -and $path -eq "/save") {
      $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
      $body = $reader.ReadToEnd()
      $reader.Close()
      try {
        $null = $body | ConvertFrom-Json  # sanity check: only write real JSON
        [System.IO.File]::WriteAllText((Join-Path $root "bea-data.json"), $body, (New-Object System.Text.UTF8Encoding($false)))
        # auto-push the data to GitHub (only when this folder is a git repo)
        if (Test-Path (Join-Path $root ".git")) {
          $cmd = "Set-Location -LiteralPath '$root'; git add bea-data.json; git commit -m 'auto: update saved data'; git push"
          Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $cmd
        }
        $out = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $ctx.Response.ContentType = "application/json"
        $ctx.Response.ContentLength64 = $out.Length
        $ctx.Response.OutputStream.Write($out, 0, $out.Length)
      } catch {
        $ctx.Response.StatusCode = 400
      }
    }
    # /drive/<fileId> -> relay the shared Drive file as playable video.
    # Drive serves downloads as "generic file + never sniff", which browsers
    # refuse to play; relabeling it here as video/mp4 is all it takes.
    elseif ($path -match '^/drive/([A-Za-z0-9_-]{20,})$') {
      $id = $Matches[1]
      $req = [System.Net.HttpWebRequest]::Create("https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t")
      $req.UserAgent = "Mozilla/5.0"
      # pass the player's byte-range through (seeking, moov-at-end files)
      $range = $ctx.Request.Headers["Range"]
      if ($range -and $range -match 'bytes=(\d*)-(\d*)') {
        if ($Matches[1] -ne "" -and $Matches[2] -ne "") { $req.AddRange([int64]$Matches[1], [int64]$Matches[2]) }
        elseif ($Matches[1] -ne "") { $req.AddRange([int64]$Matches[1]) }
        elseif ($Matches[2] -ne "") { $req.AddRange(-([int64]$Matches[2])) }
      }
      $resp = $req.GetResponse()
      if ($resp.ContentType -like "text/html*") {
        # Drive answered with a web page (sharing off / quota) — not a video
        $resp.Close()
        $ctx.Response.StatusCode = 502
      } else {
        if ([int]$resp.StatusCode -eq 206) { $ctx.Response.StatusCode = 206 }
        $ctx.Response.ContentType = "video/mp4"
        $ctx.Response.AddHeader("Accept-Ranges", "bytes")
        $cr = $resp.Headers["Content-Range"]
        if ($cr) { $ctx.Response.AddHeader("Content-Range", $cr) }
        if ($resp.ContentLength -ge 0) { $ctx.Response.ContentLength64 = $resp.ContentLength }
        $in = $resp.GetResponseStream()
        $buf = New-Object byte[] 65536
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
          $ctx.Response.OutputStream.Write($buf, 0, $n)
        }
        $in.Close()
        $resp.Close()
      }
    }
    else {
      $file = Join-Path $root ($path.TrimStart("/") -replace "/", "\")
      $full = [System.IO.Path]::GetFullPath($file)
      if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path $full -PathType Leaf)) {
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $ext = [System.IO.Path]::GetExtension($full).ToLower()
        if ($mime.ContainsKey($ext)) { $ctx.Response.ContentType = $mime[$ext] }
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      } else {
        $ctx.Response.StatusCode = 404
      }
    }
  } catch { }
  try { $ctx.Response.OutputStream.Close() } catch { }
}

# accept loop: hand each request to a fresh thread, sweep finished ones
$pending = New-Object System.Collections.ArrayList
while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
    for ($i = $pending.Count - 1; $i -ge 0; $i--) {
      $p = $pending[$i]
      if ($p[1].IsCompleted) {
        try { $p[0].EndInvoke($p[1]) } catch {}
        $p[0].Dispose()
        $pending.RemoveAt($i)
      }
    }
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript($handler.ToString()).AddArgument($ctx).AddArgument($root).AddArgument($mime)
    $null = $pending.Add(@($ps, $ps.BeginInvoke()))
  } catch { }
}
