#!/bin/bash

cat <<EOF> "${SHARED_DIR}/ovn-utils.sh"

function dump_cluster_state {
  oc get nodes -o wide
  oc get network.operator.openshift.io -o yaml
  oc get machinesets -n openshift-machine-api
  oc get co -A
}

function wait_for_operators_and_nodes {
  if [ -z "\$1" ]; then
    echo "Error: timeout value not provided" >&2
    exit 1
  fi

  # wait for all cluster operators to be done rolling out
  timeout \$1 bash <<EOT
  until
    oc wait co --all --for='condition=AVAILABLE=True' --timeout=10s && \
    oc wait co --all --for='condition=PROGRESSING=False' --timeout=10s && \
    oc wait co --all --for='condition=DEGRADED=False' --timeout=10s && \
    oc wait node --all --for condition=Ready --timeout=10s;
  do
    sleep 10
    echo "Some ClusterOperators Degraded=False,Progressing=True,or Available=False";
  done
EOT
  if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for ClusterOperators to be ready" >&2
    dump_cluster_state
    exit 1
  fi
}

function wait_for_operator_to_be_progressing {
  if [ -z "\$1" ]; then
    echo "Error: operator name not provided" >&2
    exit 1
  fi

  if ! oc wait co \$1 --for='condition=PROGRESSING=True' --timeout=120s; then
    oc get co -A
    echo "Error: the \$1 operator never moved to Progressing=True." >&2
    exit 1
  fi
}

check_annotation_on_nodes() {
    local annotation=\$1
    local key=\$2
    local cidr=\$3
    local cidr_matches=0

    nodes=\$(oc get nodes -o name)

    while IFS= read -r node; do
        output=\$(oc describe "\$node" | grep "\$annotation")
        if [ -n "\$output" ]; then
            value=\$(echo "\$output" | grep -oP '(?<="'\$key'":")[^"]+')

            # Check if the value matches the CIDR subnet
            if [[ ! \$value =~ ^\$cidr ]]; then
                echo "Node \$node: \$annotation:\$key \$value does not match \$cidr"
                oc describe "\$node"
                cidr_matches=1
            fi
        else
            echo "Node \$node: Annotation \$annotation not found"
            oc describe "\$node"
            cidr_matches=1
        fi
    done < <(echo "\$nodes")

    if [ \$cidr_matches -eq 1 ]; then
        echo "At least one node did not have the proper annotation for \$annotation:\$key. exiting"
        exit 1
    fi
}

EOF
