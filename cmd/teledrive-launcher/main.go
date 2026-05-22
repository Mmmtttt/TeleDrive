package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
)

type layout struct {
	root       string
	bin        string
	runtimeDir string
	postgres   string
	data       string
	config     string
	logs       string
}

type processSpec struct {
	name string
	path string
	args []string
	env  []string
	log  string
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "TeleDrive launcher error: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	command := "start"
	if len(os.Args) > 1 {
		command = strings.ToLower(os.Args[1])
	}
	switch command {
	case "start", "run":
		return start()
	case "init":
		l, err := resolveLayout()
		if err != nil {
			return err
		}
		return ensureConfig(l)
	case "version", "--version", "-v":
		fmt.Println("TeleDrive native launcher")
		return nil
	default:
		return fmt.Errorf("unknown command %q; use start or init", command)
	}
}

func start() error {
	l, err := resolveLayout()
	if err != nil {
		return err
	}
	if err := ensureDirs(l); err != nil {
		return err
	}
	if err := ensureConfig(l); err != nil {
		return err
	}
	if err := ensurePostgresRuntime(l); err != nil {
		return err
	}
	if err := initPostgres(l); err != nil {
		return err
	}
	if err := startPostgres(l); err != nil {
		return err
	}
	defer stopPostgres(l)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	specs := []processSpec{
		{
			name: "teldrive",
			path: binPath(l, "teldrive"),
			args: []string{"run", "-c", filepath.Join(l.config, "config.toml")},
			log:  filepath.Join(l.logs, "teldrive.log"),
		},
		{
			name: "importer",
			path: binPath(l, "teledrive-importer"),
			env: []string{
				"CONFIG_PATH=" + filepath.Join(l.config, "config.toml"),
				"IMPORTER_ADDR=127.0.0.1:8891",
				"IMPORT_FOLDER=Telegram Imports",
				"DEFAULT_LIMIT=100",
				"POLL_INTERVAL_SECONDS=0",
			},
			log: filepath.Join(l.logs, "importer.log"),
		},
		{
			name: "bridge",
			path: binPath(l, "teledrive-bridge"),
			env: []string{
				"CONFIG_PATH=" + filepath.Join(l.config, "config.toml"),
				"BRIDGE_ADDR=127.0.0.1:8892",
				"TELDRIVE_ORIGIN=http://127.0.0.1:8787",
				"IMPORTER_ORIGIN=http://127.0.0.1:8891",
			},
			log: filepath.Join(l.logs, "bridge.log"),
		},
	}

	procs, err := startProcesses(ctx, specs)
	if err != nil {
		return err
	}
	defer stopProcesses(procs)

	fmt.Println("TeleDrive native stack is starting.")
	fmt.Println("Teldrive: http://127.0.0.1:8787")
	fmt.Println("Importer: http://127.0.0.1:8891")
	fmt.Println("Bridge:   http://127.0.0.1:8892")
	fmt.Println("Press Ctrl+C to stop all services.")

	go openBrowser("http://127.0.0.1:8787")
	<-ctx.Done()
	fmt.Println()
	fmt.Println("Stopping TeleDrive...")
	return nil
}

func resolveLayout() (layout, error) {
	exe, err := os.Executable()
	if err != nil {
		return layout{}, err
	}
	root := filepath.Dir(exe)
	if filepath.Base(root) == "bin" {
		root = filepath.Dir(root)
	}
	return layout{
		root:       root,
		bin:        filepath.Join(root, "bin"),
		runtimeDir: filepath.Join(root, "runtime"),
		postgres:   filepath.Join(root, "runtime", "postgres"),
		data:       filepath.Join(root, "data"),
		config:     filepath.Join(root, "config"),
		logs:       filepath.Join(root, "logs"),
	}, nil
}

func ensureDirs(l layout) error {
	for _, dir := range []string{l.data, filepath.Join(l.data, "postgres"), l.config, l.logs} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return err
		}
	}
	return nil
}

