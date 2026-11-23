@echo off
REM FYONA dev runner: sets up adb reverse tunnel then launches the app
setlocal

echo [1/2] Setting up adb reverse tunnel (phone USB -> backend)...
C:\Users\ms522\Android\sdk\platform-tools\adb.exe reverse tcp:8001 tcp:8001
if errorlevel 1 (
  echo ERROR: adb reverse failed. Is the phone connected with USB debugging enabled?
  pause
  exit /b 1
)

echo [2/2] Launching Flutter app (API_BASE_URL=http://127.0.0.1:8001/api/v1)...
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8001/api/v1

endlocal
