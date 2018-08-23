package steps

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"k8s.io/client-go/rest"

	templateapi "github.com/openshift/api/template/v1"
	templateclientset "github.com/openshift/client-go/template/clientset/versioned/typed/template/v1"
	coreapi "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/watch"
	coreclientset "k8s.io/client-go/kubernetes/typed/core/v1"

	"github.com/openshift/ci-operator/pkg/api"
)

type templateExecutionStep struct {
	template       *templateapi.Template
	params         *DeferredParameters
	templateClient TemplateClient
	podClient      PodClient
	artifactDir    string
	jobSpec        *JobSpec
}

func (s *templateExecutionStep) Inputs(ctx context.Context, dry bool) (api.InputDefinition, error) {
	return nil, nil
}

func (s *templateExecutionStep) Run(ctx context.Context, dry bool) error {
	log.Printf("Executing template %s", s.template.Name)

	if len(s.template.Objects) == 0 {
		return fmt.Errorf("template %s has no objects", s.template.Name)
	}

	for i, p := range s.template.Parameters {
		if len(p.Value) == 0 {
			if !s.params.Has(p.Name) && !strings.HasPrefix(p.Name, "IMAGE_") && p.Required {
				return fmt.Errorf("template %s has required parameter %s which is not defined", s.template.Name, p.Name)
			}
		}
		if s.params.Has(p.Name) {
			value, err := s.params.Get(p.Name)
			if err != nil {
				if !dry {
					return fmt.Errorf("cannot resolve parameter %s into template %s: %v", p.Name, s.template.Name, err)
				}
			}
			if len(value) > 0 {
				s.template.Parameters[i].Value = value
			}
			continue
		}
		if strings.HasPrefix(p.Name, "IMAGE_") {
			component := strings.ToLower(strings.TrimPrefix(p.Name, "IMAGE_"))
			if len(component) > 0 {
				component = strings.Replace(component, "_", "-", -1)
				format, err := s.params.Get("IMAGE_FORMAT")
				if err != nil {
					return fmt.Errorf("could not resolve image format: %v", err)
				}
				s.template.Parameters[i].Value = strings.Replace(format, componentFormatReplacement, component, -1)
			}
		}
	}

	addArtifactsToTemplate(s.template)

	if dry {
		j, _ := json.MarshalIndent(s.template, "", "  ")
		log.Printf("template:\n%s", j)
		return nil
	}

	// TODO: enforce single namespace behavior
	instance := &templateapi.TemplateInstance{
		ObjectMeta: meta.ObjectMeta{
			Name: s.template.Name,
		},
		Spec: templateapi.TemplateInstanceSpec{
			Template: *s.template,
		},
	}
	if owner := s.jobSpec.Owner(); owner != nil {
		instance.OwnerReferences = append(instance.OwnerReferences, *owner)
	}

	var notifier ContainerNotifier = NopNotifier

	go func() {
		<-ctx.Done()
		notifier.Cancel()
		log.Printf("cleanup: Deleting template %s", s.template.Name)
		policy := meta.DeletePropagationForeground
		opt := &meta.DeleteOptions{
			PropagationPolicy: &policy,
		}
		if err := s.templateClient.TemplateInstances(s.jobSpec.Namespace()).Delete(s.template.Name, opt); err != nil && !errors.IsNotFound(err) {
			log.Printf("error: Could not delete template instance: %v", err)
		}
	}()

	log.Printf("Creating or restarting template instance")
	instance, err := createOrRestartTemplateInstance(s.templateClient.TemplateInstances(s.jobSpec.Namespace()), s.podClient.Pods(s.jobSpec.Namespace()), instance)
	if err != nil {
		return fmt.Errorf("could not create or restart template instance: %v", err)
	}

	log.Printf("Waiting for template instance to be ready")
	instance, err = waitForTemplateInstanceReady(s.templateClient.TemplateInstances(s.jobSpec.Namespace()), instance)
	if err != nil {
		return fmt.Errorf("could not wait for template instance to be ready: %v", err)
	}

	// now that the pods have been resolved by the template, add them to the artifact map
	if len(s.artifactDir) > 0 {
		artifacts := NewArtifactWorker(s.podClient, filepath.Join(s.artifactDir, s.template.Name), s.jobSpec.Namespace())
		for _, ref := range instance.Status.Objects {
			switch {
			case ref.Ref.Kind == "Pod" && ref.Ref.APIVersion == "v1":
				pod, err := s.podClient.Pods(s.jobSpec.Namespace()).Get(ref.Ref.Name, meta.GetOptions{})
				if err != nil {
					return fmt.Errorf("unable to retrieve pod from template - possibly deleted: %v", err)
				}
				addArtifactContainersFromPod(pod, artifacts)
			}
		}
		notifier = artifacts
	}

	for _, ref := range instance.Status.Objects {
		switch {
		case ref.Ref.Kind == "Pod" && ref.Ref.APIVersion == "v1":
			log.Printf("Running pod %s", ref.Ref.Name)
		}
	}
	for _, ref := range instance.Status.Objects {
		switch {
		case ref.Ref.Kind == "Pod" && ref.Ref.APIVersion == "v1":
			if err := waitForPodCompletion(s.podClient.Pods(s.jobSpec.Namespace()), ref.Ref.Name, notifier); err != nil {
				return fmt.Errorf("could not wait for pod to complete: %v", err)
			}
		}
	}
	return nil
}

