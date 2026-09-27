@echo off
setlocal EnableExtensions EnableDelayedExpansion

for %%I in ("%~dp0.") do set "SONARA_ROOT=%%~fI"
set "APP_DIR=%SONARA_ROOT%\apps\sonara"
set "PACKAGE_ID=dev.sonara.sonara"
set "SEEN_FILE=%TEMP%\sonara-adb-seen-%RANDOM%-%RANDOM%.txt"
set /a DEVICE_COUNT=0, INSTALLED_COUNT=0, SKIPPED_COUNT=0, FAILED_COUNT=0

if /I "%~1"=="--help" goto :help
if /I "%~1"=="debug" goto :select_debug
if /I "%~1"=="release" goto :select_release
if not "%~1"=="" goto :usage_error
set "INTERACTIVE_LAUNCH=1"

echo.
echo Sonara Android deployment
echo =========================
echo [1] Debug
echo [2] Release
echo [Q] Quit
echo.
choice /C 12Q /N /M "Choose a build: "
if errorlevel 3 exit /b 0
if errorlevel 2 goto :select_release

:select_debug
set "BUILD_MODE=debug"
set "APK_PATH=%APP_DIR%\build\app\outputs\flutter-apk\app-debug.apk"
goto :build

:select_release
set "BUILD_MODE=release"
set "APK_PATH=%APP_DIR%\build\app\outputs\flutter-apk\app-release.apk"
goto :build

:build
where adb.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: adb.exe was not found in PATH.
    echo Install Android platform-tools or add its directory to PATH.
    exit /b 1
)

where flutter.bat >nul 2>&1
if errorlevel 1 (
    echo ERROR: flutter.bat was not found in PATH.
    exit /b 1
)

if not exist "%APP_DIR%\pubspec.yaml" (
    echo ERROR: Sonara Flutter project was not found at "%APP_DIR%".
    exit /b 1
)

echo.
echo Building the latest %BUILD_MODE% APK...
if /I "%BUILD_MODE%"=="release" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SONARA_ROOT%\tools\packaging\build-release.ps1" -Platform Android
    set "BUILD_EXIT=!ERRORLEVEL!"
) else (
    pushd "%APP_DIR%"
    call flutter build apk --debug
    set "BUILD_EXIT=!ERRORLEVEL!"
    popd
)
if not "%BUILD_EXIT%"=="0" (
    echo ERROR: Flutter %BUILD_MODE% build failed.
    exit /b %BUILD_EXIT%
)
if not exist "%APK_PATH%" (
    echo ERROR: Build completed but the APK was not found:
    echo        "%APK_PATH%"
    exit /b 1
)

echo.
echo APK: "%APK_PATH%"
echo Existing Sonara installations will be uninstalled, which clears their local app data.
echo Scanning ADB connections...
echo.
break > "%SEEN_FILE%"

for /f "skip=1 tokens=1,2" %%A in ('adb devices 2^>nul') do (
    if not "%%A"=="" call :handle_connection "%%A" "%%B"
)

del /q "%SEEN_FILE%" >nul 2>&1

echo.
echo Deployment summary
echo ------------------
echo Physical devices found: %DEVICE_COUNT%
echo Installed successfully: %INSTALLED_COUNT%
echo Skipped:                %SKIPPED_COUNT%
echo Failed:                 %FAILED_COUNT%
echo.

set "RETURN_CODE=0"
if %DEVICE_COUNT% EQU 0 (
    echo No usable ADB devices were found. Check USB debugging or wireless debugging.
    set "RETURN_CODE=2"
)
if %FAILED_COUNT% GTR 0 set "RETURN_CODE=1"
if defined INTERACTIVE_LAUNCH pause
exit /b %RETURN_CODE%

:handle_connection
set "ADB_SERIAL=%~1"
set "ADB_STATE=%~2"

if /I not "%ADB_STATE%"=="device" (
    echo Skipping %ADB_SERIAL% because its state is %ADB_STATE%.
    exit /b 0
)

set "PHYSICAL_ID="
for /f "usebackq delims=" %%D in (`adb -s "%ADB_SERIAL%" shell getprop ro.serialno 2^>nul`) do (
    if not defined PHYSICAL_ID set "PHYSICAL_ID=%%D"
)
if not defined PHYSICAL_ID set "PHYSICAL_ID=%ADB_SERIAL%"

findstr /X /L /C:"%PHYSICAL_ID%" "%SEEN_FILE%" >nul 2>&1
if not errorlevel 1 (
    echo Skipping duplicate ADB connection %ADB_SERIAL% for physical device %PHYSICAL_ID%.
    exit /b 0
)
>> "%SEEN_FILE%" echo %PHYSICAL_ID%
set /a DEVICE_COUNT+=1

set "MODEL="
for /f "usebackq delims=" %%M in (`adb -s "%ADB_SERIAL%" shell getprop ro.product.model 2^>nul`) do (
    if not defined MODEL set "MODEL=%%M"
)
if not defined MODEL set "MODEL=Unknown Android device"

echo [%DEVICE_COUNT%] %MODEL%
echo     Serial: %ADB_SERIAL%

adb -s "%ADB_SERIAL%" shell pm path "%PACKAGE_ID%" 2>nul | findstr /B /L "package:" >nul
if not errorlevel 1 (
    echo     Existing Sonara installation found. Uninstalling it first...
    adb -s "%ADB_SERIAL%" uninstall "%PACKAGE_ID%" >nul
    if errorlevel 1 (
        echo     ERROR: Could not uninstall the existing app.
        set /a FAILED_COUNT+=1
        echo.
        exit /b 0
    )
    call :install_apk
    exit /b 0
)

echo     Sonara is not installed on this device.
choice /C IS /N /M "     [I]nstall or [S]kip? "
if errorlevel 2 (
    echo     Skipped.
    set /a SKIPPED_COUNT+=1
    echo.
    exit /b 0
)
call :install_apk
exit /b 0

:install_apk
echo     Installing %BUILD_MODE% build...
adb -s "%ADB_SERIAL%" install "%APK_PATH%"
if errorlevel 1 (
    echo     ERROR: Installation failed.
    set /a FAILED_COUNT+=1
) else (
    echo     Installed successfully.
    set /a INSTALLED_COUNT+=1
)
echo.
exit /b 0

:usage_error
echo ERROR: Unknown option "%~1".
echo.
:usage
echo Usage: %~nx0 [debug^|release]
echo.
echo With no argument, an interactive Debug/Release menu is shown.
exit /b 1

:help
echo Usage: %~nx0 [debug^|release]
echo.
echo With no argument, an interactive Debug/Release menu is shown.
exit /b 0
