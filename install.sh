#!/bin/sh

if [ "${DEBUG}" = 1 ]; then
    set -x
    CURL_LOG="-v"
else
    CURL_LOG="-s"
fi

# Usage:
#   curl ... | ENV_VAR=... sh -
#       or
#   ENV_VAR=... ./install.sh
#

# Environment variables:
#   System Agent Variables
#   - CATTLE_AGENT_LOGLEVEL (default: debug)
#   - CATTLE_AGENT_CONFIG_DIR (default: /etc/rancher/agent)
#   - CATTLE_AGENT_VAR_DIR (default: /var/lib/rancher/agent)
#
#   Rancher 2.6+ Variables
#   - CATTLE_SERVER
#   - CATTLE_TOKEN
#   - CATTLE_CA_CHECKSUM
#   - CATTLE_ROLE_CONTROLPLANE=false
#   - CATTLE_ROLE_ETCD=false
#   - CATTLE_ROLE_WORKER=false
#   - CATTLE_ROLE_NONE=false
#   - CATTLE_LABELS
#   - CATTLE_TAINTS
#
#   Advanced Environment Variables
#   - CATTLE_AGENT_BINARY_BASE_URL (default: latest GitHub release)
#   - CATTLE_AGENT_BINARY_URL (default: latest GitHub release)
#   - CATTLE_PRESERVE_WORKDIR (default: false)
#   - CATTLE_REMOTE_ENABLED (default: true)
#   - CATTLE_ID (default: autogenerate)
#   - CATTLE_AGENT_BINARY_LOCAL (default: false)
#   - CATTLE_AGENT_BINARY_LOCAL_LOCATION (default: )

FALLBACK=v0.0.1-alpha1
CACERTS_PATH=cacerts
RETRYCOUNT=4500

# info logs the given argument at info log level.
info() {
    echo "[INFO] " "$@"
}

# warn logs the given argument at warn log level.
warn() {
    echo "[WARN] " "$@" >&2
}

# error logs the given argument at error log level.
error() {
    echo "[ERROR] " "$@" >&2
}

# fatal logs the given argument at fatal log level.
fatal() {
    echo "[FATAL] " "$@" >&2
    exit 1
}


# parse_args will inspect the argv for --server, --token, --controlplane, --etcd, and --worker, --label x=y, and --taint dead=beef:NoSchedule
parse_args() {
    while [ $# -gt 0 ]; do	
        case "$1" in
            "--controlplane")
                info "Role requested: controlplane"
                CATTLE_ROLE_CONTROLPLANE=true
		shift 1
                ;;
            "--etcd")
                info "Role requested: etcd"
                CATTLE_ROLE_ETCD=true
		shift 1
                ;;
            "--worker")
                info "Role requested: worker"
                CATTLE_ROLE_WORKER=true
		shift 1
                ;;
            "--label")
                info "Label: $2"
                if [ -n "${CATTLE_LABELS}" ]; then
                    CATTLE_LABELS="${CATTLE_LABELS},$2"
                else
                    CATTLE_LABELS="$2"
                fi
		shift 2
                ;;
            "--taint")
                info "Taint: $2"
                if [ -n "${CATTLE_TAINTS}" ]; then
                    CATTLE_TAINTS="${CATTLE_TAINTS},$2"
                else
                    CATTLE_TAINTS="$2"
                fi
		shift 2
                ;;
            "--server")
                CATTLE_SERVER="$2"
		shift 2
                ;;
            "--token")
                CATTLE_TOKEN="$2"
		shift 2
                ;;
            "--ca-checksum")
                CATTLE_CA_CHECKSUM="$2"
        shift 2
                ;;
            *)
                fatal "Unknown argument passed in ($1)"
                ;;
        esac
    done
}

