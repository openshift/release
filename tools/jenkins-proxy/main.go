package main

import (
	"flag"
	"log"
	"net/http"
)

var configPath = flag.String("config-path", "/etc/jenkins-proxy/config", "Configuration path.")

func main() {
	flag.Parse()

	p, err := NewProxy(*configPath)
	if err != nil {
		log.Fatalf("%v", err)
	}

	log.Printf("Serving on :8080")
	http.HandleFunc("/", p.handle)
	log.Fatal("Jenkins proxy ListenAndServe returned:", http.ListenAndServe(":8080", nil))
}
