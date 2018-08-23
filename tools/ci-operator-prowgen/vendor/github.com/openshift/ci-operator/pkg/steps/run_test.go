package steps

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/openshift/ci-operator/pkg/api"
)

type fakeStep struct {
	name      string
	runErr    error
	shouldRun bool
	requires  []api.StepLink
	creates   []api.StepLink

	lock    sync.Mutex
	numRuns int
}

func (f *fakeStep) Inputs(ctx context.Context, dry bool) (api.InputDefinition, error) { return nil, nil }

func (f *fakeStep) Run(ctx context.Context, dry bool) error {
	defer f.lock.Unlock()
	f.lock.Lock()
	f.numRuns = f.numRuns + 1

	return f.runErr
}
func (f *fakeStep) Done() (bool, error)      { return true, nil }
func (f *fakeStep) Requires() []api.StepLink { return f.requires }
func (f *fakeStep) Creates() []api.StepLink  { return f.creates }
func (f *fakeStep) Name() string             { return f.name }
func (f *fakeStep) Description() string      { return f.name }

func (f *fakeStep) Provides() (api.ParameterMap, api.StepLink) { return nil, nil }

func TestRunNormalCase(t *testing.T) {
	root := &fakeStep{
		name:      "root",
		shouldRun: true,
		requires:  []api.StepLink{api.ExternalImageLink(api.ImageStreamTagReference{Namespace: "ns", Name: "base", Tag: "latest"})},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceRoot)},
	}
	other := &fakeStep{
		name:      "other",
		shouldRun: true,
		requires:  []api.StepLink{api.ExternalImageLink(api.ImageStreamTagReference{Namespace: "ns", Name: "base", Tag: "other"})},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReference("other"))},
	}
	src := &fakeStep{
		name:      "src",
		shouldRun: true,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceRoot)},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceSource)},
	}
	bin := &fakeStep{
		name:      "bin",
		shouldRun: true,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceSource)},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceBinaries)},
	}
	testBin := &fakeStep{
		name:      "testBin",
		shouldRun: true,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceSource)},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceTestBinaries)},
	}
	rpm := &fakeStep{
		name:      "rpm",
		shouldRun: true,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceBinaries)},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceRPMs)},
	}
	unrelated := &fakeStep{
		name:      "unrelated",
		shouldRun: true,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReference("other")), api.InternalImageLink(api.PipelineImageStreamTagReferenceRPMs)},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReference("unrelated"))},
	}
	final := &fakeStep{
		name:      "final",
		shouldRun: true,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReference("unrelated"))},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReference("final"))},
	}

	if _, err := Run(context.Background(), api.BuildGraph([]api.Step{root, other, src, bin, testBin, rpm, unrelated, final}), false); err != nil {
		t.Errorf("got an error but expected none: %v", err)
	}

	for _, step := range []*fakeStep{root, other, src, bin, testBin, rpm, unrelated, final} {
		if step.shouldRun && step.numRuns != 1 {
			t.Errorf("step %s did not run just once, but %d times", step.name, step.numRuns)
		}
		if !step.shouldRun && step.numRuns != 0 {
			t.Errorf("step %s expected to never run, but ran %d times", step.name, step.numRuns)
		}
	}
}

func TestRunFailureCase(t *testing.T) {
	root := &fakeStep{
		name:      "root",
		shouldRun: true,
		requires:  []api.StepLink{api.ExternalImageLink(api.ImageStreamTagReference{Namespace: "ns", Name: "base", Tag: "latest"})},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceRoot)},
	}
	other := &fakeStep{
		name:      "other",
		shouldRun: true,
		requires:  []api.StepLink{api.ExternalImageLink(api.ImageStreamTagReference{Namespace: "ns", Name: "base", Tag: "other"})},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReference("other"))},
	}
	src := &fakeStep{
		name:      "src",
		shouldRun: true,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceRoot)},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceSource)},
	}
	bin := &fakeStep{
		name:      "bin",
		shouldRun: true,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceSource)},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceBinaries)},
	}
	testBin := &fakeStep{
		name:      "testBin",
		shouldRun: true,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceSource)},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceTestBinaries)},
	}
	rpm := &fakeStep{
		name:      "rpm",
		runErr:    errors.New("oopsie"),
		shouldRun: true,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceBinaries)},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReferenceRPMs)},
	}
	unrelated := &fakeStep{
		name:      "unrelated",
		shouldRun: false,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReference("other")), api.InternalImageLink(api.PipelineImageStreamTagReferenceRPMs)},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReference("unrelated"))},
	}
	final := &fakeStep{
		name:      "final",
		shouldRun: false,
		requires:  []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReference("unrelated"))},
		creates:   []api.StepLink{api.InternalImageLink(api.PipelineImageStreamTagReference("final"))},
	}

	suites, err := Run(context.Background(), api.BuildGraph([]api.Step{root, other, src, bin, testBin, rpm, unrelated, final}), false)
	if err == nil {
		t.Error("got no error but expected one")
	}
	if len(suites.Suites) != 1 || len(suites.Suites[0].TestCases) != 6 || suites.Suites[0].NumTests != 6 || suites.Suites[0].NumFailed != 1 {
		t.Errorf("unexpected junit output: %#v", suites.Suites[0])
	}

	for _, step := range []*fakeStep{root, other, src, bin, testBin, rpm, unrelated, final} {
		if step.shouldRun && step.numRuns != 1 {
			t.Errorf("step %s did not run just once, but %d times", step.name, step.numRuns)
		}
		if !step.shouldRun && step.numRuns != 0 {
			t.Errorf("step %s expected to never run, but ran %d times", step.name, step.numRuns)
		}
	}
}
