package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ghodss/yaml"

	cioperatorapi "github.com/openshift/ci-operator/pkg/api"
	kubeapi "k8s.io/api/core/v1"
	prowconfig "k8s.io/test-infra/prow/config"
	prowkube "k8s.io/test-infra/prow/kube"

	"k8s.io/apimachinery/pkg/api/equality"
	"k8s.io/apimachinery/pkg/util/diff"
)

type options struct {
	ciOperatorConfigPath string
	prowJobConfigPath    string

	fullRepoMode bool

	ciOperatorConfigDir string
	prowJobConfigDir    string

	help    bool
	verbose bool
}

func bindOptions(flag *flag.FlagSet) *options {
	opt := &options{}

	flag.StringVar(&opt.ciOperatorConfigPath, "source-config", "", "Path to ci-operator configuration file in openshift/release repository.")
	flag.StringVar(&opt.prowJobConfigPath, "target-job-config", "", "Path to a file wher Prow job config will be written. If the file already exists and contains Prow job config, generated jobs will be merged with existing ones")

	flag.BoolVar(&opt.fullRepoMode, "full-repo", false, "If set to true, the generator will walk over all ci-operator config files in openshift/release repository and regenerate all component prow job config files")

	flag.StringVar(&opt.ciOperatorConfigDir, "config-dir", "", "Path to a root of directory structure with ci-operator config files (ci-operator/config in openshift/release)")
	flag.StringVar(&opt.prowJobConfigDir, "prow-jobs-dir", "", "Path to a root of directory structure with Prow job config files (ci-operator/jobs in openshift/release)")

	flag.BoolVar(&opt.help, "h", false, "Show help for ci-operator-prowgen")
	flag.BoolVar(&opt.verbose, "v", false, "Show verbose output")

	return opt
}

// Generate a PodSpec that runs `ci-operator`, to be used in Presubmit/Postsubmit
// Various pieces are derived from `org`, `repo`, `branch` and `target`.
// `additionalArgs` are passed as additional arguments to `ci-operator`
func generatePodSpec(org, repo, branch, target string, additionalArgs ...string) *kubeapi.PodSpec {
	configMapKeyRef := kubeapi.EnvVarSource{
		ConfigMapKeyRef: &kubeapi.ConfigMapKeySelector{
			LocalObjectReference: kubeapi.LocalObjectReference{
				Name: fmt.Sprintf("ci-operator-%s-%s", org, repo),
			},
			Key: fmt.Sprintf("%s.json", branch),
		},
	}

	return &kubeapi.PodSpec{
		ServiceAccountName: "ci-operator",
		Containers: []kubeapi.Container{
			kubeapi.Container{
				Image:   "ci-operator:latest",
				Command: []string{"ci-operator"},
				Args:    append([]string{"--artifact-dir=$(ARTIFACTS)", fmt.Sprintf("--target=%s", target)}, additionalArgs...),
				Env: []kubeapi.EnvVar{
					kubeapi.EnvVar{
						Name:      "CONFIG_SPEC",
						ValueFrom: &configMapKeyRef,
					},
				},
			},
		},
	}
}

type testDescription struct {
	Name   string
	Target string
}

// Generate a Presubmit job for the given parameters
func generatePresubmitForTest(test testDescription, org, repo, branch string) *prowconfig.Presubmit {
	return &prowconfig.Presubmit{
		Agent:        "kubernetes",
		AlwaysRun:    true,
		Brancher:     prowconfig.Brancher{Branches: []string{branch}},
		Context:      fmt.Sprintf("ci/prow/%s", test.Name),
		Name:         fmt.Sprintf("pull-ci-%s-%s-%s-%s", org, repo, branch, test.Name),
		RerunCommand: fmt.Sprintf("/test %s", test.Name),
		Spec:         generatePodSpec(org, repo, branch, test.Target),
		Trigger:      fmt.Sprintf(`((?m)^/test( all| %s),?(\\s+|$))`, test.Name),
		UtilityConfig: prowconfig.UtilityConfig{
			DecorationConfig: &prowkube.DecorationConfig{SkipCloning: true},
			Decorate:         true,
		},
	}
}

