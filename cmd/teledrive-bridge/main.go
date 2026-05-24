package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/pelletier/go-toml/v2"
)

type appConfig struct {
	DB struct {
		DataSource string `toml:"data-source"`
	} `toml:"db"`
}

type server struct {
	db               *pgxpool.Pool
	addr             string
	teldriveOrigin   string
	importerOrigin   string
	token            string
	catalogLimit     int
	mediaHTTPClient  *http.Client
	apiHTTPClient    *http.Client
	importHTTPClient *http.Client
}

type catalogItem struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	MimeType  string    `json:"mime_type"`
	Size      int64     `json:"size"`
	Category  string    `json:"category"`
	Kind      string    `json:"kind"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	MediaURL  string    `json:"media_url"`
}

type treeItem struct {
	ID        string    `json:"id"`
	ParentID  string    `json:"parent_id,omitempty"`
	Name      string    `json:"name"`
	Path      string    `json:"path"`
	Type      string    `json:"type"`
	MimeType  string    `json:"mime_type"`
	Size      int64     `json:"size"`
	Category  string    `json:"category"`
	Kind      string    `json:"kind"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	MediaURL  string    `json:"media_url,omitempty"`
}

func main() {
	cfg, err := loadConfig(envString("CONFIG_PATH", "/config.toml"))
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	if v := os.Getenv("DATABASE_URL"); v != "" {
		cfg.DB.DataSource = v
	}
	if cfg.DB.DataSource == "" {
		log.Fatal("DATABASE_URL or db.data-source is required")
	}

	ctx := context.Background()
	db, err := pgxpool.New(ctx, cfg.DB.DataSource)
	if err != nil {
		log.Fatalf("connect database: %v", err)
	}
	defer db.Close()

	s := &server{
		db:             db,
		addr:           envString("BRIDGE_ADDR", "0.0.0.0:8892"),
		teldriveOrigin: strings.TrimRight(envString("TELDRIVE_ORIGIN", "http://teldrive:8080"), "/"),
		importerOrigin: strings.TrimRight(envString("IMPORTER_ORIGIN", "http://importer:8891"), "/"),
		token:          os.Getenv("BRIDGE_TOKEN"),
		catalogLimit:   envInt("CATALOG_LIMIT", 100),
		mediaHTTPClient: &http.Client{
			Timeout: 0,
		},
		apiHTTPClient: &http.Client{
			Timeout: 60 * time.Second,
		},
		importHTTPClient: &http.Client{
			Timeout: 0,
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.health)
	mux.HandleFunc("GET /api/catalog", s.requireAuth(s.catalog))
	mux.HandleFunc("GET /v1/catalog/items", s.requireAuth(s.catalog))
	mux.HandleFunc("GET /v1/tree", s.requireAuth(s.tree))
	mux.HandleFunc("GET /media/", s.requireAuth(s.legacyMedia))
	mux.HandleFunc("GET /v1/files/", s.requireAuth(s.fileContent))
	mux.HandleFunc("HEAD /v1/files/", s.requireAuth(s.fileContent))
	mux.HandleFunc("GET /v1/imports/latest", s.requireAuth(s.proxyImporterStatus))
	mux.HandleFunc("POST /v1/imports", s.requireAuth(s.proxyImporterImport))

	log.Printf("teledrive bridge listening on %s", s.addr)
	log.Printf("teldrive origin: %s", s.teldriveOrigin)
	if s.token == "" {
		log.Printf("bridge token is not set; API is open on this listener")
	}
	if err := http.ListenAndServe(s.addr, mux); err != nil {
		log.Fatal(err)
	}
}

func loadConfig(path string) (appConfig, error) {
	var cfg appConfig
	if path == "" {
		return cfg, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) && os.Getenv("DATABASE_URL") != "" {
		return cfg, nil
	}
	if err != nil {
		return cfg, err
	}
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return cfg, err
	}
	return cfg, nil
}