func (s *templateExecutionStep) Done() (bool, error) {
	instance, err := s.templateClient.TemplateInstances(s.jobSpec.Namespace()).Get(s.template.Name, meta.GetOptions{})
	if errors.IsNotFound(err) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("unable to retrieve existing template: %v", err)
	}
	ready, err := templateInstanceReady(instance)
	if err != nil {
		return false, fmt.Errorf("could not determine if template instance was ready: %v", err)
	}
	if !ready {
		return false, nil
	}
	for _, ref := range instance.Status.Objects {
		switch {
		case ref.Ref.Kind == "Pod" && ref.Ref.APIVersion == "v1":
			ready, err := isPodCompleted(s.podClient.Pods(s.jobSpec.Namespace()), ref.Ref.Name)
			if err != nil {
				return false, fmt.Errorf("could not determine if pod completed: %v", err)
			}
			if !ready {
				return false, nil
			}
		}
	}
	return true, nil
}

func (s *templateExecutionStep) Requires() []api.StepLink {
	var links []api.StepLink
	for _, p := range s.template.Parameters {
		if s.params.Has(p.Name) {
			links = append(links, s.params.Links(p.Name)...)
			continue
		}
		if strings.HasPrefix(p.Name, "IMAGE_") {
			links = append(links, api.ReleaseImagesLink())
			continue
		}
	}
	return links
}

func (s *templateExecutionStep) Creates() []api.StepLink {
	return []api.StepLink{}
}

func (s *templateExecutionStep) Provides() (api.ParameterMap, api.StepLink) {
	return nil, nil
}

func (s *templateExecutionStep) Name() string { return s.template.Name }

func (s *templateExecutionStep) Description() string {
	return fmt.Sprintf("Instantiate the template %s into the operator namespace and wait for any pods to complete", s.template.Name)
}

func TemplateExecutionStep(template *templateapi.Template, params *DeferredParameters, podClient PodClient, templateClient TemplateClient, artifactDir string, jobSpec *JobSpec) api.Step {
	return &templateExecutionStep{
		template:       template,
		params:         params,
		podClient:      podClient,
		templateClient: templateClient,
		artifactDir:    artifactDir,
		jobSpec:        jobSpec,
	}
}

type DeferredParameters struct {
	lock   sync.Mutex
	fns    api.ParameterMap
	values map[string]string
	links  map[string][]api.StepLink
}

func NewDeferredParameters() *DeferredParameters {
	return &DeferredParameters{
		fns:    make(api.ParameterMap),
		values: make(map[string]string),
		links:  make(map[string][]api.StepLink),
	}
}