setup_env() {
    if [ -z "${CATTLE_ROLE_CONTROLPLANE}" ]; then
        CATTLE_ROLE_CONTROLPLANE=false
    fi

    if [ -z "${CATTLE_ROLE_ETCD}" ]; then
        CATTLE_ROLE_ETCD=false
    fi

    if [ -z "${CATTLE_ROLE_WORKER}" ]; then
        CATTLE_ROLE_WORKER=false
    fi

    if [ -z "${CATTLE_ROLE_NONE}" ]; then
        CATTLE_ROLE_NONE=false
    fi

    if [ -z "${CATTLE_REMOTE_ENABLED}" ]; then
        CATTLE_REMOTE_ENABLED=true
    else
        CATTLE_REMOTE_ENABLED=$(echo "${CATTLE_REMOTE_ENABLED}" | tr '[:upper:]' '[:lower:]')
    fi

    if [ -z "${CATTLE_PRESERVE_WORKDIR}" ]; then
        CATTLE_PRESERVE_WORKDIR=false
    else
        CATTLE_PRESERVE_WORKDIR=$(echo "${CATTLE_PRESERVE_WORKDIR}" | tr '[:upper:]' '[:lower:]')
    fi

    if [ -z "${CATTLE_AGENT_LOGLEVEL}" ]; then
        CATTLE_AGENT_LOGLEVEL=debug
    else
        CATTLE_AGENT_LOGLEVEL=$(echo "${CATTLE_AGENT_LOGLEVEL}" | tr '[:upper:]' '[:lower:]')
    fi

    if [ "${CATTLE_AGENT_BINARY_LOCAL}" = "true" ]; then
        if [ -z "${CATTLE_AGENT_BINARY_LOCAL_LOCATION}" ]; then
            fatal "No local binary location was specified"
        fi
        BINARY_SOURCE=local
    else
        BINARY_SOURCE=remote
        if [ -z "${CATTLE_AGENT_BINARY_URL}" ] && [ -n "${CATTLE_AGENT_BINARY_BASE_URL}" ]; then
            CATTLE_AGENT_BINARY_URL="${CATTLE_AGENT_BINARY_BASE_URL}/rancher-system-agent-${ARCH}"
        fi

        if [ -z "${CATTLE_AGENT_BINARY_URL}" ]; then
            if [ $(curl -s https://api.github.com/rate_limit | grep '"rate":' -A 4 | grep '"remaining":' | sed -E 's/.*"[^"]+": (.*),/\1/') = 0 ]; then
                info "GitHub Rate Limit exceeded, falling back to known good version"
                VERSION=$FALLBACK
            else
                VERSION=$(curl -s "https://api.github.com/repos/rancher/system-agent/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
                if [ -z "$VERSION" ]; then # Fall back to a known good fallback version because we had an error pulling the latest
                    info "Error contacting GitHub to retrieve the latest version"
                    VERSION=$FALLBACK
                fi
            fi
            CATTLE_AGENT_BINARY_URL="https://github.com/rancher/system-agent/releases/download/${VERSION}/rancher-system-agent-${ARCH}"
            BINARY_SOURCE=upstream
        fi
    fi

    if [ "${CATTLE_REMOTE_ENABLED}" = "true" ]; then
        if [ -z "${CATTLE_TOKEN}" ]; then
            fatal "\$CATTLE_TOKEN was not set."
        fi
        if [ -z "${CATTLE_SERVER}" ]; then
            fatal "\$CATTLE_SERVER was not set"
        fi
        if [ "${CATTLE_ROLE_CONTROLPLANE}" = "false" ] && [ "${CATTLE_ROLE_ETCD}" = "false" ] && [ "${CATTLE_ROLE_WORKER}" = "false" ] && [ "${CATTLE_ROLE_NONE}" = "false" ]; then
            fatal "You must select at least one role."
        fi
    fi

    if [ -z "${CATTLE_AGENT_CONFIG_DIR}" ]; then
        CATTLE_AGENT_CONFIG_DIR=/etc/rancher/agent
        info "Using default agent configuration directory ${CATTLE_AGENT_CONFIG_DIR}"
    fi

    if [ -z "${CATTLE_AGENT_VAR_DIR}" ]; then
        CATTLE_AGENT_VAR_DIR=/var/lib/rancher/agent
        info "Using default agent var directory ${CATTLE_AGENT_VAR_DIR}"
    fi

}

ensure_directories() {
    mkdir -p ${CATTLE_AGENT_VAR_DIR}
    mkdir -p ${CATTLE_AGENT_CONFIG_DIR}
}

# setup_arch set arch and suffix,
# fatal if architecture not supported.
setup_arch() {
    case ${ARCH:=$(uname -m)} in
    amd64)
        ARCH=amd64
        SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
        ;;
    x86_64)
        ARCH=amd64
        SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
        ;;
    arm64)
        ARCH=arm64
        SUFFIX=-${ARCH}
        ;;
    aarch64)
        ARCH=arm64
        SUFFIX=-${ARCH}
        ;;
    arm*)
        ARCH=arm
        SUFFIX=-${ARCH}hf
        ;;
    *)
        fatal "unsupported architecture ${ARCH}"
        ;;
    esac
}

# verify_downloader verifies existence of
# network downloader executable.
verify_downloader() {
    cmd="$(command -v "${1}")"
    if [ -z "${cmd}" ]; then
        return 1
    fi
    if [ ! -x "${cmd}" ]; then
        return 1
    fi

    # Set verified executable as our downloader program and return success
    DOWNLOADER=${cmd}
    return 0
}

