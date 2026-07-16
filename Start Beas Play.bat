@echo off
rem Launcher for Bea's Play — starts a tiny local server (so YouTube videos
rem work) and opens the game in the browser. Double-click me!
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0server.ps1"
timeout /t 1 /nobreak >nul
start "" "http://localhost:8420/"
