package main

import "testing"

func TestOptions_Validate(t *testing.T) {
	var testCases = []struct {
		name        string
		input       options
		expectedErr bool
	}{
		{
			name:        "all good",
			input:       options{},
			expectedErr: false,
		},
	}

	for _, testCase := range testCases {
		err := testCase.input.Validate()
		if testCase.expectedErr && err == nil {
			t.Errorf("%s: expected an error but got none", testCase.name)
		}
		if !testCase.expectedErr && err != nil {
			t.Errorf("%s: expected no error but got one: %v", testCase.name, err)
		}
	}
}
