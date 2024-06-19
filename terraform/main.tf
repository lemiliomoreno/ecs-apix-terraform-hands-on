terraform {
  backend "s3" {
    bucket = "apix-ecs-terraform"
    key    = "state/apix-ecs.tfstate"
    region = "us-west-2"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.54.1"
    }
  }

  required_version = ">= 1.7.4"
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      environment = var.environment
      application = "apix-ecs"
    }
  }
}

# account id

data "aws_caller_identity" "current" {}

# azs

data "aws_availability_zones" "available" {
  state = "available"
}

# vpc

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${var.cluster_name}-${var.environment}-vpc"
  cidr = var.vpc_cidr

  azs             = [data.aws_availability_zones.available.names[0], data.aws_availability_zones.available.names[1]]
  private_subnets = [cidrsubnet(var.vpc_cidr, 2, 0), cidrsubnet(var.vpc_cidr, 2, 1)]
  public_subnets  = [cidrsubnet(var.vpc_cidr, 2, 2), cidrsubnet(var.vpc_cidr, 2, 3)]

  enable_nat_gateway      = true
  map_public_ip_on_launch = true
}

# database cluster and instance

resource "aws_security_group" "database_sg" {
  name   = "${var.cluster_name}-${var.environment}-db-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port        = 5432
    to_port          = 5432
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_db_subnet_group" "database_subnets" {
  name       = "${var.cluster_name}-${var.environment}-db-subnet-group"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_rds_cluster" "database_cluster" {
  cluster_identifier      = "${var.cluster_name}-${var.environment}-db-cluster"
  engine                  = "aurora-postgresql"
  engine_version          = "16.1"
  database_name           = "postgres"
  master_username         = var.db_username
  engine_mode             = "provisioned"
  master_password         = var.db_password
  backup_retention_period = 1
  skip_final_snapshot     = true

  vpc_security_group_ids = [
    aws_security_group.database_sg.id,
  ]

  db_subnet_group_name = aws_db_subnet_group.database_subnets.id

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 16.0
  }
}

resource "aws_rds_cluster_instance" "database_instance_writer_1" {
  cluster_identifier   = aws_rds_cluster.database_cluster.id
  instance_class       = "db.serverless"
  engine               = aws_rds_cluster.database_cluster.engine
  engine_version       = aws_rds_cluster.database_cluster.engine_version
  db_subnet_group_name = aws_db_subnet_group.database_subnets.id
  publicly_accessible  = false
}

# ecs cluster, cloudwatch group, task role, execution role

resource "aws_ecs_cluster" "ecs_cluster" {
  name = "${var.cluster_name}-${var.environment}-ecs-cluster"
}

resource "aws_cloudwatch_log_group" "log_group" {
  name              = "${var.cluster_name}-${var.environment}-log-group"
  retention_in_days = 14
}

resource "aws_iam_role" "execution_role" {
  name = "${var.cluster_name}-${var.environment}-execution-role"
  assume_role_policy = jsonencode({
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  })
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
  ]
}

resource "aws_iam_role" "task_role" {
  name = "${var.cluster_name}-${var.environment}-task-role"
  assume_role_policy = jsonencode({
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  })
}

# load balancer security group

resource "aws_security_group" "load_balancer_security_group" {
  name        = "${var.cluster_name}-${var.environment}-lb-sg"
  description = "Allow load balancer inbound traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

# container security group

resource "aws_security_group" "container_security_group" {
  name        = "${var.cluster_name}-${var.environment}-ecs-sg"
  description = "Allow container inbound traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    security_groups = [
      aws_security_group.load_balancer_security_group.id
    ]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

# ecs task definition

resource "aws_ecs_task_definition" "task_definition" {
  family             = "${var.cluster_name}-${var.environment}-task-definition"
  cpu                = 512
  memory             = 1024
  network_mode       = "awsvpc"
  execution_role_arn = aws_iam_role.execution_role.arn
  task_role_arn      = aws_iam_role.task_role.arn
  requires_compatibilities = [
    "FARGATE",
  ]
  container_definitions = jsonencode(
    [
      {
        "name" : "${var.cluster_name}-${var.environment}",
        "image" : "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/emilio-ghactions-demo-tf:${var.release}",
        "portMappings" : [
          {
            "containerPort" : 80
          }
        ],
        "logConfiguration" : {
          "logDriver" : "awslogs",
          "options" : {
            "awslogs-group" : "${var.cluster_name}-${var.environment}-log-group",
            "awslogs-region" : "${var.aws_region}",
            "awslogs-stream-prefix" : "ecs"
          }
        },
        "environment" : [
          {
            "name" : "DB_NAME",
            "value" : "postgres"
          },
          {
            "name" : "DB_USERNAME",
            "value" : "${var.db_username}"
          },
          {
            "name" : "DB_PASSWORD",
            "value" : "${var.db_password}"
          },
          {
            "name" : "DB_HOST",
            "value" : "${aws_rds_cluster.database_cluster.endpoint}"
          }
        ]
      }
    ]
  )
}

# load balancer target group

resource "aws_lb_target_group" "target_group" {
  depends_on = [
    aws_lb.load_balancer
  ]
  name                 = var.cluster_name
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = module.vpc.vpc_id
  target_type          = "ip"
  deregistration_delay = 60

  health_check {
    enabled             = true
    interval            = 60
    path                = "/"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# ecs service

resource "aws_ecs_service" "service" {
  depends_on = [
    aws_lb_listener.listener_http,
  ]
  name            = var.cluster_name
  cluster         = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.task_definition.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    assign_public_ip = false
    subnets          = module.vpc.private_subnets
    security_groups = [
      aws_security_group.container_security_group.id
    ]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.target_group.arn
    container_name   = "${var.cluster_name}-${var.environment}"
    container_port   = 80
  }
}

# load balancer, and http listener

resource "aws_lb" "load_balancer" {
  name               = "${var.cluster_name}-${var.environment}-lb"
  internal           = false
  load_balancer_type = "application"
  idle_timeout       = 60
  security_groups = [
    aws_security_group.load_balancer_security_group.id
  ]
  subnets = module.vpc.public_subnets
}

resource "aws_lb_listener" "listener_http" {
  load_balancer_arn = aws_lb.load_balancer.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn
  }
}
