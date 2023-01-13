# Sync Rover Groups

## How it works

Rover groups are synced to the clusters by two jobs:

- A [`cronjob/sync-rover-groups-update`](https://console-openshift-console.apps.ocp-c1.prod.psi.redhat.com/k8s/ns/ocp-test-platform/batch~v1~CronJob/sync-rover-groups-update/) on the psi cluster: It stores the groups from Rover to `ConfigMap/sync-rover-groups` in `namespace/ci` of `app.ci`.

-  A periodic [`ProwJob/periodic-github-ldap-user-group-creator`](/ci-operator/jobs/infra-periodics.yaml): It maintains the groups defined in `ConfigMap/sync-rover-groups` on the clusters.

Currently, both jobs are daily executed and thus it might take up to two days to sync a Rover group to the clusters. Those jobs can be triggered manually for the urgent cases.

## Special Cluster Role and their Rover groups

A useful cluster role binding is
[cluster-reader](/clusters/build-clusters/common_except_app.ci/admin_cluster-reader-0_list.yaml) which defines cluster readers for all CI clusters except `app.ci`.
The existing Rover groups are referred there to give them the permissions.

| Rover Group Name                                                                                                 | Group Name On Cluster   | Role                                                                   |
|------------------------------------------------------------------------------------------------------------------|-------------------------|------------------------------------------------------------------------|
| [test-platform-ci-admins](https://rover.redhat.com/groups/group/test-platform-ci-admins)                         | test-platform-ci-admins | sudoers on all CI clusters                                             |
| [test-platform-ci-sudoers](https://rover.redhat.com/groups/group/test-platform-ci-sudoers)                       | ci-sudoers              | sudoers on build01, build02, arm01                                     |
| [test-platform-ci-monitoring-viewers](https://rover.redhat.com/groups/group/test-platform-ci-monitoring-viewers) | ci-monitoring-viewers   | viewers of openshift-monitoring on all CI clusters |

In theory, no groups except `test-platform-ci-admins` should be owned by the TP team.
In reality, the groups `ci-sudoers` and `ci-monitoring-viewers` are there on the clusters before the support of Rover groups. The members are from different OCP teams.
The Rover groups `test-platform-ci-sudoers` and `test-platform-ci-monitoring-viewers` are created to keep the permissions for the members.
Until they are replaced by the groups they belong to, we have to maintain these two groups.

Note that the group name `ci-monitoring-viewers` is misleading because they can modify alerts which is because it is bound to [monitoring-alertmanager-edit](/clusters/build-clusters/common/monitoring-alertmanager-edit.yaml).
There is [no read-only role to view alert-manager](https://issues.redhat.com/browse/MON-2637).
