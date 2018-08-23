package steps

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"sort"
	"time"

	coreapi "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"

	buildapi "github.com/openshift/api/build/v1"
	imageclientset "github.com/openshift/client-go/image/clientset/versioned/typed/image/v1"

	"github.com/openshift/ci-operator/pkg/api"
)

const (
	CiAnnotationPrefix = "ci.openshift.io"
	PersistsLabel      = "persists-between-builds"
	JobLabel           = "job"
	BuildIdLabel       = "build-id"
	CreatesLabel       = "creates"
	CreatedByCILabel   = "created-by-ci"

	ProwJobIdLabel = "prow.k8s.io/id"
)

var (
	JobSpecAnnotation = fmt.Sprintf("%s/%s", CiAnnotationPrefix, "job-spec")
)

func sourceDockerfile(fromTag api.PipelineImageStreamTagReference, pathAlias string, job *JobSpec) string {
	workingDir := fmt.Sprintf("github.com/%s/%s", job.Refs.Org, job.Refs.Repo)
	if len(pathAlias) > 0 {
		workingDir = pathAlias
	}
	return fmt.Sprintf(`
FROM %s:%s
ADD ./clonerefs /clonerefs
RUN umask 0002 && /clonerefs && chmod g+xw -R /go/src
WORKDIR /go/src/%s/
RUN git submodule update --init
`, PipelineImageStream, fromTag, workingDir)
}

type sourceStep struct {
	config             api.SourceStepConfiguration
	resources          api.ResourceConfiguration
	buildClient        BuildClient
	imageClient        imageclientset.ImageV1Interface
	clonerefsSrcClient imageclientset.ImageV1Interface
	jobSpec            *JobSpec
}

func (s *sourceStep) Inputs(ctx context.Context, dry bool) (api.InputDefinition, error) {
	return s.jobSpec.Inputs(), nil
}

func (s *sourceStep) Run(ctx context.Context, dry bool) error {
	dockerfile := sourceDockerfile(s.config.From, s.config.PathAlias, s.jobSpec)

	clonerefsRef, err := istObjectReference(s.clonerefsSrcClient, s.config.ClonerefsImage)
	if err != nil {
		return fmt.Errorf("could not resolve clonerefs source: %v", err)
	}
	build := buildFromSource(
		s.jobSpec, s.config.From, s.config.To,
		buildapi.BuildSource{
			Type:       buildapi.BuildSourceDockerfile,
			Dockerfile: &dockerfile,
			Images: []buildapi.ImageSource{
				{
					From: clonerefsRef,
					Paths: []buildapi.ImageSourcePath{
						{
							SourcePath:     s.config.ClonerefsPath,
							DestinationDir: ".",
						},
					},
				},
			},
		},
		"",
		s.resources,
	)

	refs := s.jobSpec.Refs
	refs.PathAlias = s.config.PathAlias
	optionsSpec := map[string]interface{}{
		"src_root":       "/go",
		"log":            "/dev/null",
		"git_user_name":  "ci-robot",
		"git_user_email": "ci-robot@openshift.io",
		"refs":           []interface{}{refs},
	}
	optionsJSON, err := json.Marshal(optionsSpec)
	if err != nil {
		panic(fmt.Errorf("couldn't create JSON spec for clonerefs: %v", err))
	}

	build.Spec.CommonSpec.Strategy.DockerStrategy.Env = append(
		build.Spec.CommonSpec.Strategy.DockerStrategy.Env,
		coreapi.EnvVar{Name: "CLONEREFS_OPTIONS", Value: string(optionsJSON)},
	)

	return handleBuild(s.buildClient, build, dry)
}

func buildFromSource(jobSpec *JobSpec, fromTag, toTag api.PipelineImageStreamTagReference, source buildapi.BuildSource, dockerfilePath string, resources api.ResourceConfiguration) *buildapi.Build {
	log.Printf("Building %s", toTag)
	buildResources, err := resourcesFor(resources.RequirementsForStep(string(toTag)))
	if err != nil {
		panic(fmt.Errorf("unable to parse resource requirement for build %s: %v", toTag, err))
	}
	var from *coreapi.ObjectReference
	if len(fromTag) > 0 {
		from = &coreapi.ObjectReference{
			Kind:      "ImageStreamTag",
			Namespace: jobSpec.Namespace(),
			Name:      fmt.Sprintf("%s:%s", PipelineImageStream, fromTag),
		}
	}

	layer := buildapi.ImageOptimizationSkipLayers
	build := &buildapi.Build{
		ObjectMeta: meta.ObjectMeta{
			Name:      string(toTag),
			Namespace: jobSpec.Namespace(),
			Labels: map[string]string{
				PersistsLabel:    "false",
				JobLabel:         jobSpec.Job,
				BuildIdLabel:     jobSpec.BuildId,
				ProwJobIdLabel:   jobSpec.ProwJobID,
				CreatesLabel:     string(toTag),
				CreatedByCILabel: "true",
			},
			Annotations: map[string]string{
				JobSpecAnnotation: jobSpec.rawSpec,
			},
		},
		Spec: buildapi.BuildSpec{
			CommonSpec: buildapi.CommonSpec{
				Resources:      buildResources,
				ServiceAccount: "builder", // TODO: remove when build cluster has https://github.com/openshift/origin/pull/17668
				Source:         source,
				Strategy: buildapi.BuildStrategy{
					Type: buildapi.DockerBuildStrategyType,
					DockerStrategy: &buildapi.DockerBuildStrategy{
						DockerfilePath:          dockerfilePath,
						From:                    from,
						ForcePull:               true,
						NoCache:                 true,
						Env:                     []coreapi.EnvVar{},
						ImageOptimizationPolicy: &layer,
					},
				},
				Output: buildapi.BuildOutput{
					To: &coreapi.ObjectReference{
						Kind:      "ImageStreamTag",
						Namespace: jobSpec.Namespace(),
						Name:      fmt.Sprintf("%s:%s", PipelineImageStream, toTag),
					},
				},
			},
		},
	}
	if owner := jobSpec.Owner(); owner != nil {
		build.OwnerReferences = append(build.OwnerReferences, *owner)
	}

	return build
}

