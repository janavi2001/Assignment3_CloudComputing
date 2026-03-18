# AWS Deployment - Step-by-Step Manual Guide

This guide walks through deploying HW3 to AWS manually using the AWS Console and CLI.

**Estimated time**: ~30 minutes (excluding RDS creation which takes 5-10 minutes)

---

## Step 1: Push Docker Image to ECR

### Option A: Using the Deployment Script (Recommended)
```bash
cd /Users/janavisrinivasan/Desktop/projects/CloudComputing/assignment3
bash deploy/aws/deploy.sh
```

This script automates all steps. Skip to the end to verify.

### Option B: Manual Steps via AWS CLI

```bash
# Set variables
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO_NAME="hw3-api"

# Create ECR repository
aws ecr create-repository \
  --repository-name "$ECR_REPO_NAME" \
  --region "$AWS_REGION"

# Login to Docker
aws ecr get-login-password --region "$AWS_REGION" | \
docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# Build and push image
cd /Users/janavisrinivasan/Desktop/projects/CloudComputing/assignment3
docker build -t "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:latest" .
docker push "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:latest"
```

**Result**: Image is now in ECR. Get the URI from the output or:
```bash
aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" --query 'repositories[0].repositoryUri' --output text
# Example: 123456789.dkr.ecr.us-east-1.amazonaws.com/hw3-api:latest
```

---

## Step 2: Create RDS Postgres Instance

### Via AWS CLI (Recommended)
```bash
aws rds create-db-instance \
  --db-instance-identifier hw3-postgres \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version "16.1" \
  --master-username postgres \
  --master-user-password "your-secure-password-here" \
  --db-name postgres \
  --allocated-storage 20 \
  --storage-type gp3 \
  --publicly-accessible true \
  --multi-az false \
  --region us-east-1
```

**⏳ Wait for RDS to be available** (~5-10 minutes):
```bash
aws rds wait db-instance-available \
  --db-instance-identifier hw3-postgres \
  --region us-east-1
```

**Get the RDS endpoint**:
```bash
aws rds describe-db-instances \
  --db-instance-identifier hw3-postgres \
  --region us-east-1 \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text
# Example: hw3-postgres.cxxxxxxxx.us-east-1.rds.amazonaws.com
```

