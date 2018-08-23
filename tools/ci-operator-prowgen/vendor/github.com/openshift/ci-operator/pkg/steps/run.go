package steps

import (
	"bytes"
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/openshift/ci-operator/pkg/api"
	"github.com/openshift/ci-operator/pkg/junit"
)

type message struct {
	node     *api.StepNode
	duration time.Duration
	err      error
}

func Run(ctx context.Context, graph []*api.StepNode, dry bool) (*junit.TestSuites, error) {
	var seen []api.StepLink
	results := make(chan message)
	done := make(chan bool)
	ctxDone := ctx.Done()
	wg := &sync.WaitGroup{}
	wg.Add(len(graph))
	go func() {
		wg.Wait()
		done <- true
	}()

	start := time.Now()
	for _, root := range graph {
		go runStep(ctx, root, results, dry)
	}

	suites := &junit.TestSuites{
		Suites: []*junit.TestSuite{
			{},
		},
	}
	suite := suites.Suites[0]
	var errors []error
	for {
		select {
		case <-ctxDone:
			suite.Duration = time.Now().Sub(start).Seconds()
			return suites, aggregateError(errors)
		case out := <-results:
			testCase := &junit.TestCase{Name: out.node.Step.Description(), Duration: out.duration.Seconds()}
			suite.TestCases = append(suite.TestCases, testCase)
			suite.NumTests++
			if out.err != nil {
				testCase.FailureOutput = &junit.FailureOutput{Output: out.err.Error()}
				if o, ok := out.err.(withOutput); ok {
					if out := o.ErrorOutput(); len(out) > 0 {
						testCase.FailureOutput.Output += "\n\n" + o.ErrorOutput()
					}
				}
				suite.NumFailed++
				errors = append(errors, out.err)
			} else {
				if dry {
					testCase.SkipMessage = &junit.SkipMessage{Message: "Dry run"}
					suite.NumSkipped++
				}
				seen = append(seen, out.node.Step.Creates()...)
				for _, child := range out.node.Children {
					// we can trigger a child if all of it's pre-requisites
					// have been completed and if it has not yet been triggered.
					// We can ignore the child if it does not have prerequisites
					// finished as we know that we will process it here again
					// when the last of its parents finishes.
					if api.HasAllLinks(child.Step.Requires(), seen) {
						wg.Add(1)
						go runStep(ctx, child, results, dry)
					}
				}
			}
			wg.Done()
		case <-done:
			close(results)
			close(done)
			suite.Duration = time.Now().Sub(start).Seconds()
			return suites, aggregateError(errors)
		}
	}
}

type withOutput interface {
	ErrorOutput() string
}

func aggregateError(errors []error) error {
	var aggregateErr error
	if len(errors) == 0 {
		return nil
	}
	if len(errors) == 1 {
		return errors[0]
	}
	if len(errors) > 1 {
		message := bytes.Buffer{}
		for _, err := range errors {
			message.WriteString(fmt.Sprintf("\n  * %s", err.Error()))
		}
		aggregateErr = fmt.Errorf("some steps failed:%s", message.String())
	}
	return aggregateErr
}

func runStep(ctx context.Context, node *api.StepNode, out chan<- message, dry bool) {
	start := time.Now()
	err := node.Step.Run(ctx, dry)
	duration := time.Now().Sub(start)
	out <- message{
		node:     node,
		duration: duration,
		err:      err,
	}
}
