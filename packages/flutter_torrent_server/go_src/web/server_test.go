package web

import (
	"crypto/sha1"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/gin-gonic/gin"

	"server/settings"
	"server/torr"
)

const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func init() {
	gin.SetMode(gin.TestMode)
}

// withToken installs a known per-launch token for the duration of a test.
func withToken(t *testing.T, tok string) {
	t.Helper()
	prev := settings.AuthToken
	settings.AuthToken = tok
	t.Cleanup(func() { settings.AuthToken = prev })
}

// do issues a request against the real route table. Nothing here reaches a
// handler unless the guards let it through, which is the point.
func do(r *gin.Engine, method, target string, mutate func(*http.Request)) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, strings.NewReader(`{"action":"list"}`))
	req.Host = "127.0.0.1:8090"
	req.Header.Set("Content-Type", "application/json")
	if mutate != nil {
		mutate(req)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

// privilegedRoutes is every endpoint that can enumerate, mutate or shut down
// the user's torrent library. /shutdown is exercised with ReadOnly set so that
// an ablation run cannot actually tear the engine down mid-suite.
var privilegedRoutes = []struct {
	method string
	path   string
}{
	{http.MethodGet, "/shutdown"},
	{http.MethodPost, "/settings"},
	{http.MethodPost, "/torrents"},
	{http.MethodPost, "/torrent/upload"},
	{http.MethodPost, "/cache"},
	{http.MethodPost, "/viewed"},
	{http.MethodGet, "/playlistall/all.m3u"},
	{http.MethodGet, "/download/1"},
}

// TestListenAddrIsLoopbackOnly pins the bind address itself. The shipped
// server used `":" + port`, which binds every interface, so the whole Wi-Fi
// segment could reach the API.
func TestListenAddrIsLoopbackOnly(t *testing.T) {
	prev := settings.Port
	settings.Port = "8090"
	t.Cleanup(func() { settings.Port = prev })

	addr := listenAddr()
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatalf("listenAddr() = %q, which is not a host:port pair: %v", addr, err)
	}
	if port != "8090" {
		t.Fatalf("listenAddr() = %q, want port 8090", addr)
	}
	ip := net.ParseIP(host)
	if ip == nil {
		t.Fatalf("listenAddr() = %q: host %q is not an IP literal, so the listener is not pinned to an interface", addr, host)
	}
	if !ip.IsLoopback() {
		t.Fatalf("listenAddr() = %q: host %q is not a loopback address", addr, host)
	}
}

// TestListenAddrIsUnreachableOffLoopback is the same claim, proved by actually
// binding: a socket opened at listenAddr() must not answer on this machine's
// LAN address.
func TestListenAddrIsUnreachableOffLoopback(t *testing.T) {
	lanIP := firstNonLoopbackIPv4(t)
	if lanIP == "" {
		t.Skip("host has no non-loopback IPv4 address")
	}

	// Pick a free port, then bind it the way Start() would.
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("probe listen: %v", err)
	}
	_, port, _ := net.SplitHostPort(probe.Addr().String())
	probe.Close()

	prev := settings.Port
	settings.Port = port
	t.Cleanup(func() { settings.Port = prev })

	ln, err := net.Listen("tcp", listenAddr())
	if err != nil {
		t.Fatalf("listen on %q: %v", listenAddr(), err)
	}
	defer ln.Close()

	if c, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", port)); err != nil {
		t.Fatalf("loopback client cannot reach the server on %s: %v", port, err)
	} else {
		c.Close()
	}

	c, err := net.Dial("tcp", net.JoinHostPort(lanIP, port))
	if err == nil {
		c.Close()
		t.Fatalf("the server answered on %s:%s — anyone on this Wi-Fi can reach the torrent API", lanIP, port)
	}
}

func firstNonLoopbackIPv4(t *testing.T) string {
	t.Helper()
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	for _, a := range addrs {
		n, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ip := n.IP.To4()
		if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
			continue
		}
		return ip.String()
	}
	return ""
}

