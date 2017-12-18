package buildrunner

import (
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"os/exec"
	"strings"
	"time"

	yaml "gopkg.in/yaml.v2"
)

var (
	WaitForRunningTimeout = 10 * time.Minute
	MaximumBuildDuration  = 4 * time.Hour
)

func RunBuild(resourceFile string, followBuild bool) error {

	if len(resourceFile) == 0 {
		return errors.New("no build file specified")
	}
	if resourceFile == "-" {
		tmp, err := ioutil.TempFile("", "")
		if err != nil {
			return err
		}
		_, err = io.Copy(tmp, os.Stdin)
		if err != nil {
			return err
		}
		tmp.Close()
		resourceFile = tmp.Name()
	}
	buildName, err := extractBuildName(resourceFile)
	if err != nil {
		return err
	}
	result, err := runCmd("oc", "create", "-f", resourceFile)
	if err != nil {
		if !isAlreadyExistsError(result) {
			return err
		}
	}
	if followBuild {
		return followBuild(buildName)
	} else {
		fmt.Println(buildName)
		return nil
	}
}

func isAlreadyExistsError(msg string) bool {
	return strings.Contains(msg, "AlreadyExists")
}

func extractBuildName(filename string) (string, error) {
	content, err := ioutil.ReadFile(filename)
	if err != nil {
		return "", fmt.Errorf("cannot read object YAML/JSON: %v", err)
	}
	object := map[interface{}]interface{}{}
	err = yaml.Unmarshal(content, &object)
	if err != nil {
		return "", fmt.Errorf("cannot parse YAML/JSON: %v", err)
	}
	// Check that the object is of type "Build"
	objectType, err := accessField(object, "kind")
	if err != nil {
		return "", fmt.Errorf("cannot access object kind: %v", err)
	}
	if objectType != "Build" {
		return "", fmt.Errorf("passed in object is not of type Build: %s", objectType)
	}
	return accessField(object, "metadata.name")
}

func accessField(object map[interface{}]interface{}, path string) (string, error) {
	parts := strings.Split(path, ".")
	switch len(parts) {
	case 0:
		return "", fmt.Errorf("invalid path: %s", path)
	case 1:
		value, ok := object[parts[0]]
		if !ok {
			return "", fmt.Errorf("path not found: %s", parts[0])
		}
		strValue := fmt.Sprintf("%v", value)
		return strValue, nil
	default:
		value, ok := object[parts[0]]
		if !ok {
			return "", fmt.Errorf("path not found: %s", parts[0])
		}
		mapValue, ok := value.(map[interface{}]interface{})
		if !ok {
			return "", fmt.Errorf("value at %s is not a map: %#v", parts[0], value)
		}
		return accessField(mapValue, strings.Join(parts[1:], "."))
	}
	return "", nil
}

func followBuild(name string) error {
	err := waitForRunning(name)
	if err != nil {
		return err
	}
	err = logBuild(name)
	if err != nil {
		return err
	}
	return checkBuildSuccess(name)
}

func isNewOrPending(status string) bool {
	return status == "New" || status == "Pending"
}

func isComplete(status string) bool {
	return status != "New" && status != "Pending" && status != "Running"
}

func isSuccessful(status string) bool {
	return status == "Complete"
}

func getBuildStatus(name string) (string, error) {
	result, err := runCmd("oc", "get", "build", name, "-o", "jsonpath={ .status.phase }")
	if err != nil {
		return "", fmt.Errorf("error getting build status for %s: %v, output: %s", name, err, result)
	}
	return strings.TrimSpace(result), nil
}

func getBuildCreationTime(name string) (time.Time, error) {
	result, err := runCmd("oc", "get", "build", name, "-o", "jsonpath={ .metadata.creationTimestamp }")
	if err != nil {
		return time.Time{}, fmt.Errorf("error getting build creation timestamp for %s: %v, output: %s", name, err, result)
	}
	ts, err := time.Parse(time.RFC3339, strings.TrimSpace(result))
	if err != nil {
		return time.Time{}, fmt.Errorf("error parsing build creation timestamp for %s: %v, input: %s", name, err, result)
	}
	return ts, nil
}

func waitForRunning(name string) error {
	status, err := getBuildStatus(name)
	if err != nil {
		return err
	}
	if !isNewOrPending(status) {
		return nil
	}
	// Begin wait
	creationTime, err := getBuildCreationTime(name)
	if err != nil {
		return err
	}
	for {
		status, err := getBuildStatus(name)
		if err != nil {
			return err
		}
		if !isNewOrPending(status) {
			return nil
		}
		if time.Since(creationTime) > WaitForRunningTimeout {
			return fmt.Errorf("Timed out waiting for build to start")
		}
		time.Sleep(5 * time.Second)
	}
	return nil
}

func logBuild(name string) error {
	status, err := getBuildStatus(name)
	if err != nil {
		return err
	}
	if status == "Error" {
		fmt.Printf("Build is in Error state. Cannot print log")
		return nil
	}
	return printBuildLog(name, status == "Running")
}

func printBuildLog(name string, follow bool) error {
	var args []string
	if follow {
		args = []string{"logs", "-f", fmt.Sprintf("build/%s", name)}
	} else {
		args = []string{"logs", fmt.Sprintf("build/%s", name)}
	}

	cmd := exec.Command("oc", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func checkBuildSuccess(name string) error {
	status, err := getBuildStatus(name)
	if !isComplete(status) {
		// Wait for the build to become complete
		err = waitForComplete(name)
		if err != nil {
			return err
		}
		status, err = getBuildStatus(name)
	}
	if !isSuccessful(status) {
		return fmt.Errorf("Build %s failed.", name)
	}
	return nil
}

func waitForComplete(name string) error {
	creationTime, err := getBuildCreationTime(name)
	if err != nil {
		return err
	}
	for {
		status, err := getBuildStatus(name)
		if err != nil {
			return err
		}
		if isComplete(status) {
			return nil
		}
		if time.Since(creationTime) > MaximumBuildDuration {
			return fmt.Errorf("Build %s exceeded the maximum build duration", name)
		}
		time.Sleep(5 * time.Second)
	}
}

func runCmd(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}