# --- write systemd service file ---
create_systemd_service_file() {
    info "systemd: Creating service file"
    cat <<-EOF >"/etc/systemd/system/rancher-system-agent.service"
[Unit]
Description=Rancher System Agent
Documentation=https://www.rancher.com
Wants=network-online.target
After=network-online.target
[Install]
WantedBy=multi-user.target
[Service]
EnvironmentFile=-/etc/default/rancher-system-agent
EnvironmentFile=-/etc/sysconfig/rancher-system-agent
EnvironmentFile=-/etc/systemd/system/rancher-system-agent.env
Type=simple
Restart=always
RestartSec=5s
Environment=CATTLE_LOGLEVEL=${CATTLE_AGENT_LOGLEVEL}
Environment=CATTLE_AGENT_CONFIG=${CATTLE_AGENT_CONFIG_DIR}/config.yaml
ExecStart=/usr/bin/rancher-system-agent
EOF
}

download_rancher_agent() {
    if [ "${CATTLE_AGENT_BINARY_LOCAL}" = "true" ]; then
        info "Using local rancher-system-agent binary from ${CATTLE_AGENT_BINARY_LOCAL_LOCATION}"
        cp -f "${CATTLE_AGENT_BINARY_LOCAL_LOCATION}" /usr/bin/rancher-system-agent
    else
        info "Downloading rancher-system-agent from ${CATTLE_AGENT_BINARY_URL}"
        if [ "${BINARY_SOURCE}" != "upstream" ]; then
            CURL_BIN_CAFLAG="${CURL_CAFLAG}"
        else
            CURL_BIN_CAFLAG=""
        fi
        i=1
        while [ "${i}" -ne "${RETRYCOUNT}" ]; do
            RESPONSE=$(curl --write-out "%{http_code}\n" $CURL_BIN_CAFLAG $CURL_LOG -fL "${CATTLE_AGENT_BINARY_URL}" -o /usr/bin/rancher-system-agent)
            case "${RESPONSE}" in
            200)
                info "Successfully downloaded the rancher-system-agent binary."
                break
                ;;
            000)
                fatal "There was a fatal error downloading the rancher-system-agent binary."
                ;;
            *)
                i=$i+1
                info "$RESPONSE received while downloading the rancher-system-agent binary. Sleeping for 5 seconds and trying again"
                sleep 5
                continue
                ;;
            esac
        done
        chmod +x /usr/bin/rancher-system-agent
    fi
}

check_x509_cert()
{
    cert=$1
    err=$(openssl x509 -in $cert -noout 2>&1)
    if [ $? -eq 0 ]
    then
        echo ""
    else
        echo "${err}"
    fi
}

validate_ca_checksum() {
    if [ -n "${CATTLE_CA_CHECKSUM}" ]; then
        CACERT=$(mktemp)
        i=1
        while [ "${i}" -ne "${RETRYCOUNT}" ]; do
            RESPONSE=$(curl --write-out "%{http_code}\n" --insecure $CURL_LOG -fL "${CATTLE_SERVER}/${CACERTS_PATH}" -o $CACERT)
            case "${RESPONSE}" in
            200)
                info "Successfully downloaded CA certificate"
                break
                ;;
            000)
                fatal "There was an error downloading CA certificate from Rancher"
                ;;
            *)
                i=$i+1
                info "$RESPONSE received while downloading the CA certificate. Sleeping for 5 seconds and trying again"
                sleep 5
                continue
                ;;
            esac
        done
        if [ ! -s $CACERT ]; then
          error "The environment variable CATTLE_CA_CHECKSUM is set but there is no CA certificate configured at ${CATTLE_SERVER}/${CACERTS_PATH}"
          exit 1
        fi
        err=$(check_x509_cert $CACERT)
        if [ -n "${err}" ]; then
            error "Value from ${CATTLE_SERVER}/${CACERTS_PATH} does not look like an x509 certificate (${err})"
            error "Retrieved cacerts:"
            cat $CACERT
            rm -f $CACERT
            exit 1
        else
            info "Value from ${CATTLE_SERVER}/${CACERTS_PATH} is an x509 certificate"
        fi
        CATTLE_SERVER_CHECKSUM=$(sha256sum $CACERT | awk '{print $1}')
        if [ $CATTLE_SERVER_CHECKSUM != $CATTLE_CA_CHECKSUM ]; then
            rm -f $CACERT
            error "Configured cacerts checksum ($CATTLE_SERVER_CHECKSUM) does not match given --ca-checksum ($CATTLE_CA_CHECKSUM)"
            error "Please check if the correct certificate is configured at${CATTLE_SERVER}/${CACERTS_PATH}"
            exit 1
        fi
        CURL_CAFLAG="--cacert ${CACERT}"
    fi
}

