@echo off
rem Modo dev com o "borion dev": o app servindo web\ direto da pasta; salvou um arquivo, a página recarrega.
rem Mudou o Delphi? O app é recompilado e reaberto. Feche o app para encerrar.
rem O mesmo que, nesta pasta: borion dev
setlocal
if "%BORION_HOME%"=="" set BORION_HOME=C:\dev\borion
if not exist "%BORION_HOME%\Tools\borion.exe" call "%BORION_HOME%\Tools\build.bat" || exit /b 1
"%BORION_HOME%\Tools\borion.exe" dev "%~dp0." %*