func (s *server) health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := s.db.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) catalog(w http.ResponseWriter, r *http.Request) {
	limit := s.catalogLimit
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 && parsed <= 500 {
			limit = parsed
		}
	}

	rows, err := s.db.Query(r.Context(), `
		select
			id::text,
			name,
			coalesce(mime_type, ''),
			coalesce(size, 0),
			coalesce(category, ''),
			created_at,
			updated_at
		from teldrive.files
		where type = 'file'
		  and status = 'active'
		  and (
			category in ('image', 'video')
			or mime_type like 'image/%'
			or mime_type like 'video/%'
		  )
		order by created_at desc
		limit $1
	`, limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	defer rows.Close()

	items := make([]catalogItem, 0, limit)
	for rows.Next() {
		var item catalogItem
		if err := rows.Scan(&item.ID, &item.Name, &item.MimeType, &item.Size, &item.Category, &item.CreatedAt, &item.UpdatedAt); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		item.Kind = mediaKind(item.Category, item.MimeType)
		item.MediaURL = "/v1/files/" + url.PathEscape(item.ID) + "/content?name=" + url.QueryEscape(item.Name)
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"count": len(items),
		"items": items,
	})
}

func (s *server) tree(w http.ResponseWriter, r *http.Request) {
	root := normalizeTreeRoot(r.URL.Query().Get("root"))
	limit := 10000
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 && parsed <= 50000 {
			limit = parsed
		}
	}

	rows, err := s.db.Query(r.Context(), `
		select
			id,
			parent_id,
			name,
			path,
			type,
			mime_type,
			size,
			category,
			created_at,
			updated_at
		from (
			select
				f.id::text as id,
				coalesce(f.parent_id::text, '') as parent_id,
				f.name as name,
				teldrive.get_path_from_file_id(f.id) as path,
				coalesce(f.type, '') as type,
				coalesce(f.mime_type, '') as mime_type,
				coalesce(f.size, 0) as size,
				coalesce(f.category, '') as category,
				f.created_at,
				f.updated_at
			from teldrive.files f
			where f.status = 'active'
		) items
		where $1 = '/'
		   or path = $1
		   or path like $1 || '/%'
		order by path asc
		limit $2
	`, root, limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	defer rows.Close()

	items := make([]treeItem, 0)
	for rows.Next() {
		var item treeItem
		if err := rows.Scan(
			&item.ID,
			&item.ParentID,
			&item.Name,
			&item.Path,
			&item.Type,
			&item.MimeType,
			&item.Size,
			&item.Category,
			&item.CreatedAt,
			&item.UpdatedAt,
		); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		if item.Type == "file" {
			item.Kind = mediaKind(item.Category, item.MimeType)
			item.MediaURL = "/v1/files/" + url.PathEscape(item.ID) + "/content?name=" + url.QueryEscape(item.Name)
		} else {
			item.Kind = "folder"
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"root":  root,
		"count": len(items),
		"items": items,
	})
}

func (s *server) legacyMedia(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/media/")
	parts := strings.SplitN(rest, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "media path must be /media/{file_id}/{filename}"})
		return
	}
	id, err := url.PathUnescape(parts[0])
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid file id"})
		return
	}
	name, err := url.PathUnescape(parts[1])
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid file name"})
		return
	}
	s.proxyMedia(w, r, id, name)
}

func (s *server) fileContent(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/v1/files/")
	id, ok := strings.CutSuffix(rest, "/content")
	if !ok || id == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "file path must be /v1/files/{file_id}/content"})
		return
	}
	id, err := url.PathUnescape(id)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid file id"})
		return
	}
	name := r.URL.Query().Get("name")
	if name == "" {
		name, err = s.lookupFileName(r.Context(), id)
		if err != nil {
			status := http.StatusInternalServerError
			if errors.Is(err, pgx.ErrNoRows) {
				status = http.StatusNotFound
			}
			writeJSON(w, status, map[string]string{"error": err.Error()})
			return
		}
	}
	s.proxyMedia(w, r, id, name)
}

