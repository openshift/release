package main

import (
	_ "embed"
	"flag"
	"fmt"
	"gopkg.in/yaml.v3"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"text/template"
)

type TestLaneVariant struct {
	VariantName            string `yaml:"variantName"`
	VariantFocusExpression string `yaml:"variantFocusExpression"`
	VariantSkipExpression  string `yaml:"variantSkipExpression"`
	VariantTimeout         string `yaml:"variantTimeout"`
	CronHour               string `yaml:"cronHour"`
	CronMinute             string `yaml:"cronMinute"`
	TestTimeout            string `yaml:"testTimeout"`
}

type TestLaneSpec struct {
	OcpVersion         string            `yaml:"ocpVersion"`
	KubeVirtVersion    string            `yaml:"kubeVirtVersion"`
	OcpVersionTemplate string            `yaml:"ocpVersionTemplate"`
	TestFuncCall       string            `yaml:"testFuncCall"`
	DeployFuncCall     string            `yaml:"deployFuncCall"`
	DockerPrefix       string            `yaml:"dockerPrefix"`
	TestLaneFileSuffix string            `yaml:"testLaneFileSuffix"`
	TestLaneVariants   []TestLaneVariant `yaml:"testLaneVariants"`
	ProwJobTimeout     string            `yaml:"prowJobTimeout"`
}

//go:embed test-lane.gotemplate
var testLaneTemplate string

var configDir string
var logger *log.Logger
var parsedTemplate *template.Template

func init() {
	logger = log.Default()

	flag.StringVar(&configDir, "config-path", "ci-operator/config/kubevirt/kubevirt", "The path to the test lane configurations")
	flag.Parse()

	var err error
	parsedTemplate, err = template.New("testLane").Parse(testLaneTemplate)
	panicOnErr(err)
}

func main() {
	logger.Printf("Generation of test lanes in %s started", configDir)

	var err error
	file, err := os.ReadFile(filepath.Join(configDir, "test-mapping-kubevirt-openshift.yaml_"))
	panicOnErr(err)
	var kubeVirtVersionsToOpenShiftVersions []TestLaneSpec
	err = yaml.Unmarshal(file, &kubeVirtVersionsToOpenShiftVersions)
	panicOnErr(err)
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
		panicOnErr(err)
	}
	panicOnErr(err)
	for _, data := range kubeVirtVersionsToOpenShiftVersions {
		if data.KubeVirtVersion == "nightly" {
			data.DeployFuncCall, data.TestFuncCall = "deploy_nightly_test_setup", "test_nightly"
		} else {
			data.DeployFuncCall = fmt.Sprintf("deploy_%s_test_setup %s", data.OcpVersionTemplate, data.KubeVirtVersion)
			data.TestFuncCall = fmt.Sprintf("test_%s %s", data.OcpVersionTemplate, data.KubeVirtVersion)
		}
		data.TestLaneFileSuffix = fmt.Sprintf("%s_%s", data.KubeVirtVersion, data.OcpVersion)
		for _, variant := range data.TestLaneVariants {
			_ = regexp.MustCompile(variant.VariantFocusExpression)
			_ = regexp.MustCompile(variant.VariantSkipExpression)
		}
		targetFileName := filepath.Join(configDir, fmt.Sprintf("kubevirt-kubevirt-main__%s.yaml", data.TestLaneFileSuffix))
		createdFile, err := os.Create(targetFileName)
		panicOnErr(err)
		defer func(createdFile *os.File) {
			err := createdFile.Close()
			panicOnErr(err)
		}(createdFile)
		err = parsedTemplate.Execute(createdFile, data)
		panicOnErr(err)
		logger.Printf("Generated config %s from data %+v", targetFileName, data)
	}
}

func panicOnErr(err error) {
	if err != nil {
		logger.Panic(err)
	}
}
