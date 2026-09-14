package main

import (
	"os"

	"github.com/spf13/cobra"

	"befriend/cmd/apiserver/app"
	"befriend/config"
	"befriend/internal/services/skin"
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

	evolveCMD = &cobra.Command{
		Use:   "evolve",
		Short: "Hourly job: activity retention and weekly friend evolution",
		Run: func(*cobra.Command, []string) {
			app.Evolve()
		},
	}

	skinCMD = &cobra.Command{
		Use:   "skin",
		Short: "Build, publish and grant character skins",
	}

	skinBuildCMD = &cobra.Command{
		Use:   "build <skin folder>",
		Short: "Pack a skin folder into a zip file (no database)",
		Args:  cobra.ExactArgs(1),
		Run: func(c *cobra.Command, args []string) {
			out, _ := c.Flags().GetString("out")
			app.SkinBuild(args[0], out)
		},
	}

	skinPublishCMD = &cobra.Command{
		Use:   "publish <skin folder>",
		Short: "Build a skin and store it as its next version",
		Args:  cobra.ExactArgs(1),
		Run: func(_ *cobra.Command, args []string) {
			app.SkinPublish(args[0])
		},
	}

	skinGrantCMD = &cobra.Command{
		Use:   "grant",
		Short: "Give an account a published skin",
		Args:  cobra.NoArgs,
		Run: func(c *cobra.Command, _ []string) {
			app.SkinGrant(grantPayload(c))
		},
	}

	skinRevokeCMD = &cobra.Command{
		Use:   "revoke",
		Short: "Take a skin away from an account (it falls back to the built-in skin)",
		Args:  cobra.NoArgs,
		Run: func(c *cobra.Command, _ []string) {
			app.SkinRevoke(grantPayload(c))
		},
	}
)

func grantPayload(c *cobra.Command) skin.GrantPayload {
	skinID, _ := c.Flags().GetString("skin")
	email, _ := c.Flags().GetString("email")
	userID, _ := c.Flags().GetString("user-id")
	return skin.GrantPayload{SkinID: skinID, Email: email, UserID: userID}
}

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

	skinBuildCMD.Flags().StringP("out", "o", "", "zip file to write")
	_ = skinBuildCMD.MarkFlagRequired("out")
	for _, c := range []*cobra.Command{skinGrantCMD, skinRevokeCMD} {
		c.Flags().String("skin", "", "skin id")
		c.Flags().String("email", "", "account email")
		c.Flags().String("user-id", "", "account user ID (for accounts without an email)")
		_ = c.MarkFlagRequired("skin")
	}
	skinCMD.AddCommand(skinBuildCMD, skinPublishCMD, skinGrantCMD, skinRevokeCMD)

	// Regist
	rootCMD.AddCommand(configCMD)
	rootCMD.AddCommand(serverCMD)
	rootCMD.AddCommand(migrateCMD)
	rootCMD.AddCommand(evolveCMD)
	rootCMD.AddCommand(skinCMD)
	if err := rootCMD.Execute(); err != nil {
		os.Exit(1)
	}
}
