@echo off
setlocal

cd /d "%~dp0"
echo === Workflow Query App - Windows Setup ===
echo.

set "NPM_GLOBAL_PREFIX=C:\npm"
set "PM2_CMD=%NPM_GLOBAL_PREFIX%\pm2.cmd"

echo Checking npm global prefix...
for /f "delims=" %%i in ('npm config get prefix') do set "CURRENT_PREFIX=%%i"
if /i not "%CURRENT_PREFIX%"=="%NPM_GLOBAL_PREFIX%" (
    echo Setting npm global prefix to %NPM_GLOBAL_PREFIX%...
    call npm config set prefix "%NPM_GLOBAL_PREFIX%"
    if errorlevel 1 (
        echo ERROR: Failed to set npm global prefix
        pause
        exit /b 1
    )
)

echo Checking prerequisites...
if not exist ".env.local" (
    echo ERROR: .env.local not found!
    echo.
    echo Please create a .env.local file in this folder with multi-database credentials:
    echo.
    echo   DB_NAMES=PROD,TEST
    echo   DB_PROD_LABEL=Production
    echo   DB_PROD_SERVER=your-sql-server
    echo   DB_PROD_DATABASE=your-database
    echo   DB_PROD_USER=your-username
    echo   DB_PROD_PASSWORD=your-password
    echo   DB_PROD_PORT=1433
    echo.
    echo See README.md for details.
    pause
    exit /b 1
)
echo   .env.local found.
echo.

:: Encrypt plaintext DB_*_PASSWORD entries with Windows DPAPI LocalMachine
:: LocalMachine scope is required for unattended PM2/service execution after reboot.
echo Checking for plaintext passwords in .env.local...
powershell -NonInteractive -ExecutionPolicy Bypass -Command ^
  "$f='.env.local';" ^
  "$lines=Get-Content $f;" ^
  "$changed=$false;" ^
  "$out=foreach($l in $lines){" ^
  "  if($l -match '^(DB_[^=]+_PASSWORD)=(.+)$' -and $l -notmatch '_ENCRYPTED'){" ^
  "    $key=$matches[1]; $pw=$matches[2];" ^
  "    Add-Type -AssemblyName System.Security;" ^
  "    $b=[System.Text.Encoding]::UTF8.GetBytes($pw);" ^
  "    $e=[System.Convert]::ToBase64String([System.Security.Cryptography.ProtectedData]::Protect($b,$null,[System.Security.Cryptography.DataProtectionScope]::LocalMachine));" ^
  "    $changed=$true;" ^
  "    Write-Host ('Encrypted: '+$key);" ^
  "    $key+'_ENCRYPTED='+$e" ^
  "  } else { $l }" ^
  "};" ^
  "if($changed){Set-Content $f $out;Write-Host 'Passwords encrypted and .env.local updated.'}" ^
  "else{Write-Host 'No plaintext passwords found — skipping encryption.'}"
if %errorlevel% neq 0 (echo ERROR: Password check/encryption failed & pause & exit /b 1)
echo.

echo Step 1: Installing dependencies...
call npm install
if %errorlevel% neq 0 (echo ERROR: npm install failed & pause & exit /b 1)

echo.
echo Step 2: Building the app...
call npm run build
if %errorlevel% neq 0 (echo ERROR: Build failed & pause & exit /b 1)

echo.
echo Step 3: Installing PM2 globally...
call npm install -g pm2
if %errorlevel% neq 0 (echo ERROR: PM2 install failed & pause & exit /b 1)

echo.
echo Step 4: Installing PM2 Windows startup manager...
call npm install -g pm2-windows-startup
if errorlevel 1 (echo ERROR: pm2-windows-startup install failed & pause & exit /b 1)

if not exist "%PM2_CMD%" (
    echo ERROR: PM2 executable not found at %PM2_CMD%
    echo Make sure %NPM_GLOBAL_PREFIX% is in the system PATH.
    pause
    exit /b 1
)

echo.
echo Step 5: Starting app with PM2...
call "%PM2_CMD%" start ecosystem.config.js
if errorlevel 1 (echo ERROR: PM2 start failed & pause & exit /b 1)

echo.
echo Step 6: Saving PM2 process list...
call "%PM2_CMD%" save
if errorlevel 1 (echo ERROR: PM2 save failed & pause & exit /b 1)

echo.
echo Step 7: Configuring PM2 to start on Windows boot...
call npm exec -- pm2-windows-startup install
if errorlevel 1 (echo ERROR: Startup config failed & pause & exit /b 1)

echo.
echo === Setup complete! ===
echo App is running at http://localhost:3000
echo It will restart automatically if it crashes and start on Windows boot.
echo.
echo Useful PM2 commands:
echo   pm2 status                         - check if app is running
echo   pm2 logs workflow-query-app        - view app logs
echo   pm2 restart workflow-query-app     - restart the app
echo   pm2 stop workflow-query-app        - stop the app
echo.
pause