func (p *DeferredParameters) Map() (map[string]string, error) {
	p.lock.Lock()
	defer p.lock.Unlock()
	m := make(map[string]string)
	for k, fn := range p.fns {
		if v, ok := p.values[k]; ok {
			m[k] = v
			continue
		}
		v, err := fn()
		if err != nil {
			return nil, fmt.Errorf("could not lazily evaluate deferred parameter: %v", err)
		}
		p.values[k] = v
		m[k] = v
	}
	return m, nil
}

func (p *DeferredParameters) Set(name, value string) {
	p.lock.Lock()
	defer p.lock.Unlock()
	if _, ok := p.fns[name]; ok {
		return
	}
	if _, ok := p.values[name]; ok {
		return
	}
	p.values[name] = value
}

func (p *DeferredParameters) Add(name string, link api.StepLink, fn func() (string, error)) {
	p.lock.Lock()
	defer p.lock.Unlock()
	p.fns[name] = fn
	if link != nil {
		p.links[name] = []api.StepLink{link}
	}
}

func (p *DeferredParameters) Has(name string) bool {
	p.lock.Lock()
	defer p.lock.Unlock()
	_, ok := p.fns[name]
	if ok {
		return true
	}
	_, ok = os.LookupEnv(name)
	return ok
}

func (p *DeferredParameters) Links(name string) []api.StepLink {
	p.lock.Lock()
	defer p.lock.Unlock()
	if _, ok := os.LookupEnv(name); ok {
		return nil
	}
	return p.links[name]
}

func (p *DeferredParameters) AllLinks() []api.StepLink {
	p.lock.Lock()
	defer p.lock.Unlock()
	var links []api.StepLink
	for name, v := range p.links {
		if _, ok := os.LookupEnv(name); ok {
			continue
		}
		links = append(links, v...)
	}
	return links
}

func (p *DeferredParameters) Get(name string) (string, error) {
	p.lock.Lock()
	defer p.lock.Unlock()
	if value, ok := p.values[name]; ok {
		return value, nil
	}
	if value, ok := os.LookupEnv(name); ok {
		p.values[name] = value
		return value, nil
	}
	if fn, ok := p.fns[name]; ok {
		value, err := fn()
		if err != nil {
			return "", fmt.Errorf("could not lazily evaluate deferred parameter: %v", err)
		}
		p.values[name] = value
		return value, nil
	}
	return "", nil
}

type TemplateClient interface {
	templateclientset.TemplateV1Interface
	Process(namespace string, template *templateapi.Template) (*templateapi.Template, error)
}

type templateClient struct {
	templateclientset.TemplateV1Interface
	restClient rest.Interface
}

func NewTemplateClient(client templateclientset.TemplateV1Interface, restClient rest.Interface) TemplateClient {
	return &templateClient{
		TemplateV1Interface: client,
		restClient:          restClient,
	}
}

func (c *templateClient) Process(namespace string, template *templateapi.Template) (*templateapi.Template, error) {
	processed := &templateapi.Template{}
	err := c.restClient.Post().
		Namespace(namespace).
		Resource("processedtemplates").
		Body(template).
		Do().
		Into(processed)
	return processed, fmt.Errorf("could not process template: %v", err)
}

func isPodCompleted(podClient coreclientset.PodInterface, name string) (bool, error) {
	pod, err := podClient.Get(name, meta.GetOptions{})
	if errors.IsNotFound(err) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("could not retrieve pod: %v", err)
	}
	if pod.Status.Phase == coreapi.PodSucceeded || pod.Status.Phase == coreapi.PodFailed {
		return true, nil
	}
	for _, status := range append(append([]coreapi.ContainerStatus{}, pod.Status.InitContainerStatuses...), pod.Status.ContainerStatuses...) {
		// don't fail until everything has started at least once
		if status.State.Waiting != nil && status.LastTerminationState.Terminated == nil {
			return false, nil
		}
		// artifacts doesn't count as requiring completion
		if status.Name == "artifacts" {
			continue
		}
		if s := status.State.Terminated; s != nil {
			if s.ExitCode != 0 {
				return true, nil
			}
		}
	}
	return false, nil
}

