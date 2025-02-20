variable "source_rds_instance" {
  description = "The source rds instance we are trying to move and share"
  type        = string
}

variable "target_rds_instance" {
  description = "The target rds instance we are trying to use to recreate the snapshot as"
  type        = string
}

# 1. First run run false so we have all the data needed
# 2. Second run set to true to create the target rds instance from the finaly snapshot
variable "create_target_rds" {
  description = "Whether to create a new target rds instance"
  type        = bool
  default     = false
}