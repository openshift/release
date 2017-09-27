package gcs

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	ospath "path"
	"path/filepath"
	"time"

	"cloud.google.com/go/storage"
	"github.com/openshift/release/tools/release-ci/pkg/config"
)

type Finished struct {
	// Timestamp is the time at which we finish
	// execution, in seconds past the UNIX epoch
	Timestamp int64 `json:"timestamp"`

	// Passed is the result of the build
	Passed bool `json:"passed"`
}

func UploadFinishedData(processLog, metadataFile, artifactDir string, passed bool, gcsBucket *storage.BucketHandle) error {
	metadata, err := config.LoadGcs(metadataFile)
	if err != nil {
		return err
	}

	finishedData, err := generateFinishedMetadata(passed)
	if err != nil {
		return err
	}

	gcsPath := metadata.GcsPath()
	uploadTargets := map[string]uploadFunc{
		ospath.Join(gcsPath, "finished.json"): dataUpload(finishedData),
		// TODO(skuznets): we want to stream this log during the run
		ospath.Join(gcsPath, "build-log.txt"): fileUpload(processLog),
	}
	filepath.Walk(artifactDir, func(path string, info os.FileInfo, err error) error {
		if info == nil || info.IsDir() {
			return nil
		}

		// we know path will be below artifactDir, but we can't
		// communicate that to the filepath module. We can ignore
		// this error as we can be certain it won't occur and best-
		// effort upload is OK in any case
		if relPath, err := filepath.Rel(artifactDir, path); err == nil {
			uploadTargets[ospath.Join(gcsPath, "artifacts", relPath)] = fileUpload(path)
		}
		return nil
	})

	return uploadToGCS(gcsBucket, uploadTargets)
}

// generateFinishedMetadata generates finishing metadata
func generateFinishedMetadata(passed bool) (io.Reader, error) {
	finished := Finished{
		Timestamp: time.Now().Unix(),
		Passed:    passed,
	}
	data, err := json.Marshal(&finished)
	if err != nil {
		return nil, fmt.Errorf("could not marshal starting data: %v", err)
	}
	return bytes.NewBuffer(data), nil
}
