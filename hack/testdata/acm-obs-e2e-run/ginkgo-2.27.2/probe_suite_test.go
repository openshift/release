package probe

import (
	"os"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
)

func TestProbe(t *testing.T) {
	RunSpecs(t, "ACM Observability Classifier Fixture Suite")
}

var _ = func() bool {
	switch os.Getenv("PROBE_SCENARIO") {
	case "pass":
		It("passes", func() {})
	case "body-assertion":
		It("fails in the body", func() { Fail("fixture body assertion") })
	case "before-each":
		Describe("before each fixture", func() {
			BeforeEach(func() { Fail("fixture before each failure") })
			It("never reaches the body", func() {})
		})
	case "after-each":
		Describe("after each fixture", func() {
			AfterEach(func() { Fail("fixture after each failure") })
			It("has a primary body failure", func() { Fail("fixture body assertion") })
		})
	case "defer-cleanup":
		It("has a deferred cleanup failure", func() {
			DeferCleanup(func() { Fail("fixture deferred cleanup failure") })
			Fail("fixture body assertion")
		})
	case "timeout-nested":
		It("times out and then fails", NodeTimeout(50*time.Millisecond), func(_ SpecContext) {
			time.Sleep(150 * time.Millisecond)
			Fail("fixture failure after timeout")
		})
	case "panic":
		It("panics", func() { panic("fixture panic") })
	case "skipped-pending":
		PIt("is pending", func() {})
		It("is skipped", func() { Skip("fixture skip") })
	default:
		panic("unknown PROBE_SCENARIO")
	}
	return true
}()
