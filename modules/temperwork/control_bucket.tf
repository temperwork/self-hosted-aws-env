# The control bucket: only records (execution records, pipeline snapshots,
# worker heartbeats, dataset manifests), no datasets, outputs or models.
# temperwork and your workers both read and write it.

resource "aws_s3_bucket" "control" {
  count  = var.control_bucket == "" ? 1 : 0
  bucket = "${var.name}-control"
}
