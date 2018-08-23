/*
Copyright 2017 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

var httpTransport *http.Transport

func init() {
	httpTransport = new(http.Transport)
	httpTransport.RegisterProtocol("file", http.NewFileTransport(http.Dir("/")))
}

// Essentially curl url | writer
func httpRead(url string, writer io.Writer) error {
	log.Printf("curl %s", url)
	c := &http.Client{Transport: httpTransport}
	r, err := c.Get(url)
	if err != nil {
		return err
	}
	defer r.Body.Close()
	if r.StatusCode >= 400 {
		return fmt.Errorf("%v returned %d", url, r.StatusCode)
	}
	_, err = io.Copy(writer, r.Body)
	if err != nil {
		return err
	}
	return nil
}

type instanceGroup struct {
	Name              string `json:"name"`
	CreationTimestamp string `json:"creationTimestamp"`
}

// getLatestClusterUpTime returns latest created instanceGroup timestamp from gcloud parsing results
func getLatestClusterUpTime(gcloudJSON string) (time.Time, error) {
	igs := []instanceGroup{}
	if err := json.Unmarshal([]byte(gcloudJSON), &igs); err != nil {
		return time.Time{}, fmt.Errorf("error when unmarshal json: %v", err)
	}

	latest := time.Time{}

	for _, ig := range igs {
		created, err := time.Parse(time.RFC3339, ig.CreationTimestamp)
		if err != nil {
			return time.Time{}, fmt.Errorf("error when parse time from %s: %v", ig.CreationTimestamp, err)
		}

		if created.After(latest) {
			latest = created
		}
	}

	// this returns time.Time{} if no ig exists, which will always force a new cluster
	return latest, nil
}

// (only works on gke)
// getLatestGKEVersion will return newest validMasterVersions.
// Pass in releasePrefix to get latest valid version of a specific release.
// Empty releasePrefix means use latest across all available releases.
func getLatestGKEVersion(project, zone, region, releasePrefix string) (string, error) {
	cmd := []string{
		"container",
		"get-server-config",
		fmt.Sprintf("--project=%v", project),
		"--format=value(validMasterVersions)",
	}

	// --gkeCommandGroup is from gke.go
	if *gkeCommandGroup != "" {
		cmd = append([]string{*gkeCommandGroup}, cmd...)
	}

	// zone can be empty for regional cluster
	if zone != "" {
		cmd = append(cmd, fmt.Sprintf("--zone=%v", zone))
	} else if region != "" {
		cmd = append(cmd, fmt.Sprintf("--region=%v", region))
	}

	res, err := control.Output(exec.Command("gcloud", cmd...))
	if err != nil {
		return "", err
	}
	versions := strings.Split(strings.TrimSpace(string(res)), ";")
	latestValid := ""
	for _, version := range versions {
		if strings.HasPrefix(version, releasePrefix) {
			latestValid = version
			break
		}
	}
	if latestValid == "" {
		return "", fmt.Errorf("cannot find valid gke release %s version from: %s", releasePrefix, string(res))
	}
	return "v" + latestValid, nil
}

// gcsWrite uploads contents to the dest location in GCS.
// It currently shells out to gsutil, but this could change in future.
func gcsWrite(dest string, contents []byte) error {
	f, err := ioutil.TempFile("", "")
	if err != nil {
		return fmt.Errorf("error creating temp file: %v", err)
	}

	defer func() {
		if err := os.Remove(f.Name()); err != nil {
			log.Printf("error removing temp file: %v", err)
		}
	}()

	if _, err := f.Write(contents); err != nil {
		return fmt.Errorf("error writing temp file: %v", err)
	}

	if err := f.Close(); err != nil {
		return fmt.Errorf("error closing temp file: %v", err)
	}

	return control.FinishRunning(exec.Command("gsutil", "cp", f.Name(), dest))
}
