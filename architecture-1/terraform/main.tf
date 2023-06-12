terraform {
  backend "s3" {
    bucket = "terraform-remote-state-2023-stack-academy" # Nome do bucket criado no S3 para armazenar o estado do Terraform
    key    = "architecture-1/terraform.tfstate" # Nome do arquivo de estado do Terraform que será armazenado no S3
    region = "us-east-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
  }
  required_version = ">= 0.14.9"
}

provider "aws" {
  shared_credentials_file = var.credentials.credentials_file # Caminho para o arquivo de credenciais do AWS
  region                  = var.credentials.region # Região onde serão criados os recursos
  default_tags {
    # Tags que serão aplicadas a todos os recursos criados pelo Terraform neste projeto.
    tags = {
      team    = "data"
      project = "stack-academy-architecture-1"
    }
  }
}

/**
 * Carregando dados
 */

data "aws_iam_policy_document" "ingest-data-policy" {
    /**
        * Policy para permitir que o S3 envie mensagens para a fila SQS.
        * https://docs.aws.amazon.com/pt_br/AmazonS3/latest/userguide/ways-to-add-notification-config-to-bucket.html
  */
  statement {
    actions = ["sqs:SendMessage"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    resources = [aws_sqs_queue.ingest-data-queue.arn]
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.ingest-data-bucket.arn]
    }
  }
  depends_on = [aws_sqs_queue.ingest-data-queue, aws_s3_bucket.ingest-data-bucket]
}

