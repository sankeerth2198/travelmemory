#!/usr/bin/env bash
# TravelMemory EC2 deployment via AWS CLI.
# Usage:  export VPC_ID=vpc-xxxx MONGO_URI='mongodb+srv://...'
#         ./deploy.sh backend    # SGs, backend-master, AMI, backend-2, backend ALB
#         ./deploy.sh frontend   # frontend-master, AMI, frontend-2, frontend ALB
#         ./deploy.sh cleanup    # delete everything (stop billing)
set -euo pipefail
export AWS_PAGER="" AWS_DEFAULT_REGION=ap-south-1
REGION=ap-south-1
KEY_NAME="${KEY_NAME:-test1}"          # key pair NAME (not the .pem filename)
MY_IP="13.127.127.237/32"
ITYPE="${ITYPE:-t3.micro}"
STATE=./state.env
: "${VPC_ID:?export VPC_ID=vpc-xxxx}"
touch "$STATE"; source "$STATE"
save() { echo "export $1='$2'" >> "$STATE"; eval "export $1='$2'"; }
tag() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2}]"; }

UBUNTU_AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id --query Parameter.Value --output text)

# two public subnets in different AZs
pick_subnets() {
  [ -n "${SUBNET_A:-}" ] && return
  read -r A B < <(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
    --query 'Subnets[].[AvailabilityZone,SubnetId]' --output text | sort -u -k1,1 | awk '{print $2}' | head -2 | tr '\n' ' '; echo)
  [ -n "${B:-}" ] || { echo "Need 2 subnets in different AZs in $VPC_ID"; exit 1; }
  save SUBNET_A "$A"; save SUBNET_B "$B"
}

launch() { # name subnet sg userdata-file ami
  aws ec2 run-instances --image-id "$5" --instance-type $ITYPE --key-name $KEY_NAME \
    --subnet-id "$2" --security-group-ids "$3" --associate-public-ip-address \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3}' \
    ${4:+--user-data file://$4} --tag-specifications "$(tag instance $1)" \
    --query 'Instances[0].InstanceId' --output text
}
ip_of() { aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }
wait_http() { echo "Waiting for $1 ..."; for i in $(seq 1 120); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1")" = 200 ] && { echo OK; return; }; sleep 10; done; echo "TIMEOUT: $1"; exit 1; }
make_ami() { # instance name
  local id; id=$(aws ec2 create-image --instance-id "$1" --name "$2" --query ImageId --output text)
  aws ec2 wait image-available --image-ids "$id"; echo "$id"; }
