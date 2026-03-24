🧪 OpenShift Egress IP Resilience Test -Test Steps Summary

📋 Overview
The test validates egress IP functionality under chaos engineering conditions using both primary (functional) and secondary (internal) validation approaches.

 🏗️ Test Architecture & Environment

🎯 Validation Strategy

**PRIMARY TEST (Important)**
- **Purpose**: Validate actual egress IP functionality end-to-end
- **Method**: Takes a pod from an egress-enabled namespace
- **Action**: Makes it connect to an external service  
- **Validation**: Checks "Does the external service see traffic coming from our egress IP?"
- **Success**: External service sees `egress IP` as source IP
- **Failure**: **If NO → TEST FAILS** 

**SECONDARY TEST (Additional)**
- **Purpose**: Validate internal network configuration
- **Method**: Looks inside OpenShift's networking layer (OVN)
- **Action**: Counts SNAT rules that should exist for the egress IP
- **Validation**: Checks if sufficient networking rules are configured
- **Success**: ≥1 SNAT rules found for egress IP
- **Failure**: **If too few rules → Additional validation fails**


 🔄 PHASE 1: OVN Pod Disruption Testing

**Chaos Type**: Kill networking pods to simulate component failures

🔍 Pre-Disruption Validation

Step 1.1: OVN Pod Health Check
ovn_pods=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node --no-headers | wc -l)

Pass condition  
if [[ $ovn_pods >= 2 ]]; then PASS; else FAIL; fi

Step 1.2: Egress IP Assignment Check
What we're checking
assigned_node=$(oc get egressip egress-ip-test -o jsonpath='{.status.items[0].node}')

Pass condition
if [[ -n "$assigned_node" ]]; then PASS; else FAIL; fi

 **📊 Expected**: EgressIP assigned to specific worker node
 **❌ Fails if**: No assignment (EgressIP controller malfunction)

Step 1.3: Baseline Internal Configuration (Secondary)
What we're checking  
snat_count=$(oc exec ovnkube-node-pod -- ovn-nbctl find nat external_ip="$EGRESS_IP" type=snat | wc -l)

