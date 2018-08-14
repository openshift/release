/*
Copyright 2016 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package approvers

import (
	"testing"

	"github.com/sirupsen/logrus"

	"k8s.io/apimachinery/pkg/util/sets"

	"path/filepath"
	"reflect"
	"strings"
)

const (
	TEST_SEED = int64(0)
)

type FakeRepo struct {
	approversMap      map[string]sets.String
	leafApproversMap  map[string]sets.String
	noParentOwnersMap map[string]bool
}

func (f FakeRepo) Approvers(path string) sets.String {
	return f.approversMap[path]
}

func (f FakeRepo) LeafApprovers(path string) sets.String {
	return f.leafApproversMap[path]
}

func (f FakeRepo) FindApproverOwnersForFile(path string) string {
	for dir := path; dir != "."; dir = filepath.Dir(dir) {
		if _, ok := f.leafApproversMap[dir]; ok {
			return dir
		}
	}
	return ""
}

func (f FakeRepo) IsNoParentOwners(path string) bool {
	return f.noParentOwnersMap[path]
}

type dir struct {
	fullPath  string
	approvers sets.String
}

func canonicalize(path string) string {
	if path == "." {
		return ""
	}
	return strings.TrimSuffix(path, "/")
}

func createFakeRepo(la map[string]sets.String) FakeRepo {
	// github doesn't use / at the root
	a := map[string]sets.String{}
	for dir, approvers := range la {
		la[dir] = setToLower(approvers)
		a[dir] = setToLower(approvers)
		starting_path := dir
		for {
			dir = canonicalize(filepath.Dir(dir))
			if parent_approvers, ok := la[dir]; ok {
				a[starting_path] = a[starting_path].Union(setToLower(parent_approvers))
			}
			if dir == "" {
				break
			}
		}
	}

	return FakeRepo{approversMap: a, leafApproversMap: la}
}

func setToLower(s sets.String) sets.String {
	lowered := sets.NewString()
	for _, elem := range s.List() {
		lowered.Insert(strings.ToLower(elem))
	}
	return lowered
}

func TestCreateFakeRepo(t *testing.T) {
	rootApprovers := sets.NewString("Alice", "Bob")
	aApprovers := sets.NewString("Art", "Anne")
	bApprovers := sets.NewString("Bill", "Ben", "Barbara")
	cApprovers := sets.NewString("Chris", "Carol")
	eApprovers := sets.NewString("Eve", "Erin")
	edcApprovers := eApprovers.Union(cApprovers)
	FakeRepoMap := map[string]sets.String{
		"":        rootApprovers,
		"a":       aApprovers,
		"b":       bApprovers,
		"c":       cApprovers,
		"a/combo": edcApprovers,
	}
	fake_repo := createFakeRepo(FakeRepoMap)

	tests := []struct {
		testName              string
		ownersFile            string
		expectedLeafApprovers sets.String
		expectedApprovers     sets.String
	}{
		{
			testName:              "Root Owners",
			ownersFile:            "",
			expectedApprovers:     rootApprovers,
			expectedLeafApprovers: rootApprovers,
		},
		{
			testName:              "A Owners",
			ownersFile:            "a",
			expectedLeafApprovers: aApprovers,
			expectedApprovers:     aApprovers.Union(rootApprovers),
		},
		{
			testName:              "B Owners",
			ownersFile:            "b",
			expectedLeafApprovers: bApprovers,
			expectedApprovers:     bApprovers.Union(rootApprovers),
		},
		{
			testName:              "C Owners",
			ownersFile:            "c",
			expectedLeafApprovers: cApprovers,
			expectedApprovers:     cApprovers.Union(rootApprovers),
		},
		{
			testName:              "Combo Owners",
			ownersFile:            "a/combo",
			expectedLeafApprovers: edcApprovers,
			expectedApprovers:     edcApprovers.Union(aApprovers).Union(rootApprovers),
		},
	}

	for _, test := range tests {
		calculated_leaf_approvers := fake_repo.LeafApprovers(test.ownersFile)
		calculated_approvers := fake_repo.Approvers(test.ownersFile)

		test.expectedLeafApprovers = setToLower(test.expectedLeafApprovers)
		if !calculated_leaf_approvers.Equal(test.expectedLeafApprovers) {
			t.Errorf("Failed for test %v.  Expected Leaf Approvers: %v. Actual Leaf Approvers %v", test.testName, test.expectedLeafApprovers, calculated_leaf_approvers)
		}

		test.expectedApprovers = setToLower(test.expectedApprovers)
		if !calculated_approvers.Equal(test.expectedApprovers) {
			t.Errorf("Failed for test %v.  Expected Approvers: %v. Actual Approvers %v", test.testName, test.expectedApprovers, calculated_approvers)
		}
	}
}

func TestGetLeafApprovers(t *testing.T) {
	rootApprovers := sets.NewString("Alice", "Bob")
	aApprovers := sets.NewString("Art", "Anne")
	bApprovers := sets.NewString("Bill", "Ben", "Barbara")
	dApprovers := sets.NewString("David", "Dan", "Debbie")
	FakeRepoMap := map[string]sets.String{
		"":    rootApprovers,
		"a":   aApprovers,
		"b":   bApprovers,
		"a/d": dApprovers,
	}

	tests := []struct {
		testName    string
		filenames   []string
		expectedMap map[string]sets.String
	}{
		{
			testName:    "Empty PR",
			filenames:   []string{},
			expectedMap: map[string]sets.String{},
		},
		{
			testName:    "Single Root File PR",
			filenames:   []string{"kubernetes.go"},
			expectedMap: map[string]sets.String{"": setToLower(rootApprovers)},
		},
		{
			testName:    "Internal Node File PR",
			filenames:   []string{"a/test.go"},
			expectedMap: map[string]sets.String{"a": setToLower(aApprovers)},
		},
		{
			testName:  "Two Leaf File PR",
			filenames: []string{"a/d/test.go", "b/test.go"},
			expectedMap: map[string]sets.String{
				"a/d": setToLower(dApprovers),
				"b":   setToLower(bApprovers)},
		},
		{
			testName:  "Leaf and Parent 2 File PR",
			filenames: []string{"a/test.go", "a/d/test.go"},
			expectedMap: map[string]sets.String{
				"a": setToLower(aApprovers),
			},
		},
	}

	for _, test := range tests {
		testOwners := Owners{
			filenames: test.filenames,
			repo:      createFakeRepo(FakeRepoMap),
			seed:      TEST_SEED,
			log:       logrus.WithField("plugin", "some_plugin"),
		}
		oMap := testOwners.GetLeafApprovers()
		if !reflect.DeepEqual(test.expectedMap, oMap) {
			t.Errorf("Failed for test %v.  Expected Owners: %v. Actual Owners %v", test.testName, test.expectedMap, oMap)
		}
	}
}
func TestGetOwnersSet(t *testing.T) {
	rootApprovers := sets.NewString("Alice", "Bob")
	aApprovers := sets.NewString("Art", "Anne")
	bApprovers := sets.NewString("Bill", "Ben", "Barbara")
	dApprovers := sets.NewString("David", "Dan", "Debbie")
	FakeRepoMap := map[string]sets.String{
		"":    rootApprovers,
		"a":   aApprovers,
		"b":   bApprovers,
		"a/d": dApprovers,
	}

	tests := []struct {
		testName            string
		filenames           []string
		expectedOwnersFiles sets.String
	}{
		{
			testName:            "Empty PR",
			filenames:           []string{},
			expectedOwnersFiles: sets.NewString(),
		},
		{
			testName:            "Single Root File PR",
			filenames:           []string{"kubernetes.go"},
			expectedOwnersFiles: sets.NewString(""),
		},
		{
			testName:            "Multiple Root File PR",
			filenames:           []string{"test.go", "kubernetes.go"},
			expectedOwnersFiles: sets.NewString(""),
		},
		{
			testName:            "Internal Node File PR",
			filenames:           []string{"a/test.go"},
			expectedOwnersFiles: sets.NewString("a"),
		},
		{
			testName:            "Two Leaf File PR",
			filenames:           []string{"a/test.go", "b/test.go"},
			expectedOwnersFiles: sets.NewString("a", "b"),
		},
		{
			testName:            "Leaf and Parent 2 File PR",
			filenames:           []string{"a/test.go", "a/c/test.go"},
			expectedOwnersFiles: sets.NewString("a"),
		},
	}

	for _, test := range tests {
		testOwners := Owners{
			filenames: test.filenames,
			repo:      createFakeRepo(FakeRepoMap),
			seed:      TEST_SEED,
			log:       logrus.WithField("plugin", "some_plugin"),
		}
		oSet := testOwners.GetOwnersSet()
		if !oSet.Equal(test.expectedOwnersFiles) {
			t.Errorf("Failed for test %v.  Expected Owners: %v. Actual Owners %v", test.testName, test.expectedOwnersFiles, oSet)
		}
	}
}

func TestGetSuggestedApprovers(t *testing.T) {
	var rootApprovers = sets.NewString("Alice", "Bob")
	var aApprovers = sets.NewString("Art", "Anne")
	var bApprovers = sets.NewString("Bill", "Ben", "Barbara")
	var dApprovers = sets.NewString("David", "Dan", "Debbie")
	var eApprovers = sets.NewString("Eve", "Erin")
	var edcApprovers = eApprovers.Union(dApprovers)
	var FakeRepoMap = map[string]sets.String{
		"":        rootApprovers,
		"a":       aApprovers,
		"b":       bApprovers,
		"a/d":     dApprovers,
		"a/combo": edcApprovers,
	}
	tests := []struct {
		testName  string
		filenames []string
		// need at least one person from each set
		expectedOwners []sets.String
	}{
		{
			testName:       "Empty PR",
			filenames:      []string{},
			expectedOwners: []sets.String{},
		},
		{
			testName:       "Single Root File PR",
			filenames:      []string{"kubernetes.go"},
			expectedOwners: []sets.String{setToLower(rootApprovers)},
		},
		{
			testName:       "Internal Node File PR",
			filenames:      []string{"a/test.go"},
			expectedOwners: []sets.String{setToLower(aApprovers)},
		},
		{
			testName:       "Multiple Files Internal Node File PR",
			filenames:      []string{"a/test.go", "a/test1.go"},
			expectedOwners: []sets.String{setToLower(aApprovers)},
		},
		{
			testName:       "Two Leaf File PR",
			filenames:      []string{"a/test.go", "b/test.go"},
			expectedOwners: []sets.String{setToLower(aApprovers), setToLower(bApprovers)},
		},
		{
			testName:       "Leaf and Parent 2 File PR",
			filenames:      []string{"a/test.go", "a/d/test.go"},
			expectedOwners: []sets.String{setToLower(aApprovers)},
		},
		{
			testName:       "Combo and B",
			filenames:      []string{"a/combo/test.go", "b/test.go"},
			expectedOwners: []sets.String{setToLower(edcApprovers), setToLower(bApprovers)},
		},
		{
			testName:       "Lowest Leaf",
			filenames:      []string{"a/combo/test.go"},
			expectedOwners: []sets.String{setToLower(edcApprovers)},
		},
	}

	for _, test := range tests {
		testOwners := Owners{
			filenames: test.filenames,
			repo:      createFakeRepo(FakeRepoMap),
			seed:      TEST_SEED,
			log:       logrus.WithField("plugin", "some_plugin"),
		}
		suggested := testOwners.GetSuggestedApprovers(testOwners.GetReverseMap(testOwners.GetLeafApprovers()), testOwners.GetShuffledApprovers())
		for _, ownersSet := range test.expectedOwners {
			if ownersSet.Intersection(suggested).Len() == 0 {
				t.Errorf("Failed for test %v.  Didn't find an approver from: %v. Actual Owners %v", test.testName, ownersSet, suggested)
				t.Errorf("%v", test.filenames)
			}
		}
	}
}

func TestGetAllPotentialApprovers(t *testing.T) {
	rootApprovers := sets.NewString("Alice", "Bob")
	aApprovers := sets.NewString("Art", "Anne")
	bApprovers := sets.NewString("Bill", "Ben", "Barbara")
	cApprovers := sets.NewString("Chris", "Carol")
	dApprovers := sets.NewString("David", "Dan", "Debbie")
	eApprovers := sets.NewString("Eve", "Erin")
	edcApprovers := eApprovers.Union(dApprovers).Union(cApprovers)
	FakeRepoMap := map[string]sets.String{
		"":        rootApprovers,
		"a":       aApprovers,
		"b":       bApprovers,
		"c":       cApprovers,
		"a/d":     dApprovers,
		"a/combo": edcApprovers,
	}
	tests := []struct {
		testName  string
		filenames []string
		// use an array because we expected output of this function to be sorted
		expectedApprovers []string
	}{
		{
			testName:          "Empty PR",
			filenames:         []string{},
			expectedApprovers: []string{},
		},
		{
			testName:          "Single Root File PR",
			filenames:         []string{"kubernetes.go"},
			expectedApprovers: setToLower(rootApprovers).List(),
		},
		{
			testName:          "Internal Node File PR",
			filenames:         []string{"a/test.go"},
			expectedApprovers: setToLower(aApprovers).List(),
		},
		{
			testName:          "One Leaf One Internal Node File PR",
			filenames:         []string{"a/test.go", "b/test.go"},
			expectedApprovers: setToLower(aApprovers.Union(bApprovers)).List(),
		},
		{
			testName:          "Two Leaf Files PR",
			filenames:         []string{"a/d/test.go", "c/test.go"},
			expectedApprovers: setToLower(dApprovers.Union(cApprovers)).List(),
		},
		{
			testName:          "Leaf and Parent 2 File PR",
			filenames:         []string{"a/test.go", "a/combo/test.go"},
			expectedApprovers: setToLower(aApprovers).List(),
		},
		{
			testName:          "Two Leafs",
			filenames:         []string{"a/d/test.go", "b/test.go"},
			expectedApprovers: setToLower(dApprovers.Union(bApprovers)).List(),
		},
		{
			testName:          "Lowest Leaf",
			filenames:         []string{"a/combo/test.go"},
			expectedApprovers: setToLower(edcApprovers).List(),
		},
		{
			testName:          "Root And Everything Else PR",
			filenames:         []string{"a/combo/test.go", "b/test.go", "c/test.go", "d/test.go"},
			expectedApprovers: setToLower(rootApprovers).List(),
		},
	}

	for _, test := range tests {
		testOwners := Owners{
			filenames: test.filenames,
			repo:      createFakeRepo(FakeRepoMap),
			seed:      TEST_SEED,
			log:       logrus.WithField("plugin", "some_plugin"),
		}
		all := testOwners.GetAllPotentialApprovers()
		if !reflect.DeepEqual(all, test.expectedApprovers) {
			t.Errorf("Failed for test %v.  Didn't correct approvers list.  Expected: %v. Found %v", test.testName, test.expectedApprovers, all)
		}
	}
}

func TestFindMostCoveringApprover(t *testing.T) {
	rootApprovers := sets.NewString("Alice", "Bob")
	aApprovers := sets.NewString("Art", "Anne")
	bApprovers := sets.NewString("Bill", "Ben", "Barbara")
	cApprovers := sets.NewString("Chris", "Carol")
	dApprovers := sets.NewString("David", "Dan", "Debbie")
	eApprovers := sets.NewString("Eve", "Erin")
	edcApprovers := eApprovers.Union(dApprovers).Union(cApprovers)
	FakeRepoMap := map[string]sets.String{
		"":        rootApprovers,
		"a":       aApprovers,
		"b":       bApprovers,
		"c":       cApprovers,
		"a/d":     dApprovers,
		"a/combo": edcApprovers,
	}
	tests := []struct {
		testName   string
		filenames  []string
		unapproved sets.String
		// because most covering could be two or more people
		expectedMostCovering sets.String
	}{
		{
			testName:             "Empty PR",
			filenames:            []string{},
			unapproved:           sets.String{},
			expectedMostCovering: sets.NewString(""),
		},
		{
			testName:             "Single Root File PR",
			filenames:            []string{"kubernetes.go"},
			unapproved:           sets.NewString(""),
			expectedMostCovering: setToLower(rootApprovers),
		},
		{
			testName:             "Internal Node File PR",
			filenames:            []string{"a/test.go"},
			unapproved:           sets.NewString("a"),
			expectedMostCovering: setToLower(aApprovers),
		},
		{
			testName:             "Combo and Intersecting Leaf PR",
			filenames:            []string{"a/combo/test.go", "a/d/test.go"},
			unapproved:           sets.NewString("a/combo", "a/d"),
			expectedMostCovering: setToLower(edcApprovers.Intersection(dApprovers)),
		},
		{
			testName:             "Three Leaf PR Only B Approved",
			filenames:            []string{"a/combo/test.go", "c/test.go", "b/test.go"},
			unapproved:           sets.NewString("a/combo", "c/"),
			expectedMostCovering: setToLower(edcApprovers.Intersection(cApprovers)),
		},
		{
			testName:             "Three Leaf PR Only B Left Unapproved",
			filenames:            []string{"a/combo/test.go", "a/d/test.go", "b/test.go"},
			unapproved:           sets.NewString("b"),
			expectedMostCovering: setToLower(bApprovers),
		},
		{
			testName:             "Leaf and Parent 2 File PR",
			filenames:            []string{"a/test.go", "a/d/test.go"},
			unapproved:           sets.NewString("a", "a/d"),
			expectedMostCovering: setToLower(aApprovers.Union(dApprovers)),
		},
	}

	for _, test := range tests {
		testOwners := Owners{
			filenames: test.filenames,
			repo:      createFakeRepo(FakeRepoMap),
			seed:      TEST_SEED,
			log:       logrus.WithField("plugin", "some_plugin"),
		}
		bestPerson := findMostCoveringApprover(testOwners.GetAllPotentialApprovers(), testOwners.GetReverseMap(testOwners.GetLeafApprovers()), test.unapproved)
		if test.expectedMostCovering.Intersection(sets.NewString(bestPerson)).Len() != 1 {
			t.Errorf("Failed for test %v.  Didn't correct approvers list.  Expected: %v. Found %v", test.testName, test.expectedMostCovering, bestPerson)
		}
	}
}

func TestGetReverseMap(t *testing.T) {
	rootApprovers := sets.NewString("Alice", "Bob")
	aApprovers := sets.NewString("Art", "Anne")
	cApprovers := sets.NewString("Chris", "Carol")
	dApprovers := sets.NewString("David", "Dan", "Debbie")
	eApprovers := sets.NewString("Eve", "Erin")
	edcApprovers := eApprovers.Union(dApprovers).Union(cApprovers)
	FakeRepoMap := map[string]sets.String{
		"":        rootApprovers,
		"a":       aApprovers,
		"c":       cApprovers,
		"a/d":     dApprovers,
		"a/combo": edcApprovers,
	}
	tests := []struct {
		testName       string
		filenames      []string
		expectedRevMap map[string]sets.String // people -> files they can approve
	}{
		{
			testName:       "Empty PR",
			filenames:      []string{},
			expectedRevMap: map[string]sets.String{},
		},
		{
			testName:  "Single Root File PR",
			filenames: []string{"kubernetes.go"},
			expectedRevMap: map[string]sets.String{
				"alice": sets.NewString(""),
				"bob":   sets.NewString(""),
			},
		},
		{
			testName:  "Two Leaf PRs",
			filenames: []string{"a/combo/test.go", "a/d/test.go"},
			expectedRevMap: map[string]sets.String{
				"david":  sets.NewString("a/d", "a/combo"),
				"dan":    sets.NewString("a/d", "a/combo"),
				"debbie": sets.NewString("a/d", "a/combo"),
				"eve":    sets.NewString("a/combo"),
				"erin":   sets.NewString("a/combo"),
				"chris":  sets.NewString("a/combo"),
				"carol":  sets.NewString("a/combo"),
			},
		},
	}

	for _, test := range tests {
		testOwners := Owners{
			filenames: test.filenames,
			repo:      createFakeRepo(FakeRepoMap),
			seed:      TEST_SEED,
			log:       logrus.WithField("plugin", "some_plugin"),
		}
		calculatedRevMap := testOwners.GetReverseMap(testOwners.GetLeafApprovers())
		if !reflect.DeepEqual(calculatedRevMap, test.expectedRevMap) {
			t.Errorf("Failed for test %v.  Didn't find correct reverse map.", test.testName)
			t.Errorf("Person \t\t Expected \t\tFound ")
			// printing the calculated vs expected in a nicer way for debugging
			for k, v := range test.expectedRevMap {
				if calcVal, ok := calculatedRevMap[k]; ok {
					t.Errorf("%v\t\t%v\t\t%v ", k, v, calcVal)
				} else {
					t.Errorf("%v\t\t%v", k, v)
				}
			}
		}
	}
}

func TestGetShuffledApprovers(t *testing.T) {
	rootApprovers := sets.NewString("Alice", "Bob")
	aApprovers := sets.NewString("Art", "Anne")
	bApprovers := sets.NewString("Bill", "Ben", "Barbara")
	cApprovers := sets.NewString("Chris", "Carol")
	dApprovers := sets.NewString("David", "Dan", "Debbie")
	eApprovers := sets.NewString("Eve", "Erin")
	edcApprovers := eApprovers.Union(dApprovers).Union(cApprovers)
	FakeRepoMap := map[string]sets.String{
		"":        rootApprovers,
		"a":       aApprovers,
		"b":       bApprovers,
		"c":       cApprovers,
		"a/d":     dApprovers,
		"a/combo": edcApprovers,
	}
	tests := []struct {
		testName      string
		filenames     []string
		seed          int64
		expectedOrder []string
	}{
		{
			testName:      "Empty PR",
			filenames:     []string{},
			seed:          0,
			expectedOrder: []string{},
		},
		{
			testName:      "Single Root File PR Approved",
			filenames:     []string{"kubernetes.go"},
			seed:          0,
			expectedOrder: []string{"bob", "alice"},
		},
		{
			testName:      "Combo And B PR",
			filenames:     []string{"a/combo/test.go", "b/test.go"},
			seed:          0,
			expectedOrder: []string{"erin", "bill", "carol", "barbara", "dan", "debbie", "ben", "david", "eve", "chris"},
		},
		{
			testName:      "Combo and D, Seed 0",
			filenames:     []string{"a/combo/test.go", "a/d/test.go"},
			seed:          0,
			expectedOrder: []string{"erin", "dan", "dan", "carol", "david", "debbie", "chris", "debbie", "eve", "david"},
		},
		{
			testName:      "Combo and D, Seed 2",
			filenames:     []string{"a/combo/test.go", "a/d/test.go"},
			seed:          2,
			expectedOrder: []string{"dan", "carol", "debbie", "dan", "erin", "chris", "eve", "david", "debbie", "david"},
		},
	}

	for _, test := range tests {
		testOwners := Owners{
			filenames: test.filenames,
			repo:      createFakeRepo(FakeRepoMap),
			seed:      test.seed,
			log:       logrus.WithField("plugin", "some_plugin"),
		}
		calculated := testOwners.GetShuffledApprovers()
		if !reflect.DeepEqual(test.expectedOrder, calculated) {
			t.Errorf("Failed for test %v.  Expected unapproved files: %v. Found %v", test.testName, test.expectedOrder, calculated)
		}
	}
}

func TestRemoveSubdirs(t *testing.T) {
	tests := []struct {
		testName       string
		directories    sets.String
		noParentOwners map[string]bool

		expected sets.String
	}{
		{
			testName:    "Empty PR",
			directories: sets.NewString(),
			expected:    sets.NewString(),
		},
		{
			testName:    "Root and One Level Below PR",
			directories: sets.NewString("", "a/"),
			expected:    sets.NewString(""),
		},
		{
			testName:    "Two Separate Branches",
			directories: sets.NewString("a/", "c/"),
			expected:    sets.NewString("a/", "c/"),
		},
		{
			testName:    "Lots of Branches and Leaves",
			directories: sets.NewString("a", "a/combo", "a/d", "b", "c"),
			expected:    sets.NewString("a", "b", "c"),
		},
		{
			testName:       "NoParentOwners",
			directories:    sets.NewString("a", "a/combo"),
			noParentOwners: map[string]bool{"a/combo": true},
			expected:       sets.NewString("a", "a/combo"),
		},
		{
			testName:       "NoParentOwners in relative path",
			directories:    sets.NewString("a", "a/b/combo"),
			noParentOwners: map[string]bool{"a/b": true},
			expected:       sets.NewString("a", "a/b/combo"),
		},
		{
			testName:       "NoParentOwners with child",
			directories:    sets.NewString("a", "a/b", "a/b/combo"),
			noParentOwners: map[string]bool{"a/b": true},
			expected:       sets.NewString("a", "a/b"),
		},
	}

	for _, test := range tests {
		if test.noParentOwners == nil {
			test.noParentOwners = map[string]bool{}
		}
		o := &Owners{repo: FakeRepo{noParentOwnersMap: test.noParentOwners}}
		o.removeSubdirs(test.directories)
		if !reflect.DeepEqual(test.expected, test.directories) {
			t.Errorf("Failed to remove subdirectories for test %v.  Expected files: %q. Found %q", test.testName, test.expected.List(), test.directories.List())

		}
	}
}
