terraform {
  backend "s3" {
    bucket = "terraform-remote-state-2023-stack-academy" # Nome do bucket criado no S3 para armazenar o estado do Terraform
    key    = "architecture-2/terraform.tfstate" # Nome do arquivo que será armazenado no bucket
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
  shared_credentials_file = var.credentials.credentials_file
  region                  = var.credentials.region
  default_tags {
    tags = {
      team    = "data"
      project = "stack-academy-architecture-2"
    }
  }
}

/**
 * Carregando dados
 */

data "aws_vpc" "vpc_default" {
  /**
   * Carregando a VPC default da conta, para que possamos criar os recursos dentro dela.
   * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc
   * https://docs.aws.amazon.com/vpc/latest/userguide/default-vpc.html
   */
  id = var.vpc_id
}

data "aws_iam_policy_document" "ingest_data_policy" {
  /*
  * Criando a policy que será utilizada para permitir que o S3 envie mensagens para a fila do SQS.
  * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document
  * https://docs.aws.amazon.com/pt_br/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html
  */
  statement {
    actions = ["sqs:SendMessage"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    resources = [aws_sqs_queue.queue_ingest_eks.arn]
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.ingest_data_eks.arn]
    }
  }
}

data "aws_iam_policy_document" "aws_glue_service_role" {
    /*
    * Criando a policy que será assumida pelo Glue para acessar os recursos necessários.
    * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document
    * https://docs.aws.amazon.com/pt_br/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html
    */
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

data "aws_iam_policy" "glue_execution_role" {
    /*
        * Carregando a policy que será utilizada pelo Glue para acessar os recursos necessários.
        * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy
        */
    arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy" "eks_cluster_policy" {
    /*
        * Carregando a policy que será utilizada pelo EKS para acessar os recursos necessários.
        * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy
        */
    arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy" "eks_fargate_policy" {
    /*
        * Carregando a policy que será utilizada pelo EKS para acessar os recursos necessários.
        * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy
        */
    arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

/**
 * Criando as roles e policies
 */

resource "aws_iam_policy" "cloudwatch_pod_policy" {
  /*
    * Criando a policy que será utilizada para permitir que o CloudWatch envie logs para o CloudWatch.
    * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy
    * https://docs.aws.amazon.com/pt_br/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html
    */
  name   = "cloudwatch_pod_policy"
  policy = <<EOF
{
	"Version": "2012-10-17",
	"Statement": [{
		"Effect": "Allow",
		"Action": [
			"logs:CreateLogStream",
			"logs:CreateLogGroup",
			"logs:DescribeLogStreams",
			"logs:PutLogEvents"
		],
		"Resource": "*"
	}]
}
EOF
}

resource "aws_iam_policy" "s3_policy" {
  /*
    * Criando a policy que será utilizada para permitir que o Glue acesse os recursos necessários.
    * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy
    * https://docs.aws.amazon.com/pt_br/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html
    */
  name   = "S3Policy"
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject"
            ],
            "Resource": [
                "${aws_s3_bucket.analytics_data_eks.arn}/*",
                "${aws_s3_bucket.analytics_data_eks.arn}",
                "${aws_s3_bucket.ingest_data_eks.arn}/*",
                "${aws_s3_bucket.ingest_data_eks.arn}"
            ]
        }
    ]
}
EOF
}

resource "aws_iam_role" "aws_glue_service_role" {
    /*
    * Criando a role que será utilizada pelo Glue para acessar os recursos necessários.
    * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role
    * https://docs.aws.amazon.com/pt_br/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html
    */
  name               = "aws_glue_service_role"
  assume_role_policy = data.aws_iam_policy_document.aws_glue_service_role.json
}


resource "aws_iam_role_policy_attachment" "aws_glue_service_role_policy" {
  /*
    * Anexando a policy que será utilizada pelo Glue para acessar os recursos necessários.
    * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment
    */
  role       = aws_iam_role.aws_glue_service_role.name
  policy_arn = data.aws_iam_policy.glue_execution_role.arn
}

resource "aws_iam_role_policy_attachment" "aws_glue_service_role_policy_s3" {
    /*
        * Anexando a policy que será utilizada pelo Glue para acessar os recursos necessários.
        * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment
        */
  role       = aws_iam_role.aws_glue_service_role.name
  policy_arn = aws_iam_policy.s3_policy.arn
}


resource "aws_iam_role" "eks_cluster" {
  /*
    * Criando a role que será assumida pelo EKS para acessar os recursos necessários.
    * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role
    * https://docs.aws.amazon.com/pt_br/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html
    */
  name = "eks_cluster_role"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
    /*
        * Anexando a policy que será utilizada pelo EKS para acessar os recursos necessários.
        * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment
        */
  role       = aws_iam_role.eks_cluster.name
  policy_arn = data.aws_iam_policy.eks_cluster_policy.arn
}

