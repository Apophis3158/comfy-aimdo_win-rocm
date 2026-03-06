@echo off
setlocal enabledelayedexpansion

REM Build script for comfy-aimdo on Windows ROCm

set "SCRIPT_DIR=%~dp0"

REM ---- cd to the project root (parent of the folder this script lives in) ----
cd /d "%SCRIPT_DIR%.."
echo Working directory: %CD%

echo ============================================
echo   Building comfy-aimdo for Windows ROCm
echo ============================================
echo.

REM ---- ROCm SDK Path Detection ----
where hipconfig >nul 2>nul
if !errorlevel! equ 0 (
    for /f "usebackq tokens=*" %%i in (`hipconfig --path`) do set "ROCM_PATH=%%i"
    if defined ROCM_PATH (
        echo Detected ROCM_PATH from hipconfig: !ROCM_PATH!
    )
) else (
    echo.
    echo ROCM_PATH environment variable not set and hipconfig not found.
    echo Enter the path to your ROCm SDK core directory.
    echo This is typically inside your venv, e.g.:
    echo   C:\ComfyUI\venv\Lib\site-packages\_rocm_sdk_core
    echo.
    set /p ROCM_PATH="ROCm SDK path: "
)

echo.

REM ---- CUDA Path Detection ----
if defined CUDA_PATH (
    set "CUDA_ORIG=%CUDA_PATH%"
    echo Detected CUDA_PATH environment variable: !CUDA_ORIG!
) else (
    echo.
    echo CUDA_PATH environment variable not found.
    echo Enter the path to your CUDA toolkit installation, e.g.:
    echo   C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9
    echo.
    set /p CUDA_ORIG="CUDA path: "
)

echo.

REM Strip any trailing backslash from user input
if "%ROCM_PATH:~-1%"=="\" set "ROCM_PATH=%ROCM_PATH:~0,-1%"
if "%CUDA_ORIG:~-1%"=="\" set "CUDA_ORIG=%CUDA_ORIG:~0,-1%"

REM ---- Validate inputs ----
if not exist "%ROCM_PATH%" (
    echo ERROR: ROCm path not found: %ROCM_PATH%
    exit /b 1
)
if not exist "%CUDA_ORIG%" (
    echo ERROR: CUDA path not found: %CUDA_ORIG%
    exit /b 1
)

REM ---- Build Microsoft Detours from patch folder ----
set "DETOURS_DIR=%SCRIPT_DIR%Detours"
if not exist "%DETOURS_DIR%" (
    echo Cloning Microsoft Detours into %DETOURS_DIR%...
    git clone --depth 1 https://github.com/microsoft/Detours.git "%DETOURS_DIR%"
    if %errorlevel% neq 0 (
        echo ERROR: Failed to clone Detours. Is git in your PATH?
        exit /b 1
    )
)