// TestPrivilegedRoutesRejectMissingToken is the enumeration defence: without
// the per-launch token nothing can list, add, remove or shut down torrents.
func TestPrivilegedRoutesRejectMissingToken(t *testing.T) {
	withToken(t, testToken)
	settings.ReadOnly = true
	t.Cleanup(func() { settings.ReadOnly = false })
	r := newRouter()

	for _, rt := range privilegedRoutes {
		t.Run(rt.method+" "+rt.path, func(t *testing.T) {
			w := do(r, rt.method, rt.path, nil)
			if w.Code != http.StatusUnauthorized {
				t.Fatalf("%s %s without a token returned %d, want 401 — this endpoint is reachable by any local process", rt.method, rt.path, w.Code)
			}
		})
	}
}

// TestPrivilegedRoutesRejectWrongToken guards against an empty or sloppy
// comparison letting anything through.
func TestPrivilegedRoutesRejectWrongToken(t *testing.T) {
	withToken(t, testToken)
	r := newRouter()

	for _, tok := range []string{"", "wrong", testToken[:len(testToken)-1], testToken + "x"} {
		w := do(r, http.MethodGet, "/playlistall/all.m3u", func(req *http.Request) {
			req.Header.Set(TokenHeader, tok)
		})
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("/playlistall/all.m3u with token %q returned %d, want 401", tok, w.Code)
		}
	}
}

// TestTokenGuardFailsClosed: if no token was configured at launch, the
// privileged surface is shut, not open.
func TestTokenGuardFailsClosed(t *testing.T) {
	withToken(t, "")
	r := newRouter()

	for _, tok := range []string{"", "anything"} {
		w := do(r, http.MethodGet, "/playlistall/all.m3u", func(req *http.Request) {
			req.Header.Set(TokenHeader, tok)
		})
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("with no configured token, /playlistall/all.m3u returned %d for %q, want 401", w.Code, tok)
		}
	}
}

// TestPrivilegedRoutesAcceptToken: the app must still be able to drive the
// server. All three presentation forms have a caller — header for the Kotlin,
// Swift and Dart plugins, query for anything that can only be handed a URL.
func TestPrivilegedRoutesAcceptToken(t *testing.T) {
	withToken(t, testToken)
	r := newRouter()

	cases := map[string]func(*http.Request){
		"header": func(req *http.Request) { req.Header.Set(TokenHeader, testToken) },
		"bearer": func(req *http.Request) { req.Header.Set("Authorization", "Bearer "+testToken) },
		"query":  nil,
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			target := "/download/1"
			if name == "query" {
				target += "?" + TokenQuery + "=" + testToken
			}
			w := do(r, http.MethodGet, target, mutate)
			if w.Code != http.StatusOK {
				t.Fatalf("GET %s with a valid %s token returned %d, want 200", target, name, w.Code)
			}
		})
	}
}

// TestStreamRoutesStayOpen: libVLC, mpv and Infuse are handed a bare URL and
// cannot attach a header. They are capability-protected by the infohash
// instead, so they must not be behind the token guard.
func TestStreamRoutesStayOpen(t *testing.T) {
	withToken(t, testToken)
	r := newRouter()

	for _, target := range []string{"/stream?link=abc&index=1&play", "/play/abc/1", "/playlist?hash=abc"} {
		w := do(r, http.MethodGet, target, nil)
		if w.Code == http.StatusUnauthorized {
			t.Fatalf("GET %s returned 401 — the media engine cannot present a token, playback would break", target)
		}
	}
}

// TestEchoStaysOpen: the desktop launcher probes /echo before it knows a
// token. It returns a version string and nothing about the user.
func TestEchoStaysOpen(t *testing.T) {
	withToken(t, testToken)
	r := newRouter()

	w := do(r, http.MethodGet, "/echo", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("GET /echo returned %d, want 200", w.Code)
	}
}

