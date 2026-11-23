"""Check FastAPI loads correctly inside container."""

from app.main import app

print(app.title)
