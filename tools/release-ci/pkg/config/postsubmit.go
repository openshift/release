package config

import "fmt"

// Postsubmit contains configuration for a post-submit job
type Postsubmit struct {
	Job
	Repo
}

// GcsPath is the base path for job data. Postsubmit jobs
// store their information only in the job log directory
func (p *Postsubmit) GcsPath() string {
	return fmt.Sprintf("%s/%s/%d/", JobLogPrefix, p.JobName, p.BuildNumber)
}

// Aliases are the paths to symlink to the GcsPath.
// Postsubmit jobs have no aliases.
func (p *Postsubmit) Aliases() []string {
	return []string{}
}