// TestForeignOriginIsRejectedWithoutCorsHeaders is the drive-by defence. The
// shipped server answered 200 with "Access-Control-Allow-Origin: *", so any
// page the user had open could read the torrent list.
func TestForeignOriginIsRejectedWithoutCorsHeaders(t *testing.T) {
	withToken(t, testToken)
	r := newRouter()

	for _, method := range []string{http.MethodPost, http.MethodOptions} {
		w := do(r, method, "/torrents", func(req *http.Request) {
			req.Header.Set("Origin", "https://evil.example")
			req.Header.Set("Access-Control-Request-Method", "POST")
		})
		if w.Code != http.StatusForbidden {
			t.Fatalf("%s /torrents from https://evil.example returned %d, want 403", method, w.Code)
		}
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != "" {
			t.Fatalf("%s /torrents answered a foreign origin with Access-Control-Allow-Origin: %q", method, got)
		}
	}
}

// TestForeignOriginIsRejectedOnStreamRoutes: the open routes are guarded too,
// so a page that sends an Origin cannot pull bytes out of the user's torrent.
// This is only half the browser story — see the test below for the half that
// carries no Origin at all.
func TestForeignOriginIsRejectedOnStreamRoutes(t *testing.T) {
	withToken(t, testToken)
	r := newRouter()

	w := do(r, http.MethodGet, "/stream?link=abc&index=1&play", func(req *http.Request) {
		req.Header.Set("Origin", "https://evil.example")
	})
	if w.Code != http.StatusForbidden {
		t.Fatalf("GET /stream from https://evil.example returned %d, want 403", w.Code)
	}
}

// TestBrowserSubresourceGetIsRejectedWithoutOrigin is the request shape a
// drive-by page actually produces, and the one an Origin check cannot see: per
// Fetch, a no-cors request carries Origin only when its method is not GET or
// HEAD, so <img src>, <video src>, <script src> and <iframe src> aimed at
// 127.0.0.1:8090 arrive with no Origin header whatsoever. Sec-Fetch-Site is
// what gives them away.
func TestBrowserSubresourceGetIsRejectedWithoutOrigin(t *testing.T) {
	withToken(t, testToken)
	r := newRouter()

	shapes := map[string]map[string]string{
		"<video src> cross-site": {"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Dest": "video"},
		"<img src> cross-site":   {"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Dest": "image"},
		"<iframe src> same-site": {"Sec-Fetch-Site": "same-site", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "iframe"},
		"fetch() cross-site":     {"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty"},
	}
	targets := []string{
		"/stream?link=abc&index=1&play",
		"/stream/movie.mkv?link=abc&index=1&play",
		"/stream?link=abc&stat",
		"/play/abc/1",
		"/playlist?hash=abc",
		"/echo",
	}

	for name, headers := range shapes {
		for _, target := range targets {
			t.Run(name+" "+target, func(t *testing.T) {
				w := do(r, http.MethodGet, target, func(req *http.Request) {
					for k, v := range headers {
						req.Header.Set(k, v)
					}
				})
				if w.Code != http.StatusForbidden {
					t.Fatalf("GET %s from a page (%v, no Origin) returned %d, want 403 — a page the user merely visited reached the torrent engine", target, headers, w.Code)
				}
			})
		}
	}
}

// TestNonBrowserCallersKeepWorking: the guard above keys on a header only a
// browser sends. libVLC, mpv, Infuse and the app's own HTTP client send none
// of it, and a URL the user pasted into the address bar is Sec-Fetch-Site:
// none. All of those must still be served.
func TestNonBrowserCallersKeepWorking(t *testing.T) {
	withToken(t, testToken)
	r := newRouter()

	cases := map[string]func(*http.Request){
		"media engine (no Fetch Metadata at all)": nil,
		"address bar": func(req *http.Request) {
			req.Header.Set("Sec-Fetch-Site", "none")
			req.Header.Set("Sec-Fetch-Mode", "navigate")
		},
		"a page this server served itself": func(req *http.Request) {
			req.Header.Set("Sec-Fetch-Site", "same-origin")
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			w := do(r, http.MethodGet, "/echo", mutate)
			if w.Code != http.StatusOK {
				t.Fatalf("GET /echo as %s returned %d, want 200", name, w.Code)
			}
		})
	}
}

