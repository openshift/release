#!/bin/bash

while read state job build_id; do
    echo "=== Processing $job ($state) - Build $build_id ==="
    
    test_name="${job%-golden}"
    base_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/78362/rehearse-78362-pull-ci-osac-project-osac-installer-main-e2e-metal-vmaas-${job}/${build_id}/artifacts/e2e-metal-vmaas-${test_name}"
    
    echo "Job: $job"
    echo "Build ID: $build_id"
    echo "State: $state"
    echo "Base URL: $base_url"
    echo ""
    
    # Try to fetch assisted-ofcir-setup build-log
    echo "Fetching assisted-ofcir-setup/build-log.txt..."
    wget -q -O "${job}-assisted-setup.log" "${base_url}/assisted-ofcir-setup/build-log.txt" 2>&1
    
    # Try to fetch osac-project-golden-setup build-log
    echo "Fetching osac-project-golden-setup/build-log.txt..."
    wget -q -O "${job}-golden-setup.log" "${base_url}/osac-project-golden-setup/build-log.txt" 2>&1
    
    assisted_size=$(stat -c%s "${job}-assisted-setup.log" 2>/dev/null || echo "0")
    golden_size=$(stat -c%s "${job}-golden-setup.log" 2>/dev/null || echo "0")
    
    echo "  assisted-setup.log: $assisted_size bytes"
    echo "  golden-setup.log: $golden_size bytes"
    echo ""
    
done < /tmp/latest-rehearsal-jobs.txt
