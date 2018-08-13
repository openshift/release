package steps

import (
	"context"
	"fmt"

	buildapi "github.com/openshift/api/build/v1"
	imageclientset "github.com/openshift/client-go/image/clientset/versioned/typed/image/v1"
	routeclientset "github.com/openshift/client-go/route/clientset/versioned/typed/route/v1"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/openshift/ci-operator/pkg/api"
)

func rpmInjectionDockerfile(from api.PipelineImageStreamTagReference, repo string) string {
	return fmt.Sprintf(`FROM %s:%s
RUN echo $'[built]\nname = Built RPMs\nbaseurl = http://%s\ngpgcheck = 0\nenabled = 0\n\n[origin-local-release]\nname = Built RPMs\nbaseurl = http://%s\ngpgcheck = 0\nenabled = 0' > /etc/yum.repos.d/built.repo`, PipelineImageStream, from, repo, repo)
}

type rpmImageInjectionStep struct {
	config      api.RPMImageInjectionStepConfiguration
	resources   api.ResourceConfiguration
	buildClient BuildClient
	routeClient routeclientset.RoutesGetter
	istClient   imageclientset.ImageStreamTagsGetter
	jobSpec     *JobSpec
}

func (s *rpmImageInjectionStep) Inputs(ctx context.Context, dry bool) (api.InputDefinition, error) {
	return nil, nil
}

func (s *rpmImageInjectionStep) Run(ctx context.Context, dry bool) error {
	var host string
	if dry {
		host = "dry-fake"
	} else {
		route, err := s.routeClient.Routes(s.jobSpec.Namespace()).Get(RPMRepoName, meta.GetOptions{})
		if err != nil {
			return fmt.Errorf("could not get Route for RPM server: %v", err)
		}
		host = route.Spec.Host
	}
	dockerfile := rpmInjectionDockerfile(s.config.From, host)
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

func (s *rpmImageInjectionStep) Done() (bool, error) {
	return imageStreamTagExists(s.config.To, s.istClient.ImageStreamTags(s.jobSpec.Namespace()))
}

func (s *rpmImageInjectionStep) Requires() []api.StepLink {
	return []api.StepLink{api.InternalImageLink(s.config.From), api.RPMRepoLink()}
}

func (s *rpmImageInjectionStep) Creates() []api.StepLink {
	return []api.StepLink{api.InternalImageLink(s.config.To)}
}

func (s *rpmImageInjectionStep) Provides() (api.ParameterMap, api.StepLink) {
	return nil, nil
}

func (s *rpmImageInjectionStep) Name() string { return string(s.config.To) }

func (s *rpmImageInjectionStep) Description() string {
	return "Inject an RPM repository that will point at the RPM server"
}

func RPMImageInjectionStep(config api.RPMImageInjectionStepConfiguration, resources api.ResourceConfiguration, buildClient BuildClient, routeClient routeclientset.RoutesGetter, istClient imageclientset.ImageStreamTagsGetter, jobSpec *JobSpec) api.Step {
	return &rpmImageInjectionStep{
		config:      config,
		resources:   resources,
		buildClient: buildClient,
		routeClient: routeClient,
		istClient:   istClient,
		jobSpec:     jobSpec,
	}
}
