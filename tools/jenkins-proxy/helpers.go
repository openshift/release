package main

import (
	"bytes"
	"io/ioutil"
	"log"
	"net/http"
)

func loadToken(file string) (string, error) {
	raw, err := ioutil.ReadFile(file)
	if err != nil {
		return "", err
	}
	return string(bytes.TrimSpace(raw)), nil
}

func forwardResponse(w http.ResponseWriter, resp *http.Response) {
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		log.Fatal(err)
	}

	destHeaders := w.Header()
	copyHeader(&resp.Header, &destHeaders)

	w.Write(body)
}

func copyHeader(source, dest *http.Header) {
	if source == nil {
		return
	}
	for n, v := range *source {
		for _, vv := range v {
			dest.Add(n, vv)
		}
	}
}