retrieve_connection_info() {
    if [ "${CATTLE_REMOTE_ENABLED}" = "true" ]; then
        i=1
        while [ "${i}" -ne "${RETRYCOUNT}" ]; do
            RESPONSE=$(curl --write-out "%{http_code}\n" $CURL_CAFLAG $CURL_LOG -H "Authorization: Bearer ${CATTLE_TOKEN}" -H "X-Cattle-Id: ${CATTLE_ID}" -H "X-Cattle-Role-Etcd: ${CATTLE_ROLE_ETCD}" -H "X-Cattle-Role-Control-Plane: ${CATTLE_ROLE_CONTROLPLANE}" -H "X-Cattle-Role-Worker: ${CATTLE_ROLE_WORKER}" -H "X-Cattle-Labels: ${CATTLE_LABELS}" -H "X-Cattle-Taints: ${CATTLE_TAINTS}" ${CATTLE_SERVER}/v3/connect/agent -o ${CATTLE_AGENT_VAR_DIR}/rancher2_connection_info.json)
            case "${RESPONSE}" in
            200)
                info "Successfully downloaded Rancher connection information"
                break
                ;;
            000)
                fatal "There was an error downloading Rancher connection information. Perhaps --ca-checksum needs to be set?"
                ;;
            *)
                i=$((i + 1))
                info "$RESPONSE received while downloading Rancher connection information. Sleeping for 5 seconds and trying again"
                sleep 5
                continue
                ;;
            esac
        done
    fi
}

generate_config() {

cat <<-EOF >"${CATTLE_AGENT_CONFIG_DIR}/config.yaml"
workDirectory: ${CATTLE_AGENT_VAR_DIR}/work
localPlanDirectory: ${CATTLE_AGENT_VAR_DIR}/plans
appliedPlanDirectory: ${CATTLE_AGENT_VAR_DIR}/applied
remoteEnabled: ${CATTLE_REMOTE_ENABLED}
preserveWorkDirectory: ${CATTLE_PRESERVE_WORKDIR}
EOF

    if [ "${CATTLE_REMOTE_ENABLED}" = "true" ]; then
        echo connectionInfoFile: ${CATTLE_AGENT_VAR_DIR}/rancher2_connection_info.json >> "${CATTLE_AGENT_CONFIG_DIR}/config.yaml"
    fi
}

generate_cattle_identifier() {
    if [ -z "${CATTLE_ID}" ]; then
        info "Generating Cattle ID"
        if [ -f "${CATTLE_AGENT_CONFIG_DIR}/cattle-id" ]; then
            CATTLE_ID=$(cat ${CATTLE_AGENT_CONFIG_DIR}/cattle-id);
            info "Cattle ID was already detected as ${CATTLE_ID}. Not generating a new one."
            return
        fi

        CATTLE_ID=$(sha256sum /etc/machine-id | awk '{print $1}'); # awk may not be installed. need to think of a way around this.
        echo "${CATTLE_ID}" > ${CATTLE_AGENT_CONFIG_DIR}/cattle-id
        return
    fi
    info "Not generating Cattle ID"
}


ensure_systemd_service_stopped() {
    if systemctl is-active --quiet rancher-system-agent.service; then
        info "Rancher System Agent was detected on this host. Ensuring the rancher-system-agent is stopped."
        systemctl stop rancher-system-agent
    fi
}

create_env_file() {
    FILE_SA_ENV="/etc/systemd/system/rancher-system-agent.env"
    info "Creating environment file ${FILE_SA_ENV}"
    UMASK=$(umask)
    umask 0377
    env | egrep -i '^(NO|HTTP|HTTPS)_PROXY' | tee -a ${FILE_SA_ENV} >/dev/null
    umask $UMASK
}

do_install() {
    parse_args $@
    setup_arch
    setup_env
    ensure_directories
    verify_downloader curl || fatal "can not find curl for downloading files"

    if [ -n "${CATTLE_CA_CHECKSUM}" ]; then
        validate_ca_checksum
    fi

    ensure_systemd_service_stopped

    download_rancher_agent
    generate_config

    if [ -n "${CATTLE_TOKEN}" ]; then
        generate_cattle_identifier
        retrieve_connection_info # Only retrieve connection information from Rancher if a token was passed in.
    fi
    create_systemd_service_file
    create_env_file
    systemctl daemon-reload >/dev/null
    info "Enabling rancher-system-agent.service"
    systemctl enable rancher-system-agent
    info "Starting/restarting rancher-system-agent.service"
    systemctl restart rancher-system-agent
}

do_install $@
exit 0
