package pullrefs

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"strconv"
	"strings"
)

// PullRequestRef represents a reference to a pull request
// It includes a PR number and a Commit SHA
type PullRequestRef struct {
	Number int
	Commit string
}

// SourceRef represents a source reference as specified by a
//a Prow PULL_REFS value.
type SourceRef struct {
	RepositoryURL string
	Branch        string
	BranchCommit  string
	PullRefs      []PullRequestRef
}

// ParsePullRefs will parse the value of a PULL_REFS spec
// PULL_REFS is expected to be in the form of:
//
// base_branch:commit_sha_of_base_branch,pull_request_no:commit_sha_of_pull_request_no,...
//
// For example:
//
// master:97d901d,4:bcb00a1
//
// And for multiple pull requests that have been batched:
//
// master:97d901d,4:bcb00a1,6:ddk2tka
func ParsePullRefs(pullRefs string) (*SourceRef, error) {
	refs := strings.Split(pullRefs, ",")
	sourceRef := &SourceRef{}
	for i, ref := range refs {
		parts := strings.Split(ref, ":")
		if i == 0 {
			if len(parts) > 2 {
				return nil, fmt.Errorf("expecting a branch name and commit SHA: %s", ref)
			}
			sourceRef.Branch = parts[0]
			if len(parts) > 1 {
				sourceRef.BranchCommit = parts[1]
			}
			continue
		}
		if len(parts) != 2 {
			return nil, fmt.Errorf("expecting a PR number and a commit SHA: %s", ref)
		}
		prNumber, err := strconv.Atoi(parts[0])
		if err != nil {
			return nil, fmt.Errorf("Expected valid PR number: %s: %v", ref, err)
		}
		prRef := PullRequestRef{
			Number: prNumber,
			Commit: parts[1],
		}
		sourceRef.PullRefs = append(sourceRef.PullRefs, prRef)
	}
	return sourceRef, nil
}

// ToBuildID returns a sha256 sum rerpesenting the SourceRef
func (s *SourceRef) ToBuildID() string {
	desc := &bytes.Buffer{}
	if len(s.RepositoryURL) > 0 {
		fmt.Fprintf(desc, "url: %s\n", s.RepositoryURL)
	}
	fmt.Fprintf(desc, "branch: %s", s.Branch)
	if len(s.BranchCommit) > 0 {
		fmt.Fprintf(desc, ", commit: %s", s.BranchCommit)
	}
	fmt.Fprintf(desc, "\n")
	for _, prRef := range s.PullRefs {
		fmt.Fprintf(desc, "PR: %d, Ref: %s\n", prRef.Number, prRef.Commit)
	}
	sum := sha256.Sum256(desc.Bytes())
	hash := fmt.Sprintf("%x", sum)

	jobInfo := ""
	if len(s.PullRefs) == 1 {
		jobInfo = fmt.Sprintf("pr-%d-", s.PullRefs[0].Number)
	} else if len(s.PullRefs) > 1 {
		jobInfo = "batch-"
	}

	// Shorten the hash to make it usable as an origin name
	return fmt.Sprintf("%s%s", jobInfo, hash[40:])
}
