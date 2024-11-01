#!/bin/bash
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="036855062023"
VPC_CIDR="172.16.0.0/16"
SUBNET_PUBLIC1_CIDR="172.16.1.0/24"
SUBNET_PUBLIC2_CIDR="172.16.2.0/24"
SUBNET_PRIVATE1_CIDR="172.16.3.0/24"
SUBNET_PRIVATE2_CIDR="172.16.4.0/24"
# Cấu hình AWS CLI (chỉ cần làm một lần, bỏ qua nếu đã có cấu hình)
# aws configure
# Tạo VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --region $AWS_REGION --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=main-vpc
# Tạo Subnets
SUBNET_PUBLIC1_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PUBLIC1_CIDR --availability-zone ${AWS_REGION}a --query 'Subnet.SubnetId' --output text)
SUBNET_PUBLIC2_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PUBLIC2_CIDR --availability-zone ${AWS_REGION}b --query 'Subnet.SubnetId' --output text)
SUBNET_PRIVATE1_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PRIVATE1_CIDR --availability-zone ${AWS_REGION}a --query 'Subnet.SubnetId' --output text)
SUBNET_PRIVATE2_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PRIVATE2_CIDR --availability-zone ${AWS_REGION}b --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_PUBLIC1_ID --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_PUBLIC2_ID --map-public-ip-on-launch
# Tạo Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --region $AWS_REGION --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=main-igw
# Tạo Public Route Table và Route
RT_PUBLIC_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $AWS_REGION --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PUBLIC_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --subnet-id $SUBNET_PUBLIC1_ID --route-table-id $RT_PUBLIC_ID
aws ec2 associate-route-table --subnet-id $SUBNET_PUBLIC2_ID --route-table-id $RT_PUBLIC_ID
aws ec2 create-tags --resources $RT_PUBLIC_ID --tags Key=Name,Value=public-rt
# Tạo NAT Instance
AMI_ID=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" --query 'Images[0].ImageId' --output text)
SG_NAT_ID=$(aws ec2 create-security-group --group-name nat-sg --description "NAT Security Group" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_NAT_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_NAT_ID --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_NAT_ID --protocol -1 --cidr 0.0.0.0/0
USER_DATA=$(cat <<EOF
#!/bin/bash
sudo yum update -y
sudo yum install iptables-services -y
sudo systemctl enable iptables
sudo systemctl start iptables
sudo echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/custom-ip-forwarding.conf
sudo sysctl -p /etc/sysctl.d/custom-ip-forwarding.conf
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo /sbin/iptables -F FORWARD
sudo service iptables save
EOF
)
NAT_INSTANCE_ID=$(aws ec2 run-instances --image-id $AMI_ID --instance-type t2.micro --subnet-id $SUBNET_PUBLIC1_ID --security-group-ids $SG_NAT_ID --associate-public-ip-address --user-data "$USER_DATA" --query 'Instances[0].InstanceId' --output text)
aws ec2 create-tags --resources $NAT_INSTANCE_ID --tags Key=Name,Value=nat_instance
aws ec2 wait instance-running --instance-ids $NAT_INSTANCE_ID

aws ec2 modify-instance-attribute --instance-id $NAT_INSTANCE_ID --no-source-dest-check
# Gán Elastic IP cho NAT Instance
EIP_ALLOC_ID=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
aws ec2 associate-address --allocation-id $EIP_ALLOC_ID --instance-id $NAT_INSTANCE_ID
aws ec2 create-tags --resources $EIP_ALLOC_ID --tags Key=Name,Value=nat-eip
# Tạo Private Route Table và Route

RT_PRIVATE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $AWS_REGION --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PRIVATE_ID --destination-cidr-block 0.0.0.0/0 --instance-id $NAT_INSTANCE_ID
aws ec2 associate-route-table --subnet-id $SUBNET_PRIVATE1_ID --route-table-id $RT_PRIVATE_ID
aws ec2 associate-route-table --subnet-id $SUBNET_PRIVATE2_ID --route-table-id $RT_PRIVATE_ID
aws ec2 create-tags --resources $RT_PRIVATE_ID --tags Key=Name,Value=private-rt
# Tạo repository trên ECR 
aws ecr describe-repositories --repository-names nginx-php > /dev/null 2>&1
if [ $? -ne 0 ]; then
  aws ecr create-repository --repository-name nginx-php --region $AWS_REGION
fi
aws ecr describe-repositories --repository-names mysql > /dev/null 2>&1
if [ $? -ne 0 ]; then
  aws ecr create-repository --repository-name mysql --region $AWS_REGION
fi

# Đăng nhập vào ECR

$(aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com)
# Xây dựng và đẩy Docker images
# Xây dựng và đẩy nginx-php
cd nginx-php
docker build -t nginx-php:latest .
docker tag nginx-php:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/nginx-php:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/nginx-php:latest
cd ..
# Xây dựng và đẩy mysql
cd mysql
docker build -t mysql:latest .
docker tag mysql:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/mysql:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/mysql:latest
cd ..
echo "Docker images đã được xây dựng và đẩy lên ECR thành công!"

# Xây dựng và đẩy task definition
aws ecs register-task-definition --cli-input-json file://task-definition.json --region us-east-1
echo "Task definition đã được xây dựng và đẩy lên ECS thành công!"
# Tạo ECS Cluster
aws ecs create-cluster --cluster-name main-cluster --region $AWS_REGION
echo "Created ECS cluster: main-cluster"
# Tạo Application Load Balancer (ALB)
ALB=$(aws elbv2 create-load-balancer --name ecs-load-balancer --subnets $SUBNET_PUBLIC1_ID $SUBNET_PUBLIC2_ID --security-groups $SG_NAT_ID --region $AWS_REGION --query 'LoadBalancers[0].LoadBalancerArn' --output text)
echo "Created ALB: $ALB"
# Tạo Target Group
TARGET_GROUP=$(aws elbv2 create-target-group --name ecs-target-group --protocol HTTP --port 80 --vpc-id $VPC_ID --region $AWS_REGION --health-check-path / --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "Created Target Group: $TARGET_GROUP"
# Tạo Listener cho ALB
aws elbv2 create-listener --load-balancer-arn $ALB --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP --region $AWS_REGION
echo "Created Listener for ALB"
# Tạo ECS Service
aws ecs create-service --cluster main-cluster --service-name tinlt-service --task-definition Tinlt --desired-count 1 --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_PUBLIC1_ID,$SUBNET_PUBLIC2_ID],securityGroups=[$SG_NAT_ID],assignPublicIp=ENABLED}" --load-balancers "targetGroupArn=$TARGET_GROUP,containerName=nginx,containerPort=80" --region $AWS_REGION
echo "Created ECS service: tinlt-service"
echo "Deployment complete!"