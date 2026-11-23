# ── Build stage ──
FROM python:3.12-slim AS builder

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# ── Runtime stage ──
FROM python:3.12-slim

ARG BUILD_DATE=""
ARG GIT_COMMIT=""
ARG APP_VERSION="1.0.0"

LABEL org.opencontainers.image.title="FYONA ERP API" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.description="FYONA ERP Backend API" \
      org.opencontainers.image.source="https://github.com/ms522-ms/fyona_flutter"

# Install runtime utilities (curl for health checks, gnupg for decryption)
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy from builder stage (non-root install)
COPY --from=builder /root/.local /root/.local

# Make the user-local site-packages readable by the non-root runtime user.
RUN chmod a+x /root && chmod -R a+rX /root/.local

# Resolve packages installed via `pip install --user` for the runtime user.
ENV PYTHONPATH="/root/.local/lib/python3.12/site-packages"

# Copy application
COPY . .

# Create non-root user
RUN addgroup --system --gid 1001 fyona && \
    adduser --system --uid 1001 --gid 1001 fyona && \
    chown -R fyona:fyona /app

# Make the user-local bin available
ENV PATH="/root/.local/bin:/usr/local/bin:${PATH}"

# Uploaded-content root
RUN mkdir -p /app/app/uploads && chown fyona:fyona /app/app/uploads

USER fyona

EXPOSE 8000

# ── Docker Healthcheck: uses readiness endpoint (checks DB + Redis) ──
# Separates Liveness (process alive) from Readiness (deps available)
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -sf http://127.0.0.1:8000/api/v1/health/ready || exit 1

# Production-optimized uvicorn
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--workers", "2", \
     "--loop", "uvloop", \
     "--http", "httptools", \
     "--proxy-headers", \
     "--forwarded-allow-ips", "127.0.0.1"]
