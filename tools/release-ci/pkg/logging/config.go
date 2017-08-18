package logging

// Configuration holds options for running the entrypoint
// and sidecar processes
type Configuration struct {
	// ProcessLog is the path to the log where we will stream
	// stdout and stderr for the process we execute
	ProcessLog string `json:"process-log"`

	// MarkerFile is the file we write the return code of the
	// process we execute once it has finished running
	MarkerFile string `json:"marker-file"`

	// GcsBucket is the bucket where we will store test data
	GcsBucket string `json:"gcs-bucket"`

	// GceCredentialsFile is the file where Google Cloud
	// authentication credentials are stored. See:
	// https://developers.google.com/identity/protocols/OAuth2ServiceAccount
	GceCredentialsFile string `json:"gce-credentials-file"`

	// ArtifactDir is the directory to upload to GCS
	ArtifactDir string `json:"artifact-dir"`

	// ConfigurationFile is the file we expect to contain build configuration
	ConfigurationFile string `json:"configuration-file"`
}
