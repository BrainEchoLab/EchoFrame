@echo off
REM ============================================================================
REM EchoFrame Multi-Configuration Build Script
REM ============================================================================
REM This script builds EchoFrame with different CUDA and MATLAB versions.
REM Edit the configuration sections below to match your environment.
REM
REM Dependencies folder structure (EDIT THESE PATHS):
REM   CUDA 12.9: C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9
REM   CUDA 13.1: C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.1
REM   MATLAB 2022a: C:\Program Files\MATLAB\R2022a
REM   MATLAB 2024a: C:\Program Files\MATLAB\R2024a
REM ============================================================================

setlocal enabledelayedexpansion

REM Colors for output (Windows 10+)
for /F %%A in ('copy /Z "%~f0" nul') do set "BS=%%A"

REM Repository root - this script lives in build_scripts/, so the root is one level up.
REM pushd/popd normalises the "...\build_scripts\.." form into a clean absolute path.
pushd "%~dp0.."
set "REPO_ROOT=%CD%"
popd
cd /d "%REPO_ROOT%"

REM Where the CMake build trees go. Defaults to the repository root rather than
REM echoframe\cpp\src, because the Visual Studio generator nests deeply and a
REM 260-character path is easy to hit from a deep checkout. Set EF_BUILD_ROOT to
REM build somewhere shorter still, e.g.:
REM     set EF_BUILD_ROOT=C:\efb
if not defined EF_BUILD_ROOT set "EF_BUILD_ROOT=%REPO_ROOT%"
if not exist "%EF_BUILD_ROOT%" mkdir "%EF_BUILD_ROOT%"
echo Repository root: %REPO_ROOT%
echo Build root:      %EF_BUILD_ROOT%

REM MSBuild customizations path for CUDA
set "MSBUILD_CUDA_PATH=C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Microsoft\VC\v170\BuildCustomizations"

REM Switching the Visual Studio CUDA integration rewrites files under
REM MSBUILD_CUDA_PATH, which needs Administrator. Without it every move in
REM :manage_cuda_files fails and the build silently uses whichever integration
REM happens to be active -- which only surfaces later as a confusing
REM "nvcc fatal : Unsupported gpu architecture" from the compiler-id probe.
net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo ERROR: this script must be run from an elevated terminal ^(Run as administrator^).
    echo        It switches the Visual Studio CUDA integration under:
    echo          %MSBUILD_CUDA_PATH%
    echo.
    pause
    exit /b 1
)

REM Visual Studio path
set "VS_PATH=C:\Program Files\Microsoft Visual Studio\2022\Community"
set "VSBUILD_PATH=%VS_PATH%\MSBuild\Current\Bin\amd64\MSBuild.exe"

REM CMake path
set "CMAKE_PATH=C:\Program Files\CMake\bin\cmake.exe"

REM Python for the pybind11 module. The published binaries target 3.12, so resolve
REM that interpreter through the Windows Python launcher (py) rather than hardcoding a
REM user-specific path -- anyone with Python 3.12 installed can run this unchanged.
set "PYTHON_VERSION=3.12"
set "PYTHON_ROOT="
for /f "delims=" %%P in ('py -%PYTHON_VERSION% -c "import sys,os;print(os.path.dirname(sys.executable))" 2^>nul') do set "PYTHON_ROOT=%%P"
if not defined PYTHON_ROOT (
    echo ERROR: Python %PYTHON_VERSION% not found. Install it, or make sure "py -%PYTHON_VERSION%" works.
    pause
    exit /b 1
)
set "PYTHON_EXE=%PYTHON_ROOT%\python.exe"
echo Using Python %PYTHON_VERSION%: %PYTHON_EXE%

REM vcpkg paths (EDIT IF YOUR VCPKG LOCATION IS DIFFERENT)
set "VCPKG_PATH=C:\vcpkg"
set "VCPKG_TOOLCHAIN=%VCPKG_PATH%\scripts\buildsystems\vcpkg.cmake"
REM Static libraries against the dynamic CRT, to match the MEX and Python modules.
set "VCPKG_TRIPLET=x64-windows-static-md"
set "VCPKG_PREFIX=%VCPKG_PATH%\installed\%VCPKG_TRIPLET%"

REM ============================================================================
REM BUILD CONFIGURATIONS - Edit these sections for your builds
REM ============================================================================

REM Configuration 1: CUDA 12.8 + MATLAB 2022a
set "CONFIG[0].NAME=CUDA_12.8_MATLAB_2022a"
set "CONFIG[0].CUDA_VERSION=12.8"
set "CONFIG[0].CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8"
set "CONFIG[0].MATLAB_VERSION=R2022a"
set "CONFIG[0].MATLAB_PATH=C:\Program Files\MATLAB\R2022a"
set "CONFIG[0].CMAKE_MATLAB_VERSION=9.12"

