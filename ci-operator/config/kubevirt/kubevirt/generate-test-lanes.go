package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"text/template"
)

var testLaneTemplate = `base_images:
  base:
    name: "{{.OcpVersion}}"
    namespace: ocp
    tag: base
build_root:
  image_stream_tag:
    name: release
    namespace: openshift
    tag: golang-1.13
canonical_go_repository: kubevirt.io/kubevirt
releases:
  initial:
    integration:
      name: "{{.OcpVersion}}"
      namespace: ocp
  latest:
    integration:
      include_built_images: true
      name: "{{.OcpVersion}}"
      namespace: ocp
resources:
  '*':
    limits:
      memory: 4Gi
    requests:
      cpu: 100m
      memory: 200Mi
tests:
- as: e2e
  cron: 2 3 * * *
  steps:
    cluster_profile: azure4
    test:
    - as: test
      cli: latest
      commands: |
        export DOCKER_PREFIX='{{.DockerPrefix}}'
        export KUBEVIRT_TESTS_FOCUS='-ginkgo.focus=\[rfe_id:273\]\[crit:high\]'
        export BIN_DIR="$(pwd)/_out" && mkdir -p "${BIN_DIR}"
        ./hack/ci/entrypoint.sh {{.TestFuncCall}}
      from: src
      resources:
        requests:
          cpu: 100m
          memory: 200Mi
    workflow: ipi-azure
`

type TestLaneSpec struct {
	OcpVersion         string
	TestFuncCall       string
	DockerPrefix       string
	TestLaneFileSuffix string
}

var configDir string
var logger *log.Logger

func main() {
	logger = log.Default()

	flag.StringVar(&configDir, "config-path", "ci-operator/config/kubevirt/kubevirt", "The path to the test lane configurations")

	logger.Printf("Generation of test lanes in %s started", configDir)

	parsedTemplate, err := template.New("testLane").Parse(testLaneTemplate)
	checkErr(err)
	file, err := os.ReadFile(filepath.Join(configDir, "kubevirt-openshift-test-mapping.json"))
	checkErr(err)
	var kubeVirtVersionsToOpenShiftVersions []TestLaneSpec
	err = json.Unmarshal(file, &kubeVirtVersionsToOpenShiftVersions)
	checkErr(err)
	dir, err := os.ReadDir(configDir)
	for _, entry := range dir {
		if entry.IsDir() {
			continue
		}
		if !strings.HasPrefix(entry.Name(), "kubevirt-kubevirt-main__") {
			continue
		}
		previousTestLaneFilePath := filepath.Join(configDir, entry.Name())
		logger.Printf("Removing config %s", previousTestLaneFilePath)
		err := os.Remove(previousTestLaneFilePath)
		checkErr(err)
	}
	checkErr(err)
	for _, data := range kubeVirtVersionsToOpenShiftVersions {
		targetFileName := filepath.Join(configDir, fmt.Sprintf("kubevirt-kubevirt-main__%s.yaml", data.TestLaneFileSuffix))
		createdFile, err := os.Create(targetFileName)
		checkErr(err)
		defer func(createdFile *os.File) {
			err := createdFile.Close()
			checkErr(err)
		}(createdFile)
		err = parsedTemplate.Execute(createdFile, data)
		checkErr(err)
		logger.Printf("Generated config %s from data %+v", targetFileName, data)
	}
}

func checkErr(err error) {
	if err != nil {
		logger.Panic(err)
	}
}
