package config

import (
	"reflect"
	"testing"
)

func TestBatch_GcsPath(t *testing.T) {
	batch := Batch{
		Job: Job{
			JobName:     "name",
			BuildNumber: 1,
		},
		RepoMeta: RepoMeta{
			RepoOwner: "owner",
			RepoName:  "repo",
		},
	}

	if expected, actual := "pr-logs/directory/owner_repo/name/1/", batch.GcsPath(); expected != actual {
		t.Errorf("expected batch job GCS path %s, got %s", expected, actual)
	}
}

func TestBatch_Aliases(t *testing.T) {
	batch := Batch{}
	if actual := batch.Aliases(); len(actual) != 0 {
		t.Errorf("expected batch job to have no aliases, got: %v", actual)
	}
}

func TestBatch_Type(t *testing.T) {
	batch := Batch{}
	if actual, expected := batch.Type(), BatchType; !reflect.DeepEqual(actual, expected) {
		t.Errorf("expected batch type to be %v, but got %v", expected, actual)
	}
}