// Generate a Presubmit job for the given parameters
func generatePostsubmitForTest(test testDescription, org, repo, branch string, additionalArgs ...string) *prowconfig.Postsubmit {
	return &prowconfig.Postsubmit{
		Agent: "kubernetes",
		Name:  fmt.Sprintf("branch-ci-%s-%s-%s-%s", org, repo, branch, test.Name),
		Spec:  generatePodSpec(org, repo, branch, test.Target, additionalArgs...),
		UtilityConfig: prowconfig.UtilityConfig{
			DecorationConfig: &prowkube.DecorationConfig{SkipCloning: true},
			Decorate:         true,
		},
	}
}

// Given a ci-operator configuration file and basic information about what
// should be tested, generate a following JobConfig:
//
// - one presubmit and one postsubmit for each test defined in config file
// - if the config file has non-empty `images` section, generate an additinal
//   presubmit and postsubmit that has `--target=[images]`. This postsubmit
//   will additionally pass `--promote` to ci-operator and it will have
//   `artifacts: images` label
func generateJobs(
	configSpec *cioperatorapi.ReleaseBuildConfiguration,
	org, repo, branch string,
) *prowconfig.JobConfig {

	orgrepo := fmt.Sprintf("%s/%s", org, repo)
	presubmits := map[string][]prowconfig.Presubmit{}
	postsubmits := map[string][]prowconfig.Postsubmit{}

	imagesTest := false

	for _, element := range configSpec.Tests {
		// Check if config file has "images" test defined to avoid name clash
		// (we generate the additional `--target=[images]` jobs name with `images`
		// as an identifier, but a user can have `images` test defined in his
		// config file which would result in a clash)
		if element.As == "images" {
			imagesTest = true
		}
		test := testDescription{Name: element.As, Target: element.As}
		presubmits[orgrepo] = append(presubmits[orgrepo], *generatePresubmitForTest(test, org, repo, branch))
		postsubmits[orgrepo] = append(postsubmits[orgrepo], *generatePostsubmitForTest(test, org, repo, branch))
	}

	if len(configSpec.Images) > 0 {
		var test testDescription
		if imagesTest {
			log.Print(
				"WARNING: input config file has 'images' test defined\n" +
					"This may get confused with built-in '[images]' target. Consider renaming this test.\n",
			)
			test = testDescription{Name: "[images]", Target: "[images]"}
		} else {
			test = testDescription{Name: "images", Target: "[images]"}
		}

		presubmits[orgrepo] = append(presubmits[orgrepo], *generatePresubmitForTest(test, org, repo, branch))
		imagesPostsubmit := generatePostsubmitForTest(test, org, repo, branch, "--promote")
		imagesPostsubmit.Labels = map[string]string{"artifacts": "images"}
		postsubmits[orgrepo] = append(postsubmits[orgrepo], *imagesPostsubmit)
	}

	return &prowconfig.JobConfig{
		Presubmits:  presubmits,
		Postsubmits: postsubmits,
	}
}

func readCiOperatorConfig(configFilePath string) (*cioperatorapi.ReleaseBuildConfiguration, error) {
	data, err := ioutil.ReadFile(configFilePath)
	if err != nil {
		return nil, fmt.Errorf("failed to read ci-operator config (%v)", err)
	}

	var configSpec *cioperatorapi.ReleaseBuildConfiguration
	if err := json.Unmarshal(data, &configSpec); err != nil {
		return nil, fmt.Errorf("failed to load ci-operator config (%v)", err)
	}

	return configSpec, nil
}

// We use the directory/file naming convention to encode useful information
// about component repository information.
// The convention for ci-operator config files in this repo:
// ci-operator/config/ORGANIZATION/COMPONENT/BRANCH.json
func extractRepoElementsFromPath(configFilePath string) (string, string, string, error) {
	configSpecDir := filepath.Dir(configFilePath)
	repo := filepath.Base(configSpecDir)
	if repo == "." || repo == "/" {
		return "", "", "", fmt.Errorf("Could not extract repo from '%s' (expected path like '.../ORG/REPO/BRANCH.json", configFilePath)
	}

	org := filepath.Base(filepath.Dir(configSpecDir))
	if org == "." || org == "/" {
		return "", "", "", fmt.Errorf("Could not extract org from '%s' (expected path like '.../ORG/REPO/BRANCH.json", configFilePath)
	}

	branch := strings.TrimSuffix(filepath.Base(configFilePath), filepath.Ext(configFilePath))

	return org, repo, branch, nil
}

