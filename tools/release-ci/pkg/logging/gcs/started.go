package gcs

import (
	"encoding/json"
	"fmt"
	"path"
	"time"

	"bytes"
	"io"

	"context"
	"strings"

	"cloud.google.com/go/storage"
	"github.com/openshift/release/tools/release-ci/pkg/config"
)

type Started struct {
	// Timestamp is the time at which we start
	// execution, in seconds past the UNIX epoch
	Timestamp int64 `json:"timestamp"`
}

func UploadStartingData(configurationFile string, gcsBucket *storage.BucketHandle) error {
	metadata, err := config.LoadGcs(configurationFile)
	if err != nil {
		return err
	}

	startedData, err := generateStartingMetadata()
	if err != nil {
		return err
	}

	gcsPath := metadata.GcsPath()
	uploadTargets := map[string]uploadFunc{
		path.Join(gcsPath, "configuration.json"): fileUpload(configurationFile),
		path.Join(gcsPath, "started.json"):       dataUpload(startedData),
	}

	attrs, err := gcsBucket.Attrs(context.Background())
	if err != nil {
		return fmt.Errorf("could not determine bucket attributes, skipping alias upload: %v", err)
	}

	fullGcsPath := fmt.Sprintf("gs://%s", path.Join(attrs.Name, gcsPath))

	for _, alias := range metadata.Aliases() {
		uploadTargets[alias] = dataUpload(strings.NewReader(fullGcsPath))
	}

	return uploadToGCS(gcsBucket, uploadTargets)
}

func generateStartingMetadata() (io.Reader, error) {
	started := Started{Timestamp: time.Now().Unix()}
	data, err := json.Marshal(&started)
	if err != nil {
		return nil, fmt.Errorf("could not marshal starting data: %v", err)
	}
	return bytes.NewBuffer(data), nil
}
