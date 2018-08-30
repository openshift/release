package main

import (
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"

	"gopkg.in/yaml.v2"
)

const (
	doNotEdit            = "# DO NOT EDIT; this file is auto-generated using tools/populate-owners.\n"
	ownersComment        = "# See the OWNERS docs: https://git.k8s.io/community/contributors/guide/owners.md\n"
	ownersAliasesComment = "# See the OWNERS_ALIASES docs: https://git.k8s.io/community/contributors/guide/owners.md#owners_aliases\n"
)

// owners is copied from k8s.io/test-infra/prow/repoowners's Config
type owners struct {
	Approvers         []string `json:"approvers,omitempty" yaml:"approvers,omitempty"`
	Reviewers         []string `json:"reviewers,omitempty" yaml:"reviewers,omitempty"`
	RequiredReviewers []string `json:"required_reviewers,omitempty" yaml:"required_reviewers,omitempty"`
	Labels            []string `json:"labels,omitempty" yaml:"labels,omitempty"`
}

type aliases struct {
	Aliases map[string][]string `json:"aliases,omitempty" yaml:"aliases,omitempty"`
}

type orgRepo struct {
	Directories  []string `json:"directories,omitempty" yaml:"directories,omitempty"`
	Organization string   `json:"organization,omitempty" yaml:"organization,omitempty"`
	Repository   string   `json:"repository,omitempty" yaml:"repository,omitempty"`
	Owners       *owners  `json:"owners,omitempty" yaml:"owners,omitempty"`
	Aliases      *aliases `json:"aliases,omitempty" yaml:"aliases,omitempty"`
	Commit       string   `json:"commit,omitempty" yaml:"commit,omitempty"`
}

func getRepoRoot(directory string) (root string, err error) {
	initialDir, err := filepath.Abs(directory)
	if err != nil {
		return "", err
	}

	path := initialDir
	for {
		info, err := os.Stat(filepath.Join(path, ".git"))
		if err == nil {
			if info.IsDir() {
				break
			}
		} else if !os.IsNotExist(err) {
			return "", err
		}

		parent := filepath.Dir(path)
		if parent == path {
			return "", fmt.Errorf("no .git found under %q", initialDir)
		}

		path = parent
	}

	return path, nil
}

func orgRepos(dir string) (orgRepos []*orgRepo, err error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*", "*"))
	if err != nil {
		return nil, err
	}
	sort.Strings(matches)

	orgRepos = make([]*orgRepo, len(matches))
	for i, path := range matches {
		relpath, err := filepath.Rel(dir, path)
		if err != nil {
			return nil, err
		}
		org, repo := filepath.Split(relpath)
		org = strings.TrimSuffix(org, string(filepath.Separator))
		orgRepos[i] = &orgRepo{
			Directories:  []string{path},
			Organization: org,
			Repository:   repo,
		}
	}

	return orgRepos, err
}

