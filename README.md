# HW3: Containers & Deployment - Cloud-Native API

**Status**: Local development complete. Ready for AWS deployment and load testing.

## Overview
Cloud-native containerized REST API backed by Postgres 16. Runs locally via Docker Compose with persistent data storage. Deploys to AWS using ECS Fargate + RDS + ALB with CloudWatch logging.

## 🚀 AWS Deployment (REQUIRED FOR SUBMISSION)

**Two deployment options**:

1. **Automated Script** (Recommended - 25 minutes):
   ```bash
   bash deploy/aws/deploy.sh
   ```
   Automates: ECR, RDS, ECS, ALB, security groups, CloudWatch, SSM secrets

2. **Manual Steps** (Step-by-step guide):
   - See [deploy/aws/MANUAL_DEPLOYMENT.md](deploy/aws/MANUAL_DEPLOYMENT.md)
   - AWS Console + CLI instructions
   - Troubleshooting included

**After deployment**:
- Test endpoints through ALB
- View CloudWatch logs
- Record demo video
- Run cleanup script: `bash deploy/aws/cleanup.sh`

**Full details**: [deploy/aws/README.md](deploy/aws/README.md)

## Verified Tests (Local)

### Health Endpoint (200 OK)
```bash
curl -i http://localhost:8080/health
# HTTP/1.1 200 OK
# {"db":"connected","status":"ok"}
```

### Data Persistence After API Restart
```bash
# Create item, restart container, data still exists
curl -X POST http://localhost:8080/items \
  -H "Content-Type: application/json" \
  -d '{"name":"alpha","value":123}'
# Response: {"id":1,"name":"alpha","value":123}

docker compose restart api
sleep 5
curl http://localhost:8080/items/1
# Still returns: {"id":1,"name":"alpha","value":123}
```

### Data Persistence After Postgres Restart
```bash
docker compose restart postgres
sleep 12
curl http://localhost:8080/items/1
# Still returns the item (data persists on volume)
```

## Quick Start

### Build & Run
```bash
docker compose up -d --build
```

### Test Endpoints
```bash
# Health check
curl -i http://localhost:8080/health

# POST create
curl -X POST http://localhost:8080/items \
  -H "Content-Type: application/json" \
  -d '{"name":"item1","value":42}'

# GET read
curl http://localhost:8080/items/<id>
```

## Configuration

### Local (Docker Compose)
Environment variables in `docker-compose.yml`:
- `DB_HOST=postgres` (service name)
- `DB_PORT=5432`
- `DB_USER=postgres`
- `DB_PASSWORD=postgres` (dev only)
- `DB_NAME=postgres`

### AWS (ECS Task Definition)
**Non-Secrets (env vars)**:
- `DB_HOST=<RDS_ENDPOINT>`
- `DB_PORT=5432`
- `DB_USER=postgres`
- `DB_NAME=postgres`

**Secrets** (from SSM Parameter Store or Secrets Manager):
- `DB_PASSWORD=arn:aws:ssm:REGION:ACCOUNT:parameter/my-app/db-password`

## Secrets Handling

**Rule**: Never commit real secrets to git.

- **Local**: Docker Compose env vars (git-ignored)
- **AWS**: SSM Parameter Store or AWS Secrets Manager injected as container env vars

Example ECS task snippet:
```json
"secrets": [
  {
    "name": "DB_PASSWORD",
    "valueFrom": "arn:aws:ssm:us-east-1:123456789:parameter/myapp/db-password"
  }
]
```

## Load Testing (k6)

Run on your machine (requires k6):
```bash
k6 run loadtest.js
```

## Load Test Results 

**Test Configuration**:
- **Virtual Users**: 10 concurrent
- **Duration**: 30 seconds
- **Total Iterations**: 300
- **Total Requests**: 600

**Performance Metrics**:
- **RPS** (Requests/sec): 19.6
- **p95 Latency**: **16.65 ms** ⚡
- **p90 Latency**: 14.58 ms
- **Average Latency**: 9.69 ms
- **Min Latency**: 2.02 ms
- **Max Latency**: 30.97 ms

**Reliability**:
- **Failed Requests**: 0%
- **Check Success Rate**: 100% (600/600 passed)
- **Threshold Results**: Both passed ✓
  - p95 < 500ms: **PASS** (16.65ms)
  - Failure rate < 1%: **PASS** (0%)

**Analysis**: 
- API performs excellently under load with sub-17ms p95 latency
- Zero errors across 600 requests
- Bottleneck: Minimal; likely dominated by network RTT in local testing
- Production ready for typical workloads

## AWS Deployment Checklist

### Pre-Deployment
- [ ] Docker image built and pushed to ECR
- [ ] DB password stored in SSM Parameter Store
- [ ] VPC/subnet/security group configured

### AWS Resources
- [ ] RDS Postgres instance (db.t3.micro, single-AZ)
- [ ] ECS cluster (Fargate, public subnet)
- [ ] AutoScaling group or ECS service (1 task)
- [ ] Application Load Balancer (public)
- [ ] Target group with health check `/health`
- [ ] CloudWatch log group `/ecs/hw3-api`

### Post-Deployment Verification
- [ ] ALB returns public DNS endpoint
- [ ] Health check: `curl -i http://<ALB_DNS>/health` → 200 OK
- [ ] Write data: `curl -X POST http://<ALB_DNS>/items ...`
- [ ] Read data: `curl http://<ALB_DNS>/items/<id>` → returns same record
- [ ] CloudWatch logs show HTTP requests
- [ ] Restart ECS task → data still persists in RDS

### Cleanup
- [ ] Delete ECS service
- [ ] Delete RDS instance
- [ ] Delete ALB, target group
- [ ] Delete ECR image (if desired)
- [ ] Verify cost ~$5-15 for the day

See `deploy/aws/README.md` for detailed steps.

## Architecture

### Local (Docker Compose)
```
Client:8080
    ↓
Flask API (gunicorn, 2 workers, non-root user)
    ↓
Postgres 16 (named volume, persistent)
```

### AWS (Target Deployment)
```
Client
    ↓
ALB (port 80, public, health check /health)
    ↓
ECS Fargate Service (port 8080, cloudwatch logs)
    ↓
RDS Postgres (multi-AZ optional, data store)
```

## Database Schema

**Table: `items`**
```sql
CREATE TABLE items (
  id INTEGER PRIMARY KEY,
  name VARCHAR(255) NOT NULL UNIQUE,
  value INTEGER NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);
CREATE INDEX ix_items_name ON items(name);
```

## Docker Image

**Multi-stage build**:
1. **Builder**: Installs build deps + pip packages
2. **Runtime**: Minimal image (~200MB)
   - Base: `python:3.12-slim` + `curl`
   - Non-root: `app:1000`
   - Healthcheck: curl `/health`

**Ports**: 8080 (API)

**Entrypoint**: Initializes DB tables before gunicorn starts

## Project Files

- `app/main.py` - Flask API + `/health` + `/items` routes
- `app/models.py` - SQLAlchemy ORM models
- `app/db.py` - Database connection (lazy engine init)
- `app/__init__.py` - App factory
- `entrypoint.sh` - Initializes DB tables on startup
- `Dockerfile` - Multi-stage, non-root user
- `docker-compose.yml` - Local dev environment
- `requirements.txt` - Python dependencies
- `loadtest.js` - k6 load test script
- `alembic.ini` - Alembic config (legacy, not used)
- `migrations/` - Migration templates (not used)
- `deploy/aws/` - ECS task definition + deployment guide
- `.env.example` - Environment variable template
- `.gitignore` - Excludes secrets + cache