// TestRebindingHostIsRejected: DNS rebinding makes an attacker page
// same-origin with 127.0.0.1, which no CORS policy can stop. The Host header
// still names the attacker, so that is what we check.
func TestRebindingHostIsRejected(t *testing.T) {
	withToken(t, testToken)
	r := newRouter()

	for _, host := range []string{"attacker.example:8090", "192.168.0.18:8090", "torrserver.local:8090"} {
		w := do(r, http.MethodGet, "/echo", func(req *http.Request) { req.Host = host })
		if w.Code != http.StatusForbidden {
			t.Fatalf("request with Host %q returned %d, want 403", host, w.Code)
		}
	}
}

// TestLoopbackHostsAreAccepted keeps the guard from locking out real callers.
func TestLoopbackHostsAreAccepted(t *testing.T) {
	withToken(t, testToken)
	r := newRouter()

	for _, host := range []string{"127.0.0.1:8090", "localhost:8090", "[::1]:8090", "127.0.0.1"} {
		w := do(r, http.MethodGet, "/echo", func(req *http.Request) { req.Host = host })
		if w.Code != http.StatusOK {
			t.Fatalf("request with Host %q returned %d, want 200", host, w.Code)
		}
	}
}

func TestIsLoopbackHostPort(t *testing.T) {
	yes := []string{"", "127.0.0.1:8090", "127.0.0.1", "localhost:8090", "LocalHost", "[::1]:8090", "::1", "127.9.9.9:1"}
	no := []string{"192.168.0.18:8090", "attacker.example:8090", "0.0.0.0:8090", "10.0.0.5", "evil.localhost.example:80"}
	for _, h := range yes {
		if !isLoopbackHostPort(h) {
			t.Errorf("isLoopbackHostPort(%q) = false, want true", h)
		}
	}
	for _, h := range no {
		if isLoopbackHostPort(h) {
			t.Errorf("isLoopbackHostPort(%q) = true, want false", h)
		}
	}
}

func TestIsLoopbackOrigin(t *testing.T) {
	yes := []string{"http://127.0.0.1:8090", "http://localhost:8090", "http://[::1]:8090"}
	no := []string{"", "null", "https://evil.example", "http://192.168.0.18:8090", "file://"}
	for _, o := range yes {
		if !isLoopbackOrigin(o) {
			t.Errorf("isLoopbackOrigin(%q) = false, want true", o)
		}
	}
	for _, o := range no {
		if isLoopbackOrigin(o) {
			t.Errorf("isLoopbackOrigin(%q) = true, want false", o)
		}
	}
}

func TestNewAuthTokenIsRandomAndLongEnough(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 32; i++ {
		tok := NewAuthToken()
		if len(tok) != 64 {
			t.Fatalf("NewAuthToken() = %q (len %d), want 64 hex chars", tok, len(tok))
		}
		if seen[tok] {
			t.Fatalf("NewAuthToken() repeated %q", tok)
		}
		seen[tok] = true
	}
}

