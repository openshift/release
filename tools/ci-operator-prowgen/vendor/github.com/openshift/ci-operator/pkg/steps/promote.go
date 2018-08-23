package steps

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"

	"k8s.io/apimachinery/pkg/api/errors"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/sets"

	imageapi "github.com/openshift/api/image/v1"
	"github.com/openshift/ci-operator/pkg/api"
	imageclientset "github.com/openshift/client-go/image/clientset/versioned/typed/image/v1"
)

// promotionStep will tag a full release suite
// of images out to the configured namespace.
type promotionStep struct {
	config api.PromotionConfiguration
	// tags is the set of all tags to attempt to copy over
	tags      []string
	srcClient imageclientset.ImageV1Interface
	dstClient imageclientset.ImageV1Interface
	jobSpec   *JobSpec
}

func targetName(config api.PromotionConfiguration) string {
	if len(config.Name) > 0 {
		return fmt.Sprintf("%s/%s:${component}", config.Namespace, config.Name)
	}
	return fmt.Sprintf("%s/${component}:%s", config.Namespace, config.Tag)
}

func (s *promotionStep) Inputs(ctx context.Context, dry bool) (api.InputDefinition, error) {
	return nil, nil
}

func (s *promotionStep) Run(ctx context.Context, dry bool) error {
	tags := make(map[string]string)
	names := sets.NewString()
	for _, tag := range s.tags {
		tags[tag] = tag
		names.Insert(tag)
	}
	for dst, src := range s.config.AdditionalImages {
		tags[dst] = src
		names.Insert(dst)
	}

	log.Printf("Promoting tags to %s: %s", targetName(s.config), strings.Join(names.List(), ", "))

	pipeline, err := s.srcClient.ImageStreams(s.jobSpec.Namespace()).Get(PipelineImageStream, meta.GetOptions{})
	if err != nil {
		return fmt.Errorf("could not resolve pipeline imagestream: %v", err)
	}

	if len(s.config.Name) > 0 {
		is, err := s.dstClient.ImageStreams(s.config.Namespace).Get(s.config.Name, meta.GetOptions{})
		if errors.IsNotFound(err) {
			is, err = s.dstClient.ImageStreams(s.config.Namespace).Create(&imageapi.ImageStream{
				ObjectMeta: meta.ObjectMeta{
					Name:      s.config.Name,
					Namespace: s.config.Namespace,
				},
			})
		}
		if err != nil {
			return fmt.Errorf("could not retrieve target imagestream: %v", err)
		}

		for dst, src := range tags {
			if valid, _ := findStatusTag(pipeline, src); valid != nil {
				is.Spec.Tags = append(is.Spec.Tags, imageapi.TagReference{
					Name: dst,
					From: valid,
				})
			}
		}

		if dry {
			istJSON, err := json.MarshalIndent(is, "", "  ")
			if err != nil {
				return fmt.Errorf("failed to marshal image stream: %v", err)
			}
			fmt.Printf("%s\n", istJSON)
			return nil
		}
		is, err = s.dstClient.ImageStreams(s.config.Namespace).Update(is)
		if err != nil && !errors.IsAlreadyExists(err) {
			return fmt.Errorf("could not promote image streams: %v", err)
		}

		return nil
	}

	client := s.dstClient.ImageStreamTags(s.config.Namespace)
	for dst, src := range tags {
		valid, _ := findStatusTag(pipeline, src)
		if valid == nil {
			continue
		}
		ist := &imageapi.ImageStreamTag{
			ObjectMeta: meta.ObjectMeta{
				Name:      fmt.Sprintf("%s%s:%s", s.config.NamePrefix, dst, s.config.Tag),
				Namespace: s.config.Namespace,
			},
			Tag: &imageapi.TagReference{
				Name: s.config.Tag,
				From: valid,
			},
		}
		if dry {
			istJSON, err := json.MarshalIndent(ist, "", "  ")
			if err != nil {
				return fmt.Errorf("failed to marshal imagestreamtag: %v", err)
			}
			fmt.Printf("%s\n", istJSON)
			continue
		}
		_, err := client.Update(ist)
		if err != nil {
			return fmt.Errorf("could not promote imagestreamtag %s: %v", dst, err)
		}
	}

	return nil
}

func (s *promotionStep) Done() (bool, error) {
	// TODO: define done
	return true, nil
}

func (s *promotionStep) Requires() []api.StepLink {
	return []api.StepLink{api.AllStepsLink()}
}

func (s *promotionStep) Creates() []api.StepLink {
	return []api.StepLink{}
}

func (s *promotionStep) Provides() (api.ParameterMap, api.StepLink) {
	return nil, nil
}

func (s *promotionStep) Name() string { return "" }

func (s *promotionStep) Description() string {
	return fmt.Sprintf("Promote built images into the release image stream %s", targetName(s.config))
}

// PromotionStep copies tags from the pipeline image stream to the destination defined in the promotion config.
// If the source tag does not exist it is silently skipped.
func PromotionStep(config api.PromotionConfiguration, tags []string, srcClient, dstClient imageclientset.ImageV1Interface, jobSpec *JobSpec) api.Step {
	return &promotionStep{
		config:    config,
		tags:      tags,
		srcClient: srcClient,
		dstClient: dstClient,
		jobSpec:   jobSpec,
	}
}
