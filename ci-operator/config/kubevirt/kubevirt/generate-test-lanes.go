package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"text/template"
)

var ocpVersionTemplates = map[string]string{
	"release": `    release:
      channel: stable
      version: "{{.OcpVersion}}"`,
	"integration": `    integration:
      name: "{{.OcpVersion}}"
      namespace: ocp`,
}

var testLaneTemplate = `base_images:
  base:
    name: release
    namespace: openshift
    tag: golang-1.13
releases:
  latest:
{{.OcpVersionTemplate}}
resources:
  '*':
    limits:
      memory: 4Gi
    requests:
      cpu: 100m
      memory: 200Mi
tests:{{range .TestLaneVariants}}
- as: e2e-{{.VariantName}}
  cron: {{.CronMinute}} {{.CronHour}} * * *
  steps:
    cluster_profile: azure4
    test:
    - as: enable-cpu-manager
      cli: latest
      commands: |
        curl -L "https://raw.githubusercontent.com/dhiller/kubevirt-testing/main/hack/kubevirt-testing.sh" | \
          bash -s enable_cpu_manager
      from: base
      resources:
        requests:
          cpu: 100m
          memory: 200Mi
    - as: deploy-kubevirt
      cli: latest
      commands: |
        curl -L "https://raw.githubusercontent.com/dhiller/kubevirt-testing/main/hack/kubevirt-testing.sh" | \
          bash -s {{$.DeployFuncCall}}
      from: base
      resources:
        requests:
          cpu: 100m
          memory: 200Mi
    - as: test
      cli: latest
      commands: |
        export DOCKER_PREFIX='{{$.DockerPrefix}}'
        export KUBEVIRT_E2E_FOCUS='{{.VariantFocusExpression}}'
        export KUBEVIRT_E2E_SKIP='{{.VariantSkipExpression}}'{{if .TestTimeout}}
        export TEST_TIMEOUT="{{.TestTimeout}}"{{end}}
        curl -L "https://raw.githubusercontent.com/dhiller/kubevirt-testing/main/hack/kubevirt-testing.sh" | \
          bash -s {{$.TestFuncCall}}
      from: base
      resources:
        requests:
          cpu: 100m
          memory: 200Mi
      timeout: {{.VariantTimeout}}
    workflow: ipi-azure
  timeout: {{$.ProwJobTimeout}}{{end}}
`

type TestLaneVariant struct {
	VariantName            string
	VariantFocusExpression string
	VariantSkipExpression  string
	VariantTimeout         string
	CronHour               string
	CronMinute             string
	TestTimeout            string
}

type TestLaneSpec struct {
	OcpVersion         string
	OcpVersionTemplate string
	TestFuncCall       string
	DeployFuncCall     string
	DockerPrefix       string
	TestLaneFileSuffix string
	TestLaneVariants   []TestLaneVariant
	ProwJobTimeout     string
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
		for _, variant := range data.TestLaneVariants {
			_ = regexp.MustCompile(variant.VariantFocusExpression)
			_ = regexp.MustCompile(variant.VariantSkipExpression)
		}
		versionTemplate, err := template.New(fmt.Sprintf("versionTemplate[%s]", data.OcpVersionTemplate)).Parse(ocpVersionTemplates[data.OcpVersionTemplate])
		if versionTemplate == nil {
			logger.Panic("versionTemplate is nil!")
		}
		var value bytes.Buffer
		err = versionTemplate.Execute(&value, data)
		checkErr(err)
		data.OcpVersionTemplate = value.String()
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
