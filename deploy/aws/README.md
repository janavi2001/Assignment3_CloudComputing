# AWS Deployment Guide - HW3 (ECS Fargate + RDS + ALB)

**Choose one approach below:**

## 🚀 Option 1: Automated Deployment (Recommended)

Run the deployment script that automates all AWS setup:

```bash
cd /Users/janavisrinivasan/Desktop/projects/CloudComputing/assignment3
bash deploy/aws/deploy.sh
```

This script will:
✅ Push Docker image to ECR
✅ Create RDS Postgres instance
✅ Set up security groups
✅ Create Application Load Balancer
✅ Create target group with health check
✅ Create ECS cluster + service
✅ Configure CloudWatch logging
✅ Store DB password in SSM Parameter Store
✅ Output ALB URL + test commands

**Time**: ~25 minutes (includes RDS creation)

**Prerequisites**:
- AWS CLI v2 installed and configured
- Docker installed and running
- `jq` installed (for JSON parsing)

```bash
# Check prerequisites
aws sts get-caller-identity
docker --version
jq --version
```

---

## 📖 Option 2: Step-by-Step Manual Guide

See [MANUAL_DEPLOYMENT.md](./MANUAL_DEPLOYMENT.md) for detailed console + CLI steps.

This guide covers:
- Each deployment step with explanations
- AWS Console instructions with screenshots
- AWS CLI commands (copy-paste ready)
- Troubleshooting section
- Cleanup commands

---

## 🧪 Testing Your Deployment

Once deployment completes, test the endpoints:

```bash
# Replace with your ALB DNS name
ALB_URL="hw3-alb-1234567890.us-east-1.elb.amazonaws.com"

# 1. Health check (should return 200 OK)
curl -i http://$ALB_URL/health
# Expected: {"status":"ok","db":"connected"}

# 2. Create item
curl -X POST http://$ALB_URL/items \
  -H "Content-Type: application/json" \
  -d '{"name":"aws-test","value":42}'
# Expected: {"id":1,"name":"aws-test","value":42}

# 3. Read item
curl http://$ALB_URL/items/1
# Expected: {"id":1,"name":"aws-test","value":42}

# 4. View CloudWatch logs
aws logs tail /ecs/hw3-api --follow --region us-east-1
```

---

## 📋 Architecture

### What Gets Created

| Component | Details | Cost |
|-----------|---------|------|
| **ECR** | Docker image repository | $0.07/GB storage |
| **RDS Postgres** | db.t3.micro, 20GB gp3, single-AZ | ~$0.015/hr |
| **ECS Fargate** | CPU: 256, Memory: 512MB | ~$0.04/hr |
| **ALB** | Application Load Balancer | ~$0.023/hr |
| **CloudWatch** | Logs | ~$0.50/GB ingested |

**Estimated total daily cost**: ~$5-15 (if cleaned up same day)

### Network Diagram

```
Internet
   ↓
ALB (port 80) — Application Load Balancer
   ↓
Health Check ← Target Group (/health must return 200)
   ↓
ECS Fargate (port 8080) — Running HW3 API container
   ↓
RDS Postgres — Database
```

---

## 🔐 Secrets Management

**Best Practice**: Never hardcode passwords in container images or source code.

### Setup
1. DB password stored in **AWS SSM Parameter Store** (encrypted)
2. ECS task has IAM role to read SSM parameters
3. Container receives DB password as env var from AWS

### How It Works
```
1. Launch ECS task
2. Task execution role reads from SSM: arn:aws:ssm:us-east-1:ACCOUNT:parameter/hw3-api/db-password
3. AWS injects DB_PASSWORD env var into container
4. Application reads DB_PASSWORD from environment
5. Connects to RDS using DB_PASSWORD
```

---

## ⚠️ Common Issues

### Health Check Failing
```bash
# Check ECS task logs
aws logs tail /ecs/hw3-api --follow

# Common causes:
# - DB_PASSWORD env var not set (SSM permissions issue)
# - RDS endpoint unreachable (security group issue)
# - Container crashed (check application logs)
```

### Can't Connect to RDS
```bash
# Verify RDS is publicly accessible
aws rds describe-db-instances \
  --db-instance-identifier hw3-postgres \
  --query 'DBInstances[0].PubliclyAccessible'

# Check security groups allow ECS → RDS
aws ec2 describe-security-groups --group-names hw3-ecs-sg
```

### ALB Returning 502 Bad Gateway
```bash
# Wait longer (tasks take time to start)
sleep 30

# Check target health
aws elbv2 describe-target-health \
  --target-group-arn <TARGET_GROUP_ARN>
```

---

## 🗑️ Cleanup (Important!)

After your demo, **delete AWS resources** to avoid charges:

```bash
# Delete everything in one shot
bash deploy/aws/cleanup.sh

# Or manually:
aws ecs delete-service --cluster hw3-cluster --service hw3-api-service --force --region us-east-1
aws ecs delete-cluster --cluster hw3-cluster --region us-east-1
aws rds delete-db-instance --db-instance-identifier hw3-postgres --skip-final-snapshot --region us-east-1
aws elbv2 delete-load-balancer --load-balancer-arn <ALB_ARN> --region us-east-1
aws ec2 delete-security-group --group-name hw3-alb-sg --region us-east-1
aws ec2 delete-security-group --group-name hw3-ecs-sg --region us-east-1
aws ecr delete-repository --repository-name hw3-api --force --region us-east-1
```

---

## 📚 Reference

- [AWS ECS Documentation](https://docs.aws.amazon.com/ecs/)
- [AWS RDS Documentation](https://docs.aws.amazon.com/rds/)
- [AWS ALB Documentation](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/)
- [AWS SSM Parameter Store](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html)

---

**Next Step**: Start with Option 1 (automated script) or follow Option 2 (manual steps).

Good luck! 🚀