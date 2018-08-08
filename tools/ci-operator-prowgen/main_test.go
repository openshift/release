package main

import (
	"io/ioutil"
	"log"
	"testing"

	ciop "github.com/openshift/ci-operator/pkg/api"
	kubeapi "k8s.io/api/core/v1"
	prowconfig "k8s.io/test-infra/prow/config"
	prowkube "k8s.io/test-infra/prow/kube"

	"k8s.io/apimachinery/pkg/api/equality"
	"k8s.io/apimachinery/pkg/util/diff"
)

func TestGeneratePodSpec(t *testing.T) {
	tests := []struct {
		org            string
		repo           string
		branch         string
		target         string
		additionalArgs []string

		expected *kubeapi.PodSpec
	}{
		{
			org:            "organization",
			repo:           "repo",
			branch:         "branch",
			target:         "target",
			additionalArgs: []string{},

			expected: &kubeapi.PodSpec{
				ServiceAccountName: "ci-operator",
				Containers: []kubeapi.Container{
					kubeapi.Container{
						Image:   "ci-operator:latest",
						Command: []string{"ci-operator"},
						Args:    []string{"--artifact-dir=$(ARTIFACTS)", "--target=target"},
						Env: []kubeapi.EnvVar{
							kubeapi.EnvVar{
								Name: "CONFIG_SPEC",
								ValueFrom: &kubeapi.EnvVarSource{
									ConfigMapKeyRef: &kubeapi.ConfigMapKeySelector{
										LocalObjectReference: kubeapi.LocalObjectReference{
											Name: "ci-operator-organization-repo",
										},
										Key: "branch.json",
									},
								},
							},
						},
					},
				},
			},
		},
		{
			org:            "organization",
			repo:           "repo",
			branch:         "branch",
			target:         "target",
			additionalArgs: []string{"--promote", "something"},

			expected: &kubeapi.PodSpec{
				ServiceAccountName: "ci-operator",
				Containers: []kubeapi.Container{
					kubeapi.Container{
						Image:   "ci-operator:latest",
						Command: []string{"ci-operator"},
						Args:    []string{"--artifact-dir=$(ARTIFACTS)", "--target=target", "--promote", "something"},
						Env: []kubeapi.EnvVar{
							kubeapi.EnvVar{
								Name: "CONFIG_SPEC",
								ValueFrom: &kubeapi.EnvVarSource{
									ConfigMapKeyRef: &kubeapi.ConfigMapKeySelector{
										LocalObjectReference: kubeapi.LocalObjectReference{
											Name: "ci-operator-organization-repo",
										},
										Key: "branch.json",
									},
								},
							},
						},
					},
				},
			},
		},
	}

	for _, tc := range tests {
		var podSpec *kubeapi.PodSpec
		if len(tc.additionalArgs) == 0 {
			podSpec = generatePodSpec(tc.org, tc.repo, tc.branch, tc.target)
		} else {
			podSpec = generatePodSpec(tc.org, tc.repo, tc.branch, tc.target, tc.additionalArgs...)
		}
		if !equality.Semantic.DeepEqual(podSpec, tc.expected) {
			t.Errorf("expected PodSpec diff:\n%s", diff.ObjectDiff(tc.expected, podSpec))
		}
	}
}

func TestGeneratePresubmitForTest(t *testing.T) {
	tests := []struct {
		name     string
		target   string
		org      string
		repo     string
		branch   string
		expected *prowconfig.Presubmit
	}{
		{
			name:   "testname",
			target: "target",
			org:    "org",
			repo:   "repo",
			branch: "branch",

			expected: &prowconfig.Presubmit{
				Agent:        "kubernetes",
				AlwaysRun:    true,
				Brancher:     prowconfig.Brancher{Branches: []string{"branch"}},
				Context:      "ci/prow/testname",
				Name:         "pull-ci-org-repo-branch-testname",
				RerunCommand: "/test testname",
				Trigger:      `((?m)^/test( all| testname),?(\\s+|$))`,
				UtilityConfig: prowconfig.UtilityConfig{
					DecorationConfig: &prowkube.DecorationConfig{SkipCloning: true},
					Decorate:         true,
				},
			},
		},
	}
	for _, tc := range tests {
		presubmit := generatePresubmitForTest(testDescription{tc.name, tc.target}, tc.org, tc.repo, tc.branch)
		presubmit.Spec = nil // tested in generatePodSpec

		if !equality.Semantic.DeepEqual(presubmit, tc.expected) {
			t.Errorf("expected presubmit diff:\n%s", diff.ObjectDiff(tc.expected, presubmit))
		}
	}
}