resource "aws_iam_role" "eks_fargate_pod" {
    /*
        * Criando a role que será assumida pelo EKS Pod para acessar os recursos necessários.
        * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role
        * https://docs.aws.amazon.com/pt_br/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html
        */
  name = "eks_fargate_pod_role"

  assume_role_policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "eks-fargate-pods.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "eks_fargate_pod" {
    /*
    * Anexando a policy que será utilizada pelo EKS Pod para acessar os recursos necessários.
    * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment
    */
  role       = aws_iam_role.eks_fargate_pod.name
  policy_arn = data.aws_iam_policy.eks_fargate_policy.arn
}

resource "aws_iam_role_policy_attachment" "eks_fargate_pod_log" {
    /*
    * Anexando a policy que será utilizada pelo EKS Pod para acessar os recursos necessários.
    * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment
    */
  role       = aws_iam_role.eks_fargate_pod.name
  policy_arn = aws_iam_policy.cloudwatch_pod_policy.arn
}


/*
* Criando os recursos necessários para o serviço
*/

resource "aws_s3_bucket" "ingest_data_eks" {
    /**
    * Cria um bucket S3 para armazenar os dados.
    * O bucket é criado com o nome stack-academy-eng-dados-2023-, que deve ser universalmente único.
    * O hash sha256(timestamp()) é usado para garantir que o nome do bucket seja único.
    * Essa bucket será usado para armazenar os dados que serão consumidos pelo EKS.
    * https://docs.aws.amazon.com/pt_br/AmazonS3/latest/userguide/what-is-s3.html
    */
  bucket = "stack-academy-eng-dados-2023-${substr(sha256(timestamp()), 0, 15)}"
}

resource "aws_s3_bucket" "analytics_data_eks" {
  /*
    * Cria um bucket S3 para armazenar os dados.
    * O bucket é criado com o nome stack-academy-eng-dados-2023-analytics-, que deve ser universalmente único.
    * O hash sha256(timestamp()) é usado para garantir que o nome do bucket seja único.
    * Esse bucket será usado para armazenar os dados processados pelo EKS e consumidos pelo Athena.
    * https://docs.aws.amazon.com/pt_br/AmazonS3/latest/userguide/what-is-s3.html
    */
  bucket = "stack-academy-eng-dados-2023-analytics-${substr(sha256(timestamp()), 0, 15)}"
}

resource "aws_s3_bucket" "athena_results_eks" {
    /*
    * Cria um bucket S3 para armazenar os dados.
    * O bucket é criado com o nome stack-academy-eng-dados-2023-athena-results-, que deve ser universalmente único.
    * O hash sha256(timestamp()) é usado para garantir que o nome do bucket seja único.
    * Esse bucket será usado para armazenar os resultados das queries do Athena.
    * https://docs.aws.amazon.com/pt_br/AmazonS3/latest/userguide/what-is-s3.html
    */
  bucket = "stack-academy-eng-dados-2023-athena-results-${substr(sha256(timestamp()), 0, 15)}"
}

resource "aws_sqs_queue" "queue_ingest_eks" {
  /*
    * Cria uma fila SQS para receber os dados.
    * O nome da fila é stack-academy-eng-dados-2023-queue-ingest-eks-.
    * O hash sha256(timestamp()) é usado para garantir que o nome da fila seja único.
    * https://docs.aws.amazon.com/pt_br/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html
    */
  name = "queue-ingest-stack-academy-eks-${substr(sha256(timestamp()), 0, 15)}"
}

resource "aws_ecr_repository" "ingest_data_repository_eks" {
    /*
      * Cria um repositório ECR para armazenar a imagem do container.
      * O nome do repositório é stack-academy-eng-dados-2023-ingest-data-repository-eks.
      * https://docs.aws.amazon.com/pt_br/AmazonECR/latest/userguide/what-is-ecr.html
      */
  name = "stack-academy-eng-dados-2023-ingest-data-repository-eks"
}

resource "aws_cloudwatch_log_group" "ingest_data_log_group" {
    /*
    * Cria um log group para armazenar os logs do container.
    * O nome do log group é stack-academy-eng-dados-2023-ingest-data-log-group-eks.
    * https://docs.aws.amazon.com/pt_br/AmazonCloudWatch/latest/logs/WhatIsCloudWatchLogs.html
    */
  name = "/aws/eks/${var.eks_cluster_name}/cluster"
  retention_in_days = 7
}