REM Configuration 1: CUDA 12.9 + MATLAB 2022a
set "CONFIG[1].NAME=CUDA_12.9_MATLAB_2022a"
set "CONFIG[1].CUDA_VERSION=12.9"
set "CONFIG[1].CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9"
set "CONFIG[1].MATLAB_VERSION=R2022a"
set "CONFIG[1].MATLAB_PATH=C:\Program Files\MATLAB\R2022a"
set "CONFIG[1].CMAKE_MATLAB_VERSION=9.12"

REM Configuration 2: CUDA 13.1 + MATLAB 2022a
set "CONFIG[2].NAME=CUDA_13.1_MATLAB_2022a"
set "CONFIG[2].CUDA_VERSION=13.1"
set "CONFIG[2].CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.1"
set "CONFIG[2].MATLAB_VERSION=R2022a"
set "CONFIG[2].MATLAB_PATH=C:\Program Files\MATLAB\R2022a"
set "CONFIG[2].CMAKE_MATLAB_VERSION=9.12"

REM Configuration 1: CUDA 12.8 + MATLAB 2024a
set "CONFIG[3].NAME=CUDA_12.8_MATLAB_2024a"
set "CONFIG[3].CUDA_VERSION=12.8"
set "CONFIG[3].CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8"
set "CONFIG[3].MATLAB_VERSION=R2024a"
set "CONFIG[3].MATLAB_PATH=C:\Program Files\MATLAB\R2024a"
set "CONFIG[3].CMAKE_MATLAB_VERSION=24.1"

REM Configuration 3: CUDA 12.9 + MATLAB 2024a
set "CONFIG[4].NAME=CUDA_12.9_MATLAB_2024a"
set "CONFIG[4].CUDA_VERSION=12.9"
set "CONFIG[4].CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9"
set "CONFIG[4].MATLAB_VERSION=R2024a"
set "CONFIG[4].MATLAB_PATH=C:\Program Files\MATLAB\R2024a"
set "CONFIG[4].CMAKE_MATLAB_VERSION=24.1"

REM Configuration 4: CUDA 13.1 + MATLAB 2024a
set "CONFIG[5].NAME=CUDA_13.1_MATLAB_2024a"
set "CONFIG[5].CUDA_VERSION=13.1"
set "CONFIG[5].CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.1"
set "CONFIG[5].MATLAB_VERSION=R2024a"
set "CONFIG[5].MATLAB_PATH=C:\Program Files\MATLAB\R2024a"
set "CONFIG[5].CMAKE_MATLAB_VERSION=24.1"

REM ============================================================================
REM Build selection menu
REM ============================================================================

echo.
echo ============================================================================
echo EchoFrame Multi-Configuration Build Script
echo ============================================================================
echo.
echo Available configurations:
echo [0] CUDA 12.8 + MATLAB 2022a
echo [1] CUDA 12.9 + MATLAB 2022a
echo [2] CUDA 13.1 + MATLAB 2022a
echo [3] CUDA 12.8 + MATLAB 2024a
echo [4] CUDA 12.9 + MATLAB 2024a
echo [5] CUDA 13.1 + MATLAB 2024a
echo [6] Build ALL configurations
echo [7] Exit
echo.

set /p "BUILD_CHOICE=Select configuration (0-7): "

if "%BUILD_CHOICE%"=="7" goto end
if "%BUILD_CHOICE%"=="6" (
    set "START_IDX=0"
    set "END_IDX=5"
) else (
    set "START_IDX=%BUILD_CHOICE%"
    set "END_IDX=%BUILD_CHOICE%"
)

if %BUILD_CHOICE% LSS 0 (
    echo Invalid choice. Exiting.
    goto end
)

if %BUILD_CHOICE% GTR 7 (
    echo Invalid choice. Exiting.
    goto end
)

REM ============================================================================
REM Build loop
REM ============================================================================

for /l %%i in (%START_IDX%, 1, %END_IDX%) do (
    call :build_config %%i
)

goto end

REM ============================================================================
REM Build Configuration Subroutine
REM ============================================================================

:build_config
setlocal enabledelayedexpansion
set "CFG_IDX=%~1"

set "CONFIG_NAME=!CONFIG[%CFG_IDX%].NAME!"
set "CUDA_VERSION=!CONFIG[%CFG_IDX%].CUDA_VERSION!"
set "CUDA_PATH=!CONFIG[%CFG_IDX%].CUDA_PATH!"
set "MATLAB_VERSION=!CONFIG[%CFG_IDX%].MATLAB_VERSION!"
set "MATLAB_PATH=!CONFIG[%CFG_IDX%].MATLAB_PATH!"
set "CMAKE_MATLAB_VERSION=!CONFIG[%CFG_IDX%].CMAKE_MATLAB_VERSION!"

