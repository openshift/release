package api

import (
	"context"
	"reflect"
	"testing"
)

func TestMatches(t *testing.T) {
	var testCases = []struct {
		name    string
		first   StepLink
		second  StepLink
		matches bool
	}{
		{
			name:    "internal matches itself",
			first:   InternalImageLink(PipelineImageStreamTagReferenceRPMs),
			second:  InternalImageLink(PipelineImageStreamTagReferenceRPMs),
			matches: true,
		},
		{
			name:    "external matches itself",
			first:   ExternalImageLink(ImageStreamTagReference{Namespace: "ns", Name: "name", Tag: "latest"}),
			second:  ExternalImageLink(ImageStreamTagReference{Namespace: "ns", Name: "name", Tag: "latest"}),
			matches: true,
		},
		{
			name:    "rpm matches itself",
			first:   RPMRepoLink(),
			second:  RPMRepoLink(),
			matches: true,
		},
		{
			name:    "release images matches itself",
			first:   ReleaseImagesLink(),
			second:  ReleaseImagesLink(),
			matches: true,
		},
		{
			name:    "different internal do not match",
			first:   InternalImageLink(PipelineImageStreamTagReferenceRPMs),
			second:  InternalImageLink(PipelineImageStreamTagReferenceSource),
			matches: false,
		},
		{
			name:    "different external do not match",
			first:   ExternalImageLink(ImageStreamTagReference{Namespace: "ns", Name: "name", Tag: "latest"}),
			second:  ExternalImageLink(ImageStreamTagReference{Namespace: "ns", Name: "name", Tag: "other"}),
			matches: false,
		},
		{
			name:    "internal does not match external",
			first:   InternalImageLink(PipelineImageStreamTagReferenceRPMs),
			second:  ExternalImageLink(ImageStreamTagReference{Namespace: "ns", Name: "name", Tag: "latest"}),
			matches: false,
		},
		{
			name:    "internal does not match RPM",
			first:   InternalImageLink(PipelineImageStreamTagReferenceRPMs),
			second:  RPMRepoLink(),
			matches: false,
		},
		{
			name:    "internal does not match release images",
			first:   InternalImageLink(PipelineImageStreamTagReferenceRPMs),
			second:  ReleaseImagesLink(),
			matches: false,
		},
		{
			name:    "external does not match RPM",
			first:   ExternalImageLink(ImageStreamTagReference{Namespace: "ns", Name: "name", Tag: "latest"}),
			second:  RPMRepoLink(),
			matches: false,
		},
		{
			name:    "external does not match release images",
			first:   ExternalImageLink(ImageStreamTagReference{Namespace: "ns", Name: "name", Tag: "latest"}),
			second:  ReleaseImagesLink(),
			matches: false,
		},
		{
			name:    "RPM does not match release images",
			first:   RPMRepoLink(),
			second:  ReleaseImagesLink(),
			matches: false,
		},
	}

	for _, testCase := range testCases {
		if actual, expected := testCase.first.Matches(testCase.second), testCase.matches; actual != expected {
			message := "not match"
			if testCase.matches {
				message = "match"
			}
			t.Errorf("%s: expected links to %s, but they didn't:\nfirst:\n\t%v\nsecond:\n\t%v", testCase.name, message, testCase.first, testCase.second)
		}
	}
}

type fakeStep struct {
	requires []StepLink
	creates  []StepLink
	name     string
}

func (f *fakeStep) Inputs(ctx context.Context, dry bool) (InputDefinition, error) { return nil, nil }

func (f *fakeStep) Run(ctx context.Context, dry bool) error { return nil }

func (f *fakeStep) Done() (bool, error)  { return true, nil }
func (f *fakeStep) Requires() []StepLink { return f.requires }
func (f *fakeStep) Creates() []StepLink  { return f.creates }
func (f *fakeStep) Name() string         { return f.name }
func (f *fakeStep) Description() string  { return f.name }

func (f *fakeStep) Provides() (ParameterMap, StepLink) { return nil, nil }

