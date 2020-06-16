#Provider and user configuration
provider "aws" {
    region = "ap-south-1"
    profile = "myprofile"
}

#Generate a key
resource "tls_private_key" "keyGenerate" {
    algorithm = "RSA"
}

resource "aws_key_pair" "newKey" {
	depends_on = [
		tls_private_key.keyGenerate
	]
    key_name   = "mykey2"
    public_key = tls_private_key.keyGenerate.public_key_openssh
}

resource "local_file" "keySave" {
	depends_on = [
		tls_private_key.keyGenerate
	]
    content = tls_private_key.keyGenerate.private_key_pem
    filename = "mykey2.pem"
}

#Create security group
resource "aws_security_group" "webServerFirewall" {
    name        = "webFirewall"
    description = "SSH and HTTP access"
    vpc_id      = "vpc-91617df9"

    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    ingress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Name = "webFirewall"
    }
}

#Launch ec2 instance and configure apache webserver
resource "aws_instance" "web" {
	depends_on = [
        aws_key_pair.newKey,
        aws_security_group.webServerFirewall
    ]

    ami           = "ami-052c08d70def0ac62"
    instance_type = "t2.micro"
    key_name =  aws_key_pair.newKey.key_name
    security_groups = [ "${aws_security_group.webServerFirewall.name}" ]
    
	connection {
        type     = "ssh"
        user     = "ec2-user"
        private_key = tls_private_key.keyGenerate.private_key_pem
        host     = aws_instance.web.public_ip
    }

    provisioner "remote-exec" {
        inline = [
            "sudo yum install httpd -y",
            "sudo systemctl start httpd",
            "sudo systemctl enable httpd",
			"sudo yum install git -y",
			"sudo setenforce 0"
        ]
    }
    tags = {
        Name = "web-os"
    }
}

#Create EBS of size 1GB
resource "aws_ebs_volume" "ebsWebVol" {
	depends_on = [
		aws_instance.web
	]
    availability_zone = aws_instance.web.availability_zone
    size              = 1

    tags = {
        Name = "web-vol1"
    }
}

#Attach EBS to instance
resource "aws_volume_attachment" "ebsAttach" {
	depends_on = [
        aws_ebs_volume.ebsWebVol
    ]
    device_name = "/dev/sdh"
    volume_id   = aws_ebs_volume.ebsWebVol.id
    instance_id = aws_instance.web.id
    force_detach = true
    
}

#Mount EBS to /var/www/html
resource "null_resource" "mountEbs" {
    depends_on = [
        aws_volume_attachment.ebsAttach
    ]
    connection {
        type     = "ssh"
        user     = "ec2-user"
        private_key = tls_private_key.keyGenerate.private_key_pem
        host     = aws_instance.web.public_ip
    }

    provisioner "remote-exec" {
        inline = [
            "sudo mkfs.ext4 /dev/xvdh",
            "sudo mount /dev/xvdh  /var/www/html/",
            "sudo rm -rvf /var/www/html/*",
            "sudo git clone https://github.com/surinder2000/web1.git /var/www/html/"
        ]
    }
}

#Create S3 bucket 
resource "aws_s3_bucket" "webBucket" {
    bucket = "surin-bucket"
    acl = "private"
	force_destroy = true
    tags = {
        Name = "Web-bucket"
  }
}

locals {
    s3_origin_id = "S3-surin-bucket"
}

#Copy static data of web to S3 bucket
resource "null_resource" "copyS3" {
    depends_on = [
        aws_s3_bucket.webBucket
    ]
	
    provisioner "local-exec" {
        command = "aws s3 cp  /media/surinder/Ubuntu/DevOps/images/  s3://${aws_s3_bucket.webBucket.bucket}  --recursive"
    }

}

#Create cloudfront origin access identity
resource "aws_cloudfront_origin_access_identity" "originAccessIdentity" {
    comment = "access-identity-surin-bucket"
}

#Create cloudfront distribution for s3 bucket
resource "aws_cloudfront_distribution" "s3Distribution" {
	depends_on = [
		aws_s3_bucket.webBucket,
		aws_cloudfront_origin_access_identity.originAccessIdentity
	]
    origin {
        domain_name = aws_s3_bucket.webBucket.bucket_regional_domain_name
        origin_id   = local.s3_origin_id

    s3_origin_config {
        origin_access_identity = "origin-access-identity/cloudfront/${aws_cloudfront_origin_access_identity.originAccessIdentity.id}"
    }
}

    enabled             = true
    is_ipv6_enabled     = true

    default_cache_behavior {
        allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
        cached_methods   = ["GET", "HEAD"]
        target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    }

    wait_for_deployment = false
    restrictions {
        geo_restriction {
            restriction_type = "whitelist"
            locations        = ["US", "CA", "IN"]
        }
    }

    tags = {
        Environment = "Production"
    }

    viewer_certificate {
        cloudfront_default_certificate = true
    }
}

#Create bucket read policy
data "aws_iam_policy_document" "s3Policy" {
    statement {
        actions   = ["s3:GetObject"]
        resources = ["${aws_s3_bucket.webBucket.arn}/*"]

        principals {
            type        = "AWS"
            identifiers = ["${aws_cloudfront_origin_access_identity.originAccessIdentity.iam_arn}"]
        }
    }

    statement {
        actions   = ["s3:ListBucket"]
        resources = ["${aws_s3_bucket.webBucket.arn}"]

        principals {
            type        = "AWS"
            identifiers = ["${aws_cloudfront_origin_access_identity.originAccessIdentity.iam_arn}"]
        }
    }
}

#Attach bucket read policy
resource "aws_s3_bucket_policy" "bucketReadPolicy" {
    depends_on = [
        aws_s3_bucket.webBucket
    ]
    bucket = aws_s3_bucket.webBucket.id
    policy = data.aws_iam_policy_document.s3Policy.json
}

#Update url in web page
resource "null_resource" "updateURL" {
    depends_on = [
        aws_cloudfront_distribution.s3Distribution,
        aws_instance.web,
        null_resource.mountEbs
    ]

    connection {
        type     = "ssh"
        user     = "ec2-user"
        private_key = tls_private_key.keyGenerate.private_key_pem
        host     = aws_instance.web.public_ip
    }

    provisioner "remote-exec" {
        inline = [
			"sudo sed -i 's|url|https://${aws_cloudfront_distribution.s3Distribution.domain_name}|g' /var/www/html/first.html"
        ]
    }
}
output "Webip" {
    value = aws_instance.web.public_ip
}

output "Cloudfrontdomain" {
	value = aws_cloudfront_distribution.s3Distribution.domain_name
}

#Show site
resource "null_resource" "showSite" {
    depends_on = [
        aws_cloudfront_distribution.s3Distribution,
	    null_resource.updateURL
    ]
	
    provisioner "local-exec" {
        command = "firefox http://${aws_instance.web.public_ip}/index.html &"
    }

}
