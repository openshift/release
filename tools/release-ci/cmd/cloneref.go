package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/openshift/release/tools/release-ci/pkg/pullrefs"
)

// clonerefCmd clones a PULL_REFS specification
var clonerefCmd = &cobra.Command{
	Use:   "cloneref REPOSITORY_URL [PULL_REFS]",
	Short: "Clones a PULL_REFS specification from Prow into the specified directory",
	Long: `Clones a PULL_REFS specification from Prow into the specified directory
	
PULL_REFS is expected to be in the form of:

base_branch:commit_sha_of_base_branch,pull_request_no:commit_sha_of_pull_request_no,...

For example:
master:97d901d,4:bcb00a1

And for multiple pull requests that have been batched:
master:97d901d,4:bcb00a1,6:ddk2tka

If PULL_REFS is not specified as an argument, the command will try to find it as
an environment variable.

The destination directory may be specified with --destination-dir. If not specified,
the current working directory will be used.`,
	Run: func(cmd *cobra.Command, args []string) {
		if err := cloneRefs(args); err != nil {
			fmt.Printf("Error: %v\n", err)
			os.Exit(1)
		}
	},
}

var cloneDestinationDir string

func init() {
	RootCmd.AddCommand(clonerefCmd)
	clonerefCmd.Flags().StringVar(&cloneDestinationDir, "destination-dir", "", "The destination directory of the clone operation")
}

func cloneRefs(args []string) error {
	// Check that git is available
	if _, err := exec.LookPath("git"); err != nil {
		return fmt.Errorf("git not found. Ensure that it is available and in the path")
	}

	if len(args) == 0 {
		return fmt.Errorf("A repository URL must be specified as an argument")
	}
	repositoryURL := args[0]

	pullRefs := getPullRefs(args[1:])
	if len(pullRefs) == 0 {
		return fmt.Errorf("PULL_REFS must be specified either as an argument or as an environment variable")
	}

	sourceRef, err := pullrefs.ParsePullRefs(pullRefs)
	if err != nil {
		return err
	}
	sourceRef.RepositoryURL = repositoryURL

	if len(cloneDestinationDir) == 0 {
		cloneDestinationDir, err = os.Getwd()
		if err != nil {
			return err
		}
	}

	dirExists := false
	_, err = os.Stat(cloneDestinationDir)
	if err == nil {
		_, err := os.Stat(filepath.Join(cloneDestinationDir, ".git"))
		if err == nil {
			dirExists = true
		}
	}

	return pullrefs.CloneRef(*sourceRef, cloneDestinationDir, dirExists, pullrefs.NewExecRunner(os.Stdout, os.Stderr))
}
