@echo off
rem Delegates to the VBScript launcher so no console window stays open.
start "" wscript.exe //nologo "%~dp0Start-Cockpit.vbs"
