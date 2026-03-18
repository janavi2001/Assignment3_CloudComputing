#!/bin/bash
# AWS Deployment Script - HW3 Cloud-Native API
# Tested on macOS/Linux with AWS CLI v2
# Prerequisites: AWS CLI configured, Docker installed, jq installed

set -e

# ============================================================================
# CONFIGURATION - EDIT THESE
# ============================================================================

AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REPO_NAME="hw3-api"
APP_NAME="hw3-api"
CONTAINER_PORT=8080
APP_MEMORY=512
APP_CPU=256

# RDS Configuration
RDS_DB_INSTANCE_ID="hw3-postgres"
RDS_DB_NAME="postgres"
RDS_USER="postgres"
RDS_DB_PASSWORD="$(openssl rand -base64 16)"  # Random password, save this!
RDS_INSTANCE_CLASS="db.t3.micro"

# ECS Configuration
ECS_CLUSTER_NAME="hw3-cluster"
ECS_SERVICE_NAME="hw3-api-service"
TASK_FAMILY="hw3-api-task"
LOG_GROUP="/ecs/hw3-api"

# ============================================================================
# STEP 1: BUILD & PUSH TO ECR
# ============================================================================

echo "📦 Step 1: Building and pushing Docker image to ECR..."

# Create ECR repository
(aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" > /dev/null 2>&1) || \
aws ecr create-repository \
  --repository-name "$ECR_REPO_NAME" \
  --region "$AWS_REGION" \
  --output text \
  --query 'repository.repositoryUri'

ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:latest"

# Login to ECR
aws ecr get-login-password --region "$AWS_REGION" | \
docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# Build and push
docker build -t "$ECR_URI" .
docker push "$ECR_URI"

echo "✅ Image pushed to: $ECR_URI"

# ============================================================================
# STEP 2: CREATE RDS POSTGRES INSTANCE
# ============================================================================

echo "📦 Step 2: Creating RDS Postgres instance..."

# Check if already exists
if aws rds describe-db-instances --db-instance-identifier "$RDS_DB_INSTANCE_ID" --region "$AWS_REGION" > /dev/null 2>&1; then
    echo "⚠️  RDS instance already exists"
else
    aws rds create-db-instance \
      --db-instance-identifier "$RDS_DB_INSTANCE_ID" \
      --db-instance-class "$RDS_INSTANCE_CLASS" \
      --engine postgres \
      --engine-version "16.1" \
      --master-username "$RDS_USER" \
      --master-user-password "$RDS_DB_PASSWORD" \
      --db-name "$RDS_DB_NAME" \
      --allocated-storage 20 \
      --storage-type gp3 \
      --publicly-accessible true \
      --multi-az false \
      --region "$AWS_REGION" \
      --no-enable-iam-database-authentication
    
    echo "⏳ Waiting for RDS to be available (this takes ~5-10 minutes)..."
    aws rds wait db-instance-available \
      --db-instance-identifier "$RDS_DB_INSTANCE_ID" \
      --region "$AWS_REGION"
fi

# Get RDS endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_DB_INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

echo "✅ RDS endpoint: $RDS_ENDPOINT"
echo "⚠️  SAVE DB PASSWORD: $RDS_DB_PASSWORD"

# ============================================================================
# STEP 3: STORE DB PASSWORD IN SSM PARAMETER STORE
# ============================================================================

echo "📦 Step 3: Storing DB password in SSM Parameter Store..."

aws ssm put-parameter \
  --name "/hw3-api/db-password" \
  --value "$RDS_DB_PASSWORD" \
  --type "SecureString" \
  --region "$AWS_REGION" \
  --overwrite

echo "✅ DB password stored in SSM"

# ============================================================================
# STEP 4: CREATE CLOUDWATCH LOG GROUP
# ============================================================================

echo "📦 Step 4: Creating CloudWatch log group..."

(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$AWS_REGION" | grep -q "$LOG_GROUP") || \
aws logs create-log-group \
  --log-group-name "$LOG_GROUP" \
  --region "$AWS_REGION"

echo "✅ Log group created: $LOG_GROUP"

# ============================================================================
# STEP 5: CREATE ECS CLUSTER
# ============================================================================

echo "📦 Step 5: Creating ECS cluster..."

(aws ecs describe-clusters --clusters "$ECS_CLUSTER_NAME" --region "$AWS_REGION" | grep -q "$ECS_CLUSTER_NAME") || \
aws ecs create-cluster \
  --cluster-name "$ECS_CLUSTER_NAME" \
  --region "$AWS_REGION"

echo "✅ ECS cluster created: $ECS_CLUSTER_NAME"

# ============================================================================
# STEP 6: CREATE VPC & SECURITY GROUP (if not exists)
# ============================================================================

echo "📦 Step 6: Setting up VPC and security group..."

# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text \
  --region "$AWS_REGION")

# Get public subnet
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[0].SubnetId' \
  --output text \
  --region "$AWS_REGION")

# Create security group for ALB
ALB_SG=$(aws ec2 create-security-group \
  --group-name "hw3-alb-sg" \
  --description "Security group for HW3 ALB" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION" \
  --output text \
  --query 'GroupId' 2>/dev/null || \
  aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=hw3-alb-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "$AWS_REGION")

# Create security group for ECS
ECS_SG=$(aws ec2 create-security-group \
  --group-name "hw3-ecs-sg" \
  --description "Security group for HW3 ECS" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION" \
  --output text \
  --query 'GroupId' 2>/dev/null || \
  aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=hw3-ecs-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "$AWS_REGION")

# Allow ALB to HTTP
aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region "$AWS_REGION" 2>/dev/null || true

# Allow ECS to receive from ALB
aws ec2 authorize-security-group-ingress \
  --group-id "$ECS_SG" \
  --protocol tcp \
  --port "$CONTAINER_PORT" \
  --source-group "$ALB_SG" \
  --region "$AWS_REGION" 2>/dev/null || true

echo "✅ Security groups configured"
echo "   ALB SG: $ALB_SG"
echo "   ECS SG: $ECS_SG"

# ============================================================================
# STEP 7: CREATE APPLICATION LOAD BALANCER
# ============================================================================

echo "📦 Step 7: Creating Application Load Balancer..."

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "hw3-alb" \
  --subnets "$SUBNET_ID" $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[1:2].SubnetId' --output text --region "$AWS_REGION" 2>/dev/null || echo "") \
  --security-groups "$ALB_SG" \
  --scheme internet-facing \
  --type application \
  --region "$AWS_REGION" \
  --output text \
  --query 'LoadBalancers[0].LoadBalancerArn' 2>/dev/null || \
  aws elbv2 describe-load-balancers \
  --names "hw3-alb" \
  --region "$AWS_REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

echo "✅ ALB created: $ALB_ARN"

# Get ALB DNS
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

echo "✅ ALB DNS: http://$ALB_DNS"

# ============================================================================
# STEP 8: CREATE TARGET GROUP
# ============================================================================

echo "📦 Step 8: Creating target group..."

TG_ARN=$(aws elbv2 create-target-group \
  --name "hw3-api-tg" \
  --protocol HTTP \
  --port "$CONTAINER_PORT" \
  --vpc-id "$VPC_ID" \
  --health-check-protocol HTTP \
  --health-check-path "/health" \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --matcher "HttpCode=200" \
  --region "$AWS_REGION" \
  --output text \
  --query 'TargetGroups[0].TargetGroupArn' 2>/dev/null || \
  aws elbv2 describe-target-groups \
  --names "hw3-api-tg" \
  --region "$AWS_REGION" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

echo "✅ Target group created: $TG_ARN"

# ============================================================================
# STEP 9: CREATE ALB LISTENER
# ============================================================================

echo "📦 Step 9: Creating ALB listener..."

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --region "$AWS_REGION" \
  --output text 2>/dev/null || true

echo "✅ ALB listener configured"

# ============================================================================
# STEP 10: CREATE ECS TASK DEFINITION
# ============================================================================

echo "📦 Step 10: Creating ECS task definition..."

# Create task definition JSON
cat > /tmp/task-def.json << EOF
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "$APP_CPU",
  "memory": "$APP_MEMORY",
  "executionRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskRole",
  "containerDefinitions": [
    {
      "name": "api",
      "image": "$ECR_URI",
      "portMappings": [
        {
          "containerPort": $CONTAINER_PORT,
          "hostPort": $CONTAINER_PORT,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "DB_HOST",
          "value": "$RDS_ENDPOINT"
        },
        {
          "name": "DB_PORT",
          "value": "5432"
        },
        {
          "name": "DB_USER",
          "value": "$RDS_USER"
        },
        {
          "name": "DB_NAME",
          "value": "$RDS_DB_NAME"
        }
      ],
      "secrets": [
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:ssm:$AWS_REGION:$AWS_ACCOUNT_ID:parameter/hw3-api/db-password"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$LOG_GROUP",
          "awslogs-region": "$AWS_REGION",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:$CONTAINER_PORT/health || exit 1"
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

aws ecs register-task-definition \
  --cli-input-json file:///tmp/task-def.json \
  --region "$AWS_REGION" \
  --output text > /dev/null

echo "✅ Task definition registered: $TASK_FAMILY"

# ============================================================================
# STEP 11: CREATE ECS SERVICE
# ============================================================================

echo "📦 Step 11: Creating ECS service..."

aws ecs create-service \
  --cluster "$ECS_CLUSTER_NAME" \
  --service-name "$ECS_SERVICE_NAME" \
  --task-definition "$TASK_FAMILY" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$ECS_SG],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=api,containerPort=$CONTAINER_PORT" \
  --region "$AWS_REGION" \
  --output text 2>/dev/null || true

echo "✅ ECS service created"

echo "⏳ Waiting for service to stabilize (this takes ~2-3 minutes)..."
sleep 60

# ============================================================================
# STEP 12: VERIFY DEPLOYMENT
# ============================================================================

echo "📦 Step 12: Verifying deployment..."

# Wait for tasks to be running
aws ecs wait services-stable \
  --cluster "$ECS_CLUSTER_NAME" \
  --services "$ECS_SERVICE_NAME" \
  --region "$AWS_REGION" || echo "⚠️  Service may take longer to stabilize"

echo "✅ ECS service is running"

# Test health endpoint
echo "🧪 Testing health endpoint..."
sleep 10

for i in {1..5}; do
    if curl -s "http://$ALB_DNS/health" | grep -q "ok"; then
        echo "✅ Health check PASSED"
        break
    else
        echo "⏳ Attempt $i - health check not ready, retrying..."
        sleep 10
    fi
done

# ============================================================================
# OUTPUT SUMMARY
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║         🎉 DEPLOYMENT COMPLETE 🎉                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "📋 Deployment Summary:"
echo "  Region: $AWS_REGION"
echo "  ECR URI: $ECR_URI"
echo "  RDS Endpoint: $RDS_ENDPOINT"
echo "  RDS Password: $RDS_DB_PASSWORD (⚠️  SAVE THIS!)"
echo "  ECS Cluster: $ECS_CLUSTER_NAME"
echo "  ECS Service: $ECS_SERVICE_NAME"
echo "  ALB DNS: http://$ALB_DNS"
echo "  CloudWatch Logs: $LOG_GROUP"
echo ""
echo "🧪 Test Commands:"
echo "  # Health check"
echo "  curl http://$ALB_DNS/health"
echo ""
echo "  # Create item"
echo "  curl -X POST http://$ALB_DNS/items \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"name\":\"test\",\"value\":42}'"
echo ""
echo "  # Read item"
echo "  curl http://$ALB_DNS/items/1"
echo ""
echo "🔗 AWS Console Links:"
echo "  AWS Console: https://console.aws.amazon.com/"
echo "  ECS: https://console.aws.amazon.com/ecs/v2/clusters/$ECS_CLUSTER_NAME/services"
echo "  RDS: https://console.aws.amazon.com/rds/home/databases/$RDS_DB_INSTANCE_ID"
echo "  CloudWatch: https://console.aws.amazon.com/cloudwatch/home#logStream:group=$LOG_GROUP"
echo ""
echo "🗑️  To clean up, run:"
echo "  aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service $ECS_SERVICE_NAME --force --region $AWS_REGION"
echo "  aws ecs delete-cluster --cluster $ECS_CLUSTER_NAME --region $AWS_REGION"
echo "  aws rds delete-db-instance --db-instance-identifier $RDS_DB_INSTANCE_ID --skip-final-snapshot --region $AWS_REGION"
echo "  aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN --region $AWS_REGION"
echo ""
