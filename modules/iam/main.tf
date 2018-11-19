# We need the AWS Account ID for the SSM Permissions
data "aws_caller_identity" "current" {
  count = "${var.create ? 1 : 0 }"
}

# Assume Role Policy for the ECS Task
data "aws_iam_policy_document" "ecs_task_assume_role" {
  count = "${var.create ? 1 : 0 }"

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals = {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# The ECS TASK ROLE execution role needed for FARGATE & AWS LOGS
resource "aws_iam_role" "ecs_task_execution_role" {
  count              = "${(var.create && var.fargate_enabled ) ? 1 : 0 }"
  name               = "${var.name}-ecs-task-execution_role"
  assume_role_policy = "${data.aws_iam_policy_document.ecs_task_assume_role.json}"
}

# We need this for FARGATE
resource "aws_iam_role_policy_attachment" "ecs_tasks_execution_role" {
  count      = "${(var.create && var.fargate_enabled ) ? 1 : 0 }"
  role       = "${aws_iam_role.ecs_task_execution_role.id}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The actual ECS TASK ROLE
resource "aws_iam_role" "ecs_tasks_role" {
  count              = "${var.create ? 1 : 0 }"
  name               = "${var.name}-task-role"
  assume_role_policy = "${data.aws_iam_policy_document.ecs_task_assume_role.json}"
}

# Policy Document to allow KMS Decryption with given keys
data "aws_iam_policy_document" "kms_permissions" {
  count = "${var.create ? 1 : 0 }"

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["${var.kms_keys}"]
  }
}

# Allow KMS-Decrypt permissions for the ECS Task Role
resource "aws_iam_role_policy" "kms_permissions" {
  count  = "${(var.create && var.kms_enabled) ? 1 : 0 }"
  name   = "kms-permissions"
  role   = "${aws_iam_role.ecs_tasks_role.id}"
  policy = "${data.aws_iam_policy_document.kms_permissions.json}"
}

# Policy Document to allow access to SSM Parameter Store paths
data "aws_iam_policy_document" "ssm_permissions" {
  count = "${var.create ? 1 : 0 }"

  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParametersByPath"]
    resources = ["${formatlist("arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/application/%s/*",var.ssm_paths)}"]
  }
}

# Add the SSM policy to the task role
resource "aws_iam_role_policy" "ssm_permissions" {
  count  = "${(var.create && var.ssm_enabled) ? 1 : 0 }"
  name   = "ssm-permissions"
  role   = "${aws_iam_role.ecs_tasks_role.id}"
  policy = "${data.aws_iam_policy_document.ssm_permissions.json}"
}

# Policy Document to allow S3 Read-Write Access to given paths
data "aws_iam_policy_document" "s3_rw_permissions" {
  count = "${var.create ? 1 : 0 }"

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["${formatlist("arn:aws:s3:::%s",var.s3_rw_paths)}"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["${formatlist("arn:aws:s3:::%s/*",var.s3_rw_paths)}"]
  }
}

# Policy Document to allow S3 Read-Only Access to given paths
data "aws_iam_policy_document" "s3_ro_permissions" {
  count = "${var.create ? 1 : 0 }"

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["${formatlist("arn:aws:s3:::%s",var.s3_ro_paths)}"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${formatlist("arn:aws:s3:::%s/*",var.s3_ro_paths)}"]
  }
}

# Add the S3 Read-Write policy to the task role
resource "aws_iam_role_policy" "s3_rw_permissions" {
  name   = "s3-read-write-policy"
  count  = "${(var.create && length(var.s3_rw_paths) > 0 ) ? 1 : 0 }"
  role   = "${aws_iam_role.ecs_tasks_role.id}"
  policy = "${data.aws_iam_policy_document.s3_rw_permissions.json}"
}

# Add the S3 Read-Only policy to the task role
resource "aws_iam_role_policy" "s3_ro_permissions" {
  count  = "${(var.create && length(var.s3_ro_paths) > 0 ) ? 1 : 0 }"
  name   = "s3-readonly-policy"
  role   = "${aws_iam_role.ecs_tasks_role.id}"
  policy = "${data.aws_iam_policy_document.s3_ro_permissions.json}"
}

### Lambda Support Role

# ---------------------------------------------------------------------------------------------------------------------
# CREATE INVOCATION POLICY
# We need to permit the lambda be used @Edge as well as in the traditional manner.
# ---------------------------------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "lambdaPolicy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"

      identifiers = [
        "lambda.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role" "lambda_lookup" {
  name               = "ecs-lambda-lookup-${var.name}"
  description        = "Role permitting Lambda functions to be invoked from Lambda or Lambda@Edge"
  assume_role_policy = "${data.aws_iam_policy_document.lambdaPolicy.json}"
}

data "aws_iam_policy_document" "logging_policy_document" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${format("arn:aws:logs:%s:%s:log-group:/aws/lambda/%s-lambda-lookup:*",var.region, data.aws_caller_identity.current.account_id, var.name)}"]
    effect    = "Allow"
  }

  statement {
    actions = ["logs:PutLogEvents"]

    resources = ["${format("arn:aws:logs:%s:%s:log-group:/aws/lambda/%s-lambda-lookup:*.*",var.region, data.aws_caller_identity.current.account_id, var.name)}"]
    effect    = "Allow"
  }
}

data "aws_iam_policy_document" "support_lambda_ecs_permissions" {
  statement {
    effect = "Allow"

    actions = [
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:ListTaskDefinitions",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_log_policy" {
  role   = "${aws_iam_role.lambda_lookup.name}"
  policy = "${data.aws_iam_policy_document.logging_policy_document.json}"
}

resource "aws_iam_role_policy" "lambda_lookup_policy" {
  role   = "${aws_iam_role.lambda_lookup.name}"
  policy = "${data.aws_iam_policy_document.support_lambda_ecs_permissions.json}"
}
