set -ue
set -o pipefail

PROM_VERSION=2.29.1

# see https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html
INSTANCE_ID="$(curl --silent http://169.254.169.254/latest/meta-data/instance-id)"
AWS_DEFAULT_REGION="$(curl --silent http://169.254.169.254/latest/dynamic/instance-identity/document | ruby -r json -e 'puts JSON.parse(STDIN.read)["region"]')"
export AWS_DEFAULT_REGION

# fetch tag value
SERVICE_NAME="$(aws ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" --out=text --query "Tags[?Key == 'ServiceName'].Value")"
if [ -z "$SERVICE_NAME" ]; then
  echo "Can't extract ServiceName from ec2 tags"
  exit 2
fi

curl -L https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz -o /tmp/prometheus-${PROM_VERSION}.linux-amd64.tar.gz
cd /tmp
tar zxvf prometheus-${PROM_VERSION}.linux-amd64.tar.gz
cd prometheus-${PROM_VERSION}.linux-amd64
mkdir -p /opt/prometheus
cp -p prometheus /opt/prometheus/

cat > /opt/prometheus/prometheus.yml <<_EOD_
global:
  scrape_interval:     5s
  evaluation_interval: 5s
  external_labels:
    monitor: '${SERVICE_NAME}'

scrape_configs:
  - job_name: node-exporter
    ec2_sd_configs:
      - region: ${AWS_DEFAULT_REGION}
        port: 9100
        filters:
          - name: "tag:ServiceName"
            values: ["${SERVICE_NAME}"]
    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name]
        target_label: name
      - source_labels: [__meta_ec2_tag_Env]
        target_label: env
      - source_labels: [__meta_ec2_tag_ServiceName]
        target_label: service_name
      - source_labels: [__meta_ec2_tag_Role]
        target_label: role

  - job_name: nginx
    ec2_sd_configs:
      - region: ${AWS_DEFAULT_REGION}
        port: 4040
        filters:
          - name: "tag:ServiceName"
            values: ["SERVICE_NAME"]
    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name]
        target_label: name
      - source_labels: [__meta_ec2_tag_Env]
        target_label: env
      - source_labels: [__meta_ec2_tag_ServiceName]
        target_label: service_name
      - source_labels: [__meta_ec2_tag_Role]
        target_label: role
_EOD_

cat > /usr/lib/systemd/system/prometheus.service <<'_EOD_'
[Unit]
Description=Prometheus
Documentation=https://prometheus.io/docs/introduction/overview/
After=network-online.target

[Service]
Type=simple
ExecStart=/opt/prometheus/prometheus \
  --config.file=/opt/prometheus/prometheus.yml
Restart=always
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
_EOD_

systemctl daemon-reload
systemctl enable prometheus.service
systemctl start prometheus.service
