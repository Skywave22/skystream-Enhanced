package web

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/gin-gonic/gin"

	"server/settings"
)

// The embedded server is a private, single-user, same-device component: the
// only legitimate callers are this app's own plugin code and the media player
// it hands a stream URL to. Nothing off-device, and no web page, has any
// business reaching it. Three independent defences enforce that:
//
//  1. the listener is bound to loopback (see web.Start / server.Start), so the
//     LAN cannot open a socket to it at all;
//  2. loopbackGuard rejects requests whose Host is not a loopback literal
//     (DNS rebinding turns an attacker page into a *same-origin* caller, which
//     CORS cannot stop), that carry a foreign Origin (a cross-site form or
//     media element POST is a "simple request" that CORS never blocked either),
//     or that a browser labelled as issued by a page (see FetchSiteHeader:
//     Origin alone is not enough, because a cross-origin no-cors GET — <img>,
//     <video>, <script>, <iframe> — carries no Origin at all);
//  3. tokenGuard requires a per-launch secret on every endpoint that can
//     enumerate or mutate the user's torrent library, so another process on the
//     same device cannot drive the server blind;
//  4. openGuard marks the remaining, token-less routes as unauthenticated, and
//     the handlers behind it then refuse to do anything but replay what the
//     user already added.
//
// /stream and /play stay outside tokenGuard on purpose: they are handed to an
// external media engine (libVLC, mpv, Infuse) as a bare URL, and they are
// already capability-protected — the caller must present the 160-bit infohash
// of a torrent the user added, which cannot be enumerated without a token.
// That capability argument only holds while those routes cannot *create* the
// torrent they are asked for: /stream used to hand any link it was given to
// torr.AddTorrent, so knowing no secret at all was enough to make the engine
// join an arbitrary swarm. openGuard is what makes the argument true.
const (
	// TokenHeader is the preferred way to present the per-launch token.
	TokenHeader = "X-TorrServer-Token" //nolint:gosec // header name, not a credential
	// TokenQuery lets callers that can only be handed a URL authenticate.
	TokenQuery = "token"
	// FetchSiteHeader is the Fetch Metadata header a browser attaches to every
	// request it makes, including the no-cors subresource GETs that carry no
	// Origin. Non-browser callers (libVLC, mpv, Infuse, the app's own HTTP
	// client) never send it, so its mere presence with a foreign value is
	// proof the request came from a page.
	FetchSiteHeader = "Sec-Fetch-Site"
	// CtxNotAuth is the gin context key the API handlers read to decide
	// whether a request may only replay what the user already added. The name
	// is upstream's; the handlers that consult it (api.stream, api.play) were
	// written for exactly this mode.
	CtxNotAuth = "not_auth"
)

// NewAuthToken returns a fresh 256-bit per-launch token as lowercase hex.
func NewAuthToken() string {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		// crypto/rand cannot fail on any platform we ship to; if it somehow
		// does, returning "" is the fail-closed answer because an empty
		// expected token rejects every presented token.
		return ""
	}
	return hex.EncodeToString(buf)
}

// isLoopbackHostPort reports whether an HTTP Host header names this machine's
// loopback interface. An empty Host (legal in HTTP/1.0) is accepted because no
// browser can produce one, so it cannot be part of a rebinding attack.
func isLoopbackHostPort(hostPort string) bool {
	if hostPort == "" {
		return true
	}
	host := hostPort
	if h, _, err := net.SplitHostPort(hostPort); err == nil {
		host = h
	}
	host = strings.Trim(host, "[]")
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// isLoopbackOrigin reports whether an Origin header refers back to this
// machine's loopback interface.
func isLoopbackOrigin(origin string) bool {
	u, err := url.Parse(origin)
	if err != nil || u.Host == "" {
		return false
	}
	return isLoopbackHostPort(u.Host)
}

// isForeignFetchSite reports whether a browser told us this request was issued
// by a page other than one this server served itself.
//
// Origin is not a substitute. Per Fetch, a no-cors request carries an Origin
// header only when its method is not GET or HEAD, so <img src>, <video src>,
// <script src> and <iframe src> pointing at 127.0.0.1 arrive with no Origin —
// the exact shape a drive-by page uses, and the one shape an Origin check
// cannot see. Sec-Fetch-Site is sent on every browser request (Chrome 76+,
// Firefox 90+, Safari 16.4+) and cannot be set by page script.
//
// "none" (the user typed the URL or opened a bookmark) and "same-origin" (a
// page this server served, of which there are none today) are the only values
// that are not a cross-document fetch, so they are the only ones allowed. An
// absent header means the caller is not a browser at all.
func isForeignFetchSite(site string) bool {
	switch strings.ToLower(strings.TrimSpace(site)) {
	case "", "none", "same-origin":
		return false
	default:
		return true
	}
}

// loopbackGuard blocks browser-driven and rebound requests. It runs before
// routing so it also covers unmatched paths.
func loopbackGuard(c *gin.Context) {
	if !isLoopbackHostPort(c.Request.Host) {
		c.AbortWithStatus(http.StatusForbidden)
		return
	}
	if origin := c.GetHeader("Origin"); origin != "" && !isLoopbackOrigin(origin) {
		c.AbortWithStatus(http.StatusForbidden)
		return
	}
	if isForeignFetchSite(c.GetHeader(FetchSiteHeader)) {
		c.AbortWithStatus(http.StatusForbidden)
		return
	}
	c.Next()
}

// presentedToken extracts the token from the header, an Authorization bearer,
// or the query string, in that order.
func presentedToken(c *gin.Context) string {
	if tok := c.GetHeader(TokenHeader); tok != "" {
		return tok
	}
	const bearer = "Bearer "
	if auth := c.GetHeader("Authorization"); len(auth) > len(bearer) &&
		strings.EqualFold(auth[:len(bearer)], bearer) {
		return auth[len(bearer):]
	}
	return c.Query(TokenQuery)
}

// hasValidToken fails closed: if no token was configured at launch, no
// presented token can match.
func hasValidToken(c *gin.Context) bool {
	want := settings.AuthToken
	got := presentedToken(c)
	if want == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

// tokenGuard fails closed: if no token was configured at launch, nothing can
// reach the endpoints it protects.
func tokenGuard(c *gin.Context) {
	if !hasValidToken(c) {
		c.AbortWithStatus(http.StatusUnauthorized)
		return
	}
	c.Next()
}

// openGuard protects the routes that cannot be behind tokenGuard because they
// are handed to an external media engine as a bare URL. It lets every request
// through, but marks the ones that did not present the per-launch token so the
// handlers can hold them to the capability they claim to have: play, or list,
// a torrent the user already added. Without the mark, /stream would happily
// call torr.AddTorrent on any link handed to it, which turns "can reach the
// port" — a web page, or any other process on the device — into "can make the
// user's client join, download and seed a swarm of my choosing".
func openGuard(c *gin.Context) {
	if !hasValidToken(c) {
		c.Set(CtxNotAuth, true)
	}
	c.Next()
}
