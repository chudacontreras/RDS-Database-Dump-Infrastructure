# ==============================================================
# EventBridge Rules - Reemplazan los crontabs de la EC2
# ==============================================================

# --- MENSUAL: día 5 de cada mes ---

resource "aws_cloudwatch_event_rule" "monthly_pg" {
  count               = var.pg_enabled ? 1 : 0
  name                = "${var.project_name}-monthly-postgresql"
  description         = "Dump mensual PostgreSQL - día 5 a las 02:00 UTC"
  schedule_expression = "cron(0 2 5 * ? *)"
}

resource "aws_cloudwatch_event_target" "monthly_pg" {
  count = var.pg_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.monthly_pg[0].name
  arn   = aws_lambda_function.postgresql[0].arn
  input = jsonencode({ dump_type = "monthly" })
}

resource "aws_lambda_permission" "monthly_pg" {
  count         = var.pg_enabled ? 1 : 0
  statement_id  = "AllowEventBridgeMonthly"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.postgresql[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.monthly_pg[0].arn
}

resource "aws_cloudwatch_event_rule" "monthly_my" {
  count               = var.my_enabled ? 1 : 0
  name                = "${var.project_name}-monthly-mysql"
  description         = "Dump mensual MySQL - día 5 a las 02:30 UTC"
  schedule_expression = "cron(30 2 5 * ? *)"
}

resource "aws_cloudwatch_event_target" "monthly_my" {
  count = var.my_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.monthly_my[0].name
  arn   = aws_lambda_function.mysql[0].arn
  input = jsonencode({ dump_type = "monthly" })
}

resource "aws_lambda_permission" "monthly_my" {
  count         = var.my_enabled ? 1 : 0
  statement_id  = "AllowEventBridgeMonthly"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mysql[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.monthly_my[0].arn
}

resource "aws_cloudwatch_event_rule" "monthly_ora" {
  count               = var.ora_enabled ? 1 : 0
  name                = "${var.project_name}-monthly-oracle"
  description         = "Dump mensual Oracle - día 5 a las 03:00 UTC"
  schedule_expression = "cron(0 3 5 * ? *)"
}

resource "aws_cloudwatch_event_target" "monthly_ora" {
  count = var.ora_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.monthly_ora[0].name
  arn   = aws_lambda_function.oracle[0].arn
  input = jsonencode({ dump_type = "monthly" })
}

resource "aws_lambda_permission" "monthly_ora" {
  count         = var.ora_enabled ? 1 : 0
  statement_id  = "AllowEventBridgeMonthly"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.oracle[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.monthly_ora[0].arn
}

# --- ANUAL: día 10 de enero ---

resource "aws_cloudwatch_event_rule" "yearly_pg" {
  count               = var.pg_enabled ? 1 : 0
  name                = "${var.project_name}-yearly-postgresql"
  description         = "Dump anual PostgreSQL - 10 enero a las 02:00 UTC"
  schedule_expression = "cron(0 2 10 1 ? *)"
}

resource "aws_cloudwatch_event_target" "yearly_pg" {
  count = var.pg_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.yearly_pg[0].name
  arn   = aws_lambda_function.postgresql[0].arn
  input = jsonencode({ dump_type = "yearly" })
}

resource "aws_lambda_permission" "yearly_pg" {
  count         = var.pg_enabled ? 1 : 0
  statement_id  = "AllowEventBridgeYearly"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.postgresql[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.yearly_pg[0].arn
}

resource "aws_cloudwatch_event_rule" "yearly_my" {
  count               = var.my_enabled ? 1 : 0
  name                = "${var.project_name}-yearly-mysql"
  description         = "Dump anual MySQL - 10 enero a las 02:30 UTC"
  schedule_expression = "cron(30 2 10 1 ? *)"
}

resource "aws_cloudwatch_event_target" "yearly_my" {
  count = var.my_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.yearly_my[0].name
  arn   = aws_lambda_function.mysql[0].arn
  input = jsonencode({ dump_type = "yearly" })
}

resource "aws_lambda_permission" "yearly_my" {
  count         = var.my_enabled ? 1 : 0
  statement_id  = "AllowEventBridgeYearly"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mysql[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.yearly_my[0].arn
}

resource "aws_cloudwatch_event_rule" "yearly_ora" {
  count               = var.ora_enabled ? 1 : 0
  name                = "${var.project_name}-yearly-oracle"
  description         = "Dump anual Oracle - 10 enero a las 03:00 UTC"
  schedule_expression = "cron(0 3 10 1 ? *)"
}

resource "aws_cloudwatch_event_target" "yearly_ora" {
  count = var.ora_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.yearly_ora[0].name
  arn   = aws_lambda_function.oracle[0].arn
  input = jsonencode({ dump_type = "yearly" })
}

resource "aws_lambda_permission" "yearly_ora" {
  count         = var.ora_enabled ? 1 : 0
  statement_id  = "AllowEventBridgeYearly"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.oracle[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.yearly_ora[0].arn
}
