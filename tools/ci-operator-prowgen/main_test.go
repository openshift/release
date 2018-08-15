package main

import (
	"strings"
	"testing"

	ciop "github.com/openshift/ci-operator/pkg/api"
)

func checkCondition(t *testing.T, forHumans string, condition bool) {
	if !condition {
		t.Errorf("'%s' does not hold", forHumans)
	}
}

func checkString(t *testing.T, member, value, expected string) {
	if value != expected {
		t.Errorf(
			"%s not set correctly: expected '%s', got '%s'",
			member,
			expected,
			value,
		)
	}
}

func TestGeneratePodSpec(t *testing.T) {
	podSpec := generatePodSpec("organization", "repo", "branch", "target")
	checkString(t, "podSpec.ServiceAccountName", podSpec.ServiceAccountName, "ci-operator")
	checkString(t, "podSpec.Containers[0].Image", podSpec.Containers[0].Image, "ci-operator:latest")
	checkString(t, "podSpec.Containers[0].Command[0]", podSpec.Containers[0].Command[0], "ci-operator")
	checkString(t,
		"podSpec.Containers[0].Args",
		strings.Join(podSpec.Containers[0].Args, " "),
		"--artifact-dir=$(ARTIFACTS) --target=target",
	)
	checkString(t, "podSpec.Containers[0].Env[0].Name", podSpec.Containers[0].Env[0].Name, "CONFIG_SPEC")
	checkString(t,
		"podSpec.Containers[0].Env[0].ValueFrom.ConfigMapKeyRef.LocalObjectReference.Name",
		podSpec.Containers[0].Env[0].ValueFrom.ConfigMapKeyRef.LocalObjectReference.Name,
		"ci-operator-organization-repo",
	)
	checkString(t,
		"podSpec.Containers[0].Env[0].ValueFrom.ConfigMapKeyRef.Key",
		podSpec.Containers[0].Env[0].ValueFrom.ConfigMapKeyRef.Key,
		"branch.json",
	)
}

func TestGeneratePodSpecWithAdditionalArgs(t *testing.T) {
	podSpec := generatePodSpec("organization", "repo", "branch", "target", "--promote", "something")
	checkString(t,
		"podSpec.Containers[0].Args",
		strings.Join(podSpec.Containers[0].Args, " "),
		"--artifact-dir=$(ARTIFACTS) --target=target --promote something",
	)
}

func TestGeneratePresubmitForTest(t *testing.T) {
	presubmit := generatePresubmitForTest(testDescription{"name", "target"}, "organization", "repo", "branch")
	checkString(t, "presubmit.Agent", presubmit.Agent, "kubernetes")
	checkCondition(t, "presubmit.AlwaysRun == true", presubmit.AlwaysRun)
	checkString(t, "presubmit.Brancher.Branches[0]", presubmit.Brancher.Branches[0], "branch")
	checkString(t, "presubmit.Context", presubmit.Context, "ci/prow/name")
	checkString(t, "presubmit.Name", presubmit.Name, "pull-ci-organization-repo-name")
	checkString(t, "presubmit.RerunCommand", presubmit.RerunCommand, "/test name")
	checkCondition(t, "presubmit.Spec != nil", presubmit.Spec != nil)
	checkString(t, "presubmit.Trigger", presubmit.Trigger, "((?m)^/test( all| name),?(\\\\s+|$))")
	checkCondition(t,
		"presubmit.UtilityConfig.DecorationConfig.SkipCloning == true",
		presubmit.UtilityConfig.DecorationConfig.SkipCloning,
	)
	checkCondition(t, "presubmit.UtilityConfig.Decorate == true", presubmit.UtilityConfig.Decorate)
}

func TestGeneratePostsubmitForTest(t *testing.T) {
	postsubmit := generatePostsubmitForTest(
		testDescription{"name", "target"},
		"organization",
		"repo",
		"branch",
		"--promote",
		"something",
	)
	checkString(t, "postsubmit.Agent", postsubmit.Agent, "kubernetes")
	checkString(t, "postsubmit.Name", postsubmit.Name, "branch-ci-organization-repo-name")
	checkCondition(t, "postsubmit.Spec != nil", postsubmit.Spec != nil)
	checkString(t,
		"postsubmit.Spec.Containers[0].Args",
		strings.Join(postsubmit.Spec.Containers[0].Args, " "),
		"--artifact-dir=$(ARTIFACTS) --target=target --promote something",
	)

	checkCondition(t,
		"postsubmit.UtilityConfig.DecorationConfig.SkipCloning == true",
		postsubmit.UtilityConfig.DecorationConfig.SkipCloning,
	)
	checkCondition(t, "postsubmit.UtilityConfig.Decorate == true", postsubmit.UtilityConfig.Decorate)
}

func TestGenerateJobs(t *testing.T) {
	mockConfig := ciop.ReleaseBuildConfiguration{
		Tests: []ciop.TestStepConfiguration{
			ciop.TestStepConfiguration{As: "derTest"},
			ciop.TestStepConfiguration{As: "leTest"},
		}}
	jobConfig := generateJobs(&mockConfig, "organization", "repo", "branch")
	presubmits := (*jobConfig).Presubmits
	postsubmits := (*jobConfig).Postsubmits

	checkCondition(t, "len(presubmits) == 1", len(presubmits) == 1)
	checkCondition(t, "len(postsubmits) == 1", len(postsubmits) == 1)
	checkCondition(t,
		"len(presubmits[\"organization/repo\"]) == 2",
		len(presubmits["organization/repo"]) == 2,
	)
	checkCondition(t,
		"len(postsubmits[\"organization/repo\"]) == 2",
		len(postsubmits["organization/repo"]) == 2,
	)
	checkString(t,
		"presubmits[\"organization/repo\"][0].Name",
		presubmits["organization/repo"][0].Name,
		"pull-ci-organization-repo-derTest",
	)
	checkString(t,
		"postsubmits[\"organization/repo\"][0].Name",
		postsubmits["organization/repo"][0].Name,
		"branch-ci-organization-repo-derTest",
	)
}

func TestGenerateJobsWithImages(t *testing.T) {
	mockConfig := ciop.ReleaseBuildConfiguration{
		Images: []ciop.ProjectDirectoryImageBuildStepConfiguration{
			ciop.ProjectDirectoryImageBuildStepConfiguration{},
		},
		Tests: []ciop.TestStepConfiguration{
			ciop.TestStepConfiguration{As: "derTest"},
			ciop.TestStepConfiguration{As: "leTest"},
		}}
	jobConfig := generateJobs(&mockConfig, "organization", "repo", "branch")
	presubmits := (*jobConfig).Presubmits
	postsubmits := (*jobConfig).Postsubmits

	checkCondition(t, "len(presubmits) == 1", len(presubmits) == 1)
	checkCondition(t, "len(postsubmits) == 1", len(postsubmits) == 1)
	checkCondition(t,
		"len(presubmits[\"organization/repo\"]) == 3",
		len(presubmits["organization/repo"]) == 3,
	)
	checkCondition(t,
		"len(postsubmits[\"organization/repo\"]) == 3",
		len(postsubmits["organization/repo"]) == 3,
	)
	checkString(t,
		"presubmits[\"organization/repo\"][2].Name",
		presubmits["organization/repo"][2].Name,
		"pull-ci-organization-repo-images",
	)
	checkString(t,
		"postsubmits[\"organization/repo\"][2].Name",
		postsubmits["organization/repo"][2].Name,
		"branch-ci-organization-repo-images",
	)
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
