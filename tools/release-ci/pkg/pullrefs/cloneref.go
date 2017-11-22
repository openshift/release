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
func CloneRef(ref SourceRef, cloneDest string, runner Runner) error {
	runner.Add(func() error { return os.MkdirAll(cloneDest, 0775) })
	runner.AddCmd(cloneDest, "git", "init")
	runner.AddCmd(cloneDest, "git", "fetch", ref.RepositoryURL, ref.Branch)
	runner.AddCmd(cloneDest, "git", "checkout", ref.BranchCommit)
	for _, prRef := range ref.PullRefs {
		runner.AddCmd(cloneDest, "git", "fetch", ref.RepositoryURL, fmt.Sprintf("pull/%d/head", prRef.Number))
		runner.AddCmd(cloneDest, "git", "merge", prRef.Commit)
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
		cmd.Dir = dir
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
