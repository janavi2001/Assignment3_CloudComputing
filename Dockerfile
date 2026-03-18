# syntax=docker/dockerfile:1.5

### Build stage
FROM python:3.12-slim as builder

# Install build deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install dependencies into a target directory so we can copy into runtime image
COPY requirements.txt ./
RUN python -m pip install --upgrade pip
RUN python -m pip install --prefix=/install -r requirements.txt

### Runtime stage
FROM python:3.12-slim

# Install utility tools used for healthchecks
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user and group
RUN groupadd --gid 1000 app && useradd --uid 1000 --gid app --shell /usr/sbin/nologin --create-home app

WORKDIR /app

# Copy only what is needed from builder
COPY --from=builder /install /usr/local
COPY . /app

# Ensure scripts are executable and files are owned by non-root user
RUN chmod +x /app/entrypoint.sh && chown -R app:app /app

# Ensure python bytecode is not written on mounted volumes in compose
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Run as non-root
USER app

# Default listen port
ENV PORT=8080

# Declare env vars for configuration (can be overridden in compose or ECS)
ENV DB_HOST="postgres"
ENV DB_PORT="5432"
ENV DB_USER="postgres"
ENV DB_PASSWORD="postgres"
ENV DB_NAME="postgres"

# Create an entrypoint that runs migrations before starting
ENTRYPOINT ["/app/entrypoint.sh"]

# Default command: start gunicorn
CMD ["gunicorn", "app.main:app", "--bind", "0.0.0.0:8080", "--workers", "2", "--worker-class", "gthread"]
