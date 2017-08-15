package cmd

import (
	"os"
)

const pullRefsEnvVar = "PULL_REFS"

func getPullRefs(args []string) string {
	if len(args) > 0 {
		return args[0]
	}
	return os.Getenv(pullRefsEnvVar)
}
