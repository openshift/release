package api

import (
	"context"
	"fmt"
	"strings"
)

// Step is a self-contained bit of work that the
// build pipeline needs to do.
type Step interface {
	Inputs(ctx context.Context, dry bool) (InputDefinition, error)
	Run(ctx context.Context, dry bool) error
	Done() (bool, error)

	// Name is the name of the stage, used to target it.
	// If this is the empty string the stage cannot be targeted.
	Name() string
	// Description is a short, human readable description of this step.
	Description() string
	Requires() []StepLink
	Creates() []StepLink
	Provides() (ParameterMap, StepLink)
}

type InputDefinition []string

type ParameterMap map[string]func() (string, error)

// StepLink abstracts the types of links that steps
// require and create.
type StepLink interface {
	Matches(other StepLink) bool
	Same(other StepLink) bool
}

func AllStepsLink() StepLink {
	return allStepsLink{}
}

type allStepsLink struct{}

func (_ allStepsLink) Same(other StepLink) bool {
	_, ok := other.(allStepsLink)
	if !ok {
		return false
	}
	return true
}

func (_ allStepsLink) Matches(other StepLink) bool {
	return true
}

func ExternalImageLink(ref ImageStreamTagReference) StepLink {
	return &externalImageLink{image: ref}
}

type externalImageLink struct {
	image ImageStreamTagReference
}

func (l *externalImageLink) Same(other StepLink) bool {
	o, ok := other.(*externalImageLink)
	if !ok {
		return false
	}
	return o.image == l.image
}

func (l *externalImageLink) Matches(other StepLink) bool {
	switch link := other.(type) {
	case *externalImageLink:
		return l.image.Name == link.image.Name &&
			l.image.Namespace == link.image.Namespace &&
			l.image.Tag == link.image.Tag
	default:
		return false
	}
}

func InternalImageLink(ref PipelineImageStreamTagReference) StepLink {
	return &internalImageLink{image: ref}
}

type internalImageLink struct {
	image PipelineImageStreamTagReference
}

func (l *internalImageLink) Same(other StepLink) bool {
	o, ok := other.(*internalImageLink)
	if !ok {
		return false
	}
	return o.image == l.image
}

func (l *internalImageLink) Matches(other StepLink) bool {
	switch link := other.(type) {
	case *internalImageLink:
		return l.image == link.image
	default:
		return false
	}
}

func ImagesReadyLink() StepLink {
	return &imagesReadyLink{}
}

type imagesReadyLink struct{}

func (l *imagesReadyLink) Same(other StepLink) bool {
	_, ok := other.(*imagesReadyLink)
	if !ok {
		return false
	}
	return true
}

func (l *imagesReadyLink) Matches(other StepLink) bool {
	switch other.(type) {
	case *imagesReadyLink:
		return true
	default:
		return false
	}
}

func RPMRepoLink() StepLink {
	return &rpmRepoLink{}
}

type rpmRepoLink struct{}

func (l *rpmRepoLink) Same(other StepLink) bool {
	_, ok := other.(*rpmRepoLink)
	if !ok {
		return false
	}
	return true
}

func (l *rpmRepoLink) Matches(other StepLink) bool {
	switch other.(type) {
	case *rpmRepoLink:
		return true
	default:
		return false
	}
}

func ReleaseImagesLink() StepLink {
	return &releaseImagesLink{}
}

type releaseImagesLink struct{}

func (l *releaseImagesLink) Same(other StepLink) bool {
	_, ok := other.(*releaseImagesLink)
	if !ok {
		return false
	}
	return true
}

func (l *releaseImagesLink) Matches(other StepLink) bool {
	switch other.(type) {
	case *releaseImagesLink:
		return true
	default:
		return false
	}
}

type StepNode struct {
	Step     Step
	Children []*StepNode
}

// BuildGraph returns a graph or graphs that include
// all steps given.
func BuildGraph(steps []Step) []*StepNode {
	var allNodes []*StepNode
	for _, step := range steps {
		node := StepNode{Step: step, Children: []*StepNode{}}
		allNodes = append(allNodes, &node)
	}

	var roots []*StepNode
	for _, node := range allNodes {
		isRoot := true
		for _, other := range allNodes {
			for _, nodeRequires := range node.Step.Requires() {
				for _, otherCreates := range other.Step.Creates() {
					if nodeRequires.Matches(otherCreates) {
						isRoot = false
						addToNode(other, node)
					}
				}
			}
		}
		if isRoot {
			roots = append(roots, node)
		}
	}

	return roots
}

// BuildPartialGraph returns a graph or graphs that include
// only the dependencies of the named steps.
func BuildPartialGraph(steps []Step, names []string) ([]*StepNode, error) {
	if len(names) == 0 {
		return BuildGraph(steps), nil
	}

	var required []StepLink
	candidates := make([]bool, len(steps))
	for i, step := range steps {
		for j, name := range names {
			if name != step.Name() {
				continue
			}
			candidates[i] = true
			required = append(required, step.Requires()...)
			names = append(names[:j], names[j+1:]...)
			break
		}
	}
	if len(names) > 0 {
		return nil, fmt.Errorf("the following names were not found in the config or were duplicates: %s", strings.Join(names, ", "))
	}

	// identify all other steps that provide any links required by the current set
	for {
		added := 0
		for i, step := range steps {
			if candidates[i] {
				continue
			}
			if HasAnyLinks(required, step.Creates()) {
				added++
				candidates[i] = true
				required = append(required, step.Requires()...)
			}
		}
		if added == 0 {
			break
		}
	}

	var targeted []Step
	for i, candidate := range candidates {
		if candidate {
			targeted = append(targeted, steps[i])
		}
	}
	return BuildGraph(targeted), nil
}

func addToNode(parent, child *StepNode) bool {
	for _, s := range parent.Children {
		if s == child {
			return false
		}
	}
	parent.Children = append(parent.Children, child)
	return true
}

func Reduce(steps []StepLink) []StepLink {
	top := 0
	for i := 1; i < len(steps); i++ {
		if Same(steps[:top], steps[i]) {
			continue
		}
		steps[top] = steps[i]
		top++
	}
	return steps[:top]
}

func Same(steps []StepLink, step StepLink) bool {
	for _, other := range steps {
		if step.Same(other) {
			return true
		}
	}
	return false
}

func HasAnyLinks(steps, candidates []StepLink) bool {
	for _, candidate := range candidates {
		for _, step := range steps {
			if step.Matches(candidate) {
				return true
			}
		}
	}
	return false
}

func HasAllLinks(needles, haystack []StepLink) bool {
	for _, needle := range needles {
		contains := false
		for _, hay := range haystack {
			if hay.Matches(needle) {
				contains = true
			}
		}
		if !contains {
			return false
		}
	}
	return true
}
