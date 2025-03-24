
################################################################################
# EBS Throughput Tuner using Lambda and Step Functions modules
################################################################################

module "lambda_function" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  function_name = "EbsThroughputTunerLambda"
  description   = "Lambda function to tune EBS volume throughput and IOPS"
  handler       = "app.lambda_handler"
  runtime       = "python3.11"
  timeout       = 300

  source_path = "${path.module}/ebs_throughput_tuner"

  environment_variables = {
    TARGET_EC2_TAG_KEY   = "karpenter.sh/discovery"
    TARGET_EC2_TAG_VALUE = local.name
    THROUGHPUT_VALUE     = var.ebs_throughput
    IOPS_VALUE           = var.ebs_iops
  }

  attach_policy_statements = true
  policy_statements = {
    ec2_full_access = {
      effect    = "Allow",
      actions   = ["ec2:*"],
      resources = ["*"]
    }
  }

  tags = local.tags
}

module "step_function" {
  source  = "terraform-aws-modules/step-functions/aws"
  version = "~> 4.1"

  name       = "EbsThroughputTunerStateMachine"
  definition = jsonencode({
    Comment = "EBS Throughput Tuner State Machine"
    StartAt = "Wait"
    States = {
      Wait = {
        Type    = "Wait"
        Seconds = var.ebs_tuner_duration
        Next    = "ChangeThroughput"
      }
      ChangeThroughput = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = module.lambda_function.lambda_function_arn
          "Payload.$": "$"
        }
        Retry = [
          {
            ErrorEquals = ["States.ALL"]
            IntervalSeconds = 5
            MaxAttempts = 3
            BackoffRate = 2
          }
        ]
        End = true
      }
    }
  })

  service_integrations = {
    lambda = {
      lambda = [module.lambda_function.lambda_function_arn]
    }
  }

  type = "STANDARD"

  tags = local.tags
}

module "eventbridge" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "~> 3.14"

  create_bus = false
  role_name  = "${local.name}-eventbridge-role"  # Use a unique name instead of "default"
  attach_sfn_policy = true
  sfn_target_arns   = [
    module.step_function.state_machine_arn
  ]

  rules = {
    ebs_tuner = {
      description   = "Capture EC2 Fleet and Spot Fleet instance changes"
      event_pattern = jsonencode({
        source      = ["aws.ec2"]
        detail_type = ["EC2 Instance State-change Notification"]
        detail      = {
          "state" = ["running"]
        }
      })
    }
  }

  targets = {
    ebs_tuner = [
      {
        name            = "trigger-ebs-tuner"
        arn             = module.step_function.state_machine_arn
        attach_role_arn = true
      }
    ]
  }

  tags = local.tags
}