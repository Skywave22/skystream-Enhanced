package torrServer

import (
	server "server"
)

// StartTorrentServer starts the embedded server on loopback.
//
// authToken is the per-launch secret the host app must present on privileged
// HTTP endpoints (see web.TokenHeader). Generate a fresh unguessable value per
// launch on the host side and keep it in process memory only. Passing "" locks
// the privileged endpoints instead of opening them.
func StartTorrentServer(pathdb, authToken string) {
	server.Start(pathdb, "", authToken, false, false)
}

func WaitTorrentServer() {
	server.WaitServer()
}

func StopTorrentServer() {
	server.Stop()
}

func AddTrackers(trackers string) {
	server.AddTrackers(trackers)
}
