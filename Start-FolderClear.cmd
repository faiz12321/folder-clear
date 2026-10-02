@echo off
rem Starts Folder Clear without showing a console window.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0FolderClear.ps1"
