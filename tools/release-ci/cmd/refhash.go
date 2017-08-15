package cmd

import (
	"fmt"
	"os"

	"github.com/openshift/release/tools/release-ci/pkg/pullrefs"
	"github.com/spf13/cobra"
)

// refhashCmd represents the refhash command
var refhashCmd = &cobra.Command{
	Use:   "refhash [PULL_REFS]",
	Short: "Generates a sha256 hash based on the value of PULL_REFS",
	Long: `Generates a sha256 hash based on the value of PULL_REFS
	
PULL_REFS is expected to be in the form of:	
base_branch:commit_sha_of_base_branch,pull_request_no:commit_sha_of_pull_request_no,...

For example:
master:97d901d,4:bcb00a1

And for multiple pull requests that have been batched:
master:97d901d,4:bcb00a1,6:ddk2tka

PULL_REFS can be specified either as an argument or an environment variable
`,
	Run: func(cmd *cobra.Command, args []string) {
		if err := printRefHash(args); err != nil {
			fmt.Printf("Error: %v\n", err)
			os.Exit(1)
		}
	},
}

func init() {
	RootCmd.AddCommand(refhashCmd)
}

func printRefHash(args []string) error {
	pullRefs := getPullRefs(args)
	if len(pullRefs) == 0 {
		return fmt.Errorf("PULL_REFS must be specified either as an argument or as an environment variable")
	}

	sourceRef, err := pullrefs.ParsePullRefs(pullRefs)
	if err != nil {
		return err
	}

	fmt.Printf("%s\n", sourceRef.ToBuildID())
	return nil
}
