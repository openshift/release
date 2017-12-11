package main

import (
	"flag"
	"fmt"
	"io/ioutil"
	"net/http"
	"net/url"
	"os"
	"strings"
)

var (
	prowURL = flag.String("prow-url", "https://deck-ci.svc.ci.openshift.org/", "URL to the prow frontend.")
)

func main() {
	flag.Parse()

	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "One argument required: Link to a Github pull request or pull request comment")
		os.Exit(1)
	}
	link, err := url.Parse(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}

	if link.Host != "github.com" {
		fmt.Fprintln(os.Stderr, "Host needs to be github.com")
		os.Exit(1)
	}

	parts := strings.Split(strings.Trim(link.Path, "/"), "/")
	if len(parts) != 4 {
		fmt.Fprintln(os.Stderr, "Invalid link provided")
		os.Exit(1)
	}

	params := url.Values{}
	params.Add("org", parts[0])
	params.Add("repo", parts[1])
	params.Add("pr", parts[3])

	if len(link.Fragment) > 0 && strings.HasPrefix(link.Fragment, "issuecomment-") {
		params.Add("issuecomment", strings.TrimPrefix(link.Fragment, "issuecomment-"))
	}

	target, err := url.Parse(*prowURL + "/trace")
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}

	target.RawQuery = params.Encode()
	resp, err := http.Get(target.String())
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		fmt.Fprintln(os.Stderr, fmt.Sprintf("status is not 2xx: %v", resp.Status))
		os.Exit(1)
	}
	data, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
	fmt.Println(string(data))
}
