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

service prometheus-relay-agent stop || true
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
_EOD_


#
# Install to system
#

if hash systemctl; then
# systemd
cat > /usr/lib/systemd/system/prometheus-relay-agent.service <<'_EOD_'
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

else # hash systemctl
# SysVinit
cat > /etc/init.d/prometheus-relay-agent <<'_EOD_'
#!/bin/bash
#
#   /etc/rc.d/init.d/prometheus-relay-agent
#
# chkconfig: 2345 70 30
#
# pidfile: /var/run/prometheus-relay-agent.pid

# Source function library.
. /etc/init.d/functions


RETVAL=0
ARGS="--config.file=/opt/prometheus/prometheus.yml"
PROG="prometheus-relay-agent"
DAEMON="/opt/prometheus/prometheus"
PID_FILE=/var/run/${PROG}.pid
LOG_FILE=/var/log/node_exporter.log
LOCK_FILE=/var/lock/subsys/${PROG}
GOMAXPROCS=$(grep -c ^processor /proc/cpuinfo)

start() {
    if check_status > /dev/null; then
        echo "node_exporter is already running"
        exit 0
    fi

    echo -n $"Starting node_exporter: "
    ${DAEMON} ${ARGS} 1>>${LOG_FILE} 2>&1 &
    echo $! > ${PID_FILE}
    RETVAL=$?
    [ $RETVAL -eq 0 ] && touch ${LOCK_FILE}
    echo ""
    return $RETVAL
}

stop() {
    if check_status > /dev/null; then
        echo -n $"Stopping node_exporter: "
        kill -9 "$(cat ${PID_FILE})"
        RETVAL=$?
        [ $RETVAL -eq 0 ] && rm -f ${LOCK_FILE} ${PID_FILE}
        echo ""
        return $RETVAL
    else
        echo "node_exporter is not running"
        rm -f ${LOCK_FILE} ${PID_FILE}
        return 0
    fi
}  

check_status() {
    status -p ${PID_FILE} ${DAEMON}
    RETVAL=$?
    return $RETVAL
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        start
        ;;
    *)
        N=/etc/init.d/${NAME}
        echo "Usage: $N {start|stop|restart}" >&2
        RETVAL=2
        ;;
esac

exit ${RETVAL}
_EOD_

chmod +x /etc/init.d/prometheus-relay-agent
chkconfig --add prometheus-relay-agent
chkconfig prometheus-relay-agent on
service prometheus-relay-agent start

fi # hash systemctl