func buildInputsFromStep(inputs map[string]api.ImageBuildInputs) []buildapi.ImageSource {
	var names []string
	for k := range inputs {
		names = append(names, k)
	}
	sort.Strings(names)
	var refs []buildapi.ImageSource
	for _, name := range names {
		value := inputs[name]
		var paths []buildapi.ImageSourcePath
		for _, path := range value.Paths {
			paths = append(paths, buildapi.ImageSourcePath{SourcePath: path.SourcePath, DestinationDir: path.DestinationDir})
		}
		if len(value.As) == 0 && len(paths) == 0 {
			continue
		}
		refs = append(refs, buildapi.ImageSource{
			From: coreapi.ObjectReference{
				Kind: "ImageStreamTag",
				Name: fmt.Sprintf("%s:%s", PipelineImageStream, name),
			},
			As:    value.As,
			Paths: paths,
		})
	}
	return refs
}

func handleBuild(buildClient BuildClient, build *buildapi.Build, dry bool) error {
	if dry {
		buildJSON, err := json.MarshalIndent(build, "", "  ")
		if err != nil {
			return fmt.Errorf("failed to marshal build: %v", err)
		}
		fmt.Printf("%s\n", buildJSON)
		return nil
	}
	if _, err := buildClient.Builds(build.Namespace).Create(build); err != nil && !errors.IsAlreadyExists(err) {
		fmt.Errorf("could not create build %s: %v", build.Name, err)
	}
	return waitForBuild(buildClient, build.Namespace, build.Name)
}

func waitForBuild(buildClient BuildClient, namespace, name string) error {
	for {
		retry, err := waitForBuildOrTimeout(buildClient, namespace, name)
		if err != nil {
			return fmt.Errorf("could not wait for build: %v", err)
		}
		if !retry {
			break
		}
	}
	return nil
}

func waitForBuildOrTimeout(buildClient BuildClient, namespace, name string) (bool, error) {
	isOK := func(b *buildapi.Build) bool {
		return b.Status.Phase == buildapi.BuildPhaseComplete
	}
	isFailed := func(b *buildapi.Build) bool {
		return b.Status.Phase == buildapi.BuildPhaseFailed ||
			b.Status.Phase == buildapi.BuildPhaseCancelled ||
			b.Status.Phase == buildapi.BuildPhaseError
	}
	list, err := buildClient.Builds(namespace).List(meta.ListOptions{FieldSelector: fields.Set{"metadata.name": name}.AsSelector().String()})
	if err != nil {
		return false, fmt.Errorf("could not list builds: %v", err)
	}
	if len(list.Items) != 1 {
		return false, fmt.Errorf("could not find build %s", name)
	}
	build := &list.Items[0]
	if isOK(build) {
		log.Printf("Build %s already succeeded in %s", build.Name, buildDuration(build))
		return false, nil
	}
	if isFailed(build) {
		log.Printf("Build %s failed, printing logs:", build.Name)
		printBuildLogs(buildClient, build.Namespace, build.Name)
		return false, errorWithOutput{
			err:    fmt.Errorf("the build %s failed with reason %s: %s", build.Name, build.Status.Reason, build.Status.Message),
			output: build.Status.LogSnippet,
		}
	}

	watcher, err := buildClient.Builds(namespace).Watch(meta.ListOptions{
		FieldSelector: fields.Set{"metadata.name": name}.AsSelector().String(),
		Watch:         true,
	})
	if err != nil {
		return false, fmt.Errorf("could not create watcher for build %s: %v", name, err)
	}
	defer watcher.Stop()

	for {
		event, ok := <-watcher.ResultChan()
		if !ok {
			// restart
			return true, nil
		}
		if build, ok := event.Object.(*buildapi.Build); ok {
			if isOK(build) {
				log.Printf("Build %s succeeded after %s", build.Name, buildDuration(build).Truncate(time.Second))
				return false, nil
			}
			if isFailed(build) {
				log.Printf("Build %s failed, printing logs:", build.Name)
				printBuildLogs(buildClient, build.Namespace, build.Name)
				return false, errorWithOutput{
					err:    fmt.Errorf("the build %s failed after %s with reason %s: %s", build.Name, buildDuration(build).Truncate(time.Second), build.Status.Reason, build.Status.Message),
					output: build.Status.LogSnippet,
				}
			}
		}
	}
}

