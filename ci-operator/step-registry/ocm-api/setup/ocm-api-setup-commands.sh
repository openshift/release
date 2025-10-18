#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function logger() {
  local -r log_level=$1; shift
  local -r log_msg=$1; shift
  echo "$(date -u --rfc-3339=seconds) - ${log_level}: ${log_msg}"
}


trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export TEST_PROFILE=${TEST_PROFILE:-}
export VERSION=${VERSION:-}
export CHANNEL_GROUP=${CHANNEL_GROUP:-}
export NAME_PREFIX=${NAME_PREFIX:-}

ocmTempDir=$(mktemp -d)
cd $ocmTempDir
cat << 'EOF' > main.go
package main

import (
	"context"
	"database/sql"
	"fmt"

	// Add the pgx driver
	_ "github.com/jackc/pgx/v5/stdlib"
)

type User struct {
	ID   int
	Name string
}

type UserRepository struct {
	db *sql.DB
}

func NewUserRepository(db *sql.DB) *UserRepository {
	return &UserRepository{db: db}
}

func (r *UserRepository) FindUser(ctx context.Context, id int) (*User, error) {
	var user User
	err := r.db.QueryRowContext(ctx, "SELECT id, name FROM users WHERE id = $1", id).Scan(&user.ID, &user.Name)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, nil // User not found, not an error in this case
		}
		return nil, fmt.Errorf("failed to find user: %w", err)
	}
	return &user, nil
}

// main function to make the package runnable, can be empty
func main() {}
EOF

cat << 'EOF' > user_repository_test.go
package main

import (
	"context"
	"database/sql"
	"log"
	"os"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"
)

// Declare db and ctx at the package level so they are accessible to all tests
var db *sql.DB
var ctx = context.Background()

func TestMain(m *testing.M) {
	dbName := "testdb"
	dbUser := "user"
	dbPassword := "password"

	postgresContainer, err := postgres.RunContainer(ctx,
		testcontainers.WithImage("postgres:15-alpine"),
		postgres.WithDatabase(dbName),
		postgres.WithUsername(dbUser),
		postgres.WithPassword(dbPassword),
		testcontainers.WithWaitStrategy(wait.ForLog("database system is ready to accept connections").WithOccurrence(2).WithStartupTimeout(5*time.Second)),
	)
	if err != nil {
		log.Fatalf("failed to start postgres container: %v", err)
	}

	// Clean up the container
	defer func() {
		if err := postgresContainer.Terminate(ctx); err != nil {
			log.Fatalf("failed to terminate container: %v", err)
		}
	}()

	connStr, err := postgresContainer.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		log.Fatalf("failed to get connection string: %v", err)
	}

	// Assign the connection to the package-level db variable
	db, err = sql.Open("pgx", connStr)
	if err != nil {
		log.Fatalf("failed to connect to database: %v", err)
	}
	defer db.Close()

	// **Create the necessary table schema**
	_, err = db.ExecContext(ctx, `CREATE TABLE users (id INT PRIMARY KEY, name VARCHAR(50));`)
	if err != nil {
		log.Fatalf("failed to create table: %v", err)
	}

	// Run all tests and exit
	os.Exit(m.Run())
}

func TestUserRepository(t *testing.T) {
	// Truncate the table before each test run to ensure a clean state
	_, err := db.ExecContext(ctx, "TRUNCATE TABLE users")
	if err != nil {
		t.Fatalf("failed to truncate users table: %v", err)
	}
	
	repo := NewUserRepository(db)

	t.Run("FindExistingUser", func(t *testing.T) {
		// Arrange
		_, err := db.ExecContext(ctx, "INSERT INTO users (id, name) VALUES ($1, $2)", 1, "Alice")
		if err != nil {
			t.Fatalf("failed to insert test user: %v", err)
		}

		// Act
		user, err := repo.FindUser(ctx, 1)

		// Assert
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if user == nil || user.Name != "Alice" {
			t.Errorf("expected user with name Alice, got %v", user)
		}
	})

	t.Run("FindNonExistingUser", func(t *testing.T) {
		// Act
		user, err := repo.FindUser(ctx, 999)
		
		// Assert
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if user != nil {
			t.Errorf("expected nil user, got %v", user)
		}
	})
}
EOF

chmod +x *
wget  https://go.dev/dl/go1.24.9.linux-amd64.tar.gz
tar  -zxf go1.24.9.linux-amd64.tar.gz
export GO_TOOL_PATH=$ocmTempDir/go/bin
export PATH=$GO_TOOL_PATH/:$PATH
sleep 3600
go test -v -mod=mod
exit 0