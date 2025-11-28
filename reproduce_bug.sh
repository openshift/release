#!/bin/bash

echo "=== OVN-Kubernetes EgressIP Bug Reproduction Script ==="
echo "Bug: OCPBUGS-61742 - Missing Logical_Router_Policy after label changes"
echo

# Apply resources
echo "1. Creating namespace and EgressIP resources..."
kubectl apply -f namespace.yaml
kubectl apply -f a-debug-egress-ip.yaml
kubectl apply -f b-debug-egress-ip.yaml
kubectl apply -f test-pod.yaml

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/debug-pod -n debug-egress --timeout=300s

echo
echo "2. Testing egress traffic with debug=a label..."
kubectl exec -n debug-egress debug-pod -- curl -s whatismyip.cloud.example.local/all -L

echo
echo "3. Changing namespace label to debug=b..."
kubectl patch namespace debug-egress --patch='{"metadata":{"labels":{"debug":"b"}}}'

echo "Testing egress traffic with debug=b label..."
kubectl exec -n debug-egress debug-pod -- curl -s whatismyip.cloud.example.local/all -L

echo
echo "4. Changing namespace label back to debug=a..."
kubectl patch namespace debug-egress --patch='{"metadata":{"labels":{"debug":"a"}}}'

echo "Testing egress traffic after changing back to debug=a (should fail)..."
kubectl exec -n debug-egress debug-pod -- timeout 10 curl -s whatismyip.cloud.example.local/all -L || echo "Connection failed - bug reproduced!"

echo
echo "5. Checking OVN database for missing Logical_Router_Policy..."
POD_IP=$(kubectl get pod debug-pod -n debug-egress -o jsonpath='{.status.podIP}')
echo "Pod IP: $POD_IP"

echo "Checking all ovnkube-node pods for Logical_Router_Policy..."
for entry in $(kubectl -n openshift-ovn-kubernetes get pods -l app=ovnkube-node -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName --no-headers | sed 's/ \+/:/'); do
    POD=${entry%%:*}
    NODE=${entry##*:}
    echo "---- $POD    $NODE ----"
    kubectl -n openshift-ovn-kubernetes exec -it $POD -c nbdb -- ovn-nbctl find Logical_Router_Policy "match=\"ip4.src == $POD_IP\"" || echo "Not Found"
    echo ""
done

echo
echo "=== Bug reproduction complete ==="
echo "Expected result: Missing Logical_Router_Policy entries and connection failures"
echo "Workaround: Restart ovnkube-node pod on the node with the EgressIP"