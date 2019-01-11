package main

import (
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"testing"
)

func assertEqual(t *testing.T, actual, expected interface{}) {
	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("unexpected result: %+v != %+v", actual, expected)
	}
}

func TestGetRepoRoot(t *testing.T) {
	dir, err := ioutil.TempDir("", "populate-owners-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	root := filepath.Join(dir, "root")
	deep := filepath.Join(root, "a", "b", "c")
	git := filepath.Join(root, ".git")
	err = os.MkdirAll(deep, 0777)
	if err != nil {
		t.Fatal(err)
	}
	err = os.Mkdir(git, 0777)
	if err != nil {
		t.Fatal(err)
	}

	t.Run("from inside the repository", func(t *testing.T) {
		found, err := getRepoRoot(deep)
		if err != nil {
			t.Fatal(err)
		}
		if found != root {
			t.Fatalf("unexpected root: %q != %q", found, root)
		}
	})

	t.Run("from outside the repository", func(t *testing.T) {
		_, err := getRepoRoot(dir)
		if err == nil {
			t.Fatal(err)
		}
	})
}

func TestOrgRepos(t *testing.T) {
	dir, err := ioutil.TempDir("", "populate-owners-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	repoAB := filepath.Join(dir, "a", "b")
	repoCD := filepath.Join(dir, "c", "d")
	err = os.MkdirAll(repoAB, 0777)
	if err != nil {
		t.Fatal(err)
	}
	err = os.MkdirAll(repoCD, 0777)
	if err != nil {
		t.Fatal(err)
	}

	orgRepos, err := orgRepos(dir)
	if err != nil {
		t.Fatal(err)
	}

	expected := []*orgRepo{
		{
			Directories:  []string{repoAB},
			Organization: "a",
			Repository:   "b",
		},
		{
			Directories:  []string{repoCD},
			Organization: "c",
			Repository:   "d",
		},
	}

	assertEqual(t, orgRepos, expected)
}

func TestGetDirectories(t *testing.T) {
	dir, err := ioutil.TempDir("", "populate-owners-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	repoAB := filepath.Join(dir, "a", "b")
	err = os.MkdirAll(repoAB, 0777)
	if err != nil {
		t.Fatal(err)
	}

	for _, test := range []struct {
		name     string
		input    *orgRepo
		expected *orgRepo
		error    *regexp.Regexp
	}{
		{
			name: "config exists",
			input: &orgRepo{
				Directories:  []string{"some/directory"},
				Organization: "a",
				Repository:   "b",
			},
			expected: &orgRepo{
				Directories:  []string{"some/directory", filepath.Join(dir, "a", "b")},
				Organization: "a",
				Repository:   "b",
			},
		},
		{
			name: "config does not exist",
			input: &orgRepo{
				Directories:  []string{"some/directory"},
				Organization: "c",
				Repository:   "d",
			},
			expected: &orgRepo{
				Directories:  []string{"some/directory"},
				Organization: "c",
				Repository:   "d",
			},
			error: regexp.MustCompile("^stat .*/c/d: no such file or directory"),
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := test.input.getDirectories(dir)
			if test.error == nil {
				if err != nil {
					t.Fatal(err)
				}
			} else if !test.error.MatchString(err.Error()) {
				t.Fatalf("unexpected error: %v does not match %v", err, test.error)
			}

			assertEqual(t, test.input, test.expected)
		})
	}
}

func TestExtractOwners(t *testing.T) {
	dir, err := ioutil.TempDir("", "populate-owners-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	err = ioutil.WriteFile(filepath.Join(dir, "README"), []byte("Hello, World!\n"), 0666)
	if err != nil {
		t.Fatal(err)
	}

	for _, args := range [][]string{
		{"git", "init"},
		{"git", "config", "user.name", "Test"},
		{"git", "config", "user.email", "test@test.org"},
		{"git", "add", "README"},
		{"git", "commit", "-m", "Begin versioning"},
	} {
		cmd := exec.Command(args[0], args[1:]...)
		cmd.Dir = dir
		cmd.Env = []string{ // for stable commit hashes
			"GIT_COMMITTER_DATE=1112911993 -0700",
			"GIT_AUTHOR_DATE=1112911993 -0700",
		}
		stdoutStderr, err := cmd.CombinedOutput()
		if err != nil {
			t.Log(string(stdoutStderr))
			t.Fatal(err)
		}
	}

	for _, test := range []struct {
		name     string
		setup    string
		expected *orgRepo
		error    *regexp.Regexp
	}{
		{
			name: "no OWNERS",
			expected: &orgRepo{
				Commit: "3e7341c55330a127038bfc8d7a396d4951049b85",
			},
			error: regexp.MustCompile("^open .*/populate-owners-[0-9]*/OWNERS: no such file or directory"),
		},
		{
			name:  "only OWNERS",
			setup: "OWNERS",
			expected: &orgRepo{
				Owners: &owners{Approvers: []string{"alice", "bob"}},
				Commit: "3e7341c55330a127038bfc8d7a396d4951049b85",
			},
			error: regexp.MustCompile("^open .*/populate-owners-[0-9]*/OWNERS_ALIASES: no such file or directory"),
		},
		{
			name:  "OWNERS and OWNERS_ALIASES",
			setup: "OWNERS_ALIASES",
			expected: &orgRepo{
				Owners:  &owners{Approvers: []string{"sig-alias"}},
				Aliases: &aliases{Aliases: map[string][]string{"sig-alias": {"alice", "bob"}}},
				Commit:  "3e7341c55330a127038bfc8d7a396d4951049b85",
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			switch test.setup {
			case "": // nothing to do
			case "OWNERS":
				err = ioutil.WriteFile(
					filepath.Join(dir, "OWNERS"),
					[]byte("approvers:\n- alice\n- bob\n"),
					0666,
				)
				if err != nil {
					t.Fatal(err)
				}
			case "OWNERS_ALIASES":
				err = ioutil.WriteFile(
					filepath.Join(dir, "OWNERS"),
					[]byte("approvers:\n- sig-alias\n"),
					0666,
				)
				if err != nil {
					t.Fatal(err)
				}
				err = ioutil.WriteFile(
					filepath.Join(dir, "OWNERS_ALIASES"),
					[]byte("aliases:\n  sig-alias:\n  - alice\n  - bob\n"),
					0666,
				)
				if err != nil {
					t.Fatal(err)
				}
			default:
				t.Fatalf("unrecognized setup: %q", test.setup)
			}

			orgrepo := &orgRepo{}
			err := orgrepo.extractOwners(dir)
			if test.error == nil {
				if err != nil {
					t.Fatal(err)
				}
			} else if !test.error.MatchString(err.Error()) {
				t.Fatalf("unexpected error: %v does not match %v", err, test.error)
			}

			// Need to override the newly created commit to avoid test failure
			orgrepo.Commit = test.expected.Commit
			assertEqual(t, orgrepo, test.expected)
		})
	}
}

func TestResolveAliases(t *testing.T) {
	given := &orgRepo{
		Owners: &owners{Approvers: []string{"alice", "sig-alias", "david"},
			Reviewers: []string{"adam", "sig-alias"}},
		Aliases: &aliases{Aliases: map[string][]string{"sig-alias": {"bob", "carol"}}},
	}
	expected := &orgRepo{
		Owners: &owners{Approvers: []string{"alice", "bob", "carol", "david"},
			Reviewers: []string{"adam", "bob", "carol"}},
		Aliases: &aliases{Aliases: map[string][]string{"sig-alias": {"bob", "carol"}}},
	}
	log.Println("given:", given)
	log.Println("expected:", expected)
	assertEqual(t, given.resolveOwnerAliases(), expected.Owners)
}

func TestWriteYAML(t *testing.T) {
	dir, err := ioutil.TempDir("", "populate-owners-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	for _, test := range []struct {
		name     string
		filename string
		data     interface{}
		expected string
	}{
		{
			name:     "OWNERS",
			filename: "OWNERS",
			data: &owners{
				Approvers: []string{"alice", "bob"},
			},
			expected: `# prefix 1
# prefix 2

approvers:
- alice
- bob
`,
		},
		{
			name:     "OWNERS overwrite",
			filename: "OWNERS",
			data: &owners{
				Approvers: []string{"bob", "charlie"},
			},
			expected: `# prefix 1
# prefix 2

approvers:
- bob
- charlie
`,
		},
		{
			name:     "OWNERS_ALIASES",
			filename: "OWNERS_ALIASES",
			data: &aliases{
				Aliases: map[string][]string{
					"group-1": {"alice", "bob"},
				},
			},
			expected: `# prefix 1
# prefix 2

aliases:
  group-1:
  - alice
  - bob
`,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(dir, test.filename)
			err = writeYAML(
				path,
				test.data,
				[]string{"# prefix 1\n", "# prefix 2\n", "\n"},
			)
			if err != nil {
				t.Fatal(err)
			}

			data, err := ioutil.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}

			if string(data) != test.expected {
				t.Fatalf("unexpected result:\n---\n%s\n--- != ---\n%s\n---\n", string(data), test.expected)
			}
		})
	}
}