func ensureConfig(l layout) error {
	if err := os.MkdirAll(l.config, 0755); err != nil {
		return err
	}
	target := filepath.Join(l.config, "config.toml")
	if fileExists(target) {
		return nil
	}
	template := filepath.Join(l.root, "config", "config.template.toml")
	if !fileExists(template) {
		template = filepath.Join(l.root, "config.template.toml")
	}
	if !fileExists(template) {
		return fmt.Errorf("missing config template at %s", template)
	}
	data, err := os.ReadFile(template)
	if err != nil {
		return err
	}
	password := randomSecret()
	jwt := randomSecret()
	dsn := fmt.Sprintf("postgres://teldrive:%s@127.0.0.1:55432/postgres?sslmode=disable", urlEscape(password))
	content := string(data)
	content = strings.ReplaceAll(content, "{{DB_DSN}}", dsn)
	content = strings.ReplaceAll(content, "{{POSTGRES_PASSWORD}}", password)
	content = strings.ReplaceAll(content, "{{JWT_SECRET}}", jwt)
	content = strings.ReplaceAll(content, "{{TG_APP_ID}}", "2496")
	content = strings.ReplaceAll(content, "{{TG_APP_HASH}}", "8da85b0d5bfe62527e5b244c209159c3")
	content = strings.ReplaceAll(content, "{{LOG_DIR}}", filepath.ToSlash(l.logs))
	if err := os.WriteFile(target, []byte(content), 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(l.config, "postgres-password"), []byte(password), 0600); err != nil {
		return err
	}
	return nil
}

func ensurePostgresRuntime(l layout) error {
	for _, name := range []string{"pg_ctl", "initdb", "psql"} {
		if !fileExists(postgresBin(l, name)) {
			return fmt.Errorf("missing PostgreSQL runtime binary %q under %s; use a native release package that includes runtime/postgres", name, l.postgres)
		}
	}
	return nil
}

func initPostgres(l layout) error {
	pgData := filepath.Join(l.data, "postgres")
	if fileExists(filepath.Join(pgData, "PG_VERSION")) {
		return nil
	}
	fmt.Println("Initializing PostgreSQL data directory...")
	if err := os.MkdirAll(pgData, 0700); err != nil {
		return err
	}
	args := []string{"-D", pgData, "-U", "postgres", "-A", "trust", "--encoding=UTF8"}
	if fileExists(filepath.Join(l.postgres, "share", "postgres.bki")) {
		args = append(args, "-L", filepath.Join(l.postgres, "share"))
	}
	cmd := exec.Command(postgresBin(l, "initdb"), args...)
	cmd.Env = postgresEnv(l)
	return runLogged(cmd, filepath.Join(l.logs, "postgres-init.log"))
}

func startPostgres(l layout) error {
	if isPortOpen("127.0.0.1:55432") {
		return nil
	}
	fmt.Println("Starting PostgreSQL...")
	pgData := filepath.Join(l.data, "postgres")
	logPath := filepath.Join(l.logs, "postgres.log")
	cmd := exec.Command(
		postgresBin(l, "pg_ctl"),
		"-D", pgData,
		"-l", logPath,
		"-o", "-p 55432 -h 127.0.0.1",
		"start",
	)
	cmd.Env = postgresEnv(l)
	if err := runLogged(cmd, filepath.Join(l.logs, "pg_ctl-start.log")); err != nil {
		return err
	}
	if err := waitPort("127.0.0.1:55432", 60*time.Second); err != nil {
		return err
	}
	return ensureDatabaseRole(l)
}

func stopPostgres(l layout) {
	cmd := exec.Command(postgresBin(l, "pg_ctl"), "-D", filepath.Join(l.data, "postgres"), "stop", "-m", "fast")
	cmd.Env = postgresEnv(l)
	_ = cmd.Run()
}

