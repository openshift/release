package steps

import (
	"context"
	"log"

	"github.com/openshift/ci-operator/pkg/api"
)

type imagesReadyStep struct {
	links []api.StepLink
}

func (s *imagesReadyStep) Inputs(ctx context.Context, dry bool) (api.InputDefinition, error) {
	return nil, nil
}

func (s *imagesReadyStep) Run(ctx context.Context, dry bool) error {
	log.Printf("All images ready")
	return nil
}

func (s *imagesReadyStep) Done() (bool, error) {
	return true, nil
}

func (s *imagesReadyStep) Requires() []api.StepLink {
	return s.links
}

func (s *imagesReadyStep) Creates() []api.StepLink {
	return []api.StepLink{api.ImagesReadyLink()}
}

func (s *imagesReadyStep) Provides() (api.ParameterMap, api.StepLink) {
	return nil, nil
}

func (s *imagesReadyStep) Name() string { return "[images]" }

func (s *imagesReadyStep) Description() string { return "All images are built and tagged into stable" }

func ImagesReadyStep(links []api.StepLink, jobSpec *JobSpec) api.Step {
	return &imagesReadyStep{
		links: links,
	}
}