func TestGeneratePostSumitForTest(t *testing.T) {
	tests := []struct {
		name           string
		target         string
		org            string
		repo           string
		branch         string
		additionalArgs []string

		expected *prowconfig.Postsubmit
	}{
		{
			name:           "name",
			target:         "target",
			org:            "organization",
			repo:           "repository",
			branch:         "branch",
			additionalArgs: []string{},

			expected: &prowconfig.Postsubmit{
				Agent: "kubernetes",
				Name:  "branch-ci-organization-repository-branch-name",
				UtilityConfig: prowconfig.UtilityConfig{
					DecorationConfig: &prowkube.DecorationConfig{SkipCloning: true},
					Decorate:         true,
				},
			},
		},
		{
			name:           "name",
			target:         "target",
			org:            "organization",
			repo:           "repository",
			branch:         "branch",
			additionalArgs: []string{"--promote", "additionalArg"},

			expected: &prowconfig.Postsubmit{
				Agent: "kubernetes",
				Name:  "branch-ci-organization-repository-branch-name",
				UtilityConfig: prowconfig.UtilityConfig{
					DecorationConfig: &prowkube.DecorationConfig{SkipCloning: true},
					Decorate:         true,
				},
			},
		},
	}
	for _, tc := range tests {
		var postsubmit *prowconfig.Postsubmit

		if len(tc.additionalArgs) == 0 {
			postsubmit = generatePostsubmitForTest(testDescription{tc.name, tc.target}, tc.org, tc.repo, tc.branch)
		} else {
			postsubmit = generatePostsubmitForTest(testDescription{tc.name, tc.target}, tc.org, tc.repo, tc.branch, tc.additionalArgs...)
			// tests that additional args were propagated to the PodSpec
			if !equality.Semantic.DeepEqual(postsubmit.Spec.Containers[0].Args[2:], tc.additionalArgs) {
				t.Errorf("additional args not propagated to postsubmit:\n%s", diff.ObjectDiff(tc.additionalArgs, postsubmit.Spec.Containers[0].Args[2:]))
			}
		}

		postsubmit.Spec = nil // tested in TestGeneratePodSpec

		if !equality.Semantic.DeepEqual(postsubmit, tc.expected) {
			t.Errorf("expected postsubmit diff:\n%s", diff.ObjectDiff(tc.expected, postsubmit))
		}
	}
}

func TestGenerateJobs(t *testing.T) {
	tests := []struct {
		config *ciop.ReleaseBuildConfiguration
		org    string
		repo   string
		branch string

		expectedPresubmits  map[string][]string
		expectedPostsubmits map[string][]string
		expected            *prowconfig.JobConfig
	}{
		{
			config: &ciop.ReleaseBuildConfiguration{
				Tests: []ciop.TestStepConfiguration{
					ciop.TestStepConfiguration{As: "derTest"},
					ciop.TestStepConfiguration{As: "leTest"},
				},
			},
			org:    "organization",
			repo:   "repository",
			branch: "branch",
			expected: &prowconfig.JobConfig{
				Presubmits: map[string][]prowconfig.Presubmit{
					"organization/repository": []prowconfig.Presubmit{
						prowconfig.Presubmit{Name: "pull-ci-organization-repository-branch-derTest"},
						prowconfig.Presubmit{Name: "pull-ci-organization-repository-branch-leTest"},
					},
				},
				Postsubmits: map[string][]prowconfig.Postsubmit{},
			},
		}, {
			config: &ciop.ReleaseBuildConfiguration{
				Tests: []ciop.TestStepConfiguration{
					ciop.TestStepConfiguration{As: "derTest"},
					ciop.TestStepConfiguration{As: "leTest"},
				},
				Images: []ciop.ProjectDirectoryImageBuildStepConfiguration{
					ciop.ProjectDirectoryImageBuildStepConfiguration{},
				},
			},
			org:    "organization",
			repo:   "repository",
			branch: "branch",
			expected: &prowconfig.JobConfig{
				Presubmits: map[string][]prowconfig.Presubmit{
					"organization/repository": []prowconfig.Presubmit{
						prowconfig.Presubmit{Name: "pull-ci-organization-repository-branch-derTest"},
						prowconfig.Presubmit{Name: "pull-ci-organization-repository-branch-leTest"},
						prowconfig.Presubmit{Name: "pull-ci-organization-repository-branch-images"},
					},
				},
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{
							Name: "branch-ci-organization-repository-branch-images",
						},
					},
				},
			},
		}, {
			config: &ciop.ReleaseBuildConfiguration{
				Tests: []ciop.TestStepConfiguration{
					ciop.TestStepConfiguration{As: "images"},
				},
				Images: []ciop.ProjectDirectoryImageBuildStepConfiguration{
					ciop.ProjectDirectoryImageBuildStepConfiguration{},
				},
			},
			org:    "organization",
			repo:   "repository",
			branch: "branch",
			expected: &prowconfig.JobConfig{
				Presubmits: map[string][]prowconfig.Presubmit{
					"organization/repository": []prowconfig.Presubmit{
						prowconfig.Presubmit{Name: "pull-ci-organization-repository-branch-images"},
						prowconfig.Presubmit{Name: "pull-ci-organization-repository-branch-[images]"},
					},
				},
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{
							Name: "branch-ci-organization-repository-branch-[images]",
						},
					},
				},
			},
		},
	}

	log.SetOutput(ioutil.Discard)
	for _, tc := range tests {
		jobConfig := generateJobs(tc.config, tc.org, tc.repo, tc.branch)

		prune(jobConfig) // prune the fields that are tested in TestGeneratePre/PostsubmitForTest

		if !equality.Semantic.DeepEqual(jobConfig, tc.expected) {
			t.Errorf("expected job config diff:\n%s", diff.ObjectDiff(tc.expected, jobConfig))
		}
	}
}

