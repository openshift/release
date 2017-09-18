package pullrefs

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

// Runner is an object that knows how to keep track of a list
// of commands and execute them
type Runner interface {
	Add(func() error)
	AddCmd(dir, cmd string, args ...string)
	Run() error
}

// CloneRef clones a SourceRef in the specified directory
func CloneRef(ref SourceRef, dir string, existing bool, runner Runner) error {
	if len(ref.RepositoryURL) == 0 {
		return fmt.Errorf("a repository URL must be specified")
	}

	branch := ref.Branch
	remote := "origin"
	if !existing {
		runner.Add(func() error { return os.MkdirAll(dir, 0644) })
		runner.AddCmd("", "git", "clone", ref.RepositoryURL, dir)
	} else {
		runner.AddCmd(dir, "git", "remote", "add", "cloneremote", ref.RepositoryURL)
		runner.AddCmd(dir, "git", "fetch", "cloneremote")
		branch = fmt.Sprintf("cloneremote/%s", ref.Branch)
		remote = "cloneremote"
	}
	if len(ref.BranchCommit) > 0 {
		runner.AddCmd(dir, "git", "checkout", ref.BranchCommit)
	} else {
		if len(ref.Branch) > 0 {
			runner.AddCmd(dir, "git", "checkout", branch)
		}
	}
	for _, prRef := range ref.PullRefs {
		runner.AddCmd(dir, "git", "fetch", remote, fmt.Sprintf("pull/%d/head", prRef.Number))
		runner.AddCmd(dir, "git", "merge", prRef.Commit)
	}
	return runner.Run()
}

// NewExecRunner returns an instance of runner that executes commands using
// operating system exec calls and outputs stdout and stderr to provided streams
func NewExecRunner(stdout, stderr io.Writer) Runner {
	return &execRunner{
		stdOut: stdout,
		stdErr: stderr,
	}
}

type runnerStep func() error

type execRunner struct {
	cmds   []runnerStep
	stdOut io.Writer
	stdErr io.Writer
}

// cmd adds a command to a list of
func (r *execRunner) Add(f func() error) {
	r.cmds = append(r.cmds, f)
}

func (r *execRunner) AddCmd(dir, name string, args ...string) {
	r.Add(func() error {
		fmt.Fprintf(r.stdOut, "executing: %s %s\n", name, strings.Join(args, " "))
		cmd := exec.Command(name, args...)
		cmd.Stdout = r.stdOut
		cmd.Stderr = r.stdErr
		return cmd.Run()
	})
}

func (r *execRunner) Run() error {
	for _, cmd := range r.cmds {
		if err := cmd(); err != nil {
			return err
		}
	}
	return nil
}