func TestBuildGraph(t *testing.T) {
	root := &fakeStep{
		requires: []StepLink{ExternalImageLink(ImageStreamTagReference{Namespace: "ns", Name: "base", Tag: "latest"})},
		creates:  []StepLink{InternalImageLink(PipelineImageStreamTagReferenceRoot)},
	}
	other := &fakeStep{
		requires: []StepLink{ExternalImageLink(ImageStreamTagReference{Namespace: "ns", Name: "base", Tag: "other"})},
		creates:  []StepLink{InternalImageLink(PipelineImageStreamTagReference("other"))},
	}
	src := &fakeStep{
		requires: []StepLink{InternalImageLink(PipelineImageStreamTagReferenceRoot)},
		creates:  []StepLink{InternalImageLink(PipelineImageStreamTagReferenceSource)},
	}
	bin := &fakeStep{
		requires: []StepLink{InternalImageLink(PipelineImageStreamTagReferenceSource)},
		creates:  []StepLink{InternalImageLink(PipelineImageStreamTagReferenceBinaries)},
	}
	testBin := &fakeStep{
		requires: []StepLink{InternalImageLink(PipelineImageStreamTagReferenceSource)},
		creates:  []StepLink{InternalImageLink(PipelineImageStreamTagReferenceTestBinaries)},
	}
	rpm := &fakeStep{
		requires: []StepLink{InternalImageLink(PipelineImageStreamTagReferenceBinaries)},
		creates:  []StepLink{InternalImageLink(PipelineImageStreamTagReferenceRPMs)},
	}
	unrelated := &fakeStep{
		requires: []StepLink{InternalImageLink(PipelineImageStreamTagReference("other")), InternalImageLink(PipelineImageStreamTagReferenceRPMs)},
		creates:  []StepLink{InternalImageLink(PipelineImageStreamTagReference("unrelated"))},
	}
	final := &fakeStep{
		requires: []StepLink{InternalImageLink(PipelineImageStreamTagReference("unrelated"))},
		creates:  []StepLink{InternalImageLink(PipelineImageStreamTagReference("final"))},
	}

	duplicateRoot := &fakeStep{
		requires: []StepLink{ExternalImageLink(ImageStreamTagReference{Namespace: "ns", Name: "base", Tag: "latest"})},
		creates:  []StepLink{InternalImageLink(PipelineImageStreamTagReferenceRoot)},
	}
	duplicateSrc := &fakeStep{
		requires: []StepLink{
			InternalImageLink(PipelineImageStreamTagReferenceRoot),
			InternalImageLink(PipelineImageStreamTagReferenceRoot),
		},
		creates: []StepLink{InternalImageLink(PipelineImageStreamTagReference("other"))},
	}

	var testCases = []struct {
		name   string
		input  []Step
		output []*StepNode
	}{
		{
			name:  "basic graph",
			input: []Step{root, other, src, bin, testBin, rpm, unrelated, final},
			output: []*StepNode{{
				Step: root,
				Children: []*StepNode{{
					Step: src,
					Children: []*StepNode{{
						Step: bin,
						Children: []*StepNode{{
							Step: rpm,
							Children: []*StepNode{{
								Step: unrelated,
								Children: []*StepNode{{
									Step:     final,
									Children: []*StepNode{},
								}},
							}},
						}},
					}, {
						Step:     testBin,
						Children: []*StepNode{},
					}},
				}},
			}, {
				Step: other,
				Children: []*StepNode{{
					Step: unrelated,
					Children: []*StepNode{{
						Step:     final,
						Children: []*StepNode{},
					}},
				}},
			}},
		},
		{
			name:  "duplicate links",
			input: []Step{duplicateRoot, duplicateSrc},
			output: []*StepNode{{
				Step: duplicateRoot,
				Children: []*StepNode{{
					Step:     duplicateSrc,
					Children: []*StepNode{},
				}},
			}},
		},
	}

	for _, testCase := range testCases {
		if actual, expected := BuildGraph(testCase.input), testCase.output; !reflect.DeepEqual(actual, expected) {
			t.Errorf("%s: did not generate step graph as expected:\nwant:\n\t%v\nhave:\n\t%v", testCase.name, expected, actual)
		}
	}
}