data "aws_iam_policy" "AmazonECSTaskExecutionRolePolicy" {
  /**
    * Policy para execução de tarefas ECS, necessária para que o ECS possa executar as tarefas.
    * https://docs.aws.amazon.com/pt_br/AmazonECS/latest/developerguide/task_execution_IAM_role.html
    */
  arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


data "aws_subnet" "public_subnet_a" {
    /**
    * Subnet pública A.
    * Necessario pegar o ID da subnet pública A no console e adicionar na variável subnet_public_a.
    */
    id = var.subnet_public_a
}

data "aws_subnet" "public_subnet_b" {
    /**
    * Subnet pública B.
    * Necessario pegar o ID da subnet pública B no console e adicionar na variável subnet_public_b.
    */
    id = var.subnet_public_b
}

data "aws_security_group" "default_security_group" {
    /**
    * Security group padrão da VPC.
    * Necessario pegar o ID do security group padrão da VPC no console e adicionar na variável default_security_group.
    * para que o ECS possa acessar o Redshift.
    */
    id = var.default_security_group
}

/**
* Criação de Roles e Policies.
**/

resource "aws_iam_role" "ecs_task_role" {
  /**
    * Role para execução de tarefas ECS, necessária para que o ECS possa executar as tarefas.
    * https://docs.aws.amazon.com/pt_br/AmazonECS/latest/developerguide/task_execution_IAM_role.html
    */
  name = "ecs_task_role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}


resource "aws_iam_policy" "ecs_redshift_access" {
    /**
        * Policy para permitir que o ECS acesse o Redshift, o S3 e o SQS.
        * Usando o principio de menor privilégio, apenas as permissões necessárias são concedidas.
        * https://docs.aws.amazon.com/redshift/latest/mgmt/generating-iam-credentials-role-permissions.html
        */
  name        = "ecs_redshift_access"
  description = "Allow ECS task to interact with Redshift"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "redshift:GetClusterCredentials",
      "Resource": "${aws_redshift_cluster.redshift-cluster.arn}"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "${aws_s3_bucket.ingest-data-bucket.arn}",
        "${aws_s3_bucket.ingest-data-bucket.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["sqs:ReceiveMessage","sqs:ChangeMessageVisibility", "sqs:DeleteMessage"],
      "Resource": "${aws_sqs_queue.ingest-data-queue.arn}"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "AmazonECSTaskExecutionRolePolicy" {
  /**
    * Anexa a policy AmazonECSTaskExecutionRolePolicy à role ecs_task_role.
    * Isso permite que a role ecs_task_role possua as permissões da policy AmazonECSTaskExecutionRolePolicy.
    */
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = data.aws_iam_policy.AmazonECSTaskExecutionRolePolicy.arn
}

resource "aws_iam_role_policy_attachment" "ecs_task_role_policy_attach" {
    /**
    * Anexa a policy ecs_redshift_access à role ecs_task_role.
    * Isso permite que a role ecs_task_role possua as permissões da policy ecs_redshift_access.
    */
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.ecs_redshift_access.arn
}


/**
* Criação de recursos.
**/


resource "aws_s3_bucket" "ingest-data-bucket" {
    /**
    * Cria um bucket S3 para armazenar os dados.
    * O bucket é criado com o nome stack-academy-eng-dados-2023-, que deve ser universalmente único.
    * O hash sha256(timestamp()) é usado para garantir que o nome do bucket seja único.
    * https://docs.aws.amazon.com/pt_br/AmazonS3/latest/userguide/what-is-s3.html
    */
  bucket = "stack-academy-eng-dados-2023-${substr(sha256(timestamp()), 0, 15)}"
}

resource "aws_sqs_queue" "ingest-data-queue" {
    /**
    * Cria uma fila SQS para receber as mensagens de ingestão.
    * O nome da fila é ingest-data-queue.
    * https://docs.aws.amazon.com/pt_br/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html
    */
  name = "ingest-data-queue"
}


resource "aws_sqs_queue_policy" "ingest-data-queue-policy" {
    /**
    * Anexa a policy ingest-data-policy à fila ingest-data-queue.
    * Isso permite que a fila ingest-data-queue possua as permissões da policy ingest-data-policy.
    * https://docs.aws.amazon.com/pt_br/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-queue-policies.html
    */
  queue_url = aws_sqs_queue.ingest-data-queue.id
  policy    = data.aws_iam_policy_document.ingest-data-policy.json
}

resource "aws_s3_bucket_notification" "ingest-data-bucket-notification" {
    /**
    * Configura a notificação do bucket S3 para enviar mensagens para a fila SQS quando um objeto for criado.
    * https://docs.aws.amazon.com/pt_br/AmazonS3/latest/userguide/NotificationHowTo.html
    */
  bucket = aws_s3_bucket.ingest-data-bucket.id
  queue {
    queue_arn     = aws_sqs_queue.ingest-data-queue.arn
    events        = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_sqs_queue_policy.ingest-data-queue-policy]
}

resource "aws_ecs_cluster" "ingest-data-cluster" {
    /**
    * Cria um cluster ECS para executar o container.
    * ECS clusters são grupos lógicos de instâncias para executar tarefas ECS.
    * https://docs.aws.amazon.com/pt_br/AmazonECS/latest/developerguide/clusters.html
    */
  name = "ingest-data-cluster"
}

resource "aws_ecr_repository" "ingest-data-repository" {
    /**
    * Cria um repositório ECR para armazenar a imagem do container.
    * O nome do repositório é ingest-data-repository.
    * https://docs.aws.amazon.com/pt_br/AmazonECR/latest/userguide/what-is-ecr.html
    */
  name = "ingest-data-repository"
}

resource "aws_cloudwatch_log_group" "ingest-data-log-group" {
    /**
    * Cria um grupo de logs CloudWatch para armazenar os logs do container.
    * O nome do grupo de logs é ingest-data-log-group.
    * https://docs.aws.amazon.com/pt_br/AmazonCloudWatch/latest/logs/WhatIsCloudWatchLogs.html
    */
  name = "ingest-data-log-group"
  retention_in_days = 7 // 7 dias de retenção dos logs
}

resource "aws_redshift_subnet_group" "ingest-data-subnet-group" {
    /**
    * Cria um grupo de sub-redes Redshift para armazenar as sub-redes onde o cluster Redshift será criado.
    * Criar um grupo de sub-redes Redshift é necessário para criar um cluster Redshift.
    * https://docs.aws.amazon.com/pt_br/redshift/latest/mgmt/working-with-cluster-subnet-groups.html
    */
  name       = "ingest-data-subnet-group"
  subnet_ids = [data.aws_subnet.public_subnet_a.id, data.aws_subnet.public_subnet_b.id]
}

resource "aws_redshift_cluster" "redshift-cluster" {
    /**
    * Cria um cluster Redshift para armazenar os dados.
    * As configurações do cluster são definidas para o cluster ser criado com apenas um nó e
    * usar o free tier da AWS, caso disponível na conta.
    * https://docs.aws.amazon.com/pt_br/redshift/latest/mgmt/working-with-clusters.html
    */
  cluster_identifier        = "redshift-cluster"
  database_name             = "ingest_data"
  master_username           = var.master_username // Define no arquivo variables.tf
  master_password           = var.master_password // Define no arquivo variables.tf
  node_type                 = "dc2.large"
  cluster_type              = "single-node"
  number_of_nodes           = 1
  publicly_accessible       = true
  vpc_security_group_ids    = [data.aws_security_group.default_security_group.id]
  skip_final_snapshot = true
  cluster_subnet_group_name = aws_redshift_subnet_group.ingest-data-subnet-group.name
}

resource "aws_ecs_task_definition" "ingest-data-task" {
    /**
    * Cria uma definição de tarefa ECS para executar o container.
    * A definição de tarefa ECS define como a tarefa será executada, incluindo a imagem do container,
    * a quantidade de CPU e memória que a tarefa usará, o papel de execução da tarefa e o papel da tarefa.
    * https://docs.aws.amazon.com/pt_br/AmazonECS/latest/developerguide/task_definitions.html
    */
  family                   = "ingest-data-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  runtime_platform {
    /**
    * Define a plataforma de execução da tarefa ECS.
    * A plataforma de execução da tarefa ECS define onde a tarefa será executada.
    * https://docs.aws.amazon.com/pt_br/AmazonECS/latest/developerguide/platform_versions.html
    */
    cpu_architecture = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    // Define o container que será executado pela tarefa ECS.
    name  = "ingest-data-image"
    image = "${aws_ecr_repository.ingest-data-repository.repository_url}:latest"  # Usa a imagem mais recente do repositório ECR criado anteriormente.
    essential = true // Define que o container é essencial para a tarefa.
    logConfiguration : {
          "logDriver" : "awslogs",
          "options" : {
            "awslogs-group" : aws_cloudwatch_log_group.ingest-data-log-group.name,
            "awslogs-region" : var.credentials.region,
            "awslogs-stream-prefix" : "ecs"
          }
        },
    environment: [
      {
        name: "redshift_host",
        value: aws_redshift_cluster.redshift-cluster.dns_name
      },
      {
        name: "redshift_user",
        value: var.master_username
      },
      {
        name: "redshift_password",
        value: var.master_password
      },
      {
        name: "redshift_db",
        value: aws_redshift_cluster.redshift-cluster.database_name
      },
      {
        name: "sqs_queue_url",
        value: aws_sqs_queue.ingest-data-queue.name
      }
    ]
  }])
}

