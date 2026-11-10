package main

import (
	"encoding/json"
	"encoding/xml"
	"flag"
	"io"
	"log"
	"os"

	"fmt"
	"sort"

	"github.com/openshift/release/tools/junitreport/pkg/api"
)

type uniqueSuites map[string]*suiteRuns

func (s uniqueSuites) Merge(namePrefix string, suite *api.TestSuite) {
	name := suite.Name
	if len(namePrefix) > 0 {
		name = namePrefix + "/"
	}
	existing, ok := s[name]
	if !ok {
		existing = newSuiteRuns(suite)
		s[name] = existing
	}

	existing.Merge(suite.TestCases)

	for _, suite := range suite.Children {
		s.Merge(name, suite)
	}
}

type suiteRuns struct {
	suite *api.TestSuite
	runs  map[string]*api.TestCase
}

func newSuiteRuns(suite *api.TestSuite) *suiteRuns {
	return &suiteRuns{
		suite: suite,
		runs:  make(map[string]*api.TestCase),
	}
}

func (r *suiteRuns) Merge(testCases []*api.TestCase) {
	for _, testCase := range testCases {
		existing, ok := r.runs[testCase.Name]
		if !ok {
			r.runs[testCase.Name] = testCase
			continue
		}
		switch {
		case testCase.SkipMessage != nil:
			// if the new test is a skip, ignore it
		case existing.SkipMessage != nil && testCase.SkipMessage == nil:
			// always replace a skip with a non-skip
			r.runs[testCase.Name] = testCase
		case existing.FailureOutput == nil && testCase.FailureOutput != nil:
			// replace a passing test with a failing test
			r.runs[testCase.Name] = testCase
		}
	}
}

func main() {
	log.SetFlags(0)
	opt := struct {
		JSONSummary bool
		Skip        bool
	}{}
	flag.BoolVar(&opt.Skip, "exclude-skip", false, "Exclude skipped tests when merging")
	flag.BoolVar(&opt.JSONSummary, "json-summary", false, "Convert the result to a single JSON file that summarizes the output")
	flag.Parse()

	args := flag.Args()
	if len(args) == 0 {
		args = []string{"-"}
	}

	suites := make(uniqueSuites)

	for _, arg := range args {
		func() {
			var f io.Reader
			if arg == "-" {
				f = os.Stdin
			} else {
				file, err := os.Open(arg)
				if err != nil {
					log.Fatal(err)
				}
				defer file.Close()
				f = file
			}
			d := xml.NewDecoder(f)

			for {
				t, err := d.Token()
				if err != nil {
					log.Fatal(err)
				}
				if t == nil {
					log.Fatalf("input file %s does not appear to be a JUnit XML file", arg)
				}
				// Inspect the top level DOM element and perform the appropriate action
				switch se := t.(type) {
				case xml.StartElement:
					switch se.Name.Local {
					case "testsuites":
						input := &api.TestSuites{}
						if err := d.DecodeElement(input, &se); err != nil {
							log.Fatal(err)
						}
						for _, suite := range input.Suites {
							suites.Merge("", suite)
						}
					case "testsuite":
						input := &api.TestSuite{}
						if err := d.DecodeElement(input, &se); err != nil {
							log.Fatal(err)
						}
						suites.Merge("", input)
					default:
						log.Fatal(fmt.Errorf("unexpected top level element in %s: %s", arg, se.Name.Local))
					}
				default:
					continue
				}
				break
			}
		}()
	}

	var suiteNames []string
	for k := range suites {
		suiteNames = append(suiteNames, k)
	}
	sort.Sort(sort.StringSlice(suiteNames))
	output := &api.TestSuites{}

	for _, name := range suiteNames {
		suite := suites[name]

		out := &api.TestSuite{
			Name:     name,
			NumTests: uint(len(suite.runs)),
		}

		var keys []string
		for k := range suite.runs {
			keys = append(keys, k)
		}
		sort.Sort(sort.StringSlice(keys))

		for _, k := range keys {
			testCase := suite.runs[k]
			if opt.Skip && testCase.SkipMessage != nil {
				continue
			}
			out.TestCases = append(out.TestCases, testCase)
			switch {
			case testCase.SkipMessage != nil:
				out.NumSkipped++
			case testCase.FailureOutput != nil:
				out.NumFailed++
			}
			out.Duration += testCase.Duration
		}
		out.NumTests = uint(len(out.TestCases))
		output.Suites = append(output.Suites, out)
	}

	switch {
	case opt.JSONSummary:
		summary := summaryFor(output)
		e := json.NewEncoder(os.Stdout)
		e.SetIndent("", "  ")
		e.Encode(summary)
		fmt.Fprintln(os.Stdout)
	default:
		e := xml.NewEncoder(os.Stdout)
		e.Indent("", "\t")
		if err := e.Encode(output); err != nil {
			log.Fatal(err)
		}
		e.Flush()
		fmt.Fprintln(os.Stdout)
	}
}

func summaryFor(suites *api.TestSuites) *SuiteSummary {
	s := &SuiteSummary{}
	for _, testSuite := range suites.Suites {
		for _, testCase := range testSuite.TestCases {
			if testCase.SkipMessage != nil {
				continue
			}
			s.Tests = append(s.Tests, TestCaseSummary{
				Name:   testCase.Name,
				Failed: testCase.FailureOutput != nil,
				Time:   testCase.Duration,
			})
		}
	}
	return s
}

type SuiteSummary struct {
	Tests []TestCaseSummary `json:"tests"`
}

type TestCaseSummary struct {
	Name   string  `json:"name"`
	Time   float64 `json:"time"`
	Failed bool    `json:"failed"`
}
