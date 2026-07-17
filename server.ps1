# Tiny local web server for Bea's Play — needed so YouTube videos will play
# (YouTube blocks its player on pages opened straight from a file).
# Started automatically by "Start Beas Play.bat". No installs needed.

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 8420

# If an older copy of the server (from a different folder / old download) is
# still running, stop it — the folder you double-clicked should always win.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*server.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

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
  ".woff" = "font/woff"
  ".woff2"= "font/woff2"
}

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
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
        $out = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $ctx.Response.ContentType = "application/json"
        $ctx.Response.ContentLength64 = $out.Length
        $ctx.Response.OutputStream.Write($out, 0, $out.Length)
      } catch {
        $ctx.Response.StatusCode = 400
      }
      $ctx.Response.OutputStream.Close()
      continue
    }
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
    $ctx.Response.OutputStream.Close()
  } catch { }
}
