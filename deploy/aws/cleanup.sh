#!/bin/bash
# AWS Cleanup Script - Delete all HW3 resources
# Run this after your demo to avoid charges!

set -e

AWS_REGION="us-east-1"
ECS_CLUSTER_NAME="hw3-cluster"
ECS_SERVICE_NAME="hw3-api-service"
ALB_NAME="hw3-alb"
TG_NAME="hw3-api-tg"
RDS_DB_INSTANCE_ID="hw3-postgres"
ECR_REPO_NAME="hw3-api"

echo "🗑️  CLEANUP: Deleting all HW3 AWS resources..."
echo "⚠️  This will DELETE:"
echo "   - ECS service and cluster"
echo "   - RDS PostgreSQL database"
echo "   - Application Load Balancer"
echo "   - Target groups"
echo "   - Security groups"
echo "   - ECR repository"
echo ""
read -p "Are you sure? (type 'yes' to continue): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

# ============================================================================
# Delete ECS Service (this may take a minute)
# ============================================================================
echo "Deleting ECS service..."
aws ecs delete-service \
  --cluster "$ECS_CLUSTER_NAME" \
  --service "$ECS_SERVICE_NAME" \
  --force \
  --region "$AWS_REGION" 2>/dev/null || echo "  ⚠️  Service not found or already deleted"

# ============================================================================
# Delete ECS Cluster
# ============================================================================
echo "Deleting ECS cluster..."
aws ecs delete-cluster \
  --cluster "$ECS_CLUSTER_NAME" \
  --region "$AWS_REGION" 2>/dev/null || echo "  ⚠️  Cluster not found or already deleted"

# ============================================================================
# Delete RDS Database (this takes 5-10 minutes)
# ============================================================================
echo "Deleting RDS database (this may take a few minutes)..."
aws rds delete-db-instance \
  --db-instance-identifier "$RDS_DB_INSTANCE_ID" \
  --skip-final-snapshot \
  --region "$AWS_REGION" 2>/dev/null || echo "  ⚠️  Database not found or already deleted"

# ============================================================================
# Delete Application Load Balancer
# ============================================================================
echo "Deleting Application Load Balancer..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$AWS_REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null)

if [ ! -z "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
    aws elbv2 delete-load-balancer \
      --load-balancer-arn "$ALB_ARN" \
      --region "$AWS_REGION" 2>/dev/null && echo "  ✅ ALB deleted" || true
else
    echo "  ⚠️  ALB not found"
fi

# ============================================================================
# Delete Target Group
# ============================================================================
echo "Deleting target group..."
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$TG_NAME" \
  --region "$AWS_REGION" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null)

if [ ! -z "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    aws elbv2 delete-target-group \
      --target-group-arn "$TG_ARN" \
      --region "$AWS_REGION" 2>/dev/null && echo "  ✅ Target group deleted" || echo "  ⚠️  Target group in use, will be deleted with ALB"
else
    echo "  ⚠️  Target group not found"
fi

# ============================================================================
# Delete Security Groups (may need to wait a bit)
# ============================================================================
echo "Deleting security groups (waiting 30s for dependencies)..."
sleep 30

for sg_name in "hw3-alb-sg" "hw3-ecs-sg"; do
    SG_ID=$(aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=$sg_name" \
      --query 'SecurityGroups[0].GroupId' \
      --output text \
      --region "$AWS_REGION" 2>/dev/null)
    
    if [ ! -z "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
        aws ec2 delete-security-group \
          --group-id "$SG_ID" \
          --region "$AWS_REGION" 2>/dev/null && echo "  ✅ $sg_name deleted" || echo "  ⚠️  $sg_name still in use"
    fi
done

# ============================================================================
# Delete ECR Repository
# ============================================================================
echo "Deleting ECR repository..."
aws ecr delete-repository \
  --repository-name "$ECR_REPO_NAME" \
  --force \
  --region "$AWS_REGION" 2>/dev/null && echo "  ✅ ECR repository deleted" || echo "  ⚠️  ECR repository not found"

# ============================================================================
# Delete CloudWatch Log Group
# ============================================================================
echo "Deleting CloudWatch log group..."
aws logs delete-log-group \
  --log-group-name "/ecs/hw3-api" \
  --region "$AWS_REGION" 2>/dev/null && echo "  ✅ Log group deleted" || echo "  ⚠️  Log group not found"

# ============================================================================
# Delete SSM Parameter
# ============================================================================
echo "Deleting SSM parameter..."
aws ssm delete-parameter \
  --name "/hw3-api/db-password" \
  --region "$AWS_REGION" 2>/dev/null && echo "  ✅ SSM parameter deleted" || echo "  ⚠️  SSM parameter not found"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║            ✅ CLEANUP COMPLETE ✅                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "⏳ Note: RDS deletion may take 5-10 minutes in the background."
echo "   Check AWS console to verify all resources are deleted."
echo ""
echo "Cost check: Go to AWS Cost Explorer to verify no more charges."
