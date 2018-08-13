package steps

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	buildapi "github.com/openshift/api/build/v1"
	"github.com/openshift/ci-operator/pkg/api"
	imageclientset "github.com/openshift/client-go/image/clientset/versioned/typed/image/v1"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func rawCommandDockerfile(from api.PipelineImageStreamTagReference, commands string) string {
	return fmt.Sprintf(`FROM %s:%s
RUN ["/bin/bash", "-c", %s]`, PipelineImageStream, from, strconv.Quote(fmt.Sprintf("set -o errexit; umask 0002; %s", commands)))
}

type pipelineImageCacheStep struct {
	config      api.PipelineImageCacheStepConfiguration
	resources   api.ResourceConfiguration
	buildClient BuildClient
	imageClient imageclientset.ImageV1Interface
	jobSpec     *JobSpec
}

func (s *pipelineImageCacheStep) Inputs(ctx context.Context, dry bool) (api.InputDefinition, error) {
	return nil, nil
}

func (s *pipelineImageCacheStep) Run(ctx context.Context, dry bool) error {
	dockerfile := rawCommandDockerfile(s.config.From, s.config.Commands)
	return handleBuild(s.buildClient, buildFromSource(
		s.jobSpec, s.config.From, s.config.To,
		buildapi.BuildSource{
			Type:       buildapi.BuildSourceDockerfile,
			Dockerfile: &dockerfile,
		},
		"",
		s.resources,
	), dry)
}

func (s *pipelineImageCacheStep) Done() (bool, error) {
	return imageStreamTagExists(s.config.To, s.imageClient.ImageStreamTags(s.jobSpec.Namespace()))
}

func (s *pipelineImageCacheStep) Requires() []api.StepLink {
	return []api.StepLink{api.InternalImageLink(s.config.From)}
}

func (s *pipelineImageCacheStep) Creates() []api.StepLink {
	return []api.StepLink{api.InternalImageLink(s.config.To)}
}

func (s *pipelineImageCacheStep) Provides() (api.ParameterMap, api.StepLink) {
	if len(s.config.To) == 0 {
		return nil, nil
	}
	return api.ParameterMap{
		fmt.Sprintf("LOCAL_IMAGE_%s", strings.ToUpper(strings.Replace(string(s.config.To), "-", "_", -1))): func() (string, error) {
			is, err := s.imageClient.ImageStreams(s.jobSpec.Namespace()).Get(PipelineImageStream, meta.GetOptions{})
			if err != nil {
				return "", fmt.Errorf("could not retrieve output imagestream: %v", err)
			}
			var registry string
			if len(is.Status.PublicDockerImageRepository) > 0 {
				registry = is.Status.PublicDockerImageRepository
			} else if len(is.Status.DockerImageRepository) > 0 {
				registry = is.Status.DockerImageRepository
			} else {
				return "", fmt.Errorf("image stream %s has no accessible image registry value", s.config.To)
			}
			return fmt.Sprintf("%s:%s", registry, s.config.To), nil
		},
	}, api.InternalImageLink(s.config.To)
}

func (s *pipelineImageCacheStep) Name() string { return string(s.config.To) }

func (s *pipelineImageCacheStep) Description() string {
	return fmt.Sprintf("Store build results into a layer on top of %s and save as %s", s.config.From, s.config.To)
}

func PipelineImageCacheStep(config api.PipelineImageCacheStepConfiguration, resources api.ResourceConfiguration, buildClient BuildClient, imageClient imageclientset.ImageV1Interface, jobSpec *JobSpec) api.Step {
	return &pipelineImageCacheStep{
		config:      config,
		resources:   resources,
		buildClient: buildClient,
		imageClient: imageClient,
		jobSpec:     jobSpec,
	}
}
