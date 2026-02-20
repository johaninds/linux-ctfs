# Configure the AWS Provider
# Define the region variable
variable "aws_region" {
  description = "The AWS region to deploy the CTF lab"
  type        = string
  default     = "us-east-1" # Default region if not specified
}

variable "use_local_setup" {
  description = "Use local ctf_setup.sh instead of fetching from GitHub (for testing)"
  type        = bool
  default     = false
}


# Configure the AWS Provider with the variable region
provider "aws" {
  region = var.aws_region
}

# Compress the setup script to fit within AWS user_data limit (16KB limit for base64)
data "external" "compressed_setup" {
  count   = var.use_local_setup ? 1 : 0
  program = ["bash", "-c", "jq -n --arg data \"$(gzip -c ${path.module}/../ctf_setup.sh | base64)\" '{compressed: $data}'"]
}

# Fetch availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Create a VPC
resource "aws_vpc" "ctf_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "CTF Lab VPC"
  }
}

# Create an Internet Gateway
resource "aws_internet_gateway" "ctf_igw" {
  vpc_id = aws_vpc.ctf_vpc.id

  tags = {
    Name = "CTF Lab IGW"
  }
}

# Create a Subnet
resource "aws_subnet" "ctf_subnet" {
  vpc_id            = aws_vpc.ctf_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "CTF Lab Subnet"
  }
}

# Create a Route Table
resource "aws_route_table" "ctf_route_table" {
  vpc_id = aws_vpc.ctf_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ctf_igw.id
  }

  tags = {
    Name = "CTF Lab Route Table"
  }
}

# Associate the Route Table with the Subnet
resource "aws_route_table_association" "ctf_route_table_assoc" {
  subnet_id      = aws_subnet.ctf_subnet.id
  route_table_id = aws_route_table.ctf_route_table.id
}

# Create a Security Group
resource "aws_security_group" "ctf_sg" {
  name        = "ctf_sg"
  description = "Security group for CTF lab"
  vpc_id      = aws_vpc.ctf_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8083
    to_port     = 8083
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
    Name = "CTF Lab Security Group"
  }
}