func generateProwJobsFromConfigFile(configFilePath string) (*prowconfig.JobConfig, string, string, error) {
	configSpec, err := readCiOperatorConfig(configFilePath)
	if err != nil {
		return nil, "", "", err
	}

	org, repo, branch, err := extractRepoElementsFromPath(configFilePath)
	if err != nil {
		return nil, "", "", err
	}

	jobConfig := generateJobs(configSpec, org, repo, branch)

	return jobConfig, org, repo, nil
}

func writeJobsIntoComponentDirectory(jobDir, org, repo string, jobConfig *prowconfig.JobConfig) error {
	jobDirForComponent := filepath.Join(jobDir, org, repo)
	os.MkdirAll(jobDirForComponent, os.ModePerm)
	presubmitPath := filepath.Join(jobDirForComponent, fmt.Sprintf("%s-%s-presubmits.yaml", org, repo))
	postsubmitPath := filepath.Join(jobDirForComponent, fmt.Sprintf("%s-%s-postsubmits.yaml", org, repo))

	presubmits := *jobConfig
	presubmits.Postsubmits = nil
	postsubmits := *jobConfig
	postsubmits.Presubmits = nil

	if err := mergeJobsIntoFile(presubmitPath, &presubmits); err != nil {
		return err
	}

	if err := mergeJobsIntoFile(postsubmitPath, &postsubmits); err != nil {
		return err
	}

	return nil
}

// Iterate over all ci-operator config files under a given path and generate a
// Prow job configuration file for each one under a different path, mimicking
// the directory structure.
// Example:
// for each config file like `configDir/org/component/branch.json`
// generate Prow job config file `jobDir/org/component/branch.yaml
func generateAllProwJobs(configDir, jobDir string) error {
	err := filepath.Walk(configDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error encontered while generating Prow job config: %v\n", err)
			return err
		}
		if !info.IsDir() && filepath.Ext(path) == ".json" {
			jobConfig, org, repo, err := generateProwJobsFromConfigFile(path)
			if err != nil {
				return err
			}

			if err = writeJobsIntoComponentDirectory(jobDir, org, repo, jobConfig); err != nil {
				return err
			}
		}
		return nil
	})

	if err != nil {
		return fmt.Errorf("Failed to generate all Prow jobs")
	}

	return nil
}

// Detect the root directory of this Git repository and then return absolute
// ci-operator config (`ci-operator/config`) and prow job config
// (`ci-operator/jobs`) directory paths in it.
func inferConfigDirectories() (string, string, error) {
	repoRootRaw, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", "", fmt.Errorf("failed to determine repository root with 'git rev-parse --show-toplevel' (%v)", err)
	}
	repoRoot := strings.TrimSpace(string(repoRootRaw))
	configDir := filepath.Join(repoRoot, "ci-operator", "config")
	jobDir := filepath.Join(repoRoot, "ci-operator", "jobs")

	return configDir, jobDir, nil
}

func writeJobs(jobConfig *prowconfig.JobConfig) error {
	jobConfigAsYaml, err := yaml.Marshal(*jobConfig)
	if err != nil {
		return fmt.Errorf("failed to marshal the job config (%v)", err)
	}
	fmt.Printf(string(jobConfigAsYaml))
	return nil
}

func readJobConfig(path string) (*prowconfig.JobConfig, error) {
	data, err := ioutil.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read Prow job config (%v)", err)
	}

	var jobConfig *prowconfig.JobConfig
	if err := yaml.Unmarshal(data, &jobConfig); err != nil {
		return nil, fmt.Errorf("failed to load Prow job config (%v)", err)
	}

	return jobConfig, nil
}

func writeJobsToFile(path string, jobConfig *prowconfig.JobConfig) error {
	jobConfigAsYaml, err := yaml.Marshal(*jobConfig)
	if err != nil {
		return fmt.Errorf("failed to marshal the job config (%v)", err)
	}
	if err := ioutil.WriteFile(path, jobConfigAsYaml, 0664); err != nil {
		return fmt.Errorf("Failed to write job config to '%s' (%v)", path, err)
	}

	return nil
}