# Pass condition
if [[ $snat_count >= 1 ]]; then PASS; else FAIL; fi
```
- **📊 Expected**: ≥1 SNAT rule configured for egress IP
- **❌ Fails if**: <1 rule (OVN not properly configured)

💥 Chaos Execution
 **Framework**: `redhat-chaos-pod-scenarios` kills ovnkube-node pods
 **Target**: 3 networking pods in `openshift-ovn-kubernetes` namespace
 **Recovery**: DaemonSet automatically restarts killed pods

🔍 Post-Disruption Validation

Step 1.4: Egress IP Recovery Check
What we're checking
current_node=$(oc get egressip egress-ip-test -o jsonpath='{.status.items[0].node}')

# Pass condition
if [[ -n "$current_node" ]]; then PASS; else FAIL; fi
```
- **📊 Expected**: EgressIP still assigned after pod restart
- **❌ Fails if**: Assignment lost (controller didn't recover)

🎯 Step 1.5: **PRIMARY TEST** - External Source IP Validation
What we're testing (MOST IMPORTANT)
test_pod="traffic-gen-1"  # Use existing workload (proper chaos testing)
expected_eip="$EGRESS_IP"
actual_source_ip=$(oc exec $test_pod -- curl -s $EXTERNAL_ECHO_URL | grep -o '[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*')

Critical validation
if [[ "$actual_source_ip" == "$expected_eip" ]]; then
    echo "✅ PRIMARY TEST PASSED: External traffic uses configured egress IP"
else
    echo "❌ PRIMARY TEST FAILED: External traffic does NOT use egress IP"
    exit 1  # HARD FAIL
fi

🔧 Step 1.6: **SECONDARY TEST** - Internal Configuration Recovery
What we're checking (Additional confidence)
post_disruption_snat_count=$(oc exec ovnkube-node-pod -- ovn-nbctl find nat external_ip="$EGRESS_IP" type=snat | wc -l)

Pass condition  
if [[ $post_disruption_snat_count >= 1 ]]; then
    echo "✅ SECONDARY TEST PASSED: Internal OVN configuration restored"
else
    echo "❌ SECONDARY TEST FAILED: SNAT rules not restored"
    exit 1  # HARD FAIL
fi
 **🔧 Purpose**: Verify internal networking configuration recovered
 **📊 Expected**: ≥1 SNAT rule exists after pod restart
 **❌ Fails if**: <1 rule (OVN state not recovered)


🖥️ PHASE 2: Node Reboot Testing
Step2.1--2.3
**Chaos Type**: Reboot worker nodes to simulate hardware failures

🔍 Pre-Reboot Validation

💥 Chaos Execution
**Framework**: `redhat-chaos-node-disruptions` reboots worker nodes
- **Target**: 1 node with label `node-role.kubernetes.io/worker=`
- **Method**: `node_reboot_scenario` with 120s timeout

🔍 Post-Reboot Validation

Step 2.4: Egress IP Cluster Recovery Check
What we're checking
egress_nodes=$(oc get egressip -o jsonpath='{.items[*].status.items[*].node}')

Pass condition
if [[ -n "$egress_nodes" ]]; then PASS; else FAIL; fi
- **📊 Expected**: EgressIPs reassigned to available nodes after reboot
- **❌ Fails if**: No assignments (cluster-wide failure)

🎯 Step 2.5: **PRIMARY TEST** - Post-Reboot External Validation
What we're testing (MOST IMPORTANT after infrastructure change)
test_pod="reboot-traffic-test"  # New pod for post-reboot testing
expected_eip="$EGRESS_IP"
actual_source_ip=$(oc exec $test_pod -- curl -s $EXTERNAL_ECHO_URL | grep -o '[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*')

# Critical validation
if [[ "$actual_source_ip" == "$expected_eip" ]]; then
    echo "✅ PRIMARY TEST PASSED: External traffic uses egress IP after reboot"
else
    echo "❌ PRIMARY TEST FAILED: Egress IP broken by node reboot"
    exit 1  # HARD FAIL
fi
```
- **🎯 Purpose**: **CORE VALIDATION** - Egress IP survives infrastructure disruption
- **📊 Expected**: External service still sees configured egress IP after reboot
- **❌ Fails if**: External service sees different IP (egress IP broken by reboot)

🔧 Step 2.6: **SECONDARY TEST** - Post-Reboot Configuration Check
What we're checking (Additional confidence after reboot)
post_reboot_snat_count=$(oc exec ovnkube-node-pod -- ovn-nbctl find nat external_ip="$EGRESS_IP" type=snat | wc -l)

Pass condition
if [[ $post_reboot_snat_count >= 1 ]]; then
    echo "✅ SECONDARY TEST PASSED: Internal configuration survived reboot"
else
    echo "❌ SECONDARY TEST FAILED: SNAT rules not restored after reboot"
    exit 1  # HARD FAIL
fi
- **🔧 Purpose**: Verify internal config restored after infrastructure reboot
- **📊 Expected**: ≥1 SNAT rule exists after node reboot
- **❌ Fails if**: <1 rule (OVN state not recovered from reboot)


🎯 Two-Tier Validation Approach

**PRIMARY Validation (Critical Path)**
- **What**: Functional end-to-end testing via external service
- **Question**: "Does external traffic actually use the egress IP?"
- **Method**: Pod → External Service → "What source IP do you see?"
- **Success**: External service reports configured egress IP
- **Failure**: **HARD FAIL** - Core functionality is broken

**SECONDARY Validation (Infrastructure Confidence)**
- **What**: Internal OVN networking configuration verification  
- **Question**: "Are the underlying network rules properly configured?"
- **Method**: Query OVN database for SNAT rules
- **Success**: Minimum required rules exist
- **Failure**: **HARD FAIL** - Infrastructure configuration is broken

🔄 Chaos Engineering Best Practices

**Realistic Testing Approach**
✅ **Pod Distribution**: Pods scheduled randomly (not forced to egress node)
✅ **Existing Workloads**: Tests validate surviving pods (not newly created)
✅ **External Validation**: Independent observer outside OpenShift cluster
✅ **Multi-tenant**: Multiple namespaces sharing same egress IP


✅ Success Criteria
- **🏥 Cluster Health**: Networking components functional and egress IP properly assigned
- **🛡️ Disruption Resilience**: Egress IP survives both pod-level and node-level chaos
- **🎯 Functional Validation**: External services consistently see correct source IP
- **🔧 Configuration Recovery**: Internal networking state properly restored after failures
- **🔄 End-to-End Coverage**: Complete chaos engineering validation cycle


🏁 Conclusion

This test suite provides **comprehensive validation** that OpenShift's egress IP feature delivers **reliable, resilient outbound IP management** even under infrastructure failure conditions. The combination of **functional external validation** and **internal configuration verification** ensures both user-visible functionality and underlying infrastructure integrity are maintained through chaos scenarios.

Using external service validation provides **definitive proof** that egress IP actually works from an end-user perspective, not just internal configuration checks.
