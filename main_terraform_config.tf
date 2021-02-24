terraform {
  backend "remote" {
    organization = "Cloudyrion"

    workspaces {
      name = "stan"
    }
  }
}


#--- Create VPC ---

resource "aws_vpc" "cicd_vpc" {
  cidr_block       = "10.10.0.0/16"
  tags = {
    Name = "cicd_vpc"
  }
}



#--- Create Internet Gateway


resource "aws_internet_gateway" "cicd_vpc_igw" {
 vpc_id = "${aws_vpc.cicd_vpc.id}"
 tags = {
    Name = "cicd_vpc-igw"
 }
}




# --- Create Elastic IP ---


resource "aws_eip" "eip" {
  vpc=true
    tags = {
    Name = "cicd_vpc-eip"

      }
}

data "aws_availability_zones" "available" {} #var for availability zones



#--- Create Public Subnet ---


resource "aws_subnet" "publicSubn" {
  availability_zone = "${data.aws_availability_zones.available.names[0]}"
  cidr_block        = "10.10.1.0/24"
  vpc_id            = "${aws_vpc.cicd_vpc.id}"
  map_public_ip_on_launch = "true"
  tags = {
    Name = "cicd_vpc-publicSubn"

      }
    }


    #--- Create Private Subnet ---


resource "aws_subnet" "privSubn" {
      availability_zone = "${data.aws_availability_zones.available.names[1]}"
      cidr_block = "10.10.2.0/24"
      vpc_id = "${aws_vpc.cicd_vpc.id}"
      tags = {
        "Name" = "cicd_vpc-privSubn"
      }
    }


# --------------  NAT Gateway

resource "aws_nat_gateway" "cicd_vpc-ngw" {
  allocation_id = "${aws_eip.eip.id}"
  subnet_id = "${aws_subnet.publicSubn.id}"
  tags = {
      Name = "cicd_vpc Nat Gateway"
  }
}


# ------------------- Routing ----------


resource "aws_route_table" "cicd_vpc-public-route" {
  vpc_id =  "${aws_vpc.cicd_vpc.id}"
  route {
      cidr_block = "0.0.0.0/0"
      gateway_id = "${aws_internet_gateway.cicd_vpc_igw.id}"
  }

   tags = {
       Name = "cicd_vpc-public-route"
   }
}


resource "aws_default_route_table" "cicd-default-route" {
  default_route_table_id = "${aws_vpc.cicd_vpc.default_route_table_id}"
  tags = {
      Name = "cicd_vpc-default-route"
  }
}




#--- Subnet Association -----

resource "aws_route_table_association" "arts_pubSebnet" {
  subnet_id = "${aws_subnet.publicSubn.id}"
  route_table_id = "${aws_route_table.cicd_vpc-public-route.id}"
}


resource "aws_route_table_association" "arts_privSebnet" {
  subnet_id = "${aws_subnet.privSubn.id}"
  route_table_id = "${aws_vpc.cicd_vpc.default_route_table_id}"
}


#--- Create Security Group  -----

resource "aws_security_group" "securitygroup_private_instances" {
  name = "securitygroup_pricate_instances"
  description = "in_and_outbound_FW"
  vpc_id = "${aws_vpc.cicd_vpc.id}"
  ingress { #inbound
  	description = "Allow SSH in"
    cidr_blocks = ["0.0.0.0/0"]
    from_port = 22
    to_port = 22
    protocol = "tcp"
  }

  #check required: Do we really need outbound for our security group inside privSubn?
  egress { #outbound
    cidr_blocks = ["0.0.0.0/0"]
    from_port = 0
    to_port = 0
    protocol = "-1"
  }
  tags = {
    Name = "securitygroup_private_instances"
  }
}



  #--- Create EC2 ----

resource "aws_instance" "com_1" {
  instance_type = "t2.micro"
  ami = "ami-0a6dc7529cd559185" #Amazon Linux 2 AMI (HVM), SSD Volume Type (64-bit x86)


  #reference: into subnet
  subnet_id 		= "${aws_subnet.privSubn.id}"

  #reference: into security group
  security_groups 	= [aws_security_group.securitygroup_private_instances.id]

  #reference: key-pair for instance
  key_name 					= "coms_pipeline_key"

  #actually it is false by default, but lets specify it anyways
  #fyi: it allows to terminate the instance via cli (bad if done by accident)
  disable_api_termination = false

  #EBS–optimized instances deliver dedicated bandwidth to Amazon EB
  #Not required
  ebs_optimized = false


  tags = {
    Name = "com_1"
  }
}

output "instance_private_ip" {
  value = aws_instance.com_1.private_ip
}

 #--- Create AWS EKS Cluster ----

data "aws_eks_cluster" "cluster" {
  name = module.cicd_cluster.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.cicd_cluster.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
  version                = "~> 1.9"
}

module "cicd_cluster" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = "cicd_cluster"
  cluster_version = "1.17"
  subnets         = ["cicd_vpc-publicSubn"]
  vpc_id          = "cicd_vpc"

  worker_groups = [
    {
      instance_type = "m4.large"
      asg_max_size  = 5
    }
  ]
}
