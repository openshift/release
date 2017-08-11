package config

import "testing"

func TestPeriodic_GcsPath(t *testing.T) {
	periodic := Periodic{
		Job: Job{
			JobName:     "name",
			BuildNumber: 1,
		},
	}

	if expected, actual := "logs/name/1/", periodic.GcsPath(); expected != actual {
		t.Errorf("expected periodic job GCS path %s, got %s", expected, actual)
	}
}

func TestPeriodic_Aliases(t *testing.T) {
	periodic := Periodic{}
	if actual := periodic.Aliases(); len(actual) != 0 {
		t.Errorf("expected periodic job to have no aliases, got: %v", actual)
	}
}