// withOfflineEngine gives the API handlers a real torrent engine that cannot
// talk to anything: TCP, uTP, DHT, UPnP and tracker injection are all off and
// the public IP is hard-coded, so torrent.NewClient opens no socket and makes
// no network call (it returns in well under a millisecond). That is enough for
// the only question these tests ask — did the request get far enough to put a
// torrent into the engine?
func withOfflineEngine(t *testing.T) *torr.BTServer {
	t.Helper()

	prevPath, prevIP := settings.Path, settings.PubIPv4
	settings.Path = t.TempDir()
	settings.InitSets(false, false)
	settings.PubIPv4 = "203.0.113.9" // TEST-NET-3: skips the publicip lookup
	settings.BTsets.EnableIPv6 = false
	settings.BTsets.DisableTCP = true
	settings.BTsets.DisableUTP = true
	settings.BTsets.DisableDHT = true
	settings.BTsets.DisableUPNP = true
	settings.BTsets.RetrackersMode = 2 // 2 = strip trackers; 1 would fetch a list over HTTP

	bt := torr.NewBTS()
	if err := bt.Connect(); err != nil {
		t.Fatalf("offline engine: %v", err)
	}
	t.Cleanup(func() {
		bt.Disconnect()
		settings.CloseDB()
		settings.Path, settings.PubIPv4 = prevPath, prevIP
	})
	return bt
}