type errorWithOutput struct {
	err    error
	output string
}

func (e errorWithOutput) Error() string {
	return e.err.Error()
}

func (e errorWithOutput) ErrorOutput() string {
	return e.output
}

func buildDuration(build *buildapi.Build) time.Duration {
	start := build.Status.StartTimestamp
	if start == nil {
		start = &build.CreationTimestamp
	}
	end := build.Status.CompletionTimestamp
	if end == nil {
		end = &meta.Time{Time: time.Now()}
	}
	duration := end.Sub(start.Time)
	return duration
}

func printBuildLogs(buildClient BuildClient, namespace, name string) {
	if s, err := buildClient.Logs(namespace, name, &buildapi.BuildLogOptions{
		NoWait: true,
	}); err == nil {
		defer s.Close()
		if _, err := io.Copy(os.Stdout, s); err != nil {
			log.Printf("error: Unable to copy log output from failed build: %v", err)
		}
	} else {
		log.Printf("error: Unable to retrieve logs from failed build: %v", err)
	}
}

func resourcesFor(req api.ResourceRequirements) (coreapi.ResourceRequirements, error) {
	apireq := coreapi.ResourceRequirements{}
	for name, value := range req.Requests {
		q, err := resource.ParseQuantity(value)
		if err != nil {
			return coreapi.ResourceRequirements{}, fmt.Errorf("invalid resource request: %v", err)
		}
		if apireq.Requests == nil {
			apireq.Requests = make(coreapi.ResourceList)
		}
		apireq.Requests[coreapi.ResourceName(name)] = q
	}
	for name, value := range req.Limits {
		q, err := resource.ParseQuantity(value)
		if err != nil {
			return coreapi.ResourceRequirements{}, fmt.Errorf("invalid resource limit: %v", err)
		}
		if apireq.Limits == nil {
			apireq.Limits = make(coreapi.ResourceList)
		}
		apireq.Limits[coreapi.ResourceName(name)] = q
	}
	return apireq, nil
}

func (s *sourceStep) Done() (bool, error) {
	return imageStreamTagExists(s.config.To, s.imageClient.ImageStreamTags(s.jobSpec.Namespace()))
}

func imageStreamTagExists(reference api.PipelineImageStreamTagReference, istClient imageclientset.ImageStreamTagInterface) (bool, error) {
	log.Printf("Checking for existence of %s:%s", PipelineImageStream, reference)
	_, err := istClient.Get(
		fmt.Sprintf("%s:%s", PipelineImageStream, reference),
		meta.GetOptions{},
	)
	if err != nil {
		if errors.IsNotFound(err) {
			return false, nil
		} else {
			return false, fmt.Errorf("could not get output imagestreamtag: %v", err)
		}
	} else {
		return true, nil
	}
}

func (s *sourceStep) Requires() []api.StepLink {
	return []api.StepLink{api.InternalImageLink(s.config.From)}
}

func (s *sourceStep) Creates() []api.StepLink {
	return []api.StepLink{api.InternalImageLink(s.config.To)}
}

func (s *sourceStep) Provides() (api.ParameterMap, api.StepLink) {
	return api.ParameterMap{
		"LOCAL_IMAGE_SRC": func() (string, error) {
			is, err := s.imageClient.ImageStreams(s.jobSpec.Namespace()).Get(PipelineImageStream, meta.GetOptions{})
			if err != nil {
				return "", fmt.Errorf("could not get output imagestream: %v", err)
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
	}, api.InternalImageLink("src")
}

func (s *sourceStep) Name() string { return string(s.config.To) }

func (s *sourceStep) Description() string {
	return fmt.Sprintf("Clone the correct source code into an image and tag it as %s", s.config.To)
}

func SourceStep(config api.SourceStepConfiguration, resources api.ResourceConfiguration, buildClient BuildClient, clonerefsSrcClient imageclientset.ImageV1Interface, imageClient imageclientset.ImageV1Interface, jobSpec *JobSpec) api.Step {
	return &sourceStep{
		config:             config,
		resources:          resources,
		buildClient:        buildClient,
		imageClient:        imageClient,
		clonerefsSrcClient: clonerefsSrcClient,
		jobSpec:            jobSpec,
	}
}
