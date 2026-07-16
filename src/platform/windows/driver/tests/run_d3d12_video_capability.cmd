@echo off
setlocal
call "C:\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=x64
if errorlevel 1 exit /b %errorlevel%
pushd "%~dp0"
cl /nologo /std:c++20 /EHsc /W4 /WX d3d12_video_capability.cpp /link d3d12.lib dxgi.lib /out:d3d12_video_capability.exe
if errorlevel 1 (
  popd
  exit /b %errorlevel%
)
d3d12_video_capability.exe
set "probe_exit=%errorlevel%"
popd
exit /b %probe_exit%
