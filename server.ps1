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
# players open/abort many parallel streams — the .NET default of TWO
# connections per host deadlocks the relay in minutes
try { [Net.ServicePointManager]::DefaultConnectionLimit = 64 } catch {}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try { $listener.Start() } catch { exit }

# Background downloader: copy every Drive video in bea-data.json into
# drive-cache\ (once). A cached video plays instantly from disk instead of
# waiting ~10s of round-trips to Google. Never committed to git (.gitignore).
$downloader = {
  param($root)
  $cache = Join-Path $root "drive-cache"
  if (-not (Test-Path $cache)) { $null = New-Item -ItemType Directory $cache }
  while ($true) {
    try {
      $data = Get-Content (Join-Path $root "bea-data.json") -Raw | ConvertFrom-Json
      $vids = $data.'bea-videos' | ConvertFrom-Json
      foreach ($v in $vids) {
        $id = "" + $v.id
        if ($id.Length -le 11 -or $id -notmatch '^[A-Za-z0-9_-]+$') { continue } # YouTube / junk
        $f = Join-Path $cache "$id.mp4"
        if (Test-Path $f) { continue }
        $tmp = "$f.part"
        try {
          $req = [System.Net.HttpWebRequest]::Create("https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t")
          $req.UserAgent = "Mozilla/5.0"
          $resp = $req.GetResponse()
          try {
            if ($resp.ContentType -notlike "text/html*") {
              $in = $resp.GetResponseStream()
              $out = [System.IO.File]::Create($tmp)
              $buf = New-Object byte[] 1048576
              while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n) }
              $out.Close()
              Move-Item -Force $tmp $f   # only complete files get the real name
            }
          } finally { try { $resp.Close() } catch {} }
        } catch { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
      }
    } catch {}
    Start-Sleep -Seconds 60   # picks up newly added links within a minute
  }
}
$dlPs = [PowerShell]::Create()
$null = $dlPs.AddScript($downloader.ToString()).AddArgument($root)
$null = $dlPs.BeginInvoke()

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
      $cacheFile = Join-Path $root "drive-cache\$id.mp4"
      if (Test-Path $cacheFile) {
        # cached: instant playback straight from disk, with seeking
        $fs = [System.IO.File]::Open($cacheFile, "Open", "Read", "ReadWrite")
        try {
          $total = $fs.Length
          $start = [int64]0
          $end = $total - 1
          $range = $ctx.Request.Headers["Range"]
          if ($range -and $range -match 'bytes=(\d*)-(\d*)') {
            if ($Matches[1] -ne "") {
              $start = [int64]$Matches[1]
              if ($Matches[2] -ne "") { $end = [int64]$Matches[2] }
            } elseif ($Matches[2] -ne "") {
              $start = $total - [int64]$Matches[2]
            }
            if ($end -ge $total) { $end = $total - 1 }
            $ctx.Response.StatusCode = 206
            $ctx.Response.AddHeader("Content-Range", "bytes $start-$end/$total")
          }
          $ctx.Response.ContentType = "video/mp4"
          $ctx.Response.AddHeader("Accept-Ranges", "bytes")
          $ctx.Response.ContentLength64 = $end - $start + 1
          $fs.Position = $start
          $remaining = $end - $start + 1
          $buf = New-Object byte[] 65536
          while ($remaining -gt 0) {
            $n = $fs.Read($buf, 0, [int][Math]::Min(65536, $remaining))
            if ($n -le 0) { break }
            $ctx.Response.OutputStream.Write($buf, 0, $n)
            $remaining -= $n
          }
        } finally { $fs.Close() }
        try { $ctx.Response.OutputStream.Close() } catch {}
        return
      }
      # not cached yet: relay live from Google (slower first play)
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
      try {
        if ($resp.ContentType -like "text/html*") {
          # Drive answered with a web page (sharing off / quota) — not a video
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
        }
      } finally {
        # ALWAYS give the Google connection back — an aborted play used to
        # leak it, and two leaks jammed the relay solid
        try { $resp.Close() } catch {}
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
