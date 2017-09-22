package config

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"

	"github.com/openshift/release/tools/release-ci/pkg/pullrefs"
)

func Save(file string) error {
	repoMeta, err := retrieveRepoMeta()
	if err != nil {
		return fmt.Errorf("failed to retrieve repository metadata: %v", err)
	}

	job, err := retrieveJobConfig()
	if err != nil {
		return fmt.Errorf("failed to retieve job config: %v", err)
	}

	repo, repoPresent, err := retrieveRepoConfig()
	if err != nil {
		return fmt.Errorf("failed to retrieve repo config: %v", err)
	}

	pull, pullPresent, err := retrievePullConfig()
	if err != nil {
		return fmt.Errorf("failed to retrieve pull config: %v", err)
	}

	var data Data
	if !repoPresent && !pullPresent {
		data = &Periodic{Job: job, RepoMeta: repoMeta}
	}
	if repoPresent && !pullPresent {
		sourceRef, err := pullrefs.ParsePullRefs(repo.PullRefs)
		if err != nil {
			return fmt.Errorf("failed to parse $PULL_REFS: %v", err)
		}
		if len(sourceRef.PullRefs) > 1 {
			data = &Batch{Job: job, Repo: repo}
		} else {
			data = &Postsubmit{Job: job, Repo: repo}
		}
	}
	if repoPresent && pullPresent {
		data = &Presubmit{Job: job, Repo: repo, PullRequest: pull}
	}

	var marshalled json.RawMessage
	if raw, err := json.Marshal(data); err != nil {
		return fmt.Errorf("failed to marshal job config: %v", err)
	} else {
		marshalled = raw
	}
	rawConfig := anyConfig{
		ConfigType: data.Type(),
		Config:     marshalled,
	}

	output, err := os.Create(file)
	if err != nil {
		return fmt.Errorf("could not open %s to write config: %v", file, err)
	}
	defer output.Close()

	return json.NewEncoder(output).Encode(rawConfig)
}

func retrieveJobConfig() (Job, error) {
	var missing []string
	jobName, ok := os.LookupEnv("JOB_NAME")
	if !ok {
		missing = append(missing, "JOB_NAME")
	}

	var buildNumber int
	rawBuildNumber, ok := os.LookupEnv("BUILD_NUMBER")
	if !ok {
		missing = append(missing, "BUILD_NUMBER")
	} else {
		if number, err := strconv.Atoi(rawBuildNumber); err != nil {
			return Job{}, fmt.Errorf("failed to parse build number: %v", err)
		} else {
			buildNumber = number
		}
	}

	testName, _ := os.LookupEnv("TEST_NAME")

	if len(missing) > 0 {
		return Job{}, fmt.Errorf("missing environment variables %v", missing)
	}

	return Job{
		JobName:     jobName,
		BuildNumber: buildNumber,
		TestName:    testName,
	}, nil
}

func retrieveRepoMeta() (RepoMeta, error) {
	var missing []string
	repoOwner, ok := os.LookupEnv("REPO_OWNER")
	if !ok {
		missing = append(missing, "REPO_OWNER")
	}

	repoName, ok := os.LookupEnv("REPO_NAME")
	if !ok {
		missing = append(missing, "REPO_NAME")
	}

	if len(missing) > 0 {
		return RepoMeta{}, fmt.Errorf("missing environment variables %v", missing)
	}

	return RepoMeta{
		RepoOwner: repoOwner,
		RepoName:  repoName,
	}, nil
}

func retrieveRepoConfig() (Repo, bool, error) {
	var missing []string

	baseRef, ok := os.LookupEnv("PULL_BASE_REF")
	if !ok {
		missing = append(missing, "PULL_BASE_REF")
	}

	baseSha, ok := os.LookupEnv("PULL_BASE_SHA")
	if !ok {
		missing = append(missing, "PULL_BASE_SHA")
	}

	pullRefs, ok := os.LookupEnv("PULL_REFS")
	if !ok {
		missing = append(missing, "PULL_REFS")
	}

	if len(missing) > 0 {
		if len(missing) == 3 {
			// if everything is missing, we just don't have
			// a repository configuration in this job
			return Repo{}, false, nil
		}

		// if we are partially missing, there has been
		// some error
		return Repo{}, false, fmt.Errorf("missing environment variables %v", missing)
	}

	return Repo{
		BaseRef:  baseRef,
		BaseSha:  baseSha,
		PullRefs: pullRefs,
	}, true, nil
}

func retrievePullConfig() (PullRequest, bool, error) {
	var missing []string
	var pullNumber int
	rawPullNumber, ok := os.LookupEnv("PULL_NUMBER")
	if !ok {
		missing = append(missing, "PULL_NUMBER")
	} else {
		if number, err := strconv.Atoi(rawPullNumber); err != nil {
			return PullRequest{}, false, fmt.Errorf("failed to parse build number: %v", err)
		} else {
			pullNumber = number
		}
	}

	pullSha, ok := os.LookupEnv("PULL_PULL_SHA")
	if !ok {
		missing = append(missing, "PULL_PULL_SHA")
	}

	if len(missing) > 0 {
		if len(missing) == 2 {
			// if everything is missing, we just don't have
			// a pull request configuration in this job
			return PullRequest{}, false, nil
		}

		// if we are partially missing, there has been
		// some error
		return PullRequest{}, false, fmt.Errorf("missing environment variables %v", missing)
	}

	return PullRequest{
		PullNumber: pullNumber,
		PullSha:    pullSha,
	}, true, nil
}
