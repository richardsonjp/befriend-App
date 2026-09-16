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

	harvestCMD = &cobra.Command{
		Use:   "harvest",
		Short: "Build training data for befriend's own personality model",
	}

	harvestInputsCMD = &cobra.Command{
		Use:   "inputs",
		Short: "Write prompts for synthetic users, from the live question set",
		Args:  cobra.NoArgs,
		Run: func(c *cobra.Command, _ []string) {
			n, _ := c.Flags().GetInt("count")
			seed, _ := c.Flags().GetUint64("seed")
			out, _ := c.Flags().GetString("out")
			app.HarvestInputs(n, seed, out)
		},
	}

	harvestGrammarCMD = &cobra.Command{
		Use:   "grammar",
		Short: "Print the GBNF a served model must generate under",
		Args:  cobra.NoArgs,
		Run: func(c *cobra.Command, _ []string) {
			kind, _ := c.Flags().GetString("kind")
			app.HarvestGrammar(kind)
		},
	}

	harvestFilterCMD = &cobra.Command{
		Use:   "filter",
		Short: "Keep only the harvested personalities that pass Validate whole",
		Args:  cobra.NoArgs,
		Run: func(c *cobra.Command, _ []string) {
			inputs, _ := c.Flags().GetString("inputs")
			outputs, _ := c.Flags().GetString("outputs")
			out, _ := c.Flags().GetString("out")
			app.HarvestFilter(inputs, outputs, out)
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

	harvestInputsCMD.Flags().IntP("count", "n", 1200, "how many synthetic users")
	harvestInputsCMD.Flags().Uint64("seed", 1, "same seed, same users: lets a harvest be extended")
	harvestInputsCMD.Flags().StringP("out", "o", "inputs.jsonl", "prompts file to write")
	harvestFilterCMD.Flags().String("inputs", "inputs.jsonl", "prompts written by `harvest inputs`")
	harvestFilterCMD.Flags().String("outputs", "outputs.jsonl", "answers written by the Mac harvester")
	harvestFilterCMD.Flags().StringP("out", "o", "dataset.jsonl", "training samples to write")
	harvestGrammarCMD.Flags().String("kind", "chunk", "chunk or profile")
	harvestCMD.AddCommand(harvestInputsCMD, harvestGrammarCMD, harvestFilterCMD)

	// Regist
	rootCMD.AddCommand(configCMD)
	rootCMD.AddCommand(serverCMD)
	rootCMD.AddCommand(migrateCMD)
	rootCMD.AddCommand(evolveCMD)
	rootCMD.AddCommand(skinCMD)
	rootCMD.AddCommand(harvestCMD)
	if err := rootCMD.Execute(); err != nil {
		os.Exit(1)
	}
}
