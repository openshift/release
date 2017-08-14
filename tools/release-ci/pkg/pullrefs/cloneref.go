package pullrefs

import (
	"fmt"
	"io"
	"os/exec"
)

// Runner is an object that knows how to keep track of a list
// of commands and execute them
type Runner interface {
	Add(cmd string, args ...string)
	AddAt(dir, cmd string, args ...string)
	Run() error
}

// CloneRef clones a SourceRef in the specified directory
func CloneRef(ref SourceRef, dir string, existing bool, runner Runner) error {
	if len(ref.RepositoryURL) == 0 {
		return fmt.Errorf("a repository URL must be specified")
	}

	if !existing {
		runner.Add("mkdir", "-p", dir)
		runner.Add("git", "clone", ref.RepositoryURL, dir)
	} else {
		runner.AddAt(dir, "git", "fetch", "origin")
	}
	if len(ref.BranchCommit) > 0 {
		runner.AddAt(dir, "git", "checkout", ref.BranchCommit)
	} else {
		if len(ref.Branch) > 0 {
			runner.AddAt(dir, "git", "checkout", ref.Branch)
		}
	}
	for _, prRef := range ref.PullRefs {
		runner.AddAt(dir, "git", "fetch", "origin", fmt.Sprintf("pull/%d/head", prRef.Number))
		runner.AddAt(dir, "git", "merge", prRef.Commit)
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

type execRunner struct {
	cmds   []cmdLine
	stdOut io.Writer
	stdErr io.Writer
}

// cmd adds a command to a list of
func (r *execRunner) Add(name string, args ...string) {
	r.AddAt("", name, args...)
}

func (r *execRunner) AddAt(dir, name string, args ...string) {
	r.cmds = append(r.cmds, cmdLine{
		name: name,
		dir:  dir,
		args: args,
	})
}

func (r *execRunner) Run() error {
	for _, cmd := range r.cmds {
		if err := cmd.run(r.stdOut, r.stdErr); err != nil {
			return err
		}
	}
	return nil
}

type cmdLine struct {
	name string
	args []string
	dir  string
}

func (l *cmdLine) run(stdout, stderr io.Writer) error {
	cmd := exec.Command(l.name, l.args...)
	cmd.Dir = l.dir
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	return cmd.Run()
}