func prune(jobConfig *prowconfig.JobConfig) {
	for repo := range jobConfig.Presubmits {
		for i := range jobConfig.Presubmits[repo] {
			jobConfig.Presubmits[repo][i].AlwaysRun = false
			jobConfig.Presubmits[repo][i].Context = ""
			jobConfig.Presubmits[repo][i].Trigger = ""
			jobConfig.Presubmits[repo][i].RerunCommand = ""
			jobConfig.Presubmits[repo][i].Agent = ""
			jobConfig.Presubmits[repo][i].Spec = nil
			jobConfig.Presubmits[repo][i].Brancher = prowconfig.Brancher{}
			jobConfig.Presubmits[repo][i].UtilityConfig = prowconfig.UtilityConfig{}
		}
	}
	for repo := range jobConfig.Postsubmits {
		for i := range jobConfig.Postsubmits[repo] {
			jobConfig.Postsubmits[repo][i].Agent = ""
			jobConfig.Postsubmits[repo][i].Spec = nil
			jobConfig.Postsubmits[repo][i].UtilityConfig = prowconfig.UtilityConfig{}
		}
	}
}

func TestExtractRepoElementsFromPath(t *testing.T) {
	testCases := []struct {
		path           string
		expectedOrg    string
		expectedRepo   string
		expectedBranch string
		expectedError  bool
	}{
		{"../../ci-operator/openshift/component/master.json", "openshift", "component", "master", false},
		{"master.json", "", "", "", true},
		{"dir/master.json", "", "", "", true},
	}
	for _, tc := range testCases {
		t.Run(tc.path, func(t *testing.T) {
			org, repo, branch, err := extractRepoElementsFromPath(tc.path)
			if !tc.expectedError {
				if err != nil {
					t.Errorf("returned unexpected error '%v", err)
				}
				if org != tc.expectedOrg {
					t.Errorf("org extracted incorrectly: got '%s', expected '%s'", org, tc.expectedOrg)
				}
				if repo != tc.expectedRepo {
					t.Errorf("repo extracted incorrectly: got '%s', expected '%s'", repo, tc.expectedRepo)
				}
				if branch != tc.expectedBranch {
					t.Errorf("branch extracted incorrectly: got '%s', expected '%s'", branch, tc.expectedBranch)
				}
			} else { // expected error
				if err == nil {
					t.Errorf("expected to return error, got org=%s repo=%s branch=%s instead", org, repo, branch)
				}
			}
		})
	}
}

