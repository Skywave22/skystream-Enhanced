package main

import (
	"flag"
	"log"
	"os"

	"server"
)

func main() {
	port := flag.String("p", "8090", "Port to listen on (loopback only)")
	dbPath := flag.String("d", ".", "Path to database directory")
	flag.Parse()

	// The per-launch token arrives via the environment, never argv: argv is
	// world-readable through `ps` on macOS and Linux.
	authToken := os.Getenv("TORRSERVER_AUTH_TOKEN")
	os.Unsetenv("TORRSERVER_AUTH_TOKEN")

	log.Printf("Starting TorrServer on 127.0.0.1:%s with DB at %s", *port, *dbPath)

	// Start(pathdb, port, authToken string, roSets, searchWA bool)
	server.Start(*dbPath, *port, authToken, false, false)

	// Wait until the server stops or encounters an error
	err := server.WaitServer()
	if err != "" {
		log.Fatalf("Server error: %s", err)
	}
}
