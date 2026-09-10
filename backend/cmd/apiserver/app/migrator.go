package app

import (
	"fmt"
	"befriend/config"
	"os"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/postgres"
	_ "github.com/golang-migrate/migrate/v4/source/file"
)

// Migrate runs database migrations
// direction: "up", "down", "force <version>"
func Migrate(args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: migrate <up|down|force|version> [arg]")
		os.Exit(1)
	}

	command := args[0]
	// Construct DSN
	dsn := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=%s",
		config.Config.DB.Username,
		config.Config.DB.Password,
		config.Config.DB.Host,
		config.Config.DB.Port,
		config.Config.DB.Name,
		config.Config.DB.SSLMode,
	)

	m, err := migrate.New(
		"file://cmd/apiserver/app/migrations",
		dsn,
	)
	if err != nil {
		fmt.Printf("Migration init failed: %v\n", err)
		os.Exit(1)
	}
	defer m.Close()

	switch command {
	case "up":
		if err := m.Up(); err != nil && err != migrate.ErrNoChange {
			fmt.Printf("Migrate up failed: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("Migration up completed")
	case "down":
		if err := m.Down(); err != nil && err != migrate.ErrNoChange {
			fmt.Printf("Migrate down failed: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("Migration down completed")
	case "version":
		version, dirty, err := m.Version()
		if err != nil {
			fmt.Printf("Check version failed: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Version: %d, Dirty: %v\n", version, dirty)
	case "force":
		if len(args) < 2 {
			fmt.Println("Force requires a version argument")
			os.Exit(1)
		}
		// In a real CLI validation of args[1] to int would be good, but simple for now
		// m.Force wants int, but let's just error if complex.
		// For now let's skip complex parsing and just assume user knows.
		// Actually, let's implement minimal parsing
		var v int
		_, err := fmt.Sscanf(args[1], "%d", &v)
		if err != nil {
			fmt.Printf("Invalid version: %v\n", err)
			os.Exit(1)
		}
		if err := m.Force(v); err != nil {
			fmt.Printf("Force failed: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("Force completed")
	default:
		fmt.Printf("Unknown command: %s\n", command)
		os.Exit(1)
	}
}
