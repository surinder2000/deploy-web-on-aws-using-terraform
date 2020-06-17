# Deploy website on AWS cloud using Terraform
Creating infrastructure for deploying website on AWS cloud using Terraform (Infrastructure as code)

## Prerequisites 
* Must have AWS cli configured
* Must have AWS IAM user created 
* Must have terraform configured
* Must have git installed


## Infrastructure includes:-
* Key pair
* Security group 
* EC2 instance
* EBS Volume
* S3 bucket
* Cloudfront distribution

## Let's start creating the infrastrucutre

1. Create a user profile to access AWS by terraform
* Run the following command on AWS cli to create user profile
        
      aws configure --profile myprofile (myprofile is a profile name)
      
  After running this command we need to provide **AWS Access Key ID** and **AWS Secret Access Key** and these keys are in credentials.csv file. We get this file when we create IAM user. Also provide **Default region name** and leave **Default output format**
  
2. Create one file with **.tf** extension and write complete code in this file
* Code for provider and user configuration

        provider "aws" {
            region = "ap-south-1"
            profile = "myprofile"
        }
      
* Code for generating key pair and also save it in local system

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
    
* Code for creating a security group and allow port no. 80 and 22

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

* Code fior launching EC2 instance and configure apache webserver

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
        
* Code for creating EBS volume of size 1GB

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

* Code for attaching EBS volume with the instance

        resource "aws_volume_attachment" "ebsAttach" {
            depends_on = [
                aws_ebs_volume.ebsWebVol
            ]
            device_name = "/dev/sdh"
            volume_id   = aws_ebs_volume.ebsWebVol.id
            instance_id = aws_instance.web.id
            force_detach = true
        }
        
* Code for mounting EBS volume with /var/www/html directory and pull the web pages from github repository

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

* Code for creating S3 bucket 

        resource "aws_s3_bucket" "webBucket" {
            bucket = "surin-bucket"
            acl = "private"
                force_destroy = true
            tags = {
                Name = "Web-bucket"
          }
        }
        
* Code for uploading static data of webpages like images to S3 bucket

        resource "null_resource" "copyS3" {
            depends_on = [
                aws_s3_bucket.webBucket
            ]

            provisioner "local-exec" {
                command = "aws s3 cp  /media/surinder/Ubuntu/DevOps/images/  s3://${aws_s3_bucket.webBucket.bucket}  --recursive"
            }

        }

* Code for creating cloudfront origin access identity which is required for creating cloudfront distribution for S3 bucket
        
        resource "aws_cloudfront_origin_access_identity" "originAccessIdentity" {
            comment = "access-identity-surin-bucket"
        }

* Code or creating cloudfront distribution for S3 bucket

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

* Code for creating bucket access policy

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

* Code for writing bucket policy
        
        resource "aws_s3_bucket_policy" "bucketReadPolicy" {
            depends_on = [
                aws_s3_bucket.webBucket
            ]
            bucket = aws_s3_bucket.webBucket.id
            policy = data.aws_iam_policy_document.s3Policy.json
        }

* Code for putting cloudfront distribution URL of the images in the web pages
        
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

* Code for displaying the website on the firefox browser

        resource "null_resource" "showSite" {
            depends_on = [
                aws_cloudfront_distribution.s3Distribution,
                null_resource.updateURL
            ]

            provisioner "local-exec" {
                command = "firefox http://${aws_instance.web.public_ip}/index.html &"
            }

        }
        

  This is the complete code for the required infrastructure
  
3. Run the following commands to apply this infrastructure
        
        terraform init 
        
   This command download all the required plugins for launching this infrastructure

        terraform validate
        
   This command validate the code
   
        terraform apply -auto-approve
        
   This command launch complete infrastructure
   
4. Run the following command to destroy complete infrastructure in one go

        terraform destroy -auto-approve
        
   We can integrate terraform with Jenkins for performing 3 and 4 step. By just committing the code of infrastructure from git, the code will automatically push to Github and the complete process of launching infrastructure will be done by Jenkins. 
   
### Integrating terraform with Jenkins for launching the infrastructure
#### Let's start creating the Jenkins jobs
##### Job 1. Pull the code from Github repository and copy it to one directory
* In Source Control Management section put the Github repository url and branch name

![Git configuration](https://github.com/surinder2000/deploy-web-on-aws-using-terraform/blob/master/job11.png)

* In Build trigger section select Poll SCM for checking the github repository every minute

![Build trigger](https://github.com/surinder2000/deploy-web-on-aws-using-terraform/blob/master/job12.png)

* In the Build section from Add build step select Execute shell and put the following code in the command box

![Execute shell](https://github.com/surinder2000/deploy-web-on-aws-using-terraform/blob/master/job13.png)

* Click on Apply and Save


##### Job 2. Install required plugins for launching infrastructure and also validate the code

* In Build trigger section select Build after other projects are built and put the name of Job 1 in the Project to watch box and check Trigger only if build is stable

![Build trigger](https://github.com/surinder2000/deploy-web-on-aws-using-terraform/blob/master/job21.png)

* In the Build section from Add build step select Execute shell and put the following code in the command box

![Execute shell](https://github.com/surinder2000/deploy-web-on-aws-using-terraform/blob/master/job22.png)

* Click on Apply and Save


##### Job 3. Launch infrastructure

* In Build trigger section select Build after other projects are built and put the name of Job 2 in the Project to watch box and check Trigger only if build is stable

![Build trigger](https://github.com/surinder2000/deploy-web-on-aws-using-terraform/blob/master/job31.png)

* In the Build section from Add build step select Execute shell and put the following code in the command box

![Execute shell](https://github.com/surinder2000/deploy-web-on-aws-using-terraform/blob/master/job32.png)

* Click on Apply and Save


##### Job 4. Destroy infrastructure

* In the Build Triggers section select Trigger builds remotely, put Authentication Token in the box, then the following url is used for triggering the job

        JENKINS_URL/job/Destroy%20infrastructure/build?token=TOKEN_NAME

![Build trigger](https://github.com/surinder2000/deploy-web-on-aws-using-terraform/blob/master/job41.png)

* In the Build section from Add build step select Execute shell and put the following code in the command box

![Execute shell](https://github.com/surinder2000/deploy-web-on-aws-using-terraform/blob/master/job42.png)

* Click on Apply and Save


  That's it our setup is ready
  
  Now as soon as the code is committed from git, it automatically pushed the code into the github repository and Job 1 of the Jenkins triggered which pull the code from Github and copy it into one directory. If Job 1 successfully build then Job 2 triggered and it installs the required plugins for launching infrastructure and validate the code. If Job 2 successfully build then Job 3 triggered and it launches the infrastructure.
  
  To destroy the infrastructure just trigger the Job 4 by executing the url provided by Job 4
  
  This is the Build pipeline view of the Jenkins jobs
  
  ![Build pipeline view](https://github.com/surinder2000/deploy-web-on-aws-using-terraform/blob/master/buildpipelineview.png)
  
  

        

        

        


        