### Via AWS Console
1. Go to [RDS Console](https://console.aws.amazon.com/rds)
2. Click "Create database"
3. Choose PostgreSQL, version 16.1
4. Instance class: `db.t3.micro`
5. Master username: `postgres`
6. Master password: Generate a strong password (⚠️ **Save it!**)
7. Database name: `postgres`
8. Storage: 20 GB, General Purpose (gp3)
9. **Multi-AZ**: ❌ No (to save costs)
10. **Publicly Accessible**: ✅ Yes
11. Create database
12. ⏳ Wait ~5-10 minutes for status "Available"

---

## Step 3: Store DB Password in SSM Parameter Store

### Via AWS CLI
```bash
aws ssm put-parameter \
  --name "/hw3-api/db-password" \
  --value "your-secure-password-here" \
  --type "SecureString" \
  --region us-east-1
```

This keeps the password secure and ECS can reference it without hardcoding.

### Via AWS Console
1. Go to [Systems Manager Parameters](https://console.aws.amazon.com/systems-manager/parameters)
2. Click "Create parameter"
3. Name: `/hw3-api/db-password`
4. Type: `SecureString`
5. Value: Paste your RDS master password
6. Click "Create parameter"

---

## Step 4: Create CloudWatch Log Group

### Via AWS CLI
```bash
aws logs create-log-group \
  --log-group-name /ecs/hw3-api \
  --region us-east-1
```

### Via AWS Console
1. Go to [CloudWatch Logs](https://console.aws.amazon.com/cloudwatch/home#logStream:)
2. Click "Create log group"
3. Name: `/ecs/hw3-api`
4. Create log group

---

## Step 5: Create ECS Cluster

### Via AWS CLI
```bash
aws ecs create-cluster \
  --cluster-name hw3-cluster \
  --region us-east-1
```

### Via AWS Console
1. Go to [ECS Console](https://console.aws.amazon.com/ecs)
2. Click "Create cluster"
3. Name: `hw3-cluster`
4. Infrastructure: Fargate
5. Create cluster

---

## Step 6: Create Security Groups

### Via AWS CLI
```bash
# Get default VPC ID
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region us-east-1)

# Create ALB security group
ALB_SG=$(aws ec2 create-security-group \
  --group-name hw3-alb-sg \
  --description "ALB security group" \
  --vpc-id "$VPC_ID" \
  --region us-east-1 \
  --output text \
  --query 'GroupId')

# Allow HTTP on ALB
aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region us-east-1

# Create ECS security group
ECS_SG=$(aws ec2 create-security-group \
  --group-name hw3-ecs-sg \
  --description "ECS security group" \
  --vpc-id "$VPC_ID" \
  --region us-east-1 \
  --output text \
  --query 'GroupId')

# Allow ECS port from ALB
aws ec2 authorize-security-group-ingress \
  --group-id "$ECS_SG" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG" \
  --region us-east-1
```

---

## Step 7: Create Application Load Balancer (ALB)

### Via AWS CLI
```bash
# Get default subnet
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=availabilityZone,Values=us-east-1a" --query 'Subnets[0].SubnetId' --output text --region us-east-1)

# Create ALB
ALB=$(aws elbv2 create-load-balancer \
  --name hw3-alb \
  --subnets "$SUBNET_ID" \
  --security-groups "$ALB_SG" \
  --scheme internet-facing \
  --region us-east-1 \
  --output text \
  --query 'LoadBalancers[0].LoadBalancerArn')

# Get ALB DNS
aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB" \
  --region us-east-1 \
  --query 'LoadBalancers[0].DNSName' \
  --output text
# Example: hw3-alb-1234567890.us-east-1.elb.amazonaws.com
```

### Via AWS Console
1. Go to [EC2 → Load Balancers](https://console.aws.amazon.com/ec2/v2/home#LoadBalancers:)
2. Click "Create load balancer"
3. Choose Application Load Balancer
4. Name: `hw3-alb`
5. Scheme: Internet-facing
6. Subnets: Select at least 2 (for high availability)
7. Security group: Select `hw3-alb-sg`
8. Create load balancer

---

## Step 8: Create Target Group

### Via AWS CLI
```bash
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region us-east-1)

TG=$(aws elbv2 create-target-group \
  --name hw3-api-tg \
  --protocol HTTP \
  --port 8080 \
  --vpc-id "$VPC_ID" \
  --health-check-protocol HTTP \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --matcher HttpCode=200 \
  --region us-east-1 \
  --output text \
  --query 'TargetGroups[0].TargetGroupArn')

echo "Target Group ARN: $TG"
```

### Via AWS Console
1. Go to [EC2 → Target Groups](https://console.aws.amazon.com/ec2/v2/home#TargetGroups:)
2. Click "Create target group"
3. Choose **HTTP** protocol, port **8080**
4. VPC: Select default VPC
5. Health check path: `/health`
6. Health check interval: 30 seconds
7. Healthy threshold: 2
8. Unhealthy threshold: 3
9. Matcher: 200
10. Create target group

---

## Step 9: Attach Target Group to ALB

### Via AWS Console
1. Go to [EC2 → Load Balancers](https://console.aws.amazon.com/ec2/v2/home#LoadBalancers:)
2. Select `hw3-alb`
3. Go to **Listeners and rules**
4. Click "Add listener"
5. Protocol: **HTTP**, Port: **80**
6. Default action: Forward to target group `hw3-api-tg`
7. Add listener

---

## Step 10: Create ECS Task Definition

### Via AWS CLI
```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RDS_ENDPOINT="hw3-postgres.cxxxxxxxx.us-east-1.rds.amazonaws.com"  # Replace with your RDS endpoint
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/hw3-api:latest"

cat > task-def.json << 'EOF'
{
  "family": "hw3-api-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::ACCOUNT_ID:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::ACCOUNT_ID:role/ecsTaskRole",
  "containerDefinitions": [
    {
      "name": "api",
      "image": "ECR_URI",
      "portMappings": [
        {
          "containerPort": 8080,
          "hostPort": 8080,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "DB_HOST",
          "value": "RDS_ENDPOINT"
        },
        {
          "name": "DB_PORT",
          "value": "5432"
        },
        {
          "name": "DB_USER",
          "value": "postgres"
        },
        {
          "name": "DB_NAME",
          "value": "postgres"
        }
      ],
      "secrets": [
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:ssm:us-east-1:ACCOUNT_ID:parameter/hw3-api/db-password"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/hw3-api",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:8080/health || exit 1"
        ],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
EOF

# Replace placeholders
sed -i "s|ACCOUNT_ID|$AWS_ACCOUNT_ID|g" task-def.json
sed -i "s|RDS_ENDPOINT|$RDS_ENDPOINT|g" task-def.json
sed -i "s|ECR_URI|$ECR_URI|g" task-def.json

# Register task definition
aws ecs register-task-definition \
  --cli-input-json file://task-def.json \
  --region us-east-1
```

### Via AWS Console
1. Go to [ECS → Task Definitions](https://console.aws.amazon.com/ecs/v2/task-definitions)
2. Click "Create new task definition"
3. Family: `hw3-api-task`
4. Launch type: Fargate
5. CPU: 256
6. Memory: 512
7. Container name: `api`
8. Image: Paste your ECR URI
9. Port: 8080
10. Environment variables:
    - `DB_HOST` = Your RDS endpoint
    - `DB_PORT` = 5432
    - `DB_USER` = postgres
    - `DB_NAME` = postgres
11. Secrets:
    - `DB_PASSWORD` = `arn:aws:ssm:us-east-1:ACCOUNT_ID:parameter/hw3-api/db-password`
12. Log group: `/ecs/hw3-api`
13. Create task definition

---

## Step 11: Create ECS Service

### Via AWS CLI
```bash
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region us-east-1)
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text --region us-east-1)
ECS_SG="sg-xxxxx"  # Replace with your ECS security group ID
TG_ARN="arn:aws:elasticloadbalancing:..."  # Replace with your target group ARN

aws ecs create-service \
  --cluster hw3-cluster \
  --service-name hw3-api-service \
  --task-definition hw3-api-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$ECS_SG],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=api,containerPort=8080" \
  --region us-east-1
```

### Via AWS Console
1. Go to [ECS → Services](https://console.aws.amazon.com/ecs/v2/clusters)
2. Select `hw3-cluster`
3. Click "Create"
4. Environment: **Launch type → Fargate**
5. Application type: Service
6. Task definition: `hw3-api-task`
7. Service name: `hw3-api-service`
8. Desired count: 1
9. Networking:
    - Subnets: Select at least 2
    - Public IP: **ENABLED**
    - Security group: `hw3-ecs-sg`
10. Load balancer:
    - Load balancer type: Application Load Balancer
    - Load balancer: `hw3-alb`
    - Target group: `hw3-api-tg`
    - Container: `api`
    - Port: `8080`
11. Create service

---

## Step 12: Verify Deployment

### Wait for Service to Stabilize
```bash
aws ecs wait services-stable \
  --cluster hw3-cluster \
  --services hw3-api-service \
  --region us-east-1
```

### Get ALB DNS
```bash
aws elbv2 describe-load-balancers \
  --names hw3-alb \
  --region us-east-1 \
  --query 'LoadBalancers[0].DNSName' \
  --output text
```

### Test Health Endpoint
```bash
# Replace with your ALB DNS
curl -i http://hw3-alb-1234567890.us-east-1.elb.amazonaws.com/health

# Expected response:
# HTTP/1.1 200 OK
# {"status":"ok","db":"connected"}
```

### Test Create Item
```bash
curl -X POST http://hw3-alb-1234567890.us-east-1.elb.amazonaws.com/items \
  -H "Content-Type: application/json" \
  -d '{"name":"aws-test","value":42}'

# Expected response:
# {"id":1,"name":"aws-test","value":42}
```

### Test Read Item
```bash
curl http://hw3-alb-1234567890.us-east-1.elb.amazonaws.com/items/1

# Expected response:
# {"id":1,"name":"aws-test","value":42}
```

### View CloudWatch Logs
```bash
aws logs tail /ecs/hw3-api --follow --region us-east-1
```

Or via AWS Console: [CloudWatch Logs](https://console.aws.amazon.com/cloudwatch/home#logStream:)

---

## Troubleshooting

### Task isn't starting
```bash
# Check task status
aws ecs describe-tasks \
  --cluster hw3-cluster \
  --tasks $(aws ecs list-tasks --cluster hw3-cluster --query 'taskArns[0]' --output text --region us-east-1) \
  --region us-east-1 \
  --query 'tasks[0]'
```

### Health check failing
```bash
# Check logs
aws logs tail /ecs/hw3-api --follow --region us-east-1

# Common issues:
# - DB_PASSWORD not accessible (check SSM permissions)
# - RDS endpoint not reachable (check security groups)
# - API crashed (check application logs)
```

### Database connection error
- Verify RDS is publicly accessible and in correct security group
- Check RDS password in SSM Parameter Store matches actual password
- Verify ECS task has IAM role that can read SSM parameters

---

## Cleanup (Delete Resources)

⚠️ **Do this after demo to avoid charges!**

```bash
# Delete ECS service
aws ecs delete-service \
  --cluster hw3-cluster \
  --service hw3-api-service \
  --force \
  --region us-east-1

# Delete ECS cluster
aws ecs delete-cluster \
  --cluster hw3-cluster \
  --region us-east-1

# Delete ALB
ALB_ARN=$(aws elbv2 describe-load-balancers --names hw3-alb --region us-east-1 --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region us-east-1

# Delete target group
TG_ARN=$(aws elbv2 describe-target-groups --names hw3-api-tg --region us-east-1 --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region us-east-1

# Delete RDS database
aws rds delete-db-instance \
  --db-instance-identifier hw3-postgres \
  --skip-final-snapshot \
  --region us-east-1

# Delete security groups (after ALB/RDS deleted)
aws ec2 delete-security-group --group-name hw3-alb-sg --region us-east-1
aws ec2 delete-security-group --group-name hw3-ecs-sg --region us-east-1

# Delete ECR repository
aws ecr delete-repository \
  --repository-name hw3-api \
  --force \
  --region us-east-1
```

---

## Summary

| Component | Status | Link |
|-----------|--------|------|
| Docker Image | ✅ Pushed to ECR | AWS Console → ECR |
| RDS Postgres | ✅ Running | AWS Console → RDS |
| ECS Cluster | ✅ Running | AWS Console → ECS |
| ALB | ✅ Running | AWS Console → EC2 → Load Balancers |
| Health Endpoint | ✅ 200 OK | `http://<ALB_DNS>/health` |
| CloudWatch Logs | ✅ Streaming | AWS Console → CloudWatch Logs |

**Public Endpoint**: `http://<ALB_DNS>/items`

🎉 Deployment complete!
