package main

import (
	"os"

	"github.com/spf13/cobra"

	"go-skeleton/cmd/apiserver/app"
	"go-skeleton/config"
)

var (
	rootCMD = &cobra.Command{
		Short: "skeleton-go",
	}

	configCMD = &cobra.Command{
		Use:   "config",
		Short: "Show settings",
		Run: func(*cobra.Command, []string) {
			config.Show()
		},
	}

	serverCMD = &cobra.Command{
		Use:   "server",
		Short: "Run application server",
		Run: func(*cobra.Command, []string) {
			app.Run()
		},
	}

	migrateCMD = &cobra.Command{
		Use:   "migrate [command]",
		Short: "Run database migrations",
		Run: func(c *cobra.Command, args []string) {
			app.Migrate(args)
		},
	}
)

// @title           Antartech API
// @version         1.0
// @description     Antartech API documentation

// @host      localhost:7000

// @securityDefinitions.apikey ApiKeyAuth
// @in header
// @name Authorization

// @securityDefinitions.apikey StaticApiKey
// @in header
// @name STATIC-API-KEY
func main() {
	cobra.OnInitialize(config.Init)

	// Regist
	rootCMD.AddCommand(configCMD)
	rootCMD.AddCommand(serverCMD)
	rootCMD.AddCommand(migrateCMD)
	if err := rootCMD.Execute(); err != nil {
		os.Exit(1)
	}
}
