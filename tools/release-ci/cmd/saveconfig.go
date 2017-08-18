package cmd

import (
	"errors"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/openshift/release/tools/release-ci/pkg/config"
)

// configCmd runs the command given and tees output
var configCmd = &cobra.Command{
	Use:   "save-config",
	Short: "Serializes job configuration to disk",
	Long: `Serializes job configuration to disk

This command serializes all of the job configuration
that is provided to the job by Prow using environment
variables for use by other components in a more
machine-readable manner.`,
	Args: cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		if err := runConfig(args); err != nil {
			fmt.Printf("Error: %v\n", err)
			os.Exit(1)
		}
	},
}

func init() {
	RootCmd.AddCommand(configCmd)
	configCmd.Flags().StringVar(&configurationFile, "config-path", "", "The location of the configuration file")
}

func runConfig(_ []string) error {
	if len(configurationFile) == 0 {
		return errors.New("no configuration file specified")
	}

	data, err := loadConfig(configurationFile)
	if err != nil {
		return err
	}

	return config.Save(data.ConfigurationFile)
}