func waitForTemplateInstanceReady(templateClient templateclientset.TemplateInstanceInterface, instance *templateapi.TemplateInstance) (*templateapi.TemplateInstance, error) {
	for {
		ready, err := templateInstanceReady(instance)
		if err != nil {
			return nil, fmt.Errorf("could not determine if template instance was ready: %v", err)
		}
		if ready {
			return instance, nil
		}

		time.Sleep(2 * time.Second)
		instance, err = templateClient.Get(instance.Name, meta.GetOptions{})
		if err != nil {
			return nil, fmt.Errorf("unable to retrieve existing template instance: %v", err)
		}
	}
}

func createOrRestartTemplateInstance(templateClient templateclientset.TemplateInstanceInterface, podClient coreclientset.PodInterface, instance *templateapi.TemplateInstance) (*templateapi.TemplateInstance, error) {
	if err := waitForCompletedTemplateInstanceDeletion(templateClient, podClient, instance.Name); err != nil {
		return nil, fmt.Errorf("unable to delete completed template instance: %v", err)
	}
	created, err := templateClient.Create(instance)
	if err != nil && !errors.IsAlreadyExists(err) {
		return nil, fmt.Errorf("unable to create template instance: %v", err)
	}
	if err != nil {
		created, err = templateClient.Get(instance.Name, meta.GetOptions{})
		if err != nil {
			return nil, fmt.Errorf("unable to retrieve pod: %v", err)
		}
		log.Printf("Waiting for running template %s to finish", instance.Name)
	}
	return created, nil
}

func waitForCompletedTemplateInstanceDeletion(templateClient templateclientset.TemplateInstanceInterface, podClient coreclientset.PodInterface, name string) error {
	instance, err := templateClient.Get(name, meta.GetOptions{})
	if errors.IsNotFound(err) {
		return nil
	}

	// delete the instance we had before, otherwise another user has relaunched this template
	uid := instance.UID
	policy := meta.DeletePropagationForeground
	err = templateClient.Delete(name, &meta.DeleteOptions{
		PropagationPolicy: &policy,
		Preconditions:     &meta.Preconditions{UID: &uid},
	})
	if errors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("could not delete completed template instance: %v", err)
	}

	for i := 0; ; i++ {
		instance, err := templateClient.Get(name, meta.GetOptions{})
		if errors.IsNotFound(err) {
			break
		}
		if err != nil {
			return fmt.Errorf("could not retrieve deleting template instance: %v", err)
		}
		if instance.UID != uid {
			return nil
		}
		if i == 1800 {
			data, _ := json.MarshalIndent(instance.Status, "", "  ")
			log.Printf("Template instance %s has not completed deletion after 30 minutes, possible error in controller:\n%s", name, string(data))
		}

		log.Printf("Waiting for template instance %s to be deleted ...", name)
		time.Sleep(2 * time.Second)
	}

	// TODO: we have to wait for all pods because graceful deletion foreground isn't working on template instance
	for _, ref := range instance.Status.Objects {
		switch {
		case ref.Ref.Kind == "Pod" && ref.Ref.APIVersion == "v1":
			waitForPodCompletion(podClient, ref.Ref.Name, nil)
		}
	}
	return nil
}

func createOrRestartPod(podClient coreclientset.PodInterface, pod *coreapi.Pod) (*coreapi.Pod, error) {
	if err := waitForCompletedPodDeletion(podClient, pod.Name); err != nil {
		return nil, fmt.Errorf("unable to delete completed pod: %v", err)
	}
	created, err := podClient.Create(pod)
	if err != nil && !errors.IsAlreadyExists(err) {
		return nil, fmt.Errorf("unable to create pod: %v", err)
	}
	if err != nil {
		created, err = podClient.Get(pod.Name, meta.GetOptions{})
		if err != nil {
			return nil, fmt.Errorf("unable to retrieve pod: %v", err)
		}
		log.Printf("Waiting for running pod %s to finish", pod.Name)
	}
	return created, nil
}