// engineHolds waits up to a second for the engine to hold hash, and reports
// whether it does. Adding a torrent is synchronous inside the handler, but the
// handler itself runs in another goroutine here, so the poll is for that.
func engineHolds(bt *torr.BTServer, hash string) bool {
	want := metainfo.NewHashFromHex(hash)
	for i := 0; i < 100; i++ {
		if bt.GetTorrent(want) != nil {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return false
}

// TestUnauthenticatedStreamCannotAddATorrent is the drive-by torrent
// injection. /stream is deliberately outside tokenGuard, and the argument for
// that is a capability one: the caller must already know the 160-bit infohash
// of a torrent the user added. The argument only holds if /stream cannot mint
// the torrent itself — it used to, by handing whatever `link` it was given to
// torr.AddTorrent, so one <video src="http://127.0.0.1:8090/stream?link=..."
// on any page the user visited (or any other process on the device, with no
// browser involved at all) made the user's client join, download and seed a
// swarm of the attacker's choosing, from the user's home IP, with nothing
// shown in the UI.
//
// The request here carries no Origin and no Fetch Metadata, i.e. it is the
// non-browser case that the Sec-Fetch guard does not cover.
func TestUnauthenticatedStreamCannotAddATorrent(t *testing.T) {
	withToken(t, testToken)
	bt := withOfflineEngine(t)
	r := newRouter()

	// A 160-bit infohash the user has never seen. Any value works: this is
	// the attacker's own content.
	const attacker = "4e96298b42b55490de67962d6f87c744d8920cae"
	target := "/stream?link=" + attacker + "&index=0&play&save&title=pwned"

	// Without the guard the handler blocks in GotInfo() for five minutes
	// before it answers, so the response is collected in the background and
	// the engine is what gets asserted on.
	codes := make(chan int, 1)
	go func() { codes <- do(r, http.MethodGet, target, nil).Code }()

	var code int
	answered := false
	deadline := time.Now().Add(5 * time.Second)
	for !answered && time.Now().Before(deadline) {
		if bt.GetTorrent(metainfo.NewHashFromHex(attacker)) != nil {
			break
		}
		select {
		case code = <-codes:
			answered = true
		default:
			time.Sleep(10 * time.Millisecond)
		}
	}

	if tor := bt.GetTorrent(metainfo.NewHashFromHex(attacker)); tor != nil {
		t.Fatalf("an unauthenticated GET %s made the engine join swarm %s (%q) — a page the user merely visited can put arbitrary torrents in the library", target, attacker, tor.Title)
	}
	if !answered {
		t.Fatalf("GET %s never answered within 5s", target)
	}
	if code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated GET %s for an unknown infohash returned %d, want 401", target, code)
	}
	if list := torr.ListTorrent(); len(list) != 0 {
		t.Fatalf("unauthenticated GET %s left %d torrent(s) in the library, want 0", target, len(list))
	}
}

// TestSavedTorrentStillStreamsWithoutAToken is the other side of the same
// coin, and the reason the fix is not simply "put /stream behind tokenGuard":
// libVLC, mpv and Infuse are handed a bare URL and cannot present a token, so
// a torrent the user did add must still play without one.
func TestSavedTorrentStillStreamsWithoutAToken(t *testing.T) {
	withToken(t, testToken)
	bt := withOfflineEngine(t)
	r := newRouter()

	// A torrent the user added and saved: it is in the library database,
	// which is what tells "replay what I have" from "join this swarm".
	const mine = "8c2a1f3b4d5e6a7b8c9d0e1f2a3b4c5d6e7f8091"
	settings.AddTorrent(&settings.TorrentDB{
		TorrentSpec: &torrent.TorrentSpec{InfoHash: metainfo.NewHashFromHex(mine)},
		Title:       "the user's own torrent",
		Timestamp:   time.Now().Unix(),
	})

	// Same shape the app hands libVLC: no token, no Origin, no Fetch Metadata.
	go do(r, http.MethodGet, "/stream?link="+mine+"&index=0&play", nil)

	if !engineHolds(bt, mine) {
		t.Fatalf("GET /stream for a torrent the user added never reached the engine — the user's own playback is broken")
	}
}

// TestInMemoryTorrentStillStreamsWithoutAToken covers the shape the app
// actually uses, which the saved-torrent case above does not. SkyStream adds
// its torrents with save_to_db unset — the payload the Dart, Kotlin and Swift
// plugins send is {"action":"add","link":...} and nothing else — so the
// torrent the media engine is then handed a URL for lives only in the engine's
// memory and never reaches the library database. A capability check written as
// "is it in the database?" would satisfy the test above and still break every
// real playback, so pin that the engine's own list counts as "the user added
// this".
func TestInMemoryTorrentStillStreamsWithoutAToken(t *testing.T) {
	withToken(t, testToken)
	withOfflineEngine(t)
	r := newRouter()

	hash := addInMemoryTorrent(t)

	// m3u, not play: same authorization decision, but it answers out of the
	// metainfo instead of blocking on peers this offline engine cannot have.
	w := do(r, http.MethodGet, "/stream?link="+hash+"&m3u", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("unauthenticated GET /stream?link=<torrent the app added>&m3u returned %d, want 200 — libVLC cannot present a token, so this is the user's own playback failing", w.Code)
	}
	if body := w.Body.String(); !strings.HasPrefix(body, "#EXTM3U") {
		t.Fatalf("playlist body = %q, want an M3U", body)
	}
}

// addInMemoryTorrent registers a torrent the way /torrents?action=add does,
// with complete metainfo so the offline engine needs no peers to answer for
// it, and without writing anything to the library database.
func addInMemoryTorrent(t *testing.T) string {
	t.Helper()
	info := metainfo.Info{
		Name:        "movie.mkv",
		Length:      1 << 16,
		PieceLength: 1 << 15,
	}
	var pieces []byte
	for i := int64(0); i < info.Length/info.PieceLength; i++ {
		sum := sha1.Sum(make([]byte, info.PieceLength))
		pieces = append(pieces, sum[:]...)
	}
	info.Pieces = pieces
	infoBytes, err := bencode.Marshal(info)
	if err != nil {
		t.Fatalf("bencode info: %v", err)
	}
	spec := torrent.TorrentSpecFromMetaInfo(&metainfo.MetaInfo{InfoBytes: infoBytes})
	tor, err := torr.AddTorrent(spec, "Movie", "", "")
	if err != nil {
		t.Fatalf("AddTorrent: %v", err)
	}
	if !tor.GotInfo() {
		t.Fatalf("the engine did not accept a torrent with complete metainfo")
	}
	if torr.GetTorrentDB(spec.InfoHash) != nil {
		t.Fatalf("setup error: the torrent reached the database; the app's add path does not save")
	}
	return spec.InfoHash.HexString()
}