func (orgRepo *orgRepo) getOwners() (err error) {
	dir, err := ioutil.TempDir("", "populate-owners-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)

	gitURL := fmt.Sprintf("ssh://git@github.com/%s/%s.git", orgRepo.Organization, orgRepo.Repository)
	cmd := exec.Command("git", "clone", "--depth=1", "--single-branch", gitURL, dir)
	cmd.Stderr = os.Stderr
	err = cmd.Run()
	if err != nil {
		return err
	}

	return orgRepo.extractOwners(dir)
}

func (orgRepo *orgRepo) extractOwners(repoRoot string) (err error) {
	cmd := exec.Command("git", "rev-parse", "HEAD")
	cmd.Stderr = os.Stderr
	cmd.Dir = repoRoot
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	err = cmd.Start()
	if err != nil {
		return err
	}
	hash, err := ioutil.ReadAll(stdout)
	if err != nil {
		return err
	}
	err = cmd.Wait()
	if err != nil {
		return err
	}
	orgRepo.Commit = strings.TrimSuffix(string(hash), "\n")

	data, err := ioutil.ReadFile(filepath.Join(repoRoot, "OWNERS"))
	if err != nil {
		return err
	}

	err = yaml.Unmarshal(data, &orgRepo.Owners)
	if err != nil {
		return err
	}

	data, err = ioutil.ReadFile(filepath.Join(repoRoot, "OWNERS_ALIASES"))
	if err != nil {
		return err
	}

	err = yaml.Unmarshal(data, &orgRepo.Aliases)
	if err != nil {
		return err
	}

	return nil
}

// namespaceAliases collects a set of aliases including all upstream
// aliases.  If multiple upstreams define the same alias with different
// member sets, namespaceAliases renames the colliding aliases in both
// the input 'orgRepos' and the output 'collected' to use
// unique-to-each-upstream alias names.
func namespaceAliases(orgRepos []*orgRepo) (collected *aliases, err error) {
	consumerMap := map[string][]*orgRepo{}
	for _, orgRepo := range orgRepos {
		if orgRepo.Aliases == nil {
			continue
		}

		for alias := range orgRepo.Aliases.Aliases {
			consumerMap[alias] = append(consumerMap[alias], orgRepo)
		}
	}

	if len(consumerMap) == 0 {
		return nil, nil
	}

	collected = &aliases{
		Aliases: map[string][]string{},
	}

	for alias, consumers := range consumerMap {
		namespace := false
		members := consumers[0].Aliases.Aliases[alias]
		for _, consumer := range consumers[1:] {
			otherMembers := consumer.Aliases.Aliases[alias]
			if !reflect.DeepEqual(members, otherMembers) {
				namespace = true
				break
			}
		}

		for i, consumer := range consumers {
			newAlias := alias
			if namespace {
				newAlias = fmt.Sprintf("%s-%s-%s", consumer.Organization, consumer.Repository, alias)
				consumer.Aliases.Aliases[newAlias] = consumer.Aliases.Aliases[alias]
				delete(consumer.Aliases.Aliases, alias)
			}
			fmt.Fprintf(
				os.Stderr,
				"injecting alias %q from https://github.com/%s/%s/blob/%s/OWNERS_ALIASES\n",
				alias,
				consumer.Organization,
				consumer.Repository,
				consumer.Commit,
			)
			if i == 0 || namespace {
				_, ok := collected.Aliases[newAlias]
				if ok {
					return nil, fmt.Errorf("namespaced alias collision: %q", newAlias)
				}
				collected.Aliases[newAlias] = consumer.Aliases.Aliases[newAlias]
			}
		}
	}

	return collected, nil
}

func writeYAML(path string, data interface{}, prefix []string) (err error) {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0666)
	if err != nil {
		return err
	}
	defer file.Close()

	for _, line := range prefix {
		_, err := file.Write([]byte(line))
		if err != nil {
			return err
		}
	}

	encoder := yaml.NewEncoder(file)
	return encoder.Encode(data)
}

func (orgRepo *orgRepo) writeOwners() (err error) {
	for _, directory := range orgRepo.Directories {
		path := filepath.Join(directory, "OWNERS")
		if orgRepo.Owners == nil {
			err := os.Remove(path)
			if err != nil && !os.IsNotExist(err) {
				return err
			}
			continue
		}

		err = writeYAML(path, orgRepo.Owners, []string{
			doNotEdit,
			fmt.Sprintf(
				"# from https://github.com/%s/%s/blob/%s/OWNERS\n",
				orgRepo.Organization,
				orgRepo.Repository,
				orgRepo.Commit,
			),
			ownersComment,
			"\n",
		})
		if err != nil {
			return err
		}
	}

	return nil
}

func writeOwnerAliases(repoRoot string, aliases *aliases) (err error) {
	path := filepath.Join(repoRoot, "OWNERS_ALIASES")
	if aliases == nil || len(aliases.Aliases) == 0 {
		err = os.Remove(path)
		if err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}

	return writeYAML(path, aliases, []string{
		doNotEdit,
		ownersAliasesComment,
		"\n",
	})
}

func pullOwners(directory string) (err error) {
	repoRoot, err := getRepoRoot(directory)
	if err != nil {
		return err
	}

	orgRepos, err := orgRepos(filepath.Join(repoRoot, "ci-operator", "jobs"))
	if err != nil {
		return err
	}

	for _, orgRepo := range orgRepos {
		err := orgRepo.getOwners()
		if err != nil && !os.IsNotExist(err) {
			return err
		}
	}

	aliases, err := namespaceAliases(orgRepos)
	if err != nil {
		return err
	}

	err = writeOwnerAliases(repoRoot, aliases)
	if err != nil {
		return err
	}

	for _, orgRepo := range orgRepos {
		err = orgRepo.writeOwners()
		if err != nil {
			return err
		}
	}

	return nil
}

func main() {
	err := pullOwners(".")
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
}
