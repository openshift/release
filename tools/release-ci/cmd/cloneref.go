package cmd

import (
	"errors"
	"fmt"
	"os"
	"os/exec"

	"github.com/spf13/cobra"

	"github.com/openshift/release/tools/release-ci/pkg/pullrefs"
)

// clonerefCmd clones a PULL_REFS specification
var clonerefCmd = &cobra.Command{
	Use:   "cloneref",
	Short: "Clones a PULL_REFS specification from Prow into the computed directory",
	Long: `Clones a PULL_REFS specification from Prow into the computed directory

PULL_REFS is expected to be in the form of:

base_branch:commit_sha_of_base_branch,pull_request_no:commit_sha_of_pull_request_no,...

For example:
master:97d901d,4:bcb00a1

And for multiple pull requests that have been batched:
master:97d901d,4:bcb00a1,6:ddk2tka`,
	Run: func(cmd *cobra.Command, _ []string) {
		if err := cloneRefs(); err != nil {
			fmt.Printf("Error: %v\n", err)
			os.Exit(1)
		}
	},
}

var srcRoot string

func init() {
	RootCmd.AddCommand(clonerefCmd)
	clonerefCmd.Flags().StringVar(&srcRoot, "src-root", "", "The root of source checkouts")
}

func cloneRefs() error {
	// Check that git is available
	if _, err := exec.LookPath("git"); err != nil {
		return errors.New("git not found. Ensure that it is available and in the path")
	}

	if len(srcRoot) < 0 {
		return errors.New("a source root must be specified")
	}

	repoOwner, ok := os.LookupEnv("REPO_OWNER")
	if !ok {
		return errors.New("REPO_OWNER environment variable must be set")
	}

	repoName, ok := os.LookupEnv("REPO_NAME")
	if !ok {
		return errors.New("REPO_NAME environment variable must be set")
	}
	repositoryUrl := fmt.Sprintf("https://github.com/%s/%s.git", repoOwner, repoName)
	cloneDir := fmt.Sprintf("%s/src/github.com/%s/%s", srcRoot, repoOwner, repoName)

	pullRefs, ok := os.LookupEnv("PULL_REFS")
	if !ok {
		return errors.New("PULL_REFS environment variable must be set")
	}
	sourceRef, err := pullrefs.ParsePullRefs(pullRefs)
	if err != nil {
		return err
	}
	sourceRef.RepositoryURL = repositoryUrl

	return pullrefs.CloneRef(*sourceRef, cloneDir, pullrefs.NewExecRunner(os.Stdout, os.Stderr))
}
