package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"errors"

	"github.com/openshift/release/tools/release-ci/pkg/logging/gcs"
)

// sidecarCmd should run alongside a test pod and uploads files to GCS
var uploadCmd = &cobra.Command{
	Use:   "upload",
	Short: "Uploads artifacts to GCS",
	Long: `Uploads artifacts to GCS

Looks for files in the given directory and uploads them as artifacts
to the GCS location for the given job.`,
	Args: cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		if err := runUpload(); err != nil {
			fmt.Printf("Error: %v\n", err)
			os.Exit(1)
		}
	},
}

func init() {
	RootCmd.AddCommand(uploadCmd)
	uploadCmd.Flags().StringVar(&configurationFile, "config-path", "", "The location of the configuration file")
}

func runUpload() error {
	if len(configurationFile) == 0 {
		return errors.New("no configuration file specified")
	}

	config, err := loadConfig(configurationFile)
	if err != nil {
		return err
	}

	if len(config.GceCredentialsFile) == 0 || !exists(config.GceCredentialsFile) {
		// if there is no GCE configuration,
		// we will just exit early
		return nil
	}

	gcsBucket, err := createGcsClient(config.GcsBucket, config.GceCredentialsFile)
	if err != nil {
		return err
	}

	return gcs.UploadArtifacts(config.ConfigurationFile, config.ArtifactDir, gcsBucket)
}
