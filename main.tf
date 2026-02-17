terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.region
}

####################################################
# Variables (defaults below can be overridden)
####################################################
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "ha-ecs-cluster"
}

variable "app_image" {
  type    = string
  default = "sabair0509/hiring-app:works"
}

variable "desired_count" {
  type    = number
  default = 6
}

variable "container_port" {
  type    = number
  default = 80
}

####################################################
# VPC + subnets (3 AZs)
####################################################
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "${var.cluster_name}-vpc" }
}

data "aws_availability_zones" "available" {}

# create 3 public subnets (one per AZ)
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(aws_vpc.this.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "${var.cluster_name}-public-${count.index}" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.cluster_name}-public-rt" }
}

resource "aws_route_table_association" "assoc" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

####################################################
# Security Groups
####################################################
# ALB SG: allow HTTP from anywhere
resource "aws_security_group" "alb_sg" {
  name        = "${var.cluster_name}-alb-sg"
  description = "Allow HTTP"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-alb-sg" }
}

# Tasks SG: allow from ALB SG
resource "aws_security_group" "tasks_sg" {
  name        = "${var.cluster_name}-tasks-sg"
  description = "Allow traffic from ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description      = "Allow from ALB"
    from_port        = 0
    to_port          = 65535
    protocol         = "tcp"
    security_groups  = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-tasks-sg" }
}

####################################################
# ALB + Target Group
####################################################
resource "aws_lb" "alb" {
  name               = "${var.cluster_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
  tags = { Name = "${var.cluster_name}-alb" }
}

resource "aws_lb_target_group" "tg" {
  name        = "${var.cluster_name}-tg"
  port        = var.container_port        # target group port is used as placeholder; ECS will register task IP:dynamic_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"                      # required for Fargate + dynamic port mapping

  # health check expects container to reply on container port
  health_check {
    path                = "/"
    protocol            = "HTTP"
    port                = "traffic-port"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }

  tags = { Name = "${var.cluster_name}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

####################################################
# ECS Cluster
####################################################
resource "aws_ecs_cluster" "this" {
  name = var.cluster_name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = { Name = var.cluster_name }
}

####################################################
# IAM roles for ECS task execution & task role
####################################################
data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ecs_task_role" {
  name               = "${var.cluster_name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  tags = { Name = "${var.cluster_name}-task-role" }
}

# Execution role (for pulling images, logs)
resource "aws_iam_role" "ecs_exec_role" {
  name               = "${var.cluster_name}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  tags = { Name = "${var.cluster_name}-exec-role" }
}

resource "aws_iam_role_policy_attachment" "exec_policy_attach" {
  role       = aws_iam_role.ecs_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# optional: allow tasks to write logs to CloudWatch (default provided by above policy)
####################################################
# CloudWatch log group
####################################################
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.cluster_name}"
  retention_in_days = 14
}

####################################################
# ECS Task Definition (Fargate)
####################################################
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.cluster_name}-taskdef"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_exec_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "hiring-app"
      image     = var.app_image
      essential = true

      # Fargate requires hostPort == containerPort (or omit hostPort)
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }

      # Optional: health check
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost/ || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
    }
  ])
}

####################################################
# ECS Service (Fargate) with ALB integration
####################################################
resource "aws_ecs_service" "app" {
  name            = "${var.cluster_name}-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.tasks_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "hiring-app"
    container_port   = var.container_port
  }

  # ensure tasks can be placed across AZs by using multiple subnets
  depends_on = [aws_lb_listener.http]
  lifecycle {
    ignore_changes = [task_definition] # allow updating task definition independently if desired
  }
}

####################################################
# (Optional) Service autoscaling - keep at least desired_count = 6
# You can expand this if you want dynamic autoscaling
####################################################
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 12
  min_capacity       = var.desired_count
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

output "alb_dns" {
  description = "ALB URL (HTTP)"
  value       = aws_lb.alb.dns_name
}

output "ecs_cluster" {
  value = aws_ecs_cluster.this.name
}
