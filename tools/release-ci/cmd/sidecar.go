package cmd

import (
	"context"
	"fmt"
	"io/ioutil"
	"os"
	"strconv"
	"strings"

	"cloud.google.com/go/storage"
	"github.com/spf13/cobra"

	"sync"

	"path/filepath"

	"errors"

	"github.com/fsnotify/fsnotify"
	"github.com/openshift/release/tools/release-ci/pkg/logging/gcs"
	"google.golang.org/api/option"
)

// sidecarCmd should run alongside a test pod and uploads files to GCS
var sidecarCmd = &cobra.Command{
	Use:   "sidecar",
	Short: "Uploads build log and artifacts to GCS",
	Long: `Uploads build log and artifacts to GCS

The GCS sidecar container will run alongside the container that
wraps its process with the entrypoint. These two processes are
configured together; the sidecar will look for the output from
this entrypoint to upload to GCS.`,
	Args: cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		if err := runSidecar(args); err != nil {
			fmt.Printf("Error: %v\n", err)
			os.Exit(1)
		}
	},
}

func init() {
	RootCmd.AddCommand(sidecarCmd)
	sidecarCmd.Flags().StringVar(&configurationFile, "config-path", "", "The location of the configuration file")
}

func exists(file string) bool {
	_, err := os.Stat(file)
	return err == nil
}

func runSidecar(_ []string) error {
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

	if err := gcs.UploadStartingData(config.ConfigurationFile, gcsBucket); err != nil {
		return err
	}

	returnCode, err := retrieveProcessReturnCode(config.MarkerFile)
	if err != nil {
		// even if we fail to determine this info,
		// we want to upload as much as we can
		fmt.Printf("failed to determine process return code: %v", err)
	}
	passed := returnCode == 0 && err == nil

	return gcs.UploadFinishedData(config.ProcessLog, config.ConfigurationFile, config.ArtifactDir, passed, gcsBucket)
}

func createGcsClient(bucket, credentialsFile string) (*storage.BucketHandle, error) {
	ctx := context.Background()
	gcsClient, err := storage.NewClient(ctx, option.WithCredentialsFile(credentialsFile))
	if err != nil {
		return nil, fmt.Errorf("could not connect to GCS: %v", err)
	}
	return gcsClient.Bucket(bucket), nil
}

// retrieveProcessReturnCode waits until the return code
// is available in the marker file, then returns it
func retrieveProcessReturnCode(markerFile string) (int, error) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return 1, fmt.Errorf("could not begin fsnotify watch: %v", err)
	}
	defer watcher.Close()

	group := sync.WaitGroup{}

	// Only start watching file events if the file doesn't exist
	// If the file exists, it means the main process already completed.
	if !exists(markerFile) {
		group.Add(1)
		go func() {
			defer group.Done()
			for {
				select {
				case event := <-watcher.Events:
					if event.Name == markerFile && event.Op&fsnotify.Create == fsnotify.Create {
						return
					}
				case err := <-watcher.Errors:
					fmt.Printf("encountered an error during fsnotify watch: %v\n", err)
				}
			}
		}()

		dir := filepath.Dir(markerFile)

		if err := watcher.Add(dir); err != nil {
			return 1, fmt.Errorf("could not add to fsnotify watch: %v", err)
		}
		group.Wait()
	}

	data, err := ioutil.ReadFile(markerFile)
	if err != nil {
		return 1, fmt.Errorf("could not read return code from marker file: %v", err)
	}

	return strconv.Atoi(strings.TrimSpace(string(data)))
}
