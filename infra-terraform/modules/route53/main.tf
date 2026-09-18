###############################################################################
# Route53: either create a public hosted zone (delegate NS from your registrar)
# or look up an existing one. ExternalDNS manages records inside it.
###############################################################################

resource "aws_route53_zone" "this" {
  count         = var.create_zone ? 1 : 0
  name          = var.domain
  comment       = "CloudForge ${var.environment} (records managed by ExternalDNS)"
  force_destroy = var.force_destroy
  tags          = var.tags
}

data "aws_route53_zone" "existing" {
  count        = var.create_zone ? 0 : 1
  name         = var.domain
  private_zone = false
}

locals {
  zone_id      = var.create_zone ? aws_route53_zone.this[0].zone_id : data.aws_route53_zone.existing[0].zone_id
  name_servers = var.create_zone ? aws_route53_zone.this[0].name_servers : data.aws_route53_zone.existing[0].name_servers
}

# CAA: only Let's Encrypt (cert-manager) and Amazon may issue certificates for the domain.
resource "aws_route53_record" "caa" {
  count   = var.manage_caa ? 1 : 0
  zone_id = local.zone_id
  name    = var.domain
  type    = "CAA"
  ttl     = 3600
  records = [
    "0 issue \"letsencrypt.org\"",
    "0 issue \"amazon.com\"",
    "0 iodef \"mailto:${var.security_contact}\"",
  ]
}