func mergeJobConfig(destination, source *prowconfig.JobConfig) bool {
	anythingChanged := false
	if source.Presubmits != nil {
		if destination.Presubmits == nil {
			destination.Presubmits = map[string][]prowconfig.Presubmit{}
		}
		for repo, jobs := range source.Presubmits {
			if _, hasKey := destination.Presubmits[repo]; !hasKey {
				destination.Presubmits[repo] = []prowconfig.Presubmit{}
			}
			newJobs := map[string]prowconfig.Presubmit{}
			for _, job := range jobs {
				newJobs[job.Name] = job
			}
			for i, oldJob := range destination.Presubmits[repo] {
				if job, hasKey := newJobs[oldJob.Name]; hasKey {
					if !equality.Semantic.DeepEqual(destination.Presubmits[repo][i], job) {
						log.Printf("Existing Prow job config already has a different presubmit '%s', will be overwritten", oldJob.Name)
						log.Printf("Difference:\n%s", diff.ObjectDiff(destination.Presubmits[repo][i], job))
						destination.Presubmits[repo][i] = job
						anythingChanged = true
					}
					delete(newJobs, oldJob.Name)
				}
			}
			for _, job := range newJobs {
				log.Printf("Adding new presubmit '%s'", job.Name)
				destination.Presubmits[repo] = append(destination.Presubmits[repo], job)
				anythingChanged = true
			}
		}
	}
	if source.Postsubmits != nil {
		if destination.Postsubmits == nil {
			destination.Postsubmits = map[string][]prowconfig.Postsubmit{}
		}
		for repo, jobs := range source.Postsubmits {
			if _, hasKey := destination.Postsubmits[repo]; !hasKey {
				destination.Postsubmits[repo] = []prowconfig.Postsubmit{}
			}
			newJobs := map[string]prowconfig.Postsubmit{}
			for _, job := range jobs {
				newJobs[job.Name] = job
			}
			for i, oldJob := range destination.Postsubmits[repo] {
				if job, hasKey := newJobs[oldJob.Name]; hasKey {
					if !equality.Semantic.DeepEqual(destination.Postsubmits[repo][i], job) {
						log.Printf("Existing Prow job config already has a different postsubmit '%s', will be overwritten", oldJob.Name)
						log.Printf("Difference:\n%s", diff.ObjectDiff(destination.Postsubmits[repo][i], job))
						destination.Postsubmits[repo][i] = job
						anythingChanged = true
					}
					delete(newJobs, oldJob.Name)
				}
			}
			for _, job := range newJobs {
				log.Printf("Adding new postsubmit '%s'", job.Name)
				destination.Postsubmits[repo] = append(destination.Postsubmits[repo], job)
				anythingChanged = true
			}
		}
	}

	return anythingChanged
}

func mergeJobsIntoFile(prowConfigPath string, jobConfig *prowconfig.JobConfig) error {
	existingJobConfig, err := readJobConfig(prowConfigPath)
	if err != nil {
		existingJobConfig = &prowconfig.JobConfig{}
	}
	if wasChanged := mergeJobConfig(existingJobConfig, jobConfig); wasChanged {
		log.Printf("^^^ Generated jobs into '%s'", prowConfigPath)
	}

	if err = writeJobsToFile(prowConfigPath, existingJobConfig); err != nil {
		return err
	}

	return nil
}

func main() {
	flagSet := flag.NewFlagSet("", flag.ExitOnError)
	opt := bindOptions(flagSet)
	flagSet.Parse(os.Args[1:])

	if opt.help {
		flagSet.Usage()
		os.Exit(0)
	}

	if len(opt.ciOperatorConfigPath) > 0 {
		if jobConfig, _, _, err := generateProwJobsFromConfigFile(opt.ciOperatorConfigPath); err != nil {
			fmt.Fprintf(os.Stderr, "%v\n", err)
			os.Exit(1)
		} else {
			if len(opt.prowJobConfigPath) > 0 {
				err = mergeJobsIntoFile(opt.prowJobConfigPath, jobConfig)
			} else {
				err = writeJobs(jobConfig)
			}
			if err != nil {
				fmt.Fprintf(os.Stderr, "failed to write the job configuration (%v)\n", err)
				os.Exit(1)
			}

		}
	} else if opt.fullRepoMode {
		configDir, jobDir, err := inferConfigDirectories()
		if err != nil {
			fmt.Fprintf(os.Stderr, "%v\n", err)
			os.Exit(1)
		}
		generateAllProwJobs(configDir, jobDir)
	} else if len(opt.ciOperatorConfigDir) > 0 && len(opt.prowJobConfigDir) > 0 {
		generateAllProwJobs(opt.ciOperatorConfigDir, opt.prowJobConfigDir)
	} else {
		fmt.Fprintf(os.Stderr, "ci-operator-prowgen needs --source-config, --full-repo or --{config,prow-jobs}-dir option\n")
		os.Exit(1)
	}
}
