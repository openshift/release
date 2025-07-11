[1mdiff --git a/ci-operator/config/openshift/verification-tests/openshift-verification-tests-main__installer-rehearse-4.20.yaml b/ci-operator/config/openshift/verification-tests/openshift-verification-tests-main__installer-rehearse-4.20.yaml[m
[1mindex 605df8fe2e6..15006ada955 100644[m
[1m--- a/ci-operator/config/openshift/verification-tests/openshift-verification-tests-main__installer-rehearse-4.20.yaml[m
[1m+++ b/ci-operator/config/openshift/verification-tests/openshift-verification-tests-main__installer-rehearse-4.20.yaml[m
[36m@@ -58,6 +58,31 @@[m [mtests:[m
     - chain: aws-provision-bastionhost[m
     test:[m
     - ref: cucushift-installer-wait[m
[32m+[m[32m- as: installer-rehearse-gcp-byo-priv-zone[m
[32m+[m[32m  cron: '@yearly'[m
[32m+[m[32m  steps:[m
[32m+[m[32m    cluster_profile: gcp-qe[m
[32m+[m[32m    env:[m
[32m+[m[32m      PRIVATE_ZONE_PROJECT_TYPE: third-project[m
[32m+[m[32m      SLEEP_DURATION: 30m[m
[32m+[m[32m    post:[m
[32m+[m[32m    - ref: cucushift-installer-wait[m
[32m+[m[32m    - chain: cucushift-installer-rehearse-gcp-ipi-xpn-minimal-permission-byo-hosted-zone-in-third-project-deprovision[m
[32m+[m[32m    pre:[m
[32m+[m[32m    - chain: cucushift-installer-rehearse-gcp-ipi-xpn-minimal-permission-byo-hosted-zone-in-third-project-provision[m
[32m+[m[32m- as: installer-rehearse-gcp-byo-priv-zone2[m
[32m+[m[32m  cron: '@yearly'[m
[32m+[m[32m  steps:[m
[32m+[m[32m    cluster_profile: gcp-qe[m
[32m+[m[32m    env:[m
[32m+[m[32m      CREATE_PRIVATE_ZONE: "no"[m
[32m+[m[32m      PRIVATE_ZONE_PROJECT_TYPE: third-project[m
[32m+[m[32m      SLEEP_DURATION: 30m[m
[32m+[m[32m    post:[m
[32m+[m[32m    - ref: cucushift-installer-wait[m
[32m+[m[32m    - chain: cucushift-installer-rehearse-gcp-ipi-xpn-minimal-permission-byo-hosted-zone-in-third-project-deprovision[m
[32m+[m[32m    pre:[m
[32m+[m[32m    - chain: cucushift-installer-rehearse-gcp-ipi-xpn-minimal-permission-byo-hosted-zone-in-third-project-provision[m
 - as: installer-rehearse-ibmcloud-dis[m
   cron: '@yearly'[m
   steps:[m
