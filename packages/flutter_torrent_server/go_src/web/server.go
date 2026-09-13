package web

import (
	"net"
	"net/http"
	"os"
	"sort"

	"github.com/gin-contrib/location"
	"github.com/gin-gonic/gin"

	"server/settings"

	"server/log"
	"server/torr"
	"server/version"
	"server/web/api"
)

// LoopbackHost is the only interface the HTTP API is ever bound to.
const LoopbackHost = "127.0.0.1"

var (
	BTS        = torr.NewBTS()
	waitChan   = make(chan error)
	httpServer *http.Server
)

//	@title			Swagger Torrserver API
//	@version		{version.Version}
//	@description	Torrent streaming server.

//	@license.name	GPL 3.0

//	@BasePath	/

//	@securityDefinitions.basic	BasicAuth

// @externalDocs.description	OpenAPI
// @externalDocs.url			https://swagger.io/resources/open-api/
func Start() {
	log.TLogln("Start TorrServer " + version.Version + " torrent " + version.GetTorrentVersion())
	ips := getLocalIps()
	if len(ips) > 0 {
		log.TLogln("Local IPs:", ips)
	}
	err := BTS.Connect()
	if err != nil {
		log.TLogln("BTS.Connect() error!", err) // waitChan <- err
		os.Exit(1)                              // return
	}

	gin.SetMode(gin.ReleaseMode)

	httpServer = &http.Server{
		Addr:    listenAddr(),
		Handler: newRouter(),
	}

	go func() {
		log.TLogln("Start http server at", httpServer.Addr)
		httpServer.ListenAndServe()
		//waitChan <- route.Run(" :" + settings.Port)
	}()
}

// listenAddr is loopback only. A bare ":port" listens on every interface,
// which put the user's torrent library on the cafe/hotel/office Wi-Fi for
// anyone who scanned the subnet.
func listenAddr() string {
	return net.JoinHostPort(LoopbackHost, settings.Port)
}

// newRouter builds the HTTP API. Split out of Start so the guards and the
// route table can be exercised without a torrent engine or a database.
func newRouter() *gin.Engine {
	// No CORS middleware. This server has no browser client; the previous
	// AllowAllOrigins configuration handed "Access-Control-Allow-Origin: *"
	// to any page the user happened to have open, which could then read the
	// whole torrent library. loopbackGuard replaces it with something
	// stricter: a foreign Origin, or a Host that is not loopback, is refused
	// outright rather than merely being denied the response.
	route := gin.New()
	route.Use(log.WebLogger(), gin.Recovery(), loopbackGuard, location.Default())

	// Liveness probe only: returns a static version string and no user data.
	// It stays unauthenticated so a launcher can detect a live server before
	// it knows that server's token.
	route.GET("/echo", echo)

	// The open group is not unguarded: openGuard marks a request that carries
	// no valid token, and the streaming handlers then refuse to add a torrent
	// the user never asked for. See auth.go.
	api.SetupRoute(route.Group("", openGuard), route.Group("", tokenGuard))
	return route
}

func Wait() error {
	return <-waitChan
}

func Stop() {
	if httpServer != nil {
		httpServer.Close()
	}
	BTS.Disconnect()
	//waitChan <- nil
}

// echo godoc
//
//	@Summary		Tests server status
//	@Description	Tests whether server is alive or not
//
//	@Tags			API
//
//	@Produce		plain
//	@Success		200	{string}	string	"Server version"
//	@Router			/echo [get]
func echo(c *gin.Context) {
	c.String(200, "%v", version.Version)
}

func getLocalIps() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		log.TLogln("Error get local IPs")
		return nil
	}
	var list []string
	for _, i := range ifaces {
		addrs, _ := i.Addrs()
		if i.Flags&net.FlagUp == net.FlagUp {
			for _, addr := range addrs {
				var ip net.IP
				switch v := addr.(type) {
				case *net.IPNet:
					ip = v.IP
				case *net.IPAddr:
					ip = v.IP
				}
				if !ip.IsLoopback() && !ip.IsLinkLocalUnicast() && !ip.IsLinkLocalMulticast() {
					list = append(list, ip.String())
				}
			}
		}
	}
	sort.Strings(list)
	return list
}