make_alb() { # prefix(backend|frontend) healthpath id1 id2 ; sets <PREFIX>_ALB_DNS
  local p=$1 tg alb
  tg=$(aws elbv2 create-target-group --name travelmemory-$p-tg --protocol HTTP --port 80 --vpc-id $VPC_ID \
       --health-check-path "$2" --query 'TargetGroups[0].TargetGroupArn' --output text)
  aws elbv2 register-targets --target-group-arn "$tg" --targets Id=$3 Id=$4
  alb=$(aws elbv2 create-load-balancer --name travelmemory-$p-alb --subnets $SUBNET_A $SUBNET_B \
       --security-groups $ALB_SG --scheme internet-facing --type application --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  aws elbv2 create-listener --load-balancer-arn "$alb" --protocol HTTP --port 80 \
       --default-actions Type=forward,TargetGroupArn="$tg" >/dev/null
  save "${p^^}_TG" "$tg"; save "${p^^}_ALB" "$alb"
  save "${p^^}_ALB_DNS" "$(aws elbv2 describe-load-balancers --load-balancer-arns "$alb" --query 'LoadBalancers[0].DNSName' --output text)"
  aws elbv2 wait load-balancer-available --load-balancer-arns "$alb"
  aws elbv2 wait target-in-service --target-group-arn "$tg" --targets Id=$3 Id=$4
}

NGINX_PROXY='server { listen 80 default_server; server_name _;
  location / { proxy_pass http://localhost:3000; proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; } }'
NGINX_SPA='server { listen 80 default_server; server_name _; root /var/www/html; index index.html;
  location / { try_files $uri /index.html; } }'

stage_backend() {
  : "${MONGO_URI:?export MONGO_URI='mongodb+srv://user:pass@cluster0.xxxx.mongodb.net/travelmemory?retryWrites=true&w=majority'}"
  pick_subnets
  if [ -z "${ALB_SG:-}" ]; then
    save ALB_SG "$(aws ec2 create-security-group --group-name travelmemory-alb-sg --description alb --vpc-id $VPC_ID --query GroupId --output text)"
    aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
    for t in backend frontend; do
      sg=$(aws ec2 create-security-group --group-name travelmemory-$t-sg --description $t --vpc-id $VPC_ID --query GroupId --output text)
      save "${t^^}_SG" "$sg"
      aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 80 --source-group $ALB_SG >/dev/null
      aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 80 --cidr $MY_IP >/dev/null   # direct test; remove later
      aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 22 --cidr $MY_IP >/dev/null
    done
  fi
  cat > ud-backend.sh << UD
#!/bin/bash
set -ex
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs git nginx
cd /home/ubuntu
sudo -u ubuntu git clone https://github.com/UnpredictablePrashant/TravelMemory.git
cd TravelMemory/backend
sudo -u ubuntu npm install
cat > .env << 'ENV'
MONGO_URI=$MONGO_URI
PORT=3000
ENV
chown ubuntu:ubuntu .env; chmod 600 .env
cat > /etc/systemd/system/travelmemory-backend.service << 'SVC'
[Unit]
Description=TravelMemory Backend
After=network.target
[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/TravelMemory/backend
EnvironmentFile=/home/ubuntu/TravelMemory/backend/.env
ExecStart=/usr/bin/node index.js
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload && systemctl enable --now travelmemory-backend
cat > /etc/nginx/sites-available/default << 'NG'
$NGINX_PROXY
NG
nginx -t && systemctl restart nginx
UD
  chmod 600 ud-backend.sh
  [ -n "${BE1:-}" ] || save BE1 "$(launch backend-master $SUBNET_A $BACKEND_SG ud-backend.sh $UBUNTU_AMI)"
  aws ec2 wait instance-running --instance-ids $BE1
  BE1_IP=$(ip_of $BE1); echo "backend-master: $BE1_IP"
  wait_http "http://$BE1_IP/hello"
  echo ">> Screenshot: instance, 'systemctl status travelmemory-backend', curl /hello"
  [ -n "${BACKEND_AMI:-}" ] || save BACKEND_AMI "$(make_ami $BE1 travelmemory-backend-ami)"
  [ -n "${BE2:-}" ] || save BE2 "$(launch backend-2 $SUBNET_B $BACKEND_SG "" $BACKEND_AMI)"
  aws ec2 wait instance-running --instance-ids $BE2
  wait_http "http://$(ip_of $BE2)/hello"
  [ -n "${BACKEND_TG:-}" ] || make_alb backend /hello $BE1 $BE2
  wait_http "http://$BACKEND_ALB_DNS/hello"
  echo "Backend ALB: http://$BACKEND_ALB_DNS   -> now run: ./deploy.sh frontend"
}

stage_frontend() {
  : "${BACKEND_ALB_DNS:?run backend stage first}"
  cat > ud-frontend.sh << UD
#!/bin/bash
set -ex
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs git nginx
cd /home/ubuntu
sudo -u ubuntu git clone https://github.com/UnpredictablePrashant/TravelMemory.git
cd TravelMemory/frontend
sudo -u ubuntu sed -i 's|^export const baseUrl.*|export const baseUrl = "http://$BACKEND_ALB_DNS";|' src/url.js
sudo -u ubuntu npm install
sudo -u ubuntu NODE_OPTIONS=--max-old-space-size=1024 npm run build
rm -rf /var/www/html/*; cp -r build/* /var/www/html/
cat > /etc/nginx/sites-available/default << 'NG'
$NGINX_SPA
NG
nginx -t && systemctl restart nginx
UD
  [ -n "${FE1:-}" ] || save FE1 "$(launch frontend-master $SUBNET_A $FRONTEND_SG ud-frontend.sh $UBUNTU_AMI)"
  aws ec2 wait instance-running --instance-ids $FE1
  FE1_IP=$(ip_of $FE1); echo "frontend-master: $FE1_IP (build takes ~5-10 min)"
  wait_http "http://$FE1_IP/"
  echo ">> Open http://$FE1_IP , confirm trips load and 'add experience' works BEFORE the AMI is made."
  read -rp "Press Enter once verified (Ctrl+C to abort and fix): " _
  [ -n "${FRONTEND_AMI:-}" ] || save FRONTEND_AMI "$(make_ami $FE1 travelmemory-frontend-ami)"
  [ -n "${FE2:-}" ] || save FE2 "$(launch frontend-2 $SUBNET_B $FRONTEND_SG "" $FRONTEND_AMI)"
  aws ec2 wait instance-running --instance-ids $FE2
  wait_http "http://$(ip_of $FE2)/"
  [ -n "${FRONTEND_TG:-}" ] || make_alb frontend / $FE1 $FE2
  wait_http "http://$FRONTEND_ALB_DNS/"
  echo "DONE. App: http://$FRONTEND_ALB_DNS"
}

stage_cleanup() {
  for a in ${FRONTEND_ALB:-} ${BACKEND_ALB:-}; do aws elbv2 delete-load-balancer --load-balancer-arn $a; done
  sleep 30
  for t in ${FRONTEND_TG:-} ${BACKEND_TG:-}; do aws elbv2 delete-target-group --target-group-arn $t; done
  ids="${FE1:-} ${FE2:-} ${BE1:-} ${BE2:-}"; [ -n "${ids// /}" ] && { aws ec2 terminate-instances --instance-ids $ids >/dev/null; aws ec2 wait instance-terminated --instance-ids $ids; }
  for ami in ${FRONTEND_AMI:-} ${BACKEND_AMI:-}; do
    snaps=$(aws ec2 describe-images --image-ids $ami --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text)
    aws ec2 deregister-image --image-id $ami; for s in $snaps; do aws ec2 delete-snapshot --snapshot-id $s; done
  done
  for g in ${FRONTEND_SG:-} ${BACKEND_SG:-} ${ALB_SG:-}; do aws ec2 delete-security-group --group-id $g || true; done
  rm -f "$STATE" ud-*.sh; echo cleaned
}

case "${1:-}" in backend) stage_backend;; frontend) stage_frontend;; cleanup) stage_cleanup;; *) echo "usage: $0 backend|frontend|cleanup";; esac
