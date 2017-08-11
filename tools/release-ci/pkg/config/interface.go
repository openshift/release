package config

// Gcs exposes GCS information for a job configuration
type Gcs interface {
	// GcsPath returns the path under a bucket
	// where all data for a build should live
	GcsPath() string

	// Aliases returns all paths under a bucket
	// where GCS "symlinks" should be created
	// for a build
	Aliases() []string
}