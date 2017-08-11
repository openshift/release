package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"strconv"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/openshift/release/tools/release-ci/pkg/logging"
)

// INTERNAL_ERROR is the error code we use to indicate
// an internal error in the entrypoint occurred
const INTERNAL_ERROR = 127

// entrypointCmd runs the command given and tees output
var entrypointCmd = &cobra.Command{
	Use:   "entrypoint EXECUTABLE [ARGS...]",
	Short: "Executes the command provided and copies output to a file",
	Long: `Executes the command provided and copies output to a file

The GCS sidecar container will run alongside the container that
uses this command as an entrypoint. These two processes are
configured together; the sidecar will look for the output from
this entrypoint to upload to GCS.`,
	Args: cobra.MinimumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		if err := runEntrypoint(args); err != nil {
			fmt.Printf("Error: %v\n", err)
			os.Exit(1)
		}
	},
}

var configurationFile string

func init() {
	RootCmd.AddCommand(entrypointCmd)
	entrypointCmd.Flags().StringVar(&configurationFile, "config-path", "", "The location of the configuration file")
}

func runEntrypoint(args []string) error {
	config, err := loadConfig(configurationFile)
	if err != nil {
		return err
	}

	output, err := setupOutput(config.ProcessLog)
	if err != nil {
		return err
	}
	logger := log.New(output, "", log.Ldate|log.Lmicroseconds)

	command := createCommand(args, output)
	if err := command.Start(); err != nil {
		writeReturnCodeMarker(config.MarkerFile, INTERNAL_ERROR, logger)
		return fmt.Errorf("Could not start the process: %v", err)
	}

	commandErr := command.Wait()
	writeReturnCodeMarker(config.MarkerFile, determineReturnCode(commandErr), logger)

	return commandErr
}

// loadConfig loads configuration from disk
func loadConfig(configFile string) (logging.Configuration, error) {
	var config logging.Configuration
	configData, err := ioutil.ReadFile(configFile)
	if err != nil {
		return config, fmt.Errorf("could not read configuration file at %s: %v", configFile, err)
	}

	if err := json.Unmarshal(configData, &config); err != nil {
		return config, fmt.Errorf("could not decode the configuration: %v", err)
	}

	return config, nil
}

// setupOutput returns a Writer into which all output from
// the command and logs from this script should go. All writes
// to this object will be mirrored in writes to stdout as well
// as the outputFile.
func setupOutput(outputFile string) (io.Writer, error) {
	processLog, err := os.Create(outputFile)
	if err != nil {
		return nil, fmt.Errorf("could not open output process logfile: %v", err)
	}
	return io.MultiWriter(os.Stdout, processLog), nil
}

// createCommand creates a command with the arguments that
// are specified and with stdout and stderr going to the
// writer
func createCommand(args []string, output io.Writer) *exec.Cmd {
	executable := args[0]
	arguments := []string{}
	if len(args) > 1 {
		arguments = args[1:]
	}
	command := exec.Command(executable, arguments...)
	command.Stderr = output
	command.Stdout = output

	return command
}

// writeReturnCodeMarker writes the return code
// to the marker file and logs any errors
func writeReturnCodeMarker(markerFile string, returnCode int, logger *log.Logger) {
	if err := ioutil.WriteFile(markerFile, []byte(strconv.Itoa(returnCode)), os.ModePerm); err != nil {
		logger.Fatalf("Could not write return code to marker file: %v", err)
	}
}

// determineReturnCode determines the return code
// from an error returned by exec.Command.Wait()
func determineReturnCode(err error) int {
	if err == nil {
		return 0
	}

	if exitErr, ok := err.(*exec.ExitError); ok {
		if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
			return status.ExitStatus()
		}
	}

	return 1
}
