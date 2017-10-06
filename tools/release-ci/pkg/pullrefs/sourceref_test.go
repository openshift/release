package pullrefs

import (
	"reflect"
	"regexp"
	"testing"
)

func TestParsePullRefs(t *testing.T) {
	tests := []struct {
		input     string
		expect    SourceRef
		expectErr bool
	}{
		{
			input:  "mybranch",
			expect: SourceRef{Branch: "mybranch"},
		},
		{
			input:  "master:172342134",
			expect: SourceRef{Branch: "master", BranchCommit: "172342134"},
		},
		{
			input: "master:12345,41234:7890,12345:abcde",
			expect: SourceRef{
				Branch:       "master",
				BranchCommit: "12345",
				PullRefs: []PullRequestRef{
					{
						Number: 41234,
						Commit: "7890",
					},
					{
						Number: 12345,
						Commit: "abcde",
					},
				},
			},
		},
		{
			// too many parts
			input:     "mybranch:12345:6789",
			expectErr: true,
		},
		{
			// non-numeric pr number
			input:     "branch:12345,abcd:6789",
			expectErr: true,
		},
		{
			// too many pr parts
			input:     "branch:12345,123:456:789",
			expectErr: true,
		},
	}
	for _, test := range tests {
		actual, err := ParsePullRefs(test.input)
		if err != nil {
			if !test.expectErr {
				t.Errorf("%q: unexpected error: %v", test.input, err)
			}
			continue
		}
		if err == nil && test.expectErr {
			t.Errorf("%q: did not get expected error", test.input)
			continue
		}
		if !reflect.DeepEqual(*actual, test.expect) {
			t.Errorf("%q: unexpected result: %#v", test.input, actual)
		}
	}
}

func TestToBuildID(t *testing.T) {
	expectRegex := regexp.MustCompile("^(batch-|pr-[0-9]+-|)[0-9,a-f]{24}$")
	tests := []string{
		"branch",
		"branch:12345",
		"branch:12345,23:6789",
		"branch:12345,23:6789,45:abcde",
	}
	for _, test := range tests {
		ref, err := ParsePullRefs(test)
		if err != nil {
			t.Errorf("%s: unexpected: %v", test, err)
			continue
		}
		result := ref.ToBuildID()
		if !expectRegex.Match([]byte(result)) {
			t.Errorf("%s: unexpected result: %q", test, result)
		}
	}
}