# Create an EC2 Instance
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_instance" "ctf_instance" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.small"

  vpc_security_group_ids = [aws_security_group.ctf_sg.id]
  subnet_id              = aws_subnet.ctf_subnet.id

  associate_public_ip_address = true

  # Use local file for testing, GitHub for production
  # AWS supports gzip-compressed user_data (cloud-init auto-decompresses)
  user_data_base64 = var.use_local_setup ? data.external.compressed_setup[0].result.compressed : base64encode(<<-EOF
    #!/bin/bash
    EBS_MOUNT="/mnt/ctf_ebs"
    EBS_DEVICE=""

    # Wait up to 60s for EBS to be attached
    for i in $(seq 1 30); do
      if [ -b "/dev/nvme1n1" ]; then
        EBS_DEVICE="/dev/nvme1n1"
        break
      elif [ -b "/dev/xvdf" ]; then
        EBS_DEVICE="/dev/xvdf"
        break
      fi
      sleep 2
    done

    # Mount EBS and set up persistent state directories
    if [ -n "$EBS_DEVICE" ]; then
      if ! blkid "$EBS_DEVICE" > /dev/null 2>&1; then
        mkfs.ext4 -F "$EBS_DEVICE"
      fi
      mkdir -p "$EBS_MOUNT"
      mount "$EBS_DEVICE" "$EBS_MOUNT"
      mkdir -p "$EBS_MOUNT/ctf_state" "$EBS_MOUNT/ctf_progress"
      # Auto-mount on reboot
      echo "$EBS_DEVICE $EBS_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
    else
      # Fallback so setup doesn't crash if volume fails to attach
      mkdir -p "$EBS_MOUNT/ctf_state" "$EBS_MOUNT/ctf_progress"
    fi

    # Download ctf_setup.sh
    curl -fsSL https://raw.githubusercontent.com/learntocloud/linux-ctfs/main/ctf_setup.sh -o /tmp/ctf_setup.sh

    # Setup /var/ctf symlink to EBS BEFORE running setup script
    # This ensures all start times and progress files written by ctf_setup.sh go directly to EBS
    if mountpoint -q "$EBS_MOUNT"; then
      mkdir -p /var/ctf
      if [ ! -f "$EBS_MOUNT/ctf_progress/completed_challenges" ]; then
        # On first run, we have no progress to copy but we link it anyway
        true
      fi
      rm -rf /var/ctf
      ln -sf "$EBS_MOUNT/ctf_progress" /var/ctf
    fi

    # Patch ctf_setup.sh to persist/restore INSTANCE_SUFFIX and INSTANCE_ID from EBS
    # We write the python script via base64 to avoid ANY Terraform heredoc escaping issues
    echo 'aW1wb3J0IHJlCgp3aXRoIG9wZW4oJy90bXAvY3RmX3NldHVwLnNoJywgJ3InKSBhcyBmOgogICAgY29udGVudCA9IGYucmVhZCgpCgojIFJlcGxhY2UgZ2VuZXJhdGVfZmxhZ19zdWZmaXgoKSB0byByZXN0b3JlIGZyb20gRUJTIG9yIGdlbmVyYXRlK3NhdmUgbmV3IG9uZQpvbGRfZm4gPSAnZ2VuZXJhdGVfZmxhZ19zdWZmaXgoKSB7XG4gICAgaGVhZCAtYyA0IC9kZXYvdXJhbmRvbSB8IHh4ZCAtcFxufScKbmV3X2ZuID0gJycnZ2VuZXJhdGVfZmxhZ19zdWZmaXgoKSB7CiAgICBpZiBbIC1mIC9tbnQvY3RmX2Vicy9jdGZfc3RhdGUvc3VmZml4IF07IHRoZW4KICAgICAgICBjYXQgL21udC9jdGZfZWJzL2N0Zl9zdGF0ZS9zdWZmaXgKICAgIGVsc2UKICAgICAgICBsb2NhbCBzCiAgICAgICAgcz0kKGhlYWQgLWMgNCAvZGV2L3VyYW5kb20gfCB4eGQgLXApCiAgICAgICAgZWNobyAiJHMiID4gL21udC9jdGZfZWJzL2N0Zl9zdGF0ZS9zdWZmaXgKICAgICAgICBlY2hvICIkcyIKICAgIGZpCn0nJycKY29udGVudCA9IGNvbnRlbnQucmVwbGFjZShvbGRfZm4sIG5ld19mbikKCiMgUmVwbGFjZSBJTlNUQU5DRV9JRCBnZW5lcmF0aW9uIHRvIHJlc3RvcmUgZnJvbSBFQlMgb3IgZ2VuZXJhdGUrc2F2ZSBuZXcgb25lCm9sZF9pZCA9ICdJTlNUQU5DRV9JRD0kKGhlYWQgLWMgMTYgL2Rldi91cmFuZG9tIHwgeHhkIC1wKScKbmV3X2lkID0gJ0lOU1RBTkNFX0lEPSQoY2F0IC9tbnQvY3RmX2Vicy9jdGZfc3RhdGUvaW5zdGFuY2VfaWQgMi4vZGV2L251bGwgfHwgKGhlYWQgLWMgMTYgL2Rldi91cmFuZG9tIHwgeHhkIC1wIHwgdGVlIC9tbnQvY3RmX2Vicy9jdGZfc3RhdGUvaW5zdGFuY2VfaWQpKScKY29udGVudCA9IGNvbnRlbnQucmVwbGFjZShvbGRfaWQsIG5ld19pZCkKCndpdGggb3BlbignL3RtcC9jdGZfc2V0dXAuc2gnLCAndzcpIGFzIGY6CiAgICBmLndyaXRlKGNvbnRlbnQpCg==' | base64 -d > /tmp/patch.py
    python3 /tmp/patch.py

    bash /tmp/ctf_setup.sh

  EOF
  )

  tags = {
    Name = "CTF Lab Instance"
  }
}

# Persistent EBS volume — survives terraform destroy via destroy.sh
resource "aws_ebs_volume" "ctf_data" {
  availability_zone = data.aws_availability_zones.available.names[0]
  size              = 10 # GB
  type              = "gp3"

  tags = {
    Name = "CTF Lab Data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Attach the EBS volume to the EC2 instance
resource "aws_volume_attachment" "ctf_data_attach" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.ctf_data.id
  instance_id = aws_instance.ctf_instance.id

  # Do not detach/destroy the volume when the attachment resource is removed
  skip_destroy = true
}

resource "null_resource" "wait_for_setup" {
  depends_on = [aws_instance.ctf_instance]

  provisioner "remote-exec" {
    connection {
      type     = "ssh"
      host     = aws_instance.ctf_instance.public_ip
      user     = "ctf_user"
      password = "CTFpassword123!"
      timeout  = "15m"
    }

    inline = [
      "while [ ! -f /var/log/setup_complete ]; do sleep 10; done"
    ]
  }
}

# Output the public IP of the instance
output "public_ip_address" {
  value = aws_instance.ctf_instance.public_ip
}

# Output the persistent EBS volume ID
output "ctf_ebs_volume_id" {
  value       = aws_ebs_volume.ctf_data.id
  description = "Persistent EBS volume ID — stays alive across terraform destroy"
}
