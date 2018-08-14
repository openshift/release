/*
Copyright 2018 The Kubernetes Authors.

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

// Package cat adds cat images to issues in response to a /meow comment
package cat

import (
	"encoding/xml"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/sirupsen/logrus"

	"k8s.io/test-infra/prow/github"
	"k8s.io/test-infra/prow/pluginhelp"
	"k8s.io/test-infra/prow/plugins"
)

var (
	match = regexp.MustCompile(`(?mi)^/meow( .+)?\s*$`)
	meow  = &realClowder{
		url: "http://thecatapi.com/api/images/get?format=xml&results_per_page=1",
	}
)

const (
	pluginName = "cat"
)

func init() {
	plugins.RegisterGenericCommentHandler(pluginName, handleGenericComment, helpProvider)
}

func helpProvider(config *plugins.Configuration, enabledRepos []string) (*pluginhelp.PluginHelp, error) {
	// The Config field is omitted because this plugin is not configurable.
	pluginHelp := &pluginhelp.PluginHelp{
		Description: "The cat plugin adds a cat image to an issue in response to the `/meow` command.",
	}
	pluginHelp.AddCommand(pluginhelp.Command{
		Usage:       "/meow",
		Description: "Add a cat image to the issue",
		Featured:    false,
		WhoCanUse:   "Anyone",
		Examples:    []string{"/meow", "/meow caturday"},
	})
	return pluginHelp, nil
}

type githubClient interface {
	CreateComment(owner, repo string, number int, comment string) error
}

type clowder interface {
	readCat(string) (string, error)
}

type realClowder struct {
	url     string
	lock    sync.RWMutex
	update  time.Time
	key     string
	keyPath string
}

func (c *realClowder) setKey(keyPath string, log *logrus.Entry) {
	c.lock.Lock()
	defer c.lock.Unlock()
	if !time.Now().After(c.update) {
		return
	}
	c.update = time.Now().Add(1 * time.Minute)
	if keyPath == "" {
		c.key = ""
		return
	}
	b, err := ioutil.ReadFile(keyPath)
	if err == nil {
		c.key = strings.TrimSpace(string(b))
		return
	}
	log.WithError(err).Errorf("failed to read key at %s", keyPath)
	c.key = ""
}

type catResult struct {
	Source string `xml:"data>images>image>source_url"`
	Image  string `xml:"data>images>image>url"`
}

func (cr catResult) Format() (string, error) {
	if cr.Source == "" {
		return "", errors.New("empty source_url")
	}
	if cr.Image == "" {
		return "", errors.New("empty image url")
	}
	src, err := url.Parse(cr.Source)
	if err != nil {
		return "", fmt.Errorf("invalid source_url %s: %v", cr.Source, err)
	}
	img, err := url.Parse(cr.Image)
	if err != nil {
		return "", fmt.Errorf("invalid image url %s: %v", cr.Image, err)
	}

	return fmt.Sprintf("[![cat image](%s)](%s)", img, src), nil
}

func (r *realClowder) Url(category string) string {
	r.lock.RLock()
	defer r.lock.RUnlock()
	uri := string(r.url)
	if category != "" {
		uri += "&category=" + url.QueryEscape(category)
	}
	if r.key != "" {
		uri += "&api_key=" + url.QueryEscape(r.key)
	}
	return uri
}

func (r *realClowder) readCat(category string) (string, error) {
	uri := r.Url(category)
	resp, err := http.Get(uri)
	if err != nil {
		return "", fmt.Errorf("could not read cat from %s: %v", uri, err)
	}
	defer resp.Body.Close()
	if sc := resp.StatusCode; sc > 299 || sc < 200 {
		return "", fmt.Errorf("failing %d response from %s", sc, uri)
	}
	var a catResult
	if err = xml.NewDecoder(resp.Body).Decode(&a); err != nil {
		return "", err
	}
	if a.Image == "" {
		return "", fmt.Errorf("no image url in response from %s", uri)
	}
	// checking size, GitHub doesn't support big images
	toobig, err := github.ImageTooBig(a.Image)
	if err != nil {
		return "", fmt.Errorf("could not validate image size %s: %v", a.Image, err)
	} else if toobig {
		return "", fmt.Errorf("longcat is too long: %s", a.Image)
	}
	return a.Format()
}

func handleGenericComment(pc plugins.PluginClient, e github.GenericCommentEvent) error {
	return handle(
		pc.GitHubClient,
		pc.Logger,
		&e,
		meow,
		func() { meow.setKey(pc.PluginConfig.Cat.KeyPath, pc.Logger) },
	)
}

func handle(gc githubClient, log *logrus.Entry, e *github.GenericCommentEvent, c clowder, setKey func()) error {
	// Only consider new comments.
	if e.Action != github.GenericCommentActionCreated {
		return nil
	}
	// Make sure they are requesting a cat
	mat := match.FindStringSubmatch(e.Body)
	if mat == nil {
		return nil
	}

	// Now that we know this is a relevant event we can set the key.
	setKey()

	category := mat[1]
	if len(category) > 1 {
		category = category[1:]
	}

	org := e.Repo.Owner.Login
	repo := e.Repo.Name
	number := e.Number

	for i := 0; i < 3; i++ {
		resp, err := c.readCat(category)
		if err != nil {
			log.WithError(err).Error("Failed to get cat img")
			continue
		}
		return gc.CreateComment(org, repo, number, plugins.FormatResponseRaw(e.Body, e.HTMLURL, e.User.Login, resp))
	}

	var msg string
	if category != "" {
		msg = "Bad category. Please see http://thecatapi.com/api/categories/list"
	} else {
		msg = "http://thecatapi.com appears to be down"
	}
	if err := gc.CreateComment(org, repo, number, plugins.FormatResponseRaw(e.Body, e.HTMLURL, e.User.Login, msg)); err != nil {
		log.WithError(err).Error("Failed to leave comment")
	}

	return errors.New("could not find a valid cat image")
}