func (s *server) proxyMedia(w http.ResponseWriter, r *http.Request, id string, name string) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	hash, err := s.sessionHash(r.Context())
	if err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, pgx.ErrNoRows) {
			status = http.StatusServiceUnavailable
		}
		writeJSON(w, status, map[string]string{"error": err.Error()})
		return
	}

	upstreamURL := fmt.Sprintf("%s/api/files/%s/%s?hash=%s",
		s.teldriveOrigin,
		url.PathEscape(id),
		url.PathEscape(name),
		url.QueryEscape(hash),
	)
	method := r.Method
	if method == http.MethodHead {
		method = http.MethodGet
	}
	req, err := http.NewRequestWithContext(r.Context(), method, upstreamURL, nil)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	copyRequestHeader(req.Header, r.Header, "Range")
	copyRequestHeader(req.Header, r.Header, "If-None-Match")
	copyRequestHeader(req.Header, r.Header, "If-Modified-Since")
	copyRequestHeader(req.Header, r.Header, "User-Agent")

	resp, err := s.mediaHTTPClient.Do(req)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	defer resp.Body.Close()

	copyResponseHeader(w.Header(), resp.Header, "Accept-Ranges")
	copyResponseHeader(w.Header(), resp.Header, "Content-Disposition")
	copyResponseHeader(w.Header(), resp.Header, "Content-Length")
	copyResponseHeader(w.Header(), resp.Header, "Content-Range")
	copyResponseHeader(w.Header(), resp.Header, "Content-Type")
	copyResponseHeader(w.Header(), resp.Header, "ETag")
	copyResponseHeader(w.Header(), resp.Header, "Last-Modified")
	w.Header().Set("Cache-Control", "private, max-age=30")
	w.WriteHeader(resp.StatusCode)
	if r.Method == http.MethodHead {
		return
	}
	_, _ = io.Copy(w, resp.Body)
}

func (s *server) proxyImporterStatus(w http.ResponseWriter, r *http.Request) {
	s.proxyImporter(w, r, http.MethodGet, "/api/status")
}

func (s *server) proxyImporterImport(w http.ResponseWriter, r *http.Request) {
	s.proxyImporterWithClient(w, r, http.MethodPost, "/api/import", s.importHTTPClient)
}

func (s *server) proxyImporter(w http.ResponseWriter, r *http.Request, method string, path string) {
	s.proxyImporterWithClient(w, r, method, path, s.apiHTTPClient)
}

func (s *server) proxyImporterWithClient(w http.ResponseWriter, r *http.Request, method string, path string, client *http.Client) {
	if s.importerOrigin == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "IMPORTER_ORIGIN is not configured"})
		return
	}
	if client == nil {
		client = s.apiHTTPClient
	}
	req, err := http.NewRequestWithContext(r.Context(), method, s.importerOrigin+path, r.Body)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	copyRequestHeader(req.Header, r.Header, "Content-Type")
	resp, err := client.Do(req)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	defer resp.Body.Close()
	copyResponseHeader(w.Header(), resp.Header, "Content-Type")
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func (s *server) lookupFileName(ctx context.Context, id string) (string, error) {
	var name string
	err := s.db.QueryRow(ctx, `
		select name
		from teldrive.files
		where id = $1::uuid and type = 'file' and status = 'active'
	`, id).Scan(&name)
	return name, err
}

func (s *server) sessionHash(ctx context.Context) (string, error) {
	var hash string
	err := s.db.QueryRow(ctx, `
		select hash
		from teldrive.sessions
		order by session_date desc
		limit 1
	`).Scan(&hash)
	if err != nil {
		return "", err
	}
	if hash == "" {
		return "", errors.New("latest Teldrive session has empty hash")
	}
	return hash, nil
}

func (s *server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.token == "" {
			next(w, r)
			return
		}
		if r.Header.Get("Authorization") != "Bearer "+s.token {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next(w, r)
	}
}

func mediaKind(category string, mimeType string) string {
	if category == "video" || strings.HasPrefix(strings.ToLower(mimeType), "video/") {
		return "video"
	}
	if category == "image" || strings.HasPrefix(strings.ToLower(mimeType), "image/") {
		return "image"
	}
	return "file"
}

func normalizeTreeRoot(raw string) string {
	root := strings.TrimSpace(strings.ReplaceAll(raw, "\\", "/"))
	if root == "" {
		return "/"
	}
	if !strings.HasPrefix(root, "/") {
		root = "/" + root
	}
	for strings.Contains(root, "//") {
		root = strings.ReplaceAll(root, "//", "/")
	}
	if root != "/" {
		root = strings.TrimRight(root, "/")
	}
	return root
}

func copyRequestHeader(dst http.Header, src http.Header, name string) {
	if value := src.Get(name); value != "" {
		dst.Set(name, value)
	}
}

func copyResponseHeader(dst http.Header, src http.Header, name string) {
	if value := src.Get(name); value != "" {
		dst.Set(name, value)
	}
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func envString(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		n, err := strconv.Atoi(v)
		if err == nil {
			return n
		}
	}
	return fallback
}