func waitForCompletedPodDeletion(podClient coreclientset.PodInterface, name string) error {
	pod, err := podClient.Get(name, meta.GetOptions{})
	if errors.IsNotFound(err) {
		return nil
	}
	// running pods are left to run, we just wait for them to finish
	if pod.Status.Phase != coreapi.PodSucceeded && pod.Status.Phase != coreapi.PodFailed && pod.DeletionTimestamp == nil {
		return nil
	}

	// delete the pod we expect, otherwise another user has relaunched this pod
	uid := pod.UID
	err = podClient.Delete(name, &meta.DeleteOptions{Preconditions: &meta.Preconditions{UID: &uid}})
	if errors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("could not delete completed pod: %v", err)
	}

	for {
		pod, err := podClient.Get(name, meta.GetOptions{})
		if errors.IsNotFound(err) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("could not retrieve deleting pod: %v", err)
		}
		if pod.UID != uid {
			return nil
		}
		log.Printf("Waiting for pod %s to be deleted ...", name)
		time.Sleep(2 * time.Second)
	}
}

func waitForPodCompletion(podClient coreclientset.PodInterface, name string, notifier ContainerNotifier) error {
	if notifier == nil {
		notifier = NopNotifier
	}
	completed := make(map[string]time.Time)
	for {
		retry, err := waitForPodCompletionOrTimeout(podClient, name, completed, notifier)
		// continue waiting if the container notifier is not yet complete for the given pod
		if !notifier.Done(name) {
			if !retry || err == nil {
				time.Sleep(5 * time.Second)
			}
			continue
		}
		if err != nil {
			return fmt.Errorf("could not wait for pod completion: %v", err)
		}
		if !retry {
			break
		}
	}
	return nil
}

func waitForPodCompletionOrTimeout(podClient coreclientset.PodInterface, name string, completed map[string]time.Time, notifier ContainerNotifier) (bool, error) {
	list, err := podClient.List(meta.ListOptions{FieldSelector: fields.Set{"metadata.name": name}.AsSelector().String()})
	if err != nil {
		return false, fmt.Errorf("could not list pod: %v", err)
	}
	if len(list.Items) != 1 {
		notifier.Complete(name)
		return false, fmt.Errorf("pod %s was already deleted", name)
	}
	pod := &list.Items[0]
	if pod.Spec.RestartPolicy == coreapi.RestartPolicyAlways {
		return false, nil
	}
	podLogNewFailedContainers(podClient, pod, completed, notifier)
	if podJobIsOK(pod) {
		log.Printf("Pod %s already succeeded in %s", pod.Name, podDuration(pod).Truncate(time.Second))
		return false, nil
	}
	if podJobIsFailed(pod) {
		return false, errorWithOutput{
			err:    fmt.Errorf("the pod %s/%s failed after %s (failed containers: %s): %s", pod.Namespace, pod.Name, podDuration(pod).Truncate(time.Second), strings.Join(failedContainerNames(pod), ", "), podReason(pod)),
			output: podMessages(pod),
		}
	}

	watcher, err := podClient.Watch(meta.ListOptions{
		FieldSelector: fields.Set{"metadata.name": name}.AsSelector().String(),
		Watch:         true,
	})
	if err != nil {
		return false, fmt.Errorf("could not create watcher for pod: %v", err)
	}
	defer watcher.Stop()

	for {
		event, ok := <-watcher.ResultChan()
		if !ok {
			// restart
			return true, nil
		}
		if pod, ok := event.Object.(*coreapi.Pod); ok {
			podLogNewFailedContainers(podClient, pod, completed, notifier)
			if podJobIsOK(pod) {
				log.Printf("Pod %s succeeded after %s", pod.Name, podDuration(pod).Truncate(time.Second))
				return false, nil
			}
			if podJobIsFailed(pod) {
				return false, errorWithOutput{
					err:    fmt.Errorf("the pod %s/%s failed after %s (failed containers: %s): %s", pod.Namespace, pod.Name, podDuration(pod).Truncate(time.Second), strings.Join(failedContainerNames(pod), ", "), podReason(pod)),
					output: podMessages(pod),
				}
			}
			continue
		}
		if event.Type == watch.Deleted {
			podLogNewFailedContainers(podClient, pod, completed, notifier)
			return false, errorWithOutput{
				err:    fmt.Errorf("the pod %s/%s was deleted without completing after %s (failed containers: %s)", pod.Namespace, pod.Name, podDuration(pod).Truncate(time.Second), strings.Join(failedContainerNames(pod), ", ")),
				output: podMessages(pod),
			}
		}
		log.Printf("error: Unrecognized event in watch: %v %#v", event.Type, event.Object)
	}
}

