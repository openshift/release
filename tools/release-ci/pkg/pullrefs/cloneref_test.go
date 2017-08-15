package pullrefs

import (
	"reflect"
	"testing"
)

type fakeCmd struct {
	name string
	args []string
	dir  string
}

type fakeRunner struct {
	commands []fakeCmd
}

func (r *fakeRunner) Add(func() error) {
	// no-op
}

func (r *fakeRunner) AddCmd(dir, name string, args ...string) {
	r.commands = append(r.commands, fakeCmd{
		name: name,
		dir:  dir,
		args: args,
	})
}

func (r *fakeRunner) Run() error {
	return nil
}

func runner() *fakeRunner {
	return &fakeRunner{}
}

func (r *fakeRunner) c(dir, name string, args ...string) *fakeRunner {
	r.AddCmd(dir, name, args...)
	return r
}

func TestCloneRef(t *testing.T) {
	dir := "/test/dir/path"
	repoURL := "https://github.com/openshift/origin.git"
	tests := []struct {
		name      string
		ref       SourceRef
		expect    *fakeRunner
		expectErr bool
	}{
		{
			name: "no repo url",
			ref: SourceRef{
				Branch:       "master",
				BranchCommit: "12345",
			},
			expectErr: true,
		},
		{
			name: "only repo url",
			ref: SourceRef{
				RepositoryURL: repoURL,
			},
			expect: runner().
				c("", "git", "clone", repoURL, dir),
		},
		{
			name: "branch specified",
			ref: SourceRef{
				RepositoryURL: repoURL,
				Branch:        "test",
			},
			expect: runner().
				c("", "git", "clone", repoURL, dir).
				c(dir, "git", "checkout", "test"),
		},
		{
			name: "branch commit specified",
			ref: SourceRef{
				RepositoryURL: repoURL,
				Branch:        "test",
				BranchCommit:  "12345",
			},
			expect: runner().
				c("", "git", "clone", repoURL, dir).
				c(dir, "git", "checkout", "12345"),
		},
		{
			name: "one pr specified",
			ref: SourceRef{
				RepositoryURL: repoURL,
				Branch:        "test",
				BranchCommit:  "12345",
				PullRefs: []PullRequestRef{
					{
						Number: 123,
						Commit: "abc1234",
					},
				},
			},
			expect: runner().
				c("", "git", "clone", repoURL, dir).
				c(dir, "git", "checkout", "12345").
				c(dir, "git", "fetch", "origin", "pull/123/head").
				c(dir, "git", "merge", "abc1234"),
		},
		{
			name: "multiple prs specified",
			ref: SourceRef{
				RepositoryURL: repoURL,
				Branch:        "test",
				BranchCommit:  "12345",
				PullRefs: []PullRequestRef{
					{
						Number: 123,
						Commit: "abc1234",
					},
					{
						Number: 789,
						Commit: "def7890",
					},
				},
			},
			expect: runner().
				c("", "git", "clone", repoURL, dir).
				c(dir, "git", "checkout", "12345").
				c(dir, "git", "fetch", "origin", "pull/123/head").
				c(dir, "git", "merge", "abc1234").
				c(dir, "git", "fetch", "origin", "pull/789/head").
				c(dir, "git", "merge", "def7890"),
		},
	}

	for _, test := range tests {
		actual := runner()
		err := CloneRef(test.ref, dir, false, actual)
		if err != nil {
			if !test.expectErr {
				t.Errorf("%s: unexpected error: %v", test.name, err)
			}
			continue
		}
		if test.expectErr {
			t.Errorf("%s: did not get expected error", test.name)
			continue
		}
		if !reflect.DeepEqual(*actual, *test.expect) {
			t.Errorf("%s: expected: %#v, actual: %#v", test.name, test.expect, actual)
		}
	}
}
