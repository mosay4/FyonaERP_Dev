@echo off
cd /d C:\Users\gomaro\Desktop\fyona_flutter_full\backend
echo ============================================
echo   FYONA ERP Backend
echo   Local:  http://127.0.0.1:8001
echo   LAN:    http://192.168.8.139:8001
echo   Docs:   http://127.0.0.1:8001/docs
echo   API:    http://127.0.0.1:8001/api/v1
echo ============================================
echo.
python -m uvicorn app.main:app --host 0.0.0.0 --port 8001
pause