// podReason returns the pod's reason and message for exit or tries to find one from the pod.
func podReason(pod *coreapi.Pod) string {
	reason := pod.Status.Reason
	message := pod.Status.Message
	if len(message) == 0 {
		message = "unknown"
	}
	if len(reason) == 0 {
		for _, status := range append(append([]coreapi.ContainerStatus{}, pod.Status.InitContainerStatuses...), pod.Status.ContainerStatuses...) {
			state := status.State.Terminated
			if state == nil || state.ExitCode == 0 {
				continue
			}
			if len(reason) == 0 {
				continue
			}
			reason = state.Reason
			if len(message) == 0 {
				message = fmt.Sprintf("container failure with exit code %d", state.ExitCode)
			}
			break
		}
	}
	return fmt.Sprintf("%s %s", reason, message)
}

// podMessages returns a string containing the messages and reasons for all terminated containers with a non-zero exit code.
func podMessages(pod *coreapi.Pod) string {
	var messages []string
	for _, status := range append(append([]coreapi.ContainerStatus{}, pod.Status.InitContainerStatuses...), pod.Status.ContainerStatuses...) {
		if state := status.State.Terminated; state != nil && state.ExitCode != 0 {
			messages = append(messages, fmt.Sprintf("Container %s exited with code %d, reason %s", status.Name, state.ExitCode, state.Reason))
			if msg := state.Message; len(msg) > 0 {
				messages = append(messages, "---", msg, "---")
			}
		}
	}
	return strings.Join(messages, "\n")
}

func podDuration(pod *coreapi.Pod) time.Duration {
	start := pod.Status.StartTime
	if start == nil {
		start = &pod.CreationTimestamp
	}
	var end meta.Time
	for _, status := range pod.Status.ContainerStatuses {
		if s := status.State.Terminated; s != nil {
			if end.IsZero() || s.FinishedAt.Time.After(end.Time) {
				end = s.FinishedAt
			}
		}
	}
	if end.IsZero() {
		for _, status := range pod.Status.InitContainerStatuses {
			if s := status.State.Terminated; s != nil && s.ExitCode != 0 {
				if end.IsZero() || s.FinishedAt.Time.After(end.Time) {
					end = s.FinishedAt
					break
				}
			}
		}
	}
	if end.IsZero() {
		end = meta.Now()
	}
	duration := end.Sub(start.Time)
	return duration
}

func templateInstanceReady(instance *templateapi.TemplateInstance) (ready bool, err error) {
	for _, c := range instance.Status.Conditions {
		switch {
		case c.Type == templateapi.TemplateInstanceReady && c.Status == coreapi.ConditionTrue:
			return true, nil
		case c.Type == templateapi.TemplateInstanceInstantiateFailure && c.Status == coreapi.ConditionTrue:
			return true, fmt.Errorf("failed to create objects: %s", c.Message)
		}
	}
	return false, nil
}

func podRunningContainers(pod *coreapi.Pod) []string {
	var names []string
	for _, status := range append(append([]coreapi.ContainerStatus{}, pod.Status.InitContainerStatuses...), pod.Status.ContainerStatuses...) {
		if status.State.Running != nil || status.State.Waiting != nil || status.State.Terminated == nil {
			continue
		}
		names = append(names, status.Name)
	}
	return names
}