resource "aws_sqs_queue_policy" "ingest_data_queue_policy" {
    /*
      * Anexando a policy que será utilizada pela fila SQS para acessar os recursos necessários.
      * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy
      */
  queue_url = aws_sqs_queue.queue_ingest_eks.id
  policy    = data.aws_iam_policy_document.ingest_data_policy.json
}

resource "aws_s3_bucket_notification" "ingest_data_bucket_notification" {
    /*
    * Criando uma notificação do S3 para a fila SQS toda vez que um arquivo for criado no bucket.
    * https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification
    */
  bucket = aws_s3_bucket.ingest_data_eks.id
  queue {
    queue_arn     = aws_sqs_queue.queue_ingest_eks.arn
    events        = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_sqs_queue_policy.ingest_data_queue_policy]
}

resource "aws_glue_catalog_database" "stack_academy_glue_catalog_database" {
    /*
    * Criando um banco de dados no Glue Catalog.
    * O nome do banco de dados é stack_academy_glue_catalog_database.
    * https://docs.aws.amazon.com/pt_br/glue/latest/dg/define-database.html
    */
  name = "stack_academy_glue_catalog_database"
}

resource "aws_glue_catalog_table" "my_table" {
    /*
    * Criando uma tabela no Glue Catalog.
    * O nome da tabela é movie_data.
    * O tipo da tabela é EXTERNAL_TABLE.
    * O local onde os dados processados pelo EKS serão armazenados é o stack-academy-eng-dados-2023 criado anteriormente.
    * O formato dos dados é parquet.
    * https://docs.aws.amazon.com/pt_br/glue/latest/dg/define-table.html
    */
  name     = "movie_data"
  database_name = aws_glue_catalog_database.stack_academy_glue_catalog_database.name

  table_type = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL = "TRUE"
    "parquet.compression" = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.ingest_data_eks.id}/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name = "movie_data"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = 1
      }
    }

    columns {
      name = "title_id"
      type = "string"
    }

    columns {
      name = "title_type"
      type = "string"
    }

    columns {
      name = "primary_title"
      type = "string"
    }

    columns {
      name = "original_title"
      type = "string"
    }

    columns {
      name = "is_adult"
      type = "boolean"
    }

    columns {
      name = "end_year"
      type = "int"
    }

    columns {
      name = "runtime_minutes"
      type = "int"
    }

    columns {
      name = "genres"
      type = "array<string>"
    }
  }

  partition_keys {
    /*
    * Criando uma partição na tabela para o campo start_year.
    * O tipo do campo é int.
    * https://docs.aws.amazon.com/pt_br/glue/latest/dg/partitioning-importing-exporting.html
    */
    name = "start_year"
    type = "int"
  }
  depends_on = [aws_glue_catalog_database.stack_academy_glue_catalog_database]
}


resource "aws_glue_crawler" "crawler" {
  /*
    * Criando um crawler no Glue para ler os dados do bucket e armazenar no Glue Catalog.
    * O crawler é necessário para que o Glue Catalog possa ser utilizado pelo Athena.
    * Para que novos dados aparecem no Athena, é necessário rodar o crawler primeiro, para que o Glue Catalog seja atualizado.
    * https://docs.aws.amazon.com/pt_br/glue/latest/dg/add-crawler.html
    */
  database_name = aws_glue_catalog_database.stack_academy_glue_catalog_database.name
  name          = "stack_academy_glue_crawler"
  role          = aws_iam_role.aws_glue_service_role.arn

  catalog_target {
    database_name = aws_glue_catalog_database.stack_academy_glue_catalog_database.name
    tables        = [aws_glue_catalog_table.my_table.name]
  }

  schema_change_policy {
    delete_behavior = "LOG"
  }

  schedule = "cron(0 12 * * ? *)" # Rodar o crawler todos os dias às 12:00, horário de Brasília. Porém iremos rodar manualmente.
  depends_on = [
    aws_iam_role_policy_attachment.aws_glue_service_role_policy,
    aws_iam_role_policy_attachment.aws_glue_service_role_policy_s3,
    aws_iam_role.aws_glue_service_role,
    aws_glue_catalog_table.my_table
  ]
}


resource "aws_subnet" "private" {
  /*
    * Criando uma subnet privada para o EKS.
    * A subnet privada é necessária para que o EKS possa ser criado.
    * https://docs.aws.amazon.com/pt_br/vpc/latest/userguide/VPC_Subnets.html
    */
  vpc_id     = data.aws_vpc.vpc_default.id
  cidr_block = var.private_subnet.cidr_block
  availability_zone = var.private_subnet.availability_zone
}

resource "aws_route_table" "private" {
  /*
    * Criando uma route table privada para o EKS.
    * A route table privada é necessária para que o EKS possa ser criado.
    * https://docs.aws.amazon.com/pt_br/vpc/latest/userguide/VPC_Route_Tables.html
    */
  vpc_id = data.aws_vpc.vpc_default.id
}

