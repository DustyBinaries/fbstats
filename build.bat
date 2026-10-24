@echo off
rem Compila o fbstats.exe com o "borion build" (ou abra fbstats.dpr na IDE).
rem O mesmo que, nesta pasta: borion build
setlocal
if "%BORION_HOME%"=="" set BORION_HOME=C:\dev\borion
if not exist "%BORION_HOME%\Tools\borion.exe" call "%BORION_HOME%\Tools\build.bat" || exit /b 1
"%BORION_HOME%\Tools\borion.exe" build "%~dp0."