resource "aws_ecs_service" "ingest-data-service" {
    /**
    * Cria um serviço ECS para executar a tarefa ECS.
    * O serviço ECS define qual e como a tarefa será executada, incluindo a quantidade de tarefas que serão executadas.
    * https://docs.aws.amazon.com/pt_br/AmazonECS/latest/developerguide/ecs_services.html
    */
  name            = "ingest-data-service"
  cluster         = aws_ecs_cluster.ingest-data-cluster.id
  task_definition = aws_ecs_task_definition.ingest-data-task.arn
  desired_count   = 0
  launch_type     = "FARGATE"
  network_configuration {
    subnets = [data.aws_subnet.public_subnet_a.id, data.aws_subnet.public_subnet_b.id]
    security_groups = [data.aws_security_group.default_security_group.id]
    assign_public_ip = true
  }
}

resource "aws_appautoscaling_target" "autoscaling_target" {
    /**
    * Cria um alvo de escalonamento automático para o serviço ECS.
    * O alvo de escalonamento automático define qual serviço ECS será escalonado.
    * https://docs.aws.amazon.com/pt_br/AmazonECS/latest/developerguide/service-auto-scaling.html
    */
  service_namespace  = "ecs" // Define que o alvo de escalonamento automático será um serviço ECS.
  resource_id        = "service/${aws_ecs_cluster.ingest-data-cluster.name}/${aws_ecs_service.ingest-data-service.name}" // Define qual serviço ECS que será escalonado.
  scalable_dimension = "ecs:service:DesiredCount" // Define que o alvo de escalonamento automático será a quantidade de tarefas que serão executadas.
  min_capacity       = 0 // Define a quantidade mínima de tarefas que serão executadas, quando o serviço ECS for escalonado.
  max_capacity       = 1  // Define a quantidade máxima de tarefas que serão executadas, quando o serviço ECS for escalonado.
}

