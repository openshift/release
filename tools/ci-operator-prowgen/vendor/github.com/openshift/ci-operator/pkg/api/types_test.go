package api

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestOverlay(t *testing.T) {
	tests := []struct {
		name      string
		base      string
		overlay   string
		want      *ReleaseBuildConfiguration
		wantInput *InputConfiguration
	}{
		{
			name:      "empty",
			base:      "{}",
			overlay:   "{}",
			want:      &ReleaseBuildConfiguration{},
			wantInput: &InputConfiguration{},
		},
		{
			name:    "empty",
			base:    `{}`,
			overlay: `{"base_images":{"test":{"name":"test-1"}}}`,
			want: &ReleaseBuildConfiguration{
				InputConfiguration: InputConfiguration{
					BaseImages: map[string]ImageStreamTagReference{
						"test": {Name: "test-1"},
					},
				},
			},
			wantInput: &InputConfiguration{
				BaseImages: map[string]ImageStreamTagReference{
					"test": {Name: "test-1"},
				},
			},
		},
		{
			name:    "overwrite",
			base:    `{"base_images":{"test":{"name":"test-0"}}}`,
			overlay: `{"base_images":{"test":{"name":"test-1"}}}`,
			want: &ReleaseBuildConfiguration{
				InputConfiguration: InputConfiguration{
					BaseImages: map[string]ImageStreamTagReference{
						"test": {Name: "test-1"},
					},
				},
			},
			wantInput: &InputConfiguration{
				BaseImages: map[string]ImageStreamTagReference{
					"test": {Name: "test-1"},
				},
			},
		},
		{
			name:    "map merge",
			base:    `{"base_images":{"test-0":{"name":"test-0"}}}`,
			overlay: `{"base_images":{"test-1":{"name":"test-1"}}}`,
			want: &ReleaseBuildConfiguration{
				InputConfiguration: InputConfiguration{
					BaseImages: map[string]ImageStreamTagReference{
						"test-0": {Name: "test-0"},
						"test-1": {Name: "test-1"},
					},
				},
			},
			wantInput: &InputConfiguration{
				BaseImages: map[string]ImageStreamTagReference{
					"test-1": {Name: "test-1"},
				},
			},
		},
		{
			name:    "map merge by field",
			base:    `{"base_images":{"test-0":{"name":"test-0","namespace":"0"}}}`,
			overlay: `{"base_images":{"test-0":{"name":"test-0","namespace":null}}}`,
			want: &ReleaseBuildConfiguration{
				InputConfiguration: InputConfiguration{
					BaseImages: map[string]ImageStreamTagReference{
						"test-0": {Name: "test-0"},
					},
				},
			},
			wantInput: &InputConfiguration{
				BaseImages: map[string]ImageStreamTagReference{
					"test-0": {Name: "test-0"},
				},
			},
		},
		{
			name:    "skips missing key",
			base:    `{"test_base_image":{}}`,
			overlay: `{}`,
			want: &ReleaseBuildConfiguration{
				InputConfiguration: InputConfiguration{
					TestBaseImage: &ImageStreamTagReference{},
				},
			},
			wantInput: &InputConfiguration{},
		},
		{
			name:    "clears with explicit null",
			base:    `{"test_base_image":{}}`,
			overlay: `{"test_base_image":null}`,
			want: &ReleaseBuildConfiguration{
				InputConfiguration: InputConfiguration{},
			},
			wantInput: &InputConfiguration{},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			config := &ReleaseBuildConfiguration{}
			input := &InputConfiguration{}
			if err := json.Unmarshal([]byte(tt.base), config); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal([]byte(tt.overlay), config); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal([]byte(tt.overlay), input); err != nil {
				t.Fatal(err)
			}
			if got := input; !reflect.DeepEqual(got, tt.wantInput) {
				t.Errorf("input:\n%#v\n%#v", got, tt.wantInput)
			}
			if got := config; !reflect.DeepEqual(got, tt.want) {
				t.Errorf("config:\n%#v\n%#v", got, tt.want)
			}
		})
	}
}