resource "aws_route_table_association" "private_route_table_association" {
    /*
      * Associando a subnet privada à route table privada.
      * https://docs.aws.amazon.com/pt_br/vpc/latest/userguide/VPC_Route_Tables.html
      */
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# Security group for SQS
resource "aws_security_group" "sg_for_sqs" {
  /*
    * Criando um security group para o SQS.
    * O security group é necessário para que o SQS possa ser criado.
    * https://docs.aws.amazon.com/pt_br/vpc/latest/userguide/VPC_SecurityGroups.html
    */
  name        = "private_sg"
  vpc_id      = data.aws_vpc.vpc_default.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_endpoint" "s3" {
  /*
    * Criando um endpoint para o S3.
    * O endpoint é necessário para que o EKS possa ser criado.
    * https://docs.aws.amazon.com/pt_br/vpc/latest/userguide/vpc-endpoints.html
    */
  vpc_id       = data.aws_vpc.vpc_default.id
  service_name = "com.amazonaws.${var.credentials.region}.s3"
  route_table_ids = [aws_route_table.private.id]
}

#
resource "aws_vpc_endpoint" "ecr_api" {
  /*
    * Criando um endpoint para o Amazon ECR API (Interface).
    * O endpoint é necessário para que o EKS possa ser criado.
    * https://docs.aws.amazon.com/pt_br/vpc/latest/userguide/vpc-endpoints.html
    */
  vpc_id            = data.aws_vpc.vpc_default.id
  service_name      = "com.amazonaws.${var.credentials.region}.ecr.api"
  vpc_endpoint_type = "Interface"
  subnet_ids        = [aws_subnet.private.id]
  security_group_ids = [aws_security_group.sg_for_sqs.id]
  private_dns_enabled = true
}

# Create an endpoint for Amazon ECR DKR (Interface)
resource "aws_vpc_endpoint" "ecr_dkr" {
  /*
    * Criando um endpoint para o Amazon ECR DKR (Interface).
    * O endpoint é necessário para que o EKS possa ser criado.
    * https://docs.aws.amazon.com/pt_br/vpc/latest/userguide/vpc-endpoints.html
    */
  vpc_id            = data.aws_vpc.vpc_default.id
  service_name      = "com.amazonaws.${var.credentials.region}.ecr.dkr"
  vpc_endpoint_type = "Interface"
  subnet_ids        = [aws_subnet.private.id]
  security_group_ids = [aws_security_group.sg_for_sqs.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "sqs_api" {
  /*
    * Criando um endpoint para o Amazon SQS API (Interface).
    * O endpoint é necessário para que o EKS possa ser criado.
    * https://docs.aws.amazon.com/pt_br/vpc/latest/userguide/vpc-endpoints.html
    */
  vpc_id            = data.aws_vpc.vpc_default.id
  service_name      = "com.amazonaws.${var.credentials.region}.sqs"
  vpc_endpoint_type = "Interface"
  subnet_ids        = [aws_subnet.private.id]
  security_group_ids = [aws_security_group.sg_for_sqs.id]
  private_dns_enabled = true
}


resource "aws_eks_cluster" "stack_cluster" {
  /*
    * Criando um cluster EKS.
    * O cluster EKS é necessário para que o Fargate Profile possa ser criado.
    * https://docs.aws.amazon.com/pt_br/eks/latest/userguide/create-cluster.html
    */
  name     = var.eks_cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version = "1.27"

  vpc_config {
    subnet_ids = [aws_subnet.private.id, var.subnet_public_b]
    security_group_ids = [aws_security_group.sg_for_sqs.id]
    endpoint_private_access = true
  }
  enabled_cluster_log_types = [
      "api",
      "audit",
      "authenticator",
      "controllerManager",
      "scheduler"
    ]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster,
    aws_route_table_association.private_route_table_association,
    aws_cloudwatch_log_group.ingest_data_log_group
  ]
}

resource "aws_eks_fargate_profile" "stack_fargate_profile" {
  /*
    * Criando um Fargate Profile.
    * O Fargate Profile é necessário para que o Fargate possa ser criado.
    * https://docs.aws.amazon.com/pt_br/eks/latest/userguide/fargate-profile.html
    */
  cluster_name = aws_eks_cluster.stack_cluster.name
  fargate_profile_name  = "stack-fargate-profile"
  pod_execution_role_arn = aws_iam_role.eks_fargate_pod.arn

  subnet_ids = [aws_subnet.private.id]

  selector {
    namespace = "default"

    labels = {
      team     = "data"
      service  = "eks"
      project  = "architecture"
      aws-observability = "enabled"
    }
  }
}