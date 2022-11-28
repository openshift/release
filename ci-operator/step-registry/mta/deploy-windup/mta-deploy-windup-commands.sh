#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# Deploy windup CRD
oc apply -f - <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: windups.windup.jboss.org
  labels:
    application: windup
spec:
  group: windup.jboss.org
  scope: Namespaced
  preserveUnknownFields: false
  names:
    plural: windups
    singular: windup
    kind: Windup
    shortNames:
    - w
  versions:
    - name: v1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                hostname_http:
                  type: string
                  default: ""
                volumeCapacity:
                  type: string
                  default: "20G"
                windup_Volume_Capacity:
                  type: string
                  default: "20G"
                messaging_serializer:
                  type: string
                  default: "http.post.serializer"
                db_jndi:
                  type: string
                  default: "java:jboss/datasources/WindupServicesDS"
                db_username:
                  type: string
                  description: leave empty for auto-generation
                db_password:
                  description: leave empty for auto-generation
                  type: string
                db_min_pool_size:
                  type: string
                db_max_pool_size:
                  type: string
                db_tx_isolation:
                  type: string
                mq_cluster_password:
                  type: string
                  description: leave empty for auto-generation
                mq_queues:
                  type: string
                  default: ""
                mq_topics:
                  type: string
                  default: ""
                jgroups_encrypt_secret:
                  type: string
                  default: "wildfly-app-secret"
                jgroups_encrypt_keystore:
                  type: string
                  default: "jgroups.jceks"
                jgroups_encrypt_name:
                  type: string
                  default: ""
                jgroups_encrypt_password:
                  type: string
                  default: ""
                jgroups_cluster_password:
                  type: string
                  description: leave empty for auto-generation
                auto_deploy_exploded:
                  type: string
                  default: "false"
                sso_server_url:
                  type: string
                sso_realm:
                  type: string
                sso_client_id:
                  type: string
                sso_ssl_required:
                  type: string
                sso_saml_keystore_secret:
                  type: string
                  default: "wildfly-app-secret"
                sso_saml_keystore:
                  type: string
                  default: "keystore.jks"
                sso_saml_certificate_name:
                  type: string
                  default: "jboss"
                sso_saml_keystore_password:
                  type: string
                  default: "mykeystorepass"
                sso_secret:
                  type: string
                  description: leave empty for auto-generation
                sso_enable_cors:
                  type: string
                  default: "false"
                sso_saml_logout_page:
                  type: string
                  default: "/"
                sso_disable_ssl_certificate_validation:
                  type: string
                  default: "true"
                sso_truststore:
                  type: string
                  default: ""
                sso_truststore_password:
                  type: string
                  default: ""
                sso_truststore_secret:
                  type: string
                  default: "wildfly-app-secret"
                gc_max_metaspace_size:
                  type: integer
                  default: 512
                max_post_size:
                  type: string
                  default: "4294967296"
                sso_force_legacy_security:
                  type: string
                  default: "false"
                db_database:
                  type: string
                  default: "windup"
                postgresql_max_connections:
                  type: string
                  default: "200"
                postgresql_shared_buffers:
                  type: string
                postgresql_cpu_request:
                  type: string
                  default: "0.5"
                postgresql_mem_request:
                  type: string
                  default: "0.5Gi"
                postgresql_cpu_limit:
                  type: string
                  default: "2"
                postgresql_mem_limit:
                  type: string
                  default: "2Gi"
                webLivenessInitialDelaySeconds:
                  type: string
                  default: "120"
                webLivenessTimeoutSeconds:
                  type: string
                  default: "10"
                webLivenessFailureThreshold:
                  type: string
                  default: "3"
                webReadinessInitialDelaySeconds:
                  type: string
                  default: "120"
                webReadinessTimeoutSeconds:
                  type: string
                  default: "10"
                webReadinessFailureThreshold:
                  type: string
                  default: "3"
                web_cpu_request:
                  type: string
                  default: "0.5"
                web_mem_request:
                  type: string
                  default: "0.5Gi"
                web_cpu_limit:
                  type: string
                  default: "4"
                web_mem_limit:
                  type: string
                  default: "4Gi"
                executor_cpu_request:
                  type: string
                  default: "0.5"
                executor_mem_request:
                  type: string
                  default: "0.5Gi"
                executor_cpu_limit:
                  type: string
                  default: "4"
                executor_mem_limit:
                  type: string
                  default: "4Gi"
                web_readiness_probe:
                  type: string
                  default: "/bin/bash, -c, ${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands='/core-service=management:read-boot-errors()' | grep '\"result\" => \\[]' && ${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands='ls deployment' | grep 'api.war'"
                web_liveness_probe:
                  type: string
                  default: "/bin/bash, -c, ${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands='/core-service=management:read-boot-errors()' | grep '\"result\" => \\[]' && ${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands=ls | grep 'server-state=running'"
                executor_readiness_probe:
                  type: string
                  default: "/bin/bash, -c, /opt/windup-cli/bin/livenessProbe.sh"
                executor_liveness_probe:
                  type: string
                  default: "/bin/bash, -c, /opt/windup-cli/bin/livenessProbe.sh"
                executor_desired_replicas:
                  type: integer
                  default: 1
                tls_secret:
                  type: string
                  default: ""
                ingress_custom_labels:
                  type: string
                  default: ""
              required:
                  - web_cpu_request
                  - web_mem_request
                  - executor_cpu_request
                  - executor_mem_request
                  - messaging_serializer
                  - windup_Volume_Capacity
                  - db_database
                  - volumeCapacity
                  - max_post_size
                  - sso_force_legacy_security
                  - executor_desired_replicas
            status:
              type: object
              properties:
                conditions:
                  items:
                    properties:
                      lastTransitionTime:
                        type: string
                      message:
                        type: string
                      reason:
                        type: string
                      status:
                        type: string
                      type:
                        type: string
                    required:
                    - status
                    - type
                    type: object
                  type: array
          required:
          - spec
          - apiVersion

EOF

# Deploy windup
oc apply -f - <<EOF
apiVersion: windup.jboss.org/v1
kind: Windup
metadata:
    name: mta
    namespace: mta
    labels:
      application: mta
spec:
    mta_Volume_Cpacity: "5Gi"
    volumeCapacity: "5Gi"
EOF

# Wait 5 minutes for Windup to fully deploy
echo "Waiting 5 minutes for Windup to finish deploying"
sleep 300

echo "MTA operator installed and Windup deployed."