func podJobIsOK(pod *coreapi.Pod) bool {
	if pod.Status.Phase == coreapi.PodSucceeded {
		return true
	}
	if pod.Status.Phase == coreapi.PodPending || pod.Status.Phase == coreapi.PodUnknown {
		return false
	}
	// if all containers except artifacts are in terminated and have exit code 0, we're ok
	hasArtifacts := false
	for _, status := range append(append([]coreapi.ContainerStatus{}, pod.Status.InitContainerStatuses...), pod.Status.ContainerStatuses...) {
		// don't succeed until everything has started at least once
		if status.State.Waiting != nil && status.LastTerminationState.Terminated == nil {
			return false
		}
		if status.Name == "artifacts" {
			hasArtifacts = true
			continue
		}
		s := status.State.Terminated
		if s == nil {
			return false
		}
		if s.ExitCode != 0 {
			return false
		}
	}
	if pod.Status.Phase == coreapi.PodFailed && !hasArtifacts {
		return false
	}
	return true
}

func podJobIsFailed(pod *coreapi.Pod) bool {
	if pod.Status.Phase == coreapi.PodFailed {
		return true
	}
	if pod.Status.Phase == coreapi.PodPending || pod.Status.Phase == coreapi.PodUnknown {
		return false
	}
	// if any container is in a non-zero status we have failed
	for _, status := range append(append([]coreapi.ContainerStatus{}, pod.Status.InitContainerStatuses...), pod.Status.ContainerStatuses...) {
		// don't fail until everything has started at least once
		if status.State.Waiting != nil && status.LastTerminationState.Terminated == nil {
			return false
		}
		if status.Name == "artifacts" {
			continue
		}
		if s := status.State.Terminated; s != nil {
			if s.ExitCode != 0 {
				return true
			}
		}
	}
	return false
}

func failedContainerNames(pod *coreapi.Pod) []string {
	var names []string
	for _, status := range append(append([]coreapi.ContainerStatus{}, pod.Status.InitContainerStatuses...), pod.Status.ContainerStatuses...) {
		if s := status.State.Terminated; s != nil {
			if s.ExitCode != 0 {
				names = append(names, status.Name)
			}
		}
	}
	sort.Strings(names)
	return names
}

func podLogNewFailedContainers(podClient coreclientset.PodInterface, pod *coreapi.Pod, completed map[string]time.Time, notifier ContainerNotifier) {
	var statuses []coreapi.ContainerStatus
	statuses = append(statuses, pod.Status.InitContainerStatuses...)
	statuses = append(statuses, pod.Status.ContainerStatuses...)

	for _, status := range statuses {
		if _, ok := completed[status.Name]; ok {
			continue
		}
		s := status.State.Terminated
		if s == nil {
			continue
		}
		completed[status.Name] = s.FinishedAt.Time
		notifier.Notify(pod, status.Name)

		if s.ExitCode == 0 {
			log.Printf("Container %s in pod %s completed successfully", status.Name, pod.Name)
			continue
		}

		if s, err := podClient.GetLogs(pod.Name, &coreapi.PodLogOptions{
			Container: status.Name,
		}).Stream(); err == nil {
			if _, err := io.Copy(os.Stdout, s); err != nil {
				log.Printf("error: Unable to copy log output from failed pod container %s: %v", status.Name, err)
			}
			s.Close()
		} else {
			log.Printf("error: Unable to retrieve logs from failed pod container %s: %v", status.Name, err)
		}

		log.Printf("Container %s in pod %s failed, exit code %d, reason %s", status.Name, pod.Name, status.State.Terminated.ExitCode, status.State.Terminated.Reason)
	}
	// if there are no running containers and we're in a terminal state, mark the pod complete
	if (pod.Status.Phase == coreapi.PodFailed || pod.Status.Phase == coreapi.PodSucceeded) && len(podRunningContainers(pod)) == 0 {
		notifier.Complete(pod.Name)
	}
}
