etcd slowness
=============

This happens from time to time, since our build clusters works a lot.

We can identify this problem when we received the following messages on **#ops-testplatform** channel, commonly
these messages are packed together:

- etcdMemberCommunicationSlow
- etcdMembersDown
- etcdNoLeader

Procedure
---------

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
# compact the revision
crictl exec $ETCD sh -c "unset ETCDCTL_ENDPOINTS && etcdctl compact 6031370795"
# defrag
crictl exec $ETCD sh -c "unset ETCDCTL_ENDPOINTS && etcdctl defrag 6031370795 --command-timeout 120s"
# verify if the size decreased
crictl exec $ETCD sh -c "etcdctl endpoint status --write-out=table"
```

**Important:**

These commands can take a while depending on the state of the cluster, in any case you can increase
the value of `--command-timeout` to `300` or even higher if you receive `context deadline exceeded`.

All-in-one script
-----------------

We should execute these commands very carefully, but in a case where you want to execute everything together:

```bash
# from inside machine or pod
ETCD=`crictl ps --label io.kubernetes.container.name=etcd --quiet`
crictl exec $ETCD sh -c "etcdctl endpoint status --write-out=table"
REV=`crictl exec $ETCD sh -c "unset ETCDCTL_ENDPOINTS && etcdctl endpoint status --write-out fields" | sed -nE 's,"Revision" : ([0-9]+),\1,p'`
crictl exec $ETCD sh -c "unset ETCDCTL_ENDPOINTS && etcdctl compact $REV"
crictl exec $ETCD sh -c "unset ETCDCTL_ENDPOINTS && etcdctl defrag $REV --command-timeout 120s"
crictl exec $ETCD sh -c "etcdctl endpoint status --write-out=table"
```
