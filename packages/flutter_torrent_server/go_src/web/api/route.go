package api

import (
	"github.com/gin-gonic/gin"
)

type requestI struct {
	Action string `json:"action,omitempty"`
}

// SetupRoute registers the HTTP API on two groups.
//
//   - priv carries the per-launch token guard. Everything that can enumerate,
//     mutate or shut down the user's torrent library lives here, because those
//     are the endpoints that turn "someone can reach the port" into "someone
//     learns what you are watching".
//   - open carries no token, because everything on it is handed to an external
//     media engine (libVLC, mpv, Infuse) as a bare URL and that engine cannot
//     attach a header. These endpoints are capability-protected instead: the
//     caller must already know a torrent's 160-bit infohash, which is not
//     discoverable without a privileged call.
//
// The capability argument only holds while a handler on open cannot mint the
// torrent it is asked for. It could: /stream handed any `link` it was given
// straight to torr.AddTorrent, so knowing no secret at all was enough to make
// the engine join, download and seed a swarm of the caller's choosing. open
// therefore runs openGuard, which marks every request that arrived without a
// valid token, and the handlers behind it (api.stream, api.play) refuse to do
// anything for a marked request but replay a torrent the user already added.
// A new route added to open inherits that mark and must honour it.
func SetupRoute(open, priv *gin.RouterGroup) {
	priv.GET("/shutdown", shutdown)

	priv.POST("/settings", settings)

	priv.POST("/torrents", torrents)
	priv.POST("/torrent/upload", torrentUpload)

	priv.POST("/cache", cache)

	priv.POST("/viewed", viewed)

	priv.GET("/playlistall/all.m3u", allPlayList)

	priv.GET("/download/:size", download)

	open.HEAD("/stream", stream)
	open.HEAD("/stream/*fname", stream)

	open.GET("/stream", stream)
	open.GET("/stream/*fname", stream)

	open.HEAD("/play/:hash/:id", play)
	open.GET("/play/:hash/:id", play)

	open.GET("/playlist", playList)
	open.GET("/playlist/*fname", playList) // Is this endpoint still needed ? `fname` is never used in the handler
}
