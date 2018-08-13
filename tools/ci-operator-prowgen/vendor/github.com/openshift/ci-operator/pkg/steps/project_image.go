package steps

import (
	"context"
	"encoding/json"
	"fmt"

	buildapi "github.com/openshift/api/build/v1"
	"github.com/openshift/api/image/docker10"
	"github.com/openshift/ci-operator/pkg/api"
	imageclientset "github.com/openshift/client-go/image/clientset/versioned/typed/image/v1"
	coreapi "k8s.io/api/core/v1"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type projectDirectoryImageBuildStep struct {
	config      api.ProjectDirectoryImageBuildStepConfiguration
	resources   api.ResourceConfiguration
	buildClient BuildClient
	istClient   imageclientset.ImageStreamTagsGetter
	jobSpec     *JobSpec
}

func (s *projectDirectoryImageBuildStep) Inputs(ctx context.Context, dry bool) (api.InputDefinition, error) {
	return nil, nil
}

func (s *projectDirectoryImageBuildStep) Run(ctx context.Context, dry bool) error {
	source := fmt.Sprintf("%s:%s", PipelineImageStream, api.PipelineImageStreamTagReferenceSource)

	var workingDir string
	if dry {
		workingDir = "dry-fake"
	} else {
		ist, err := s.istClient.ImageStreamTags(s.jobSpec.Namespace()).Get(source, meta.GetOptions{})
		if err != nil {
			return fmt.Errorf("could not fetch source ImageStreamTag: %v", err)
		}
		metadata := &docker10.DockerImage{}
		if len(ist.Image.DockerImageMetadata.Raw) == 0 {
			return fmt.Errorf("could not fetch Docker image metadata for ImageStreamTag %s", source)
		}
		if err := json.Unmarshal(ist.Image.DockerImageMetadata.Raw, metadata); err != nil {
			return fmt.Errorf("malformed Docker image metadata on ImageStreamTag: %v", err)
		}
		workingDir = metadata.Config.WorkingDir
	}
	images := buildInputsFromStep(s.config.Inputs)
	if _, ok := s.config.Inputs["src"]; !ok {
		images = append(images, buildapi.ImageSource{
			From: coreapi.ObjectReference{
				Kind: "ImageStreamTag",
				Name: source,
			},
			Paths: []buildapi.ImageSourcePath{{
				SourcePath:     fmt.Sprintf("%s/%s/.", workingDir, s.config.ContextDir),
				DestinationDir: ".",
			}},
		})
	}
	return handleBuild(s.buildClient, buildFromSource(
		s.jobSpec, s.config.From, s.config.To,
		buildapi.BuildSource{
			Type:   buildapi.BuildSourceImage,
			Images: images,
		},
		s.config.DockerfilePath,
		s.resources,
	), dry)
}

func (s *projectDirectoryImageBuildStep) Done() (bool, error) {
	return imageStreamTagExists(s.config.To, s.istClient.ImageStreamTags(s.jobSpec.Namespace()))
}

func (s *projectDirectoryImageBuildStep) Requires() []api.StepLink {
	links := []api.StepLink{
		api.InternalImageLink(api.PipelineImageStreamTagReferenceSource),
	}
	if len(s.config.From) > 0 {
		links = append(links, api.InternalImageLink(s.config.From))
	}
	for name := range s.config.Inputs {
		links = append(links, api.InternalImageLink(api.PipelineImageStreamTagReference(name)))
	}
	return links
}

func (s *projectDirectoryImageBuildStep) Creates() []api.StepLink {
	return []api.StepLink{api.InternalImageLink(s.config.To)}
}

func (s *projectDirectoryImageBuildStep) Provides() (api.ParameterMap, api.StepLink) {
	return nil, nil
}

func (s *projectDirectoryImageBuildStep) Name() string { return string(s.config.To) }

func (s *projectDirectoryImageBuildStep) Description() string {
	return fmt.Sprintf("Build image %s from the repository", s.config.To)
}

func ProjectDirectoryImageBuildStep(config api.ProjectDirectoryImageBuildStepConfiguration, resources api.ResourceConfiguration, buildClient BuildClient, istClient imageclientset.ImageStreamTagsGetter, jobSpec *JobSpec) api.Step {
	return &projectDirectoryImageBuildStep{
		config:      config,
		resources:   resources,
		buildClient: buildClient,
		istClient:   istClient,
		jobSpec:     jobSpec,
	}
}
