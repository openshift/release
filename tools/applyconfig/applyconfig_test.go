package main

import (
	"reflect"
	"testing"
)

func TestIsAdminConfig(t *testing.T) {
	testCases := []struct{
		filename string
		expected bool
	}{
		{
			filename: "admin_01_something_rbac.yaml",
			expected: true,
		},
		{
			filename: "admin_something_rbac.yaml",
			expected: true,
		},
		// Negative
		{ filename: "cfg_01_something" },
		{ filename: "admin_01_something_rbac" },
		{ filename: "admin_01_something_rbac.yml"	},
		{ filename: "admin.yaml" },
	}

	for _, tc := range testCases {
		t.Run(tc.filename, func(t *testing.T){
			is := isAdminConfig(tc.filename)
			if is != tc.expected {
				t.Errorf("expected %t, got %t", tc.expected, is)
			}
		})
	}
}

func TestIsStandardConfig(t *testing.T) {
	testCases := []struct{
		filename string
		expected bool
	}{
		{
			filename: "01_something_rbac.yaml",
			expected: true,
		},
		{
			filename: "something_rbac.yaml",
			expected: true,
		},
		// Negative
		{ filename: "admin_01_something.yaml" },
		{ filename: "cfg_01_something_rbac" },
		{ filename: "cfg_01_something_rbac.yml"	},
	}

	for _, tc := range testCases {
		t.Run(tc.filename, func(t *testing.T){
			is := isStandardConfig(tc.filename)
			if is != tc.expected {
				t.Errorf("expected %t, got %t", tc.expected, is)
			}
		})
	}
}

func TestMakeOcArgs(t *testing.T) {
	testCases := []struct{
		name string

		path string
		user string
		dry bool

		expected []string
	}{
		{
			name: "no user, not dry",
			path: "/path/to/file",
			expected: []string{"apply", "-f", "/path/to/file"},
		},
		{
			name: "no user, dry",
			path: "/path/to/different/file",
			dry: true,
			expected: []string{"apply", "-f", "/path/to/different/file", "--dry-run"},
		},
		{
			name: "user, dry",
			path: "/path/to/file",
			dry: true,
			user: "joe",
			expected: []string{"apply", "-f", "/path/to/file", "--dry-run", "--as", "joe"},
		},
		{
			name: "user, not dry",
			path: "/path/to/file",
			user: "joe",
			expected: []string{"apply", "-f", "/path/to/file", "--as", "joe"},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T){
			args := makeOcArgs(tc.path, tc.user, tc.dry)
			if !reflect.DeepEqual(args, tc.expected) {
				t.Errorf("Expected '%v', got '%v'", tc.expected, args)
			}
		})
	}
}

