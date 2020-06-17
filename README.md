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

## Let's get started creating this infrastrucutre

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

* 

