etcd slowness
=============

This happens from time to time, since our build clusters works a lot.

We can identify this problem when we received the following messages on **#ops-testplatform** channel, commonly
these messages are packed together:

- etcdMemberCommunicationSlow
- etcdMembersDown
- etcdNoLeader

Or when writing operations inside the cluster start to fail with the message `etcdserver: mvcc: database space exceeded`.
In this case, after you release space you need to execute:

```bash
etcdctl alarm list
# memberID:4998245273275409700 alarm:NOSPACE
etcdctl alarm disarm
```

[!IMPORTANT]
Always start etcd defragmentation on follower members, defragmenting the leader first can cause
high disk latency, stall write requests, and trigger unnecessary leader elections that make your
Kubernetes control plane unstable.

Procedure
---------

If we still have access to cluster API we can `exec` directly on each etcd pod inside `openshift-etcd` namespace:

```bash
oc get pods -n openshift-etcd -l app=etcd
# NAME                                     READY   STATUS 
# etcd-ip-xxx.us-east-2.compute.internal   5/5     Running
# etcd-ip-yyy.us-east-2.compute.internal   5/5     Running
# etcd-ip-zzz.us-east-2.compute.internal   5/5     Running
oc -n openshift-etcd --as system:admin exec -ti etcd-ip-xxx.us-east-2.compute.internal -- sh
```

Check if this member is not the leader, and start defragmentation process:

```bash
# etcdctl endpoint status --write-out=table
unset ETCDCTL_ENDPOINTS
etcdctl endpoint status | awk -F, '{print "endpoint: "$1" leader:"$9}'
REVISION=$(etcdctl endpoint status --write-out fields | sed -nE 's,"Revision" : ([0-9]+),\1,p')
etcdctl compact $REVISION # needed only a single time on any member
etcdctl defrag --command-timeout=120s 
```

**Important:**

These commands can take a while depending on the state of the cluster, in any case you can increase
the value of `--command-timeout` to `300s` or even higher if you receive `context deadline exceeded`.

### All-in-one script

In case you already know what you are doing, is easier to execute this on a single batch:

```bash
read -r -d '' defrag_commands <<'EOF'
unset ETCDCTL_ENDPOINTS
REVISION=$(etcdctl endpoint status --write-out fields | sed -nE 's,"Revision" : ([0-9]+),\1,p')
etcdctl compact $REVISION # needed only a single time on any member
etcdctl defrag --command-timeout=120s
EOF

for pod in $(oc get pods -n openshift-etcd -l app=etcd --no-headers | cut -d' ' -f1); do
        is_leader=$(oc --as system:admin -n openshift-etcd exec -i $pod -c etcdctl -- sh -c 'unset ETCDCTL_ENDPOINTS; etcdctl endpoint status | awk -F, "{print \$9}"')
        if [[ $is_leader == *true* ]]; then
                leader=$pod
                continue
        fi
        oc --as system:admin -n openshift-etcd exec -i $pod -c etcdctl -- sh <<<$defrag_commands
        sleep 60
done

oc --as system:admin -n openshift-etcd exec -i $leader -c etcdctl -- sh <<<$defrag_commands
```

Procedure without cluster API
-----------------------------

In this case we can manually defrag the etcd using the standard procedure:

[How to compact and defrag etcd to decrease database size in OpenShift 4](https://access.redhat.com/solutions/5564771)

Unfortunately, since this is an indicator that the cluster API is out of service, there is a high probability 
that we can only access the pods using SSH.

For SSH connections, we need to allow it (TCP port 22) inside cloud account firewall. In cases like that
we probably will need to connect into a `worker` and jump from it to a `master`. The ssh key can be
found on **bitwarden**.

Once inside the master we can execute the following commands:

```bash
sudo -i
# get etcd container id
ETCD=`crictl ps --label io.kubernetes.container.name=etcd --quiet`
# check the size
crictl exec $ETCD sh -c "etcdctl endpoint status --write-out=table"
# at this point we should unset ETCDCTL_ENDPOINTS
# get the revision
crictl exec $ETCD sh -c "unset ETCDCTL_ENDPOINTS && etcdctl endpoint status --write-out fields" | sed -nE 's,"Revision" : ([0-9]+),\1,p'
# output:
# 6031370795
# compact the revision, need only a single time on any member
crictl exec $ETCD sh -c "unset ETCDCTL_ENDPOINTS && etcdctl compact 6031370795"
# defrag
crictl exec $ETCD sh -c "unset ETCDCTL_ENDPOINTS && etcdctl defrag --command-timeout 120s"
# verify if the size decreased
crictl exec $ETCD sh -c "etcdctl endpoint status --write-out=table"
```

**Important:**

These commands can take a while depending on the state of the cluster, in any case you can increase
the value of `--command-timeout` to `300` or even higher if you receive `context deadline exceeded`.

### All-in-one script

We should execute these commands very carefully, but in a case where you want to execute everything together:

```bash
# from inside machine or pod
ETCD=`crictl ps --label io.kubernetes.container.name=etcd --quiet`
crictl exec $ETCD sh -c "etcdctl endpoint status --write-out=table"
REV=`crictl exec $ETCD sh -c "unset ETCDCTL_ENDPOINTS && etcdctl endpoint status --write-out fields" | sed -nE 's,"Revision" : ([0-9]+),\1,p'`
crictl exec $ETCD sh -c "unset ETCDCTL_ENDPOINTS && etcdctl compact $REV"
crictl exec $ETCD sh -c "unset ETCDCTL_ENDPOINTS && etcdctl defrag --command-timeout 120s"
crictl exec $ETCD sh -c "etcdctl endpoint status --write-out=table"
```
