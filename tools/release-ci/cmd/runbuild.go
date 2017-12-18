package cmd

import (
	"errors"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/openshift/release/tools/release-ci/pkg/buildrunner"
)

// runBuildCmd runs the build with the passed in JSON
// If the build already exists, then the build that already
// exists is used. The build logs are followed and the
// command will succeed or fail based on the status of the build
var runBuildCmd = &cobra.Command{
	Use:   "run-build",
	Short: "Runs a build, logs its output and returns exit code based on build result",
	Long: `Runs a build

Takes the build definition in a file (either json or yaml).
If '-' is specified as the filename, the build is read from stdin.
The log of the build is output and the command will succeed or fail
based on the result of the build`,
	Args: cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		if err := runBuild(); err != nil {
			fmt.Printf("Error: %v\n", err)
			os.Exit(1)
		}
	},
}

var buildFile string
var followBuild bool

func init() {
	RootCmd.AddCommand(runBuildCmd)
	runBuildCmd.Flags().StringVarP(&buildFile, "file", "f", "", "The file containing the build definition")
	runBuildCmd.Flags().BoolVarP(&followBuild, "follow", "", false, "Follow the build's logs")
}

func runBuild() error {
	if len(buildFile) == 0 {
		return errors.New("no build file specified")
	}
	return buildrunner.RunBuild(buildFile, followBuild)
}
