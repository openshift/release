package main

import (
	"bytes"
	"fmt"
	"os"
	"text/template"

	"sigs.k8s.io/yaml"
	prowapi "k8s.io/test-infra/prow/apis/prowjobs/v1"
)

func main() {
	// TODO: change to your own template
	report_template := `
{{ if eq .Status.State "success" }} :green_jenkins_circle:
{{ else }} :red_jenkins_circle: {{ end }} Job *{{.Spec.Job}}* ended with *{{.Status.State}}*.
<{{.Status.URL}}|View logs> | <https://amd64.ocp.releases.ci.openshift.org/releasestream/4.9.0-0.ci/release/{{index
.Annotations "release.openshift.io/tag"}}|Release status>
`

	// TODO: copy "Prow Job YAML" from an actual job
	prowJobYaml := `
metadata:
  annotations:
    prow.k8s.io/context: ""
    prow.k8s.io/job: periodic-ci-openshift-release-master-nightly-4.9-e2e-metal-assisted-ipv6
    release.openshift.io/architecture: amd64
    release.openshift.io/source: ocp/4.9-art-latest
    release.openshift.io/tag: 4.9.0-0.nightly-2021-08-26-013855
  creationTimestamp: "2021-08-26T01:41:15Z"
  generation: 7
  labels:
    created-by-prow: "true"
    prow.k8s.io/build-id: "1430706875984252928"
    prow.k8s.io/context: ""
    prow.k8s.io/id: 4.9.0-0.nightly-2021-08-26-013855-metal-assisted-ipv6
    prow.k8s.io/job: periodic-ci-openshift-release-master-nightly-4.9-e2e-metal-assi
    prow.k8s.io/refs.base_ref: master
    prow.k8s.io/refs.org: openshift
    prow.k8s.io/refs.repo: release
    prow.k8s.io/type: periodic
    release.openshift.io/verify: "true"
  name: 4.9.0-0.nightly-2021-08-26-013855-metal-assisted-ipv6
  namespace: ci
  resourceVersion: "988015468"
  uid: 32120952-00cb-4563-8f11-63aa0e521527
spec:
  agent: kubernetes
  cluster: build02
  decoration_config:
    censor_secrets: true
    gcs_configuration:
      bucket: test-platform-results
      default_org: openshift
      default_repo: origin
      mediaTypes:
        log: text/plain
      path_strategy: single
    gcs_credentials_secret: gce-sa-credentials-gcs-publisher
    grace_period: 1h0m0s
    resources:
      clonerefs:
        limits:
          memory: 3Gi
        requests:
          cpu: 100m
          memory: 500Mi
      initupload:
        limits:
          memory: 200Mi
        requests:
          cpu: 100m
          memory: 50Mi
      place_entrypoint:
        limits:
          memory: 100Mi
        requests:
          cpu: 100m
          memory: 25Mi
      sidecar:
        limits:
          memory: 2Gi
        requests:
          cpu: 100m
          memory: 250Mi
    skip_cloning: true
    timeout: 4h0m0s
    utility_images:
      clonerefs: us-docker.pkg.dev/k8s-infra-prow/images/clonerefs:v20240802-66b115076
      entrypoint: us-docker.pkg.dev/k8s-infra-prow/images/entrypoint:v20240802-66b115076
      initupload: us-docker.pkg.dev/k8s-infra-prow/images/initupload:v20240802-66b115076
      sidecar: us-docker.pkg.dev/k8s-infra-prow/images/sidecar:v20240802-66b115076
  extra_refs:
  - base_ref: master
    org: openshift
    repo: release
  job: periodic-ci-openshift-release-master-nightly-4.9-e2e-metal-assisted-ipv6
  namespace: ci
  pod_spec:
    containers:
    - args:
      - --gcs-upload-secret=/secrets/gcs/service-account.json
      - --image-import-pull-secret=/etc/pull-secret/.dockerconfigjson
      - --lease-server-credentials-file=/etc/boskos/credentials
      - --report-credentials-file=/etc/report/credentials
      - --secret-dir=/secrets/ci-pull-credentials
      - --secret-dir=/usr/local/e2e-metal-assisted-ipv6-cluster-profile
      - --target=e2e-metal-assisted-ipv6
      - --variant=nightly-4.9
      command:
      - ci-operator
      env:
      - name: RELEASE_IMAGE_LATEST
        value: registry.ci.openshift.org/ocp/release:4.9.0-0.nightly-2021-08-26-013855
      - name: RELEASE_IMAGE_INITIAL
        value: registry.ci.openshift.org/ocp/release:4.9.0-0.nightly-2021-08-26-013855
      image: ci-operator:latest
      imagePullPolicy: Always
      name: ""
      resources:
        requests:
          cpu: 10m
      volumeMounts:
      - mountPath: /etc/boskos
        name: boskos
        readOnly: true
      - mountPath: /secrets/ci-pull-credentials
        name: ci-pull-credentials
        readOnly: true
      - mountPath: /usr/local/e2e-metal-assisted-ipv6-cluster-profile
        name: cluster-profile
      - mountPath: /secrets/gcs
        name: gcs-credentials
        readOnly: true
      - mountPath: /etc/pull-secret
        name: pull-secret
        readOnly: true
      - mountPath: /etc/report
        name: result-aggregator
        readOnly: true
    serviceAccountName: ci-operator
    volumes:
    - name: boskos
      secret:
        items:
        - key: credentials
          path: credentials
        secretName: boskos-credentials
    - name: ci-pull-credentials
      secret:
        secretName: ci-pull-credentials
    - name: cluster-profile
      projected:
        sources:
        - secret:
            name: cluster-secrets-packet
    - name: pull-secret
      secret:
        secretName: registry-pull-credentials
    - name: result-aggregator
      secret:
        secretName: result-aggregator
  report: true
  reporter_config:
    slack:
      channel: '#assisted-deployment-ci'
      job_states_to_report:
      - failure
      - error
      report_template: '{{ if eq .Status.State "success" }} :green_jenkins_circle:
        {{ else }} :red_jenkins_circle: {{ end }} Job *{{.Spec.Job}}* ended with *{{.Status.State}}*.
        <{{.Status.URL}}|View logs> | <https://openshift-release.apps.ci.l2s4.p1.openshiftapps.com/releasestream/4.9.0-0.nightly/release/{{index
        .Metadata.Annotations "release.openshift.io/tag"}}|Release status>'
  type: periodic
status:
  build_id: "1430706875984252928"
  completionTime: "2021-08-26T04:10:35Z"
  description: Job failed.
  pendingTime: "2021-08-26T01:41:15Z"
  pod_name: 4.9.0-0.nightly-2021-08-26-013855-metal-assisted-ipv6
  prev_report_states:
    gcsk8sreporter: failure
    gcsreporter: failure
  startTime: "2021-08-26T01:41:15Z"
  state: failure
  url: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-openshift-release-master-nightly-4.9-e2e-metal-assisted-ipv6/1430706875984252928
`

	prowJob := &prowapi.ProwJob{}
	if err := yaml.Unmarshal([]byte(prowJobYaml), prowJob); err != nil {
		fmt.Printf("failed to unmarshal from yaml to prowJob object: %v", err)
		os.Exit(1)
	}

	tmpl, err := template.New("").Parse(report_template)
	if err != nil {
		fmt.Printf("failed to parse template: %v", err)
		os.Exit(1)
	}

	buffer := &bytes.Buffer{}
	if err := tmpl.Execute(buffer, prowJob); err != nil {
		fmt.Printf("failed to execute report_template: %v", err)
		os.Exit(1)
	}

	fmt.Printf("Template is valid. This is how it will look like:\n")
	fmt.Printf("%v\n", buffer.String())
}