echo.
echo ============================================================================
echo Building Configuration: %CONFIG_NAME%
echo ============================================================================
echo CUDA Version: %CUDA_VERSION%
echo CUDA Path: %CUDA_PATH%
if not "!MATLAB_VERSION!"=="" (
    echo MATLAB Version: %MATLAB_VERSION%
    echo MATLAB Path: %MATLAB_PATH%
    echo MATLAB Version for CMake: !CMAKE_MATLAB_VERSION!
)
echo.

REM Create build directory
set "BUILD_DIR=%EF_BUILD_ROOT%\build_%CONFIG_NAME%"
set "BINARIES_DIR=%REPO_ROOT%\binaries"
if exist "!BUILD_DIR!" (
    echo Cleaning up existing build directory...
    rmdir /s /q "!BUILD_DIR!"
    echo Removed old build directory: !BUILD_DIR!
)
if not exist "!BINARIES_DIR!" (
    mkdir "!BINARIES_DIR!"
    echo Created binaries directory: !BINARIES_DIR!
)
mkdir "!BUILD_DIR!"
if not exist "!BINARIES_DIR!\build_%CONFIG_NAME%" (
    mkdir "!BINARIES_DIR!\build_%CONFIG_NAME%"
    echo Created binaries subdirectory: "!BINARIES_DIR!\build_%CONFIG_NAME%"
)


echo Created build directory: !BUILD_DIR!

REM The Visual Studio generator adds roughly 120 characters of nested
REM intermediate path under this directory, against a 260-character limit.
call :strlen BUILD_DIR_LEN "!BUILD_DIR!"
if !BUILD_DIR_LEN! GTR 130 (
    echo.
    echo WARNING: the build path is !BUILD_DIR_LEN! characters. The Visual Studio
    echo          generator may exceed the 260-character limit from here.
    echo          Set EF_BUILD_ROOT to something shorter, e.g. C:\efb, or enable
    echo          long paths, then run this again.
    echo.
)

REM Handle CUDA file renaming
call :manage_cuda_files "%CUDA_VERSION%"
if errorlevel 1 (
    echo ERROR: could not switch the CUDA integration for !CONFIG_NAME! - skipping.
    endlocal
    exit /b 1
)

REM Change to build directory
cd /d "!BUILD_DIR!"

REM Run CMake configuration
echo Configuring with CMake...

"%CMAKE_PATH%" -S "%REPO_ROOT%\echoframe\cpp\src" -B "!BUILD_DIR!" ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_TOOLCHAIN_FILE="%VCPKG_TOOLCHAIN%" ^
    -DVCPKG_TARGET_TRIPLET=%VCPKG_TRIPLET% ^
    -DCMAKE_PREFIX_PATH="%VCPKG_PREFIX%" ^
    -DMATLAB_VERSION="%CMAKE_MATLAB_VERSION%" ^
    -DEF_BUILD_CLI=ON ^
    -DEF_BUILD_MEX=ON ^
    -DEF_BUILD_PYTHON=ON ^
    -DPython_ROOT_DIR="%PYTHON_ROOT%" ^
    -DPython_EXECUTABLE="%PYTHON_EXE%" ^
    -DPython_FIND_STRATEGY=LOCATION

if errorlevel 1 (
    echo ERROR: CMake configuration failed for !CONFIG_NAME!
    endlocal
    exit /b 1
)

REM Build with CMake
echo Building with CMake...
"%CMAKE_PATH%" --build "!BUILD_DIR!" --config Release -j16

if errorlevel 1 (
    echo ERROR: CMake build failed for !CONFIG_NAME!
    endlocal
    exit /b 1
)

echo.
echo ✓ Successfully built: %CONFIG_NAME%
echo.

REM Copy Release artifacts to the binaries folder for this configuration
REM Package the Release artifacts as binaries\build_<CONFIG>\build.zip, matching
REM the published layout: the archive contains build\Release\<files>.
if exist "!BUILD_DIR!\Release" (
    set "ZIP_OUT=!BINARIES_DIR!\build_%CONFIG_NAME%\build.zip"
    echo Writing "!ZIP_OUT!"...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\build_scripts\pack_build.ps1" ^
        -ReleaseDir "!BUILD_DIR!\Release" -Out "!ZIP_OUT!"
    if errorlevel 1 (
        echo ERROR: packaging failed for !CONFIG_NAME!
        endlocal
        exit /b 1
    )
) else (
    echo No Release directory found at "!BUILD_DIR!\Release" - skipping packaging.
)

endlocal
goto :eof