func ensureDatabaseRole(l layout) error {
	passwordBytes, err := os.ReadFile(filepath.Join(l.config, "postgres-password"))
	if err != nil {
		return err
	}
	password := strings.TrimSpace(string(passwordBytes))
	sql := fmt.Sprintf(`
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'teldrive') then
    create role teldrive with login superuser password %s;
  else
    alter role teldrive with login superuser password %s;
  end if;
end $$;
alter database postgres owner to teldrive;
`, quoteSQL(password), quoteSQL(password))
	cmd := exec.Command(postgresBin(l, "psql"), "-h", "127.0.0.1", "-p", "55432", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-c", sql)
	cmd.Env = postgresEnv(l)
	return runLogged(cmd, filepath.Join(l.logs, "postgres-role.log"))
}

func startProcesses(ctx context.Context, specs []processSpec) ([]*exec.Cmd, error) {
	procs := make([]*exec.Cmd, 0, len(specs))
	for _, spec := range specs {
		if !fileExists(spec.path) {
			stopProcesses(procs)
			return nil, fmt.Errorf("missing binary for %s: %s", spec.name, spec.path)
		}
		logFile, err := os.OpenFile(spec.log, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err != nil {
			stopProcesses(procs)
			return nil, err
		}
		cmd := exec.CommandContext(ctx, spec.path, spec.args...)
		cmd.Env = append(os.Environ(), spec.env...)
		cmd.Stdout = logFile
		cmd.Stderr = logFile
		if err := cmd.Start(); err != nil {
			_ = logFile.Close()
			stopProcesses(procs)
			return nil, fmt.Errorf("start %s: %w", spec.name, err)
		}
		procs = append(procs, cmd)
		go func(name string, c *exec.Cmd, f *os.File) {
			err := c.Wait()
			_ = f.Close()
			if err != nil && ctx.Err() == nil {
				log.Printf("%s exited: %v", name, err)
			}
		}(spec.name, cmd, logFile)
	}
	return procs, nil
}

func stopProcesses(procs []*exec.Cmd) {
	var wg sync.WaitGroup
	for _, proc := range procs {
		if proc.Process == nil {
			continue
		}
		wg.Add(1)
		go func(p *os.Process) {
			defer wg.Done()
			_ = p.Signal(os.Interrupt)
			time.Sleep(2 * time.Second)
			_ = p.Kill()
		}(proc.Process)
	}
	wg.Wait()
}

func postgresEnv(l layout) []string {
	env := os.Environ()
	bin := filepath.Join(l.postgres, "bin")
	lib := filepath.Join(l.postgres, "lib")
	libDeps := filepath.Join(l.postgres, "libdeps")
	env = append(env, "PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	env = append(env, "LD_LIBRARY_PATH="+lib+string(os.PathListSeparator)+libDeps+string(os.PathListSeparator)+os.Getenv("LD_LIBRARY_PATH"))
	env = append(env, "DYLD_LIBRARY_PATH="+lib+string(os.PathListSeparator)+libDeps+string(os.PathListSeparator)+os.Getenv("DYLD_LIBRARY_PATH"))
	return env
}

func postgresBin(l layout, name string) string {
	return withExe(filepath.Join(l.postgres, "bin", name))
}

func binPath(l layout, name string) string {
	return withExe(filepath.Join(l.bin, name))
}

func withExe(path string) string {
	if runtime.GOOS == "windows" && !strings.HasSuffix(strings.ToLower(path), ".exe") {
		return path + ".exe"
	}
	return path
}

func runLogged(cmd *exec.Cmd, logPath string) error {
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return err
	}
	defer f.Close()
	cmd.Stdout = f
	cmd.Stderr = f
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s failed; see %s: %w", filepath.Base(cmd.Path), logPath, err)
	}
	return nil
}

func waitPort(addr string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, time.Second)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for %s", addr)
}

func waitHTTP(rawURL string, timeout time.Duration) error {
	client := http.Client{Timeout: 2 * time.Second}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := client.Get(rawURL)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 500 {
				return nil
			}
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("timed out waiting for %s", rawURL)
}

func isPortOpen(addr string) bool {
	conn, err := net.DialTimeout("tcp", addr, 300*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func openBrowser(rawURL string) {
	if os.Getenv("TELEDRIVE_OPEN_BROWSER") == "0" {
		return
	}
	if err := waitHTTP(rawURL, 90*time.Second); err != nil {
		return
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("cmd", "/c", "start", "", rawURL)
	case "darwin":
		cmd = exec.Command("open", rawURL)
	default:
		cmd = exec.Command("xdg-open", rawURL)
	}
	_ = cmd.Start()
}

func randomSecret() string {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		panic(err)
	}
	return strings.TrimRight(base64.URLEncoding.EncodeToString(buf), "=")
}

func urlEscape(value string) string {
	replacer := strings.NewReplacer("%", "%25", ":", "%3A", "@", "%40", "/", "%2F", "?", "%3F", "#", "%23", "&", "%26", "=", "%3D", "+", "%2B")
	return replacer.Replace(value)
}

func quoteSQL(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil || !errors.Is(err, os.ErrNotExist)
}
