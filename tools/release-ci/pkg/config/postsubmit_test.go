package config

import "testing"

func TestPostsubmit_GcsPath(t *testing.T) {
	postsubmit := Postsubmit{
		Job: Job{
			JobName:     "name",
			BuildNumber: 1,
		},
	}

	if expected, actual := "logs/name/1/", postsubmit.GcsPath(); expected != actual {
		t.Errorf("expected postsubmit job GCS path %s, got %s", expected, actual)
	}
}

func TestPostsubmit_Aliases(t *testing.T) {
	postsubmit := Postsubmit{}
	if actual := postsubmit.Aliases(); len(actual) != 0 {
		t.Errorf("expected postsubmit job to have no aliases, got: %v", actual)
	}
}