REM ============================================================================
REM String Length Subroutine
REM ============================================================================

:strlen
setlocal enabledelayedexpansion
set "s=%~2#"
set "len=0"
for %%A in (4096 2048 1024 512 256 128 64 32 16 8 4 2 1) do (
    if "!s:~%%A!" NEQ "" (
        set /a len+=%%A
        set "s=!s:~%%A!"
    )
)
endlocal & set "%~1=%len%"
goto :eof

REM ============================================================================
REM CUDA File Management Subroutine
REM ============================================================================

:manage_cuda_files
setlocal enabledelayedexpansion
set "TARGET_CUDA_VERSION=%~1"

REM Convert version to file naming format (e.g., 12.9 -> CUDA 12.9)
REM Extract major and minor versions
for /f "tokens=1,2 delims=." %%a in ("%TARGET_CUDA_VERSION%") do (
    set "CUDA_MAJOR=%%a"
    set "CUDA_MINOR=%%b"
)

echo.
echo Managing CUDA build customizations files...

REM List of files to manage
set "CUDA_FILES[0]=CUDA %CUDA_MAJOR%.%CUDA_MINOR%.props"
set "CUDA_FILES[1]=CUDA %CUDA_MAJOR%.%CUDA_MINOR%.targets"
set "CUDA_FILES[2]=CUDA %CUDA_MAJOR%.%CUDA_MINOR%.xml"
set "CUDA_FILES[3]=CUDA %CUDA_MAJOR%.%CUDA_MINOR%.Version.props"

REM Restore all backed up files
echo Restoring previously managed CUDA files...
for %%f in ("%MSBUILD_CUDA_PATH%\*.bak") do (
    set "BAK_FILE=%%f"
    set "ORIG_FILE=!BAK_FILE:.bak=!"
    if exist "!BAK_FILE!" (
        move /Y "!BAK_FILE!" "!ORIG_FILE!" >nul 2>&1
        if errorlevel 1 (
            echo   ERROR: could not restore "!ORIG_FILE!"
            endlocal
            exit /b 1
        )
        echo   Restored: !ORIG_FILE!
    )
)

REM Rename all CUDA props and targets files that don't match our version
echo Backing up non-matching CUDA files...
for %%f in ("%MSBUILD_CUDA_PATH%\CUDA *.props") do (
    if not "%%f"=="%MSBUILD_CUDA_PATH%\CUDA %CUDA_MAJOR%.%CUDA_MINOR%.props" (
        if exist "%%f" (
            if not "%%f"=="%MSBUILD_CUDA_PATH%\CUDA %CUDA_MAJOR%.%CUDA_MINOR%.Version.props" (
                move /Y "%%f" "%%f.bak" >nul 2>&1
                if errorlevel 1 (
                    echo   ERROR: could not back up "%%f"
                    endlocal
                    exit /b 1
                )
                echo   Backed up: %%f
            ) else (
                echo  Keeping version file: %%f
            )
        )
    )
)

for %%f in ("%MSBUILD_CUDA_PATH%\CUDA *.targets") do (
    if not "%%f"=="%MSBUILD_CUDA_PATH%\CUDA %CUDA_MAJOR%.%CUDA_MINOR%.targets" (
        if exist "%%f" (
            move /Y "%%f" "%%f.bak" >nul 2>&1
            if errorlevel 1 (
                echo   ERROR: could not back up "%%f"
                endlocal
                exit /b 1
            )
            echo   Backed up: %%f
        )
    )
)


REM Verify the switch actually took effect. MSBuild picks the integration from
REM whatever is present here, so a leftover second version would be used
REM instead of the toolkit this configuration wants.
if not exist "%MSBUILD_CUDA_PATH%\CUDA %CUDA_MAJOR%.%CUDA_MINOR%.targets" (
    echo ERROR: CUDA %CUDA_MAJOR%.%CUDA_MINOR% integration is not active in:
    echo          %MSBUILD_CUDA_PATH%
    endlocal
    exit /b 1
)
for %%f in ("%MSBUILD_CUDA_PATH%\CUDA *.targets") do (
    if not "%%f"=="%MSBUILD_CUDA_PATH%\CUDA %CUDA_MAJOR%.%CUDA_MINOR%.targets" (
        echo ERROR: a second CUDA integration is still active: %%f
        echo        The build would not use CUDA %CUDA_MAJOR%.%CUDA_MINOR%.
        endlocal
        exit /b 1
    )
)

echo CUDA %CUDA_MAJOR%.%CUDA_MINOR% integration is active.
echo.

endlocal
goto :eof

REM ============================================================================
REM Cleanup and Exit
REM ============================================================================

:end
echo.
echo ============================================================================
echo Build script completed.
echo ============================================================================
echo.
pause
endlocal