for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath`) do set "VS_PATH=%%i"
if not defined VS_PATH (
    REM ---- Visual Studio Path Prompt ----
    echo.
    echo Could not use vswhere.exe.
    echo Enter the path to your Visual Studio installation directory.
    echo This is the folder containing the 'VC' folder, e.g.:
    echo   C:\Program Files\Microsoft Visual Studio\2022\Community
    echo.
    set /p VS_PATH="Visual Studio Path: "
)

if not exist "%VS_PATH%\VC\Tools\MSVC\" (
    echo ERROR: Visual Studio path invalid or MSVC tools missing: %VS_PATH%
    exit /b 1
)
echo Found VS at: %VS_PATH%

if not exist "%DETOURS_DIR%\lib.X64\detours.lib" (
    echo Building Detours...
    set "DETOURS_BUILD_BAT=%TEMP%\build_detours_%RANDOM%.bat"
    (
        echo @echo off
        echo call "!VS_PATH!\VC\Auxiliary\Build\vcvars64.bat"
        echo cd /d "!DETOURS_DIR!"
        echo cd src
		echo nmake
    ) > "!DETOURS_BUILD_BAT!"
    cmd.exe /c "!DETOURS_BUILD_BAT!"
    del "!DETOURS_BUILD_BAT!" >nul 2>nul
    if %errorlevel% neq 0 (
        echo ERROR: Detours nmake failed.
        exit /b 1
    )
    if not exist "%DETOURS_DIR%\lib.X64\detours.lib" (
        echo ERROR: Detours built but detours.lib still not found. Check nmake output above.
        exit /b 1
    )
)
echo Detours ready at: %DETOURS_DIR%

REM ---- Derive paths ----
set "ROCM_CLANG=%ROCM_PATH%\lib\llvm\lib\clang"
set "CLANG_EXE=%ROCM_PATH%\lib\llvm\bin\clang.exe"
set "LLDLINK_EXE=%ROCM_PATH%\lib\llvm\bin\lld-link.exe"
set "HIP_INCLUDE=%ROCM_PATH%\include"
set "HIP_LIB=%ROCM_PATH%\lib"

for /d %%i in ("%ROCM_CLANG%\*") do set "CLANG_RESOURCE_DIR=%%i"

if not defined CLANG_RESOURCE_DIR (
    echo ERROR: Could not find clang version directory under %ROCM_CLANG%
    exit /b 1
)
if not exist "%CLANG_EXE%" (
    echo ERROR: clang.exe not found at %CLANG_EXE%
    exit /b 1
)

echo ROCm path:  %ROCM_PATH%
echo CUDA path:  %CUDA_ORIG%
echo Clang:      %CLANG_EXE%
echo Clang dir:  %CLANG_RESOURCE_DIR%
echo.

REM ---- CUDA junction (hipify needs a path without spaces) ----
REM Python creates the junction to avoid mklink quoting issues from PowerShell
set "CUDA_LINK=%TEMP%\cuda_hip_%RANDOM%%RANDOM%"
python "%SCRIPT_DIR%_make_junction.py" "%CUDA_LINK%" "%CUDA_ORIG%"
if %errorlevel% neq 0 (
    echo ERROR: Failed to create junction at %CUDA_LINK%
    echo        Try running this script as Administrator.
    exit /b 1
)

REM ---- Pre-build Cleanup and Copy ----
if exist hip_src rmdir /S /Q hip_src
if exist build rmdir /S /Q build
if exist comfy_aimdo.egg-info rmdir /S /Q comfy_aimdo.egg-info
if exist comfy_aimdo\_version.py del /F /Q comfy_aimdo\_version.py
if exist comfy_aimdo\aimdo.dll del /F /Q comfy_aimdo\aimdo.dll
if exist comfy_aimdo\aimdo.lib del /F /Q comfy_aimdo\aimdo.lib
mkdir hip_src
copy src\*.c hip_src\ >nul 2>nul
copy src\*.h hip_src\ >nul 2>nul
if exist src-win\ (
    copy src-win\*.c hip_src\ >nul 2>nul
    copy src-win\*.h hip_src\ >nul 2>nul
)
REM cuda-detour.c is hipified in-place like all other sources; hip-detour.c is generated later

set "HIPIFY_EXE=%ROCM_PATH%\bin\hipify-clang.exe"

REM ---- Fix hipMemAddressReserve alignment for AMD Windows ----
echo Patching source files for AMD Windows pre-reserved VA support...
python "%SCRIPT_DIR%_patch_prereserved.py"
if %errorlevel% neq 0 (
    echo ERROR: Pre-reserved VA patch failed.
    goto :buildfailed
)

REM ---- HIPify ----
echo Converting CUDA to HIP...
if not exist "%HIPIFY_EXE%" (
    echo WARNING: hipify-clang not found at %HIPIFY_EXE%, trying PATH...
    set "HIPIFY_EXE=hipify-clang"
)
for %%f in (hip_src\*.h hip_src\*.c) do (
    "%HIPIFY_EXE%" --default-preprocessor --clang-resource-directory="%CLANG_RESOURCE_DIR%" --cuda-path="%CUDA_LINK%" --cuda-gpu-arch=sm_52 --inplace "%%f" >nul 2>nul
)

REM cuda-detour.c is replaced by the generated hip-detour.c -- remove it now
if exist hip_src\cuda-detour.c del /F /Q hip_src\cuda-detour.c

REM ---- Manual type replacements (hipify misses some) ----
echo Applying type replacements...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%_type_replace.ps1"
if %errorlevel% neq 0 (
    echo ERROR: Type replacement failed.
    goto :buildfailed
)

REM ---- Generate AMD DXGI-based cuDeviceGetLuid + ROCm stubs ----
echo Generating ROCm platform stubs...
python "%SCRIPT_DIR%_gen_stubs.py"
if %errorlevel% neq 0 (
    echo ERROR: Failed to generate ROCm stubs.
    goto :buildfailed
)

REM ---- Compile each source to an object file ----
echo.
echo Compiling...
set "HIP_SRC_PATH=%CD%\hip_src"
if not exist comfy_aimdo mkdir comfy_aimdo
if not exist obj mkdir obj

REM ---- Auto-detect MSVC Version ----
set "MSVC_VER="
for /f "delims=" %%i in ('dir /b /ad /on "%VS_PATH%\VC\Tools\MSVC\"') do set "MSVC_VER=%%i"
set "MSVC_VER_PATH=%VS_PATH%\VC\Tools\MSVC\%MSVC_VER%"

REM ---- Auto-detect Windows SDK ----
set "WINSDK_BASE="
if exist "D:\Program Files (x86)\Windows Kits\10" set "WINSDK_BASE=D:\Program Files (x86)\Windows Kits\10"
if not defined WINSDK_BASE if exist "C:\Program Files (x86)\Windows Kits\10" set "WINSDK_BASE=C:\Program Files (x86)\Windows Kits\10"
if not defined WINSDK_BASE if exist "D:\Program Files\Windows Kits\10" set "WINSDK_BASE=D:\Program Files\Windows Kits\10"
if not defined WINSDK_BASE if exist "C:\Program Files\Windows Kits\10" set "WINSDK_BASE=C:\Program Files\Windows Kits\10"
if not defined WINSDK_BASE (
    echo ERROR: Windows SDK 10 not found.
    exit /b 1
)

set "WINSDK_VER="
for /f "delims=" %%i in ('dir /b /ad /on "%WINSDK_BASE%\Include\"') do set "WINSDK_VER=%%i"
set "WINSDK_INC_PATH=%WINSDK_BASE%\Include\%WINSDK_VER%"
set "WINSDK_LIB_PATH=%WINSDK_BASE%\Lib\%WINSDK_VER%"
echo Found WinSDK at: %WINSDK_BASE% (%WINSDK_VER%)

REM Build compile flags across multiple lines to stay readable
set "CF=-D__HIP_PLATFORM_AMD__ -O3 -fms-extensions -fms-compatibility"
set "CF=%CF% -I"%DETOURS_DIR%\include""
set "CF=%CF% -I"%HIP_SRC_PATH%" -I"%HIP_INCLUDE%""
set "CF=%CF% -isystem "%CLANG_RESOURCE_DIR%\include""
set "CF=%CF% -isystem "%MSVC_VER_PATH%\include""
set "CF=%CF% -isystem "%WINSDK_INC_PATH%\ucrt""
set "CF=%CF% -isystem "%WINSDK_INC_PATH%\shared""
set "CF=%CF% -isystem "%WINSDK_INC_PATH%\um""

set "OBJ_FILES="
for %%f in (hip_src\*.c) do (
    echo Compiling %%f...
    "%CLANG_EXE%" %CF% -c "%%f" -o "obj\%%~nf.obj"
    if errorlevel 1 (
        echo COMPILE ERROR in %%f
        goto :buildfailed
    )
    set "OBJ_FILES=!OBJ_FILES! "obj\%%~nf.obj""
)

REM ---- Linking ----
echo.
echo Linking...
set "MSVC_LIB=%MSVC_VER_PATH%\lib\x64"
if exist comfy_aimdo\aimdo.dll del comfy_aimdo\aimdo.dll

"%LLDLINK_EXE%" ^
    -out:comfy_aimdo\aimdo.dll ^
    -dll ^
    -nologo ^
    "-libpath:%HIP_LIB%" ^
    "-libpath:%MSVC_LIB%" ^
    "-libpath:%WINSDK_LIB_PATH%\ucrt\x64" ^
    "-libpath:%WINSDK_LIB_PATH%\um\x64" ^
    "-libpath:%CLANG_RESOURCE_DIR%\lib\windows" ^
    "%CLANG_RESOURCE_DIR%\lib\windows\clang_rt.builtins-x86_64.lib" ^
    "-libpath:%DETOURS_DIR%\lib.X64" ^
    amdhip64.lib ^
	detours.lib ^
	dxgi.lib ^
    dxguid.lib ^
    libcmt.lib ^
    %OBJ_FILES%

set BUILD_RESULT=%ERRORLEVEL%
if %BUILD_RESULT% neq 0 goto :buildfailed

echo Removing Detours folder (no longer needed after linking)...
rmdir /S /Q "%DETOURS_DIR%"

REM ---- Write comfy_aimdo\model_vbar.py ----
echo Patching comfy_aimdo\model_vbar.py...
python "%SCRIPT_DIR%_write_model_vbar.py" comfy_aimdo\model_vbar.py
if %errorlevel% neq 0 (
    echo ERROR: Failed to write model_vbar.py
    goto :buildfailed
)
echo   model_vbar.py patched OK.

goto :cleanup

:buildfailed
set BUILD_RESULT=1

:cleanup
if exist "%CUDA_LINK%\" rmdir "%CUDA_LINK%"
if exist obj rmdir /S /Q obj

echo.
if %BUILD_RESULT% EQU 0 (
    if exist comfy_aimdo\aimdo.dll (
        echo ============================================
        echo          BUILD SUCCESSFUL
        echo ============================================
        echo Output: comfy_aimdo\aimdo.dll
        for %%F in (comfy_aimdo\aimdo.dll) do echo Size:   %%~zF bytes
        echo.
        echo Now run:
		echo   cd .. ^&^& pip install .
        echo.
        echo After that, one manual step:
        for /f "tokens=*" %%i in ('python -c "import site; print(site.getsitepackages()[0])"') do set "VENV_SITE=%%i"
        echo Copy %ROCM_PATH%\bin\amdhip64_7.dll
        echo   to !VENV_SITE!\Lib\site-packages\comfy_aimdo\
        echo   This ensures the package uses the venv-local ROCm runtime.
		echo   Otherwise, it will fall back to the system-wide version,
		echo   which may fail if the versions differ.
        echo ============================================
    ) else (
        echo ============================================
        echo BUILD FAILED - DLL not produced
        echo ============================================
        exit /b 1
    )
) else (
    echo ============================================
    echo BUILD FAILED - error code %BUILD_RESULT%
    echo ============================================
    exit /b %BUILD_RESULT%
)