resource "aws_appautoscaling_policy" "scale_up" {
    /**
    * Cria uma política de escalonamento automático para o alvo de escalonamento automático.
    * A política de escalonamento automático define como o alvo de escalonamento automático será escalonado.
    * https://docs.aws.amazon.com/pt_br/AmazonECS/latest/developerguide/service-auto-scaling.html
    */
  name               = "scale_up"
  service_namespace  = aws_appautoscaling_target.autoscaling_target.service_namespace
  scalable_dimension = aws_appautoscaling_target.autoscaling_target.scalable_dimension
  resource_id        = aws_appautoscaling_target.autoscaling_target.resource_id
  policy_type        = "StepScaling"

  step_scaling_policy_configuration {
    adjustment_type         = "ExactCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_with_message_alarm" {
    /**
    * Cria um alarme do CloudWatch para monitorar o tamanho da fila SQS.
    * O alarme do CloudWatch define quando o alvo de escalonamento automático será escalonado.
    * Quando o alarme do CloudWatch for acionado, o alvo de escalonamento automático será escalonado.
    * Quando o alarme do CloudWatch for desacionado, o alvo deve ser escalonado para a quantidade mínima de tarefas.
    * https://docs.aws.amazon.com/pt_br/AmazonECS/latest/developerguide/service-auto-scaling.html
    */
  alarm_name          = "queue_with_message_alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = "60"
  statistic           = "Maximum"
  threshold           = "1"
  alarm_description   = "Alarm when queue size increases"
  alarm_actions       = [aws_appautoscaling_policy.scale_up.arn]
  dimensions = {
    QueueName = aws_sqs_queue.ingest-data-queue.name
  }
}

resource "aws_appautoscaling_policy" "scale_down" {
  /**
    * Cria uma política de escalonamento automático para o alvo de escalonamento automático.
    * Essa policie coloca o alvo de escalonamento automático para 0 quando o alarme do CloudWatch for acionado.
    * https://docs.aws.amazon.com/pt_br/AmazonECS/latest/developerguide/service-auto-scaling.html
    */
  name               = "scale_down"
  service_namespace  = aws_appautoscaling_target.autoscaling_target.service_namespace
  scalable_dimension = aws_appautoscaling_target.autoscaling_target.scalable_dimension
  resource_id        = aws_appautoscaling_target.autoscaling_target.resource_id
  policy_type        = "StepScaling"

  step_scaling_policy_configuration {
    adjustment_type         = "ExactCapacity"
    cooldown                = 60
    metric_aggregation_type = "Minimum"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 0
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_without_message_alarm" {
    /**
    * Cria um alarme do CloudWatch para monitorar o tamanho da fila SQS.
    * Quando o alarme do CloudWatch for acionado, o alvo deve ser escalonado para 0.
    * https://docs.aws.amazon.com/pt_br/AmazonECS/latest/developerguide/service-auto-scaling.html
    */
  alarm_name          = "queue_size_alarm"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = "60"
  statistic           = "Maximum"
  threshold           = "1"
  alarm_description   = "Alarm when queue size decreases"
  alarm_actions       = [aws_appautoscaling_policy.scale_up.arn]
  dimensions = {
    QueueName = aws_sqs_queue.ingest-data-queue.name
  }
}