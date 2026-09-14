@echo off
setlocal EnableExtensions

set "AAB_PATH="
set "VERSION_CODE="
set "VERSION_NAME="
set "KEYSTORE="
set "KEY_PASSWORD="
set "STORE_PASSWORD="
set "ALIAS="
set "OUTPUT_AAB="

set "JARSIGNER_EXE=C:\Program Files\Unity 2022.3.62f2\Editor\Data\PlaybackEngines\AndroidPlayer\OpenJDK\bin\jarsigner.exe"
set "SEVENZIP_EXE=C:\Program Files\7-Zip\7z.exe"

set "SCRIPT_DIR=%~dp0"
set "PATCHER_PS1=%SCRIPT_DIR%AabManifestPatcher.ps1"
set "ZIP_REPLACE_PS1=%SCRIPT_DIR%AabZipReplace.ps1"

:parse
if "%~1"=="" goto after_parse

if /I "%~1"=="-AabPath" set "AAB_PATH=%~2" & shift & shift & goto parse
if /I "%~1"=="-VersionCode" set "VERSION_CODE=%~2" & shift & shift & goto parse
if /I "%~1"=="-VersionName" set "VERSION_NAME=%~2" & shift & shift & goto parse
if /I "%~1"=="-Keystore" set "KEYSTORE=%~2" & shift & shift & goto parse
if /I "%~1"=="-KeyPassword" set "KEY_PASSWORD=%~2" & shift & shift & goto parse
if /I "%~1"=="-StorePassword" set "STORE_PASSWORD=%~2" & shift & shift & goto parse
if /I "%~1"=="-Alias" set "ALIAS=%~2" & shift & shift & goto parse
if /I "%~1"=="-OutputAab" set "OUTPUT_AAB=%~2" & shift & shift & goto parse
if /I "%~1"=="-JarsignerExe" set "JARSIGNER_EXE=%~2" & shift & shift & goto parse
if /I "%~1"=="-SevenZipExe" set "SEVENZIP_EXE=%~2" & shift & shift & goto parse

echo [ERROR] Unknown argument: %~1
exit /b 1

:after_parse

if "%AAB_PATH%"=="" echo [ERROR] Missing -AabPath & exit /b 1
if "%VERSION_CODE%"=="" echo [ERROR] Missing -VersionCode & exit /b 1
if "%KEYSTORE%"=="" echo [ERROR] Missing -Keystore & exit /b 1
if "%KEY_PASSWORD%"=="" echo [ERROR] Missing -KeyPassword & exit /b 1
if "%ALIAS%"=="" echo [ERROR] Missing -Alias & exit /b 1

if "%STORE_PASSWORD%"=="" set "STORE_PASSWORD=%KEY_PASSWORD%"

if not exist "%AAB_PATH%" echo [ERROR] AAB not found: %AAB_PATH% & exit /b 1
if not exist "%KEYSTORE%" echo [ERROR] Keystore not found: %KEYSTORE% & exit /b 1
if not exist "%JARSIGNER_EXE%" echo [ERROR] jarsigner.exe not found: %JARSIGNER_EXE% & exit /b 1
if not exist "%SEVENZIP_EXE%" echo [ERROR] 7z.exe not found: %SEVENZIP_EXE% & exit /b 1
if not exist "%PATCHER_PS1%" echo [ERROR] Patcher not found: %PATCHER_PS1% & exit /b 1
if not exist "%ZIP_REPLACE_PS1%" echo [ERROR] Zip replace script not found: %ZIP_REPLACE_PS1% & exit /b 1

for %%I in ("%AAB_PATH%") do (
    set "AAB_DIR=%%~dpI"
    set "AAB_NAME=%%~nI"
)

if "%OUTPUT_AAB%"=="" (
    set "OUTPUT_AAB=%AAB_DIR%%AAB_NAME%-v%VERSION_CODE%-signed.aab"
)

if /I "%AAB_PATH%"=="%OUTPUT_AAB%" (
    echo [ERROR] OutputAab must not be same as AabPath.
    exit /b 1
)

set "TEMP_DIR=%TEMP%\aab_edit_%RANDOM%%RANDOM%%RANDOM%"

mkdir "%TEMP_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to create temp dir.
    exit /b 1
)

echo [INFO] Extracting manifest only...
"%SEVENZIP_EXE%" x "%AAB_PATH%" "base\manifest\AndroidManifest.xml" "-o%TEMP_DIR%" -y
if errorlevel 1 (
    "%SEVENZIP_EXE%" x "%AAB_PATH%" "base/manifest/AndroidManifest.xml" "-o%TEMP_DIR%" -y
    if errorlevel 1 goto fail
)

set "MANIFEST_PATH=%TEMP_DIR%\base\manifest\AndroidManifest.xml"

if not exist "%MANIFEST_PATH%" (
    echo [ERROR] Manifest not found after extraction: %MANIFEST_PATH%
    goto fail
)

echo [INFO] Patching manifest...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PATCHER_PS1%" ^
  -ManifestPath "%MANIFEST_PATH%" ^
  -VersionCode "%VERSION_CODE%" ^
  -VersionName "%VERSION_NAME%"

if errorlevel 1 goto fail

echo [INFO] Rewriting output AAB with patched manifest...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ZIP_REPLACE_PS1%" ^
  -SourceAab "%AAB_PATH%" ^
  -DestAab "%OUTPUT_AAB%" ^
  -ManifestPath "%MANIFEST_PATH%" ^
  -ManifestEntry "base/manifest/AndroidManifest.xml"
if errorlevel 1 goto fail

echo [INFO] Checking manifest entries in output AAB...
"%SEVENZIP_EXE%" l "%OUTPUT_AAB%" | findstr /i "AndroidManifest.xml"

echo [INFO] Signing AAB...
"%JARSIGNER_EXE%" -verbose -keystore "%KEYSTORE%" -storepass "%STORE_PASSWORD%" -keypass "%KEY_PASSWORD%" -sigalg SHA256withRSA -digestalg SHA-256 "%OUTPUT_AAB%" "%ALIAS%"
if errorlevel 1 goto fail

echo [INFO] Verifying signature...
"%JARSIGNER_EXE%" -verify "%OUTPUT_AAB%"
if errorlevel 1 goto fail

echo [INFO] Dumping output AAB version info...
java -jar "F:\com.haifura.cyoujp.gp\bundletool-all-1.18.1.jar" dump manifest --bundle "%OUTPUT_AAB%" --module base | findstr /i "package versionCode versionName"
if errorlevel 1 (
    echo [WARN] Failed to dump version info from output AAB.
)

echo.
echo [SUCCESS] Done: %OUTPUT_AAB%
goto cleanup_success

:fail
echo.
echo [FAILED]
goto cleanup_fail

:cleanup_success
if exist "%TEMP_DIR%" rmdir /S /Q "%TEMP_DIR%"
if exist "%OUTPUT_AAB%.rewriting" del /F /Q "%OUTPUT_AAB%.rewriting"
exit /b 0

:cleanup_fail
if exist "%TEMP_DIR%" rmdir /S /Q "%TEMP_DIR%"
if exist "%OUTPUT_AAB%.rewriting" del /F /Q "%OUTPUT_AAB%.rewriting"
exit /b 1
