package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
)

type Type string

const (
	PeriodicType   Type = "periodic"
	BatchType      Type = "batch"
	PostsubmitType Type = "postsubmit"
	PresubmitType  Type = "presubmit"
)

// anyConfig is a representation of serialized
// configuration on disk
type anyConfig struct {
	ConfigType Type            `json:"type"`
	Config     json.RawMessage `json:"config"`
}

// LoadGcs loads GCS configuration from the file
func LoadGcs(path string) (Gcs, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	return loadGcsFromReader(file)
}

func loadGcsFromReader(reader io.Reader) (Gcs, error) {
	raw, err := loadRawFromReader(reader)
	if err != nil {
		return nil, err
	}

	switch raw.ConfigType {
	case PeriodicType:
		conf, err := loadPeriodic(raw.Config)
		if err != nil {
			return nil, err
		}
		return &conf, nil
	case BatchType:
		conf, err := loadBatch(raw.Config)
		if err != nil {
			return nil, err
		}
		return &conf, nil
	case PostsubmitType:
		conf, err := loadPostsubmit(raw.Config)
		if err != nil {
			return nil, err
		}
		return &conf, nil
	case PresubmitType:
		conf, err := loadPresubmit(raw.Config)
		if err != nil {
			return nil, err
		}
		return &conf, nil
	default:
		return nil, fmt.Errorf("unknown job configuration type: %s", raw.ConfigType)
	}
}

// loadRawFromReader loads a serialized job configuration
// and returns the job type and configuration data
func loadRawFromReader(reader io.Reader) (anyConfig, error) {
	var raw anyConfig
	if err := json.NewDecoder(reader).Decode(&raw); err != nil {
		return anyConfig{}, fmt.Errorf("failed to decode job configuration: %v", err)
	}

	if raw.ConfigType == "" {
		return raw, errors.New("invalid job configuration: no configuration type")
	}

	if len(raw.Config) == 0 {
		return raw, errors.New("invalid job configuration: no configuration")
	}

	return raw, nil
}

// LoadPeriodic attempts to load a periodic job configuration
// from the file. If the file contains a different type of job
// configuration, this returns an error.
func LoadPeriodic(path string) (Periodic, error) {
	file, err := os.Open(path)
	if err != nil {
		return Periodic{}, err
	}
	return loadPeriodicFromReader(file)
}

func loadPeriodicFromReader(reader io.Reader) (Periodic, error) {
	raw, err := loadRawFromReader(reader)
	if err != nil {
		return Periodic{}, err
	}

	if actual, expected := raw.ConfigType, PeriodicType; actual != expected {
		return Periodic{}, fmt.Errorf("configuration was of type %s, not %s", actual, expected)
	}

	return loadPeriodic(raw.Config)
}

func loadPeriodic(data json.RawMessage) (Periodic, error) {
	var periodic Periodic
	err := json.Unmarshal(data, &periodic)
	return periodic, err
}

// LoadBatch attempts to load a batch job configuration
// from the file. If the file contains a different type of job
// configuration, this returns an error.
func LoadBatch(path string) (Batch, error) {
	file, err := os.Open(path)
	if err != nil {
		return Batch{}, err
	}
	return loadBatchFromReader(file)
}

func loadBatchFromReader(reader io.Reader) (Batch, error) {
	raw, err := loadRawFromReader(reader)
	if err != nil {
		return Batch{}, err
	}

	if actual, expected := raw.ConfigType, BatchType; actual != expected {
		return Batch{}, fmt.Errorf("configuration was of type %s, not %s", actual, expected)
	}

	return loadBatch(raw.Config)
}

func loadBatch(data json.RawMessage) (Batch, error) {
	var batch Batch
	err := json.Unmarshal(data, &batch)
	return batch, err
}

// LoadPostsubmit attempts to load a postsubmit job configuration
// from the file. If the file contains a different type of job
// configuration, this returns an error.
func LoadPostsubmit(path string) (Postsubmit, error) {
	file, err := os.Open(path)
	if err != nil {
		return Postsubmit{}, err
	}
	return loadPostsubmitFromReader(file)
}

func loadPostsubmitFromReader(reader io.Reader) (Postsubmit, error) {
	raw, err := loadRawFromReader(reader)
	if err != nil {
		return Postsubmit{}, err
	}

	if actual, expected := raw.ConfigType, PostsubmitType; actual != expected {
		return Postsubmit{}, fmt.Errorf("configuration was of type %s, not %s", actual, expected)
	}

	return loadPostsubmit(raw.Config)
}

func loadPostsubmit(data json.RawMessage) (Postsubmit, error) {
	var postsubmit Postsubmit
	err := json.Unmarshal(data, &postsubmit)
	return postsubmit, err
}

// LoadPresubmit attempts to load a presubmit job configuration
// from the file. If the file contains a different type of job
// configuration, this returns an error.
func LoadPresubmit(path string) (Presubmit, error) {
	file, err := os.Open(path)
	if err != nil {
		return Presubmit{}, err
	}
	return loadPresubmitFromReader(file)
}

func loadPresubmitFromReader(reader io.Reader) (Presubmit, error) {
	raw, err := loadRawFromReader(reader)
	if err != nil {
		return Presubmit{}, err
	}

	if actual, expected := raw.ConfigType, PresubmitType; actual != expected {
		return Presubmit{}, fmt.Errorf("configuration was of type %s, not %s", actual, expected)
	}

	return loadPresubmit(raw.Config)
}

func loadPresubmit(data json.RawMessage) (Presubmit, error) {
	var presubmit Presubmit
	err := json.Unmarshal(data, &presubmit)
	return presubmit, err
}