func TestMergeJobConfig(t *testing.T) {
	tests := []struct {
		destination, source, expected *prowconfig.JobConfig
	}{
		{
			destination: &prowconfig.JobConfig{},
			source: &prowconfig.JobConfig{
				Presubmits: map[string][]prowconfig.Presubmit{
					"organization/repository": []prowconfig.Presubmit{
						prowconfig.Presubmit{Name: "source-job", Context: "ci/prow/source"},
					},
				},
			},
			expected: &prowconfig.JobConfig{
				Presubmits: map[string][]prowconfig.Presubmit{
					"organization/repository": []prowconfig.Presubmit{
						prowconfig.Presubmit{Name: "source-job", Context: "ci/prow/source"},
					},
				},
			},
		}, {
			destination: &prowconfig.JobConfig{
				Presubmits: map[string][]prowconfig.Presubmit{
					"organization/repository": []prowconfig.Presubmit{
						prowconfig.Presubmit{Name: "another-job", Context: "ci/prow/another"},
					},
				},
			},
			source: &prowconfig.JobConfig{
				Presubmits: map[string][]prowconfig.Presubmit{
					"organization/repository": []prowconfig.Presubmit{
						prowconfig.Presubmit{Name: "source-job", Context: "ci/prow/source"},
					},
				},
			},
			expected: &prowconfig.JobConfig{
				Presubmits: map[string][]prowconfig.Presubmit{
					"organization/repository": []prowconfig.Presubmit{
						prowconfig.Presubmit{Name: "source-job", Context: "ci/prow/source"},
						prowconfig.Presubmit{Name: "another-job", Context: "ci/prow/another"},
					},
				},
			},
		}, {
			destination: &prowconfig.JobConfig{
				Presubmits: map[string][]prowconfig.Presubmit{
					"organization/repository": []prowconfig.Presubmit{
						prowconfig.Presubmit{Name: "same-job", Context: "ci/prow/same"},
					},
				},
			},
			source: &prowconfig.JobConfig{
				Presubmits: map[string][]prowconfig.Presubmit{
					"organization/repository": []prowconfig.Presubmit{
						prowconfig.Presubmit{Name: "same-job", Context: "ci/prow/different"},
					},
				},
			},
			expected: &prowconfig.JobConfig{
				Presubmits: map[string][]prowconfig.Presubmit{
					"organization/repository": []prowconfig.Presubmit{
						prowconfig.Presubmit{Name: "same-job", Context: "ci/prow/different"},
					},
				},
			},
		}, {
			destination: &prowconfig.JobConfig{},
			source: &prowconfig.JobConfig{
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{Name: "source-job", Agent: "ci/prow/source"},
					},
				},
			},
			expected: &prowconfig.JobConfig{
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{Name: "source-job", Agent: "ci/prow/source"},
					},
				},
			},
		}, {
			destination: &prowconfig.JobConfig{
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{Name: "another-job", Agent: "ci/prow/another"},
					},
				},
			},
			source: &prowconfig.JobConfig{
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{Name: "source-job", Agent: "ci/prow/source"},
					},
				},
			},
			expected: &prowconfig.JobConfig{
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{Name: "source-job", Agent: "ci/prow/source"},
						prowconfig.Postsubmit{Name: "another-job", Agent: "ci/prow/another"},
					},
				},
			},
		}, {
			destination: &prowconfig.JobConfig{
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{Name: "same-job", Agent: "ci/prow/same"},
					},
				},
			},
			source: &prowconfig.JobConfig{
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{Name: "same-job", Agent: "ci/prow/different"},
					},
				},
			},
			expected: &prowconfig.JobConfig{
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{Name: "same-job", Agent: "ci/prow/different"},
					},
				},
			},
		}, {
			destination: &prowconfig.JobConfig{
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{Name: "same-job", Agent: "ci/prow/same"},
					},
				},
			},
			source: &prowconfig.JobConfig{
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{Name: "same-job", Agent: "ci/prow/same"},
					},
				},
			},
			expected: &prowconfig.JobConfig{
				Postsubmits: map[string][]prowconfig.Postsubmit{
					"organization/repository": []prowconfig.Postsubmit{
						prowconfig.Postsubmit{Name: "same-job", Agent: "ci/prow/same"},
					},
				},
			},
		},
	}
	for _, tc := range tests {
		mergeJobConfig(tc.destination, tc.source)

		if !equality.Semantic.DeepEqual(tc.destination, tc.expected) {
			t.Errorf("expected merged job config diff:\n%s", diff.ObjectDiff(tc.expected, tc.destination))
		}
	}
}
