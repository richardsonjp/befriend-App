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

	skinSubmissionsCMD = &cobra.Command{
		Use:   "submissions",
		Short: "List artists' submissions waiting for review",
		Args:  cobra.NoArgs,
		Run: func(_ *cobra.Command, _ []string) {
			app.SkinSubmissions()
		},
	}

	skinSubmissionCMD = &cobra.Command{
		Use:   "submission <submission id>",
		Short: "Save a submission's upload to look at before approving it",
		Args:  cobra.ExactArgs(1),
		Run: func(c *cobra.Command, args []string) {
			out, _ := c.Flags().GetString("out")
			app.SkinSubmission(args[0], out)
		},
	}

	skinApproveCMD = &cobra.Command{
		Use:   "approve <submission id>",
		Short: "Publish a submission as its artist's skin (--tier N also puts it on sale)",
		Args:  cobra.ExactArgs(1),
		Run: func(c *cobra.Command, args []string) {
			tier, _ := c.Flags().GetInt("tier")
			app.SkinApprove(args[0], tier)
		},
	}

	skinPriceCMD = &cobra.Command{
		Use:   "price <skin id>",
		Short: "Put a published skin on sale in a price tier (--tier 0 takes it off sale)",
		Args:  cobra.ExactArgs(1),
		Run: func(c *cobra.Command, args []string) {
			tier, _ := c.Flags().GetInt("tier")
			app.SkinPrice(args[0], tier)
		},
	}

	skinRejectCMD = &cobra.Command{
		Use:   "reject <submission id>",
		Short: "Turn a submission down, telling the artist why",
		Args:  cobra.ExactArgs(1),
		Run: func(c *cobra.Command, args []string) {
			note, _ := c.Flags().GetString("note")
			app.SkinReject(args[0], note)
		},
	}

	artistCMD = &cobra.Command{
		Use:   "artist",
		Short: "Invite accounts to submit skins",
	}

	artistAddCMD = &cobra.Command{
		Use:   "add",
		Short: "Let an account submit skins",
		Args:  cobra.NoArgs,
		Run: func(c *cobra.Command, _ []string) {
			app.SetArtist(grantPayload(c), true)
		},
	}

	artistRemoveCMD = &cobra.Command{
		Use:   "remove",
		Short: "Stop an account submitting skins (its published skins stay)",
		Args:  cobra.NoArgs,
		Run: func(c *cobra.Command, _ []string) {
			app.SetArtist(grantPayload(c), false)
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
	for _, c := range []*cobra.Command{artistAddCMD, artistRemoveCMD} {
		c.Flags().String("email", "", "account email")
		c.Flags().String("user-id", "", "account user ID (for accounts without an email)")
	}
	skinSubmissionCMD.Flags().StringP("out", "o", "", "zip file to write")
	_ = skinSubmissionCMD.MarkFlagRequired("out")
	skinApproveCMD.Flags().Int("tier", 0, "price tier 1-9 to sell it in; 0 grants it only")
	skinPriceCMD.Flags().Int("tier", 0, "price tier 1-9; 0 takes it off sale")
	_ = skinPriceCMD.MarkFlagRequired("tier")
	skinRejectCMD.Flags().String("note", "", "why, for the artist (max 500 characters)")
	_ = skinRejectCMD.MarkFlagRequired("note")
	skinCMD.AddCommand(skinBuildCMD, skinPublishCMD, skinGrantCMD, skinRevokeCMD,
		skinSubmissionsCMD, skinSubmissionCMD, skinApproveCMD, skinRejectCMD, skinPriceCMD)
	artistCMD.AddCommand(artistAddCMD, artistRemoveCMD)

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
	rootCMD.AddCommand(artistCMD)
	rootCMD.AddCommand(harvestCMD)
	if err := rootCMD.Execute(); err != nil {
		os.Exit(1)
	}
}
