package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

type level string

type options struct {
	confirm   bool
	level     level
	user      string
	directory string
}

const (
	standardLevel level = "standard"
	adminLevel    level = "admin"
	allLevel      level = "all"
)

const defaultAdminUser = "system:admin"

func (l level) isValid() bool {
	return l == standardLevel || l == adminLevel || l == allLevel
}

func (l level) shouldApplyAdmin() bool {
	return l == adminLevel || l == allLevel
}

func (l level) shouldApplyStandard() bool {
	return l == standardLevel || l == allLevel
}

var adminConfig = regexp.MustCompile(`^admin_.+\.yaml$`)

func gatherOptions() *options {
	opt := &options{}
	var lvl string
	flag.BoolVar(&opt.confirm, "confirm", false, "Set to true to make applyconfig commit the config to the cluster")
	flag.StringVar(&lvl, "level", "standard", "Select which config to apply (standard, admin, all)")
	flag.StringVar(&opt.user, "as", "", "Username to impersonate while applying the config")
	flag.StringVar(&opt.directory, "config-dir", "", "Directory with config to apply")
	flag.Parse()

	opt.level = level(lvl)

	if !opt.level.isValid() {
		fmt.Fprintf(os.Stderr, "--level: must be one of [standard, admin, all]\n")
		os.Exit(1)
	}

	if opt.directory == "" {
		fmt.Fprintf(os.Stderr, "--config-dir must be provided\n")
		os.Exit(1)
	}

	return opt
}

func isAdminConfig(filename string) bool {
	return adminConfig.MatchString(filename)
}

func isStandardConfig(filename string) bool {
	return filepath.Ext(filename) == ".yaml" &&
		!isAdminConfig(filename)
}

func makeOcArgs(path, user string, dry bool) []string {
	args := []string{"apply", "-f", path}
	if dry {
		args = append(args, "--dry-run")
	}

	if user != "" {
		args = append(args, "--as", user)
	}

	return args
}

func apply(path, user string, dry bool) error {
	args := makeOcArgs(path, user, dry)

	cmd := exec.Command("oc", args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		if _, ok := err.(*exec.ExitError); ok {
			fmt.Printf("[ERROR] oc %s: failed to apply\n%s\n", strings.Join(args, " "), string(output))
		} else {
			fmt.Printf("[ERROR] oc %s: failed to execute: %v\n", strings.Join(args, " "), err)
		}
		return fmt.Errorf("failed to apply config")
	}

	fmt.Printf("oc %s: OK\n", strings.Join(args, " "))
	return nil
}

type processFn func(name, path string) error

func applyConfig(rootDir, cfgType string, process processFn) error {
	failures := false
	if err := filepath.Walk(rootDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		if info.IsDir() {
			if strings.HasPrefix(info.Name(), "_") {
				fmt.Printf("Skipping directory: %s\n", path)
				return filepath.SkipDir
			}
			fmt.Printf("Applying %s config in directory: %s\n", cfgType, path)
			return nil
		}

		if err := process(info.Name(), path); err != nil {
			failures = true
		}

		return nil
	}); err != nil {
		// should not happen
		fmt.Fprintf(os.Stderr, "failed to walk directory '%s': %v\n", rootDir, err)
		return err
	}

	if failures {
		return fmt.Errorf("failed to apply admin config")
	}

	return nil
}

func main() {
	o := gatherOptions()
	var adminErr, standardErr error

	if o.level.shouldApplyAdmin() {
		if o.user == "" {
			o.user = defaultAdminUser
		}

		f := func(name, path string) error {
			if !isAdminConfig(name) {
				return nil
			}
			return apply(path, o.user, !o.confirm)
		}

		adminErr = applyConfig(o.directory, "admin", f)
		if adminErr != nil {
			fmt.Printf("There were failures while applying admin config\n")
		}
	}

	if o.level.shouldApplyStandard() {
		f := func(name, path string) error {
			if !isStandardConfig(name) {
				return nil
			}
			if strings.HasPrefix(name, "_") {
				return nil
			}

			return apply(path, o.user, !o.confirm)
		}

		standardErr = applyConfig(o.directory, "standard", f)
		if standardErr != nil {
			fmt.Printf("There were failures while applying standard config\n")
		}
	}

	if standardErr != nil || adminErr != nil {
		os.Exit(1)
	}

	fmt.Printf("Success!\n")
}
