package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gotd/td/session"
	"github.com/gotd/td/telegram"
	"github.com/gotd/td/telegram/message"
	"github.com/gotd/td/telegram/query"
	tgmessages "github.com/gotd/td/telegram/query/messages"
	"github.com/gotd/td/telegram/uploader"
	"github.com/gotd/td/tg"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/pelletier/go-toml/v2"
)

const importerSchemaSQL = `
create schema if not exists teldrive_importer;
create table if not exists teldrive_importer.imported_messages (
	channel_id bigint not null,
	original_msg_id integer not null,
	imported_msg_id integer not null,
	file_id uuid,
	name text not null,
	media_kind text not null,
	converted boolean not null default false,
	created_at timestamptz not null default timezone('utc'::text, now()),
	primary key (channel_id, original_msg_id)
);
`

type filePart struct {
	ID int `json:"id"`
}

type appConfig struct {
	DB struct {
		DataSource string `toml:"data-source"`
	} `toml:"db"`
	TG struct {
		AppHash        string `toml:"app-hash"`
		AppID          int    `toml:"app-id"`
		AppVersion     string `toml:"app-version"`
		DeviceModel    string `toml:"device-model"`
		SystemVersion  string `toml:"system-version"`
		SystemLangCode string `toml:"system-lang-code"`
		LangPack       string `toml:"lang-pack"`
		LangCode       string `toml:"lang-code"`
	} `toml:"tg"`
}

type server struct {
	cfg          appConfig
	db           *pgxpool.Pool
	addr         string
	importFolder string
	defaultLimit int
	pollInterval time.Duration
	mu           sync.Mutex
	lastResult   *importResult
	lastErr      string
}

type importRequest struct {
	UserID        int64 `json:"user_id"`
	ChannelID     int64 `json:"channel_id"`
	Limit         int   `json:"limit"`
	ConvertPhotos bool  `json:"convert_photos"`
	DryRun        bool  `json:"dry_run"`
}

type importResult struct {
	StartedAt       time.Time      `json:"started_at"`
	FinishedAt      time.Time      `json:"finished_at"`
	UserID          int64          `json:"user_id"`
	ChannelID       int64          `json:"channel_id"`
	Scanned         int            `json:"scanned"`
	Imported        int            `json:"imported"`
	ConvertedPhotos int            `json:"converted_photos"`
	Skipped         int            `json:"skipped"`
	Errors          []string       `json:"errors,omitempty"`
	Files           []importedFile `json:"files"`
	DryRun          bool           `json:"dry_run"`
}

type importedFile struct {
	OriginalMessageID int    `json:"original_message_id"`
	ImportedMessageID int    `json:"imported_message_id"`
	FileID            string `json:"file_id"`
	Name              string `json:"name"`
	MimeType          string `json:"mime_type"`
	Size              int64  `json:"size"`
	Category          string `json:"category"`
	Converted         bool   `json:"converted"`
}

type mediaCandidate struct {
	OriginalMessageID int
	ImportedMessageID int
	Name              string
	MimeType          string
	Size              int64
	Category          string
	Kind              string
	Document          *tg.Document
	Photo             *tg.Photo
	PhotoThumbType    string
	PhotoSize         int64
	Converted         bool
}

func main() {
	cfgPath := envString("CONFIG_PATH", "/config.toml")
	cfg, err := loadConfig(cfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	if v := os.Getenv("DATABASE_URL"); v != "" {
		cfg.DB.DataSource = v
	}

	ctx := context.Background()
	db, err := pgxpool.New(ctx, cfg.DB.DataSource)
	if err != nil {
		log.Fatalf("connect database: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(ctx, importerSchemaSQL); err != nil {
		log.Fatalf("init importer schema: %v", err)
	}

	s := &server{
		cfg:          cfg,
		db:           db,
		addr:         envString("IMPORTER_ADDR", "0.0.0.0:8891"),
		importFolder: envString("IMPORT_FOLDER", "Telegram Imports"),
		defaultLimit: envInt("DEFAULT_LIMIT", 100),
		pollInterval: time.Duration(envInt("POLL_INTERVAL_SECONDS", 0)) * time.Second,
	}

	if s.pollInterval > 0 {
		go s.pollLoop(ctx)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.health)
	mux.HandleFunc("GET /api/status", s.status)
	mux.HandleFunc("POST /api/import", s.importOnce)

	log.Printf("teldrive importer listening on %s", s.addr)
	log.Printf("manual trigger: POST /api/import")
	if err := http.ListenAndServe(s.addr, mux); err != nil {
		log.Fatal(err)
	}
}

func loadConfig(path string) (appConfig, error) {
	var cfg appConfig
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return cfg, err
	}
	if cfg.DB.DataSource == "" {
		return cfg, errors.New("db.data-source is empty")
	}
	if cfg.TG.AppID == 0 || cfg.TG.AppHash == "" {
		return cfg, errors.New("tg.app-id/app-hash are empty")
	}
	return cfg, nil
}

func (s *server) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) status(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"manual_url":    "/api/import",
		"poll_interval": s.pollInterval.String(),
		"last_result":   s.lastResult,
		"last_error":    s.lastErr,
	})
}

func (s *server) importOnce(w http.ResponseWriter, r *http.Request) {
	req := importRequest{Limit: s.defaultLimit, ConvertPhotos: true}
	if r.Body != nil {
		defer r.Body.Close()
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
	}
	if req.Limit <= 0 {
		req.Limit = s.defaultLimit
	}

	result, err := s.runImport(r.Context(), req)
	status := http.StatusOK
	if err != nil {
		status = http.StatusInternalServerError
	}
	payload := map[string]any{"result": result}
	if err != nil {
		payload["error"] = err.Error()
	}
	writeJSON(w, status, payload)
}

func (s *server) pollLoop(ctx context.Context) {
	ticker := time.NewTicker(s.pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_, err := s.runImport(ctx, importRequest{
				Limit:         s.defaultLimit,
				ConvertPhotos: true,
			})
			if err != nil {
				log.Printf("poll import failed: %v", err)
			}
		}
	}
}

func (s *server) runImport(ctx context.Context, req importRequest) (*importResult, error) {
	if !s.mu.TryLock() {
		return nil, errors.New("import is already running")
	}
	defer s.mu.Unlock()

	result := &importResult{
		StartedAt: time.Now().UTC(),
		DryRun:    req.DryRun,
		Files:     []importedFile{},
		Errors:    []string{},
	}
	defer func() {
		result.FinishedAt = time.Now().UTC()
		s.lastResult = result
	}()

	userID, channelID, sessionStr, err := s.resolveTarget(ctx, req)
	if err != nil {
		s.lastErr = err.Error()
		return result, err
	}
	result.UserID = userID
	result.ChannelID = channelID

	parentID, err := s.ensureImportFolder(ctx, userID)
	if err != nil {
		s.lastErr = err.Error()
		return result, err
	}

	existingParts, err := s.loadExistingPartIDs(ctx, channelID)
	if err != nil {
		s.lastErr = err.Error()
		return result, err
	}
	alreadyImported, err := s.loadImportedSourceIDs(ctx, channelID)
	if err != nil {
		s.lastErr = err.Error()
		return result, err
	}

	client, err := s.telegramClient(ctx, sessionStr)
	if err != nil {
		s.lastErr = err.Error()
		return result, err
	}

	err = client.Run(ctx, func(ctx context.Context) error {
		status, err := client.Auth().Status(ctx)
		if err != nil {
			return err
		}
		if !status.Authorized {
			return errors.New("telegram session is not authorized")
		}

		channel, err := getChannel(ctx, client.API(), channelID)
		if err != nil {
			return err
		}

		q := query.NewQuery(client.API()).Messages().GetHistory(&tg.InputPeerChannel{
			ChannelID:  channel.ChannelID,
			AccessHash: channel.AccessHash,
		})
		iter := tgmessages.NewIterator(q, 100)
		for iter.Next(ctx) {
			if result.Scanned >= req.Limit {
				break
			}
			result.Scanned++

			msg, ok := iter.Value().Msg.(*tg.Message)
			if !ok || msg.ID <= 0 {
				result.Skipped++
				continue
			}
			if alreadyImported[msg.ID] {
				result.Skipped++
				continue
			}

			candidate, ok := mediaFromMessage(msg, req.ConvertPhotos)
			if !ok {
				result.Skipped++
				continue
			}
			if existingParts[candidate.OriginalMessageID] {
				result.Skipped++
				continue
			}

			if candidate.Photo != nil {
				if !req.ConvertPhotos {
					result.Skipped++
					continue
				}
				if req.DryRun {
					candidate.Converted = true
				} else {
					converted, err := convertPhotoToDocument(ctx, client.API(), channel, candidate)
					if err != nil {
						result.Errors = append(result.Errors, fmt.Sprintf("message %d: convert photo: %v", msg.ID, err))
						continue
					}
					candidate = converted
				}
			}

			if candidate.ImportedMessageID == 0 {
				candidate.ImportedMessageID = candidate.OriginalMessageID
			}
			if existingParts[candidate.ImportedMessageID] {
				result.Skipped++
				continue
			}
			candidate.Name, err = s.uniqueName(ctx, parentID, userID, candidate.Name)
			if err != nil {
				result.Errors = append(result.Errors, fmt.Sprintf("message %d: unique name: %v", msg.ID, err))
				continue
			}

			var fileID string
			if req.DryRun {
				fileID = "dry-run"
			} else {
				fileID, err = s.createFile(ctx, userID, channelID, parentID, candidate)
				if err != nil {
					result.Errors = append(result.Errors, fmt.Sprintf("message %d: create file: %v", msg.ID, err))
					continue
				}
				if err := s.recordImportedMessage(ctx, channelID, candidate, fileID); err != nil {
					result.Errors = append(result.Errors, fmt.Sprintf("message %d: record source: %v", msg.ID, err))
					continue
				}
			}

			result.Imported++
			if candidate.Converted {
				result.ConvertedPhotos++
			}
			result.Files = append(result.Files, importedFile{
				OriginalMessageID: candidate.OriginalMessageID,
				ImportedMessageID: candidate.ImportedMessageID,
				FileID:            fileID,
				Name:              candidate.Name,
				MimeType:          candidate.MimeType,
				Size:              candidate.Size,
				Category:          candidate.Category,
				Converted:         candidate.Converted,
			})
			existingParts[candidate.ImportedMessageID] = true
			alreadyImported[candidate.OriginalMessageID] = true
		}
		if err := iter.Err(); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		s.lastErr = err.Error()
		return result, err
	}
	s.lastErr = ""
	return result, nil
}

func (s *server) resolveTarget(ctx context.Context, req importRequest) (int64, int64, string, error) {
	userID := req.UserID
	if userID == 0 {
		err := s.db.QueryRow(ctx, `select user_id from teldrive.sessions order by created_at desc limit 1`).Scan(&userID)
		if err != nil {
			return 0, 0, "", fmt.Errorf("resolve user: %w", err)
		}
	}

	channelID := req.ChannelID
	if channelID == 0 {
		err := s.db.QueryRow(ctx, `
			select channel_id
			from teldrive.channels
			where user_id = $1 and selected = true
			order by created_at desc
			limit 1
		`, userID).Scan(&channelID)
		if err != nil {
			return 0, 0, "", fmt.Errorf("resolve selected channel: %w", err)
		}
	}

	var sessionStr string
	err := s.db.QueryRow(ctx, `
		select session
		from teldrive.sessions
		where user_id = $1
		order by created_at desc
		limit 1
	`, userID).Scan(&sessionStr)
	if err != nil {
		return 0, 0, "", fmt.Errorf("load session: %w", err)
	}
	return userID, channelID, sessionStr, nil
}

func (s *server) ensureImportFolder(ctx context.Context, userID int64) (string, error) {
	var rootID string
	err := s.db.QueryRow(ctx, `
		select id::text
		from teldrive.files
		where user_id = $1 and parent_id is null and name = 'root' and type = 'folder' and status = 'active'
		limit 1
	`, userID).Scan(&rootID)
	if errors.Is(err, pgx.ErrNoRows) {
		err = s.db.QueryRow(ctx, `
			insert into teldrive.files (name, user_id, mime_type, type, encrypted, status, updated_at)
			values ('root', $1, 'drive/folder', 'folder', false, 'active', timezone('utc'::text, now()))
			returning id::text
		`, userID).Scan(&rootID)
	}
	if err != nil {
		return "", fmt.Errorf("ensure root folder: %w", err)
	}

	var folderID string
	err = s.db.QueryRow(ctx, `
		insert into teldrive.files (name, parent_id, user_id, mime_type, type, encrypted, status, updated_at)
		values ($1, $2::uuid, $3, 'drive/folder', 'folder', false, 'active', timezone('utc'::text, now()))
		on conflict (name, coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), user_id)
		where status = 'active'
		do update set name = excluded.name
		returning id::text
	`, s.importFolder, rootID, userID).Scan(&folderID)
	if err != nil {
		return "", fmt.Errorf("ensure import folder: %w", err)
	}
	return folderID, nil
}

func (s *server) loadExistingPartIDs(ctx context.Context, channelID int64) (map[int]bool, error) {
	rows, err := s.db.Query(ctx, `
		select distinct (part ->> 'id')::integer
		from teldrive.files f
		cross join lateral jsonb_array_elements(f.parts) part
		where f.channel_id = $1
		  and f.type = 'file'
		  and f.status = 'active'
		  and f.parts is not null
	`, channelID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int]bool{}
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = true
	}
	return out, rows.Err()
}

func (s *server) loadImportedSourceIDs(ctx context.Context, channelID int64) (map[int]bool, error) {
	rows, err := s.db.Query(ctx, `
		select original_msg_id
		from teldrive_importer.imported_messages
		where channel_id = $1
	`, channelID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int]bool{}
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = true
	}
	return out, rows.Err()
}

func (s *server) telegramClient(ctx context.Context, sessionStr string) (*telegram.Client, error) {
	data, err := session.TelethonSession(sessionStr)
	if err != nil {
		return nil, err
	}
	storage := new(session.StorageMemory)
	loader := session.Loader{Storage: storage}
	if err := loader.Save(ctx, data); err != nil {
		return nil, err
	}
	return telegram.NewClient(s.cfg.TG.AppID, s.cfg.TG.AppHash, telegram.Options{
		SessionStorage: storage,
		Device: telegram.DeviceConfig{
			DeviceModel:    s.cfg.TG.DeviceModel,
			SystemVersion:  s.cfg.TG.SystemVersion,
			AppVersion:     s.cfg.TG.AppVersion,
			SystemLangCode: s.cfg.TG.SystemLangCode,
			LangPack:       s.cfg.TG.LangPack,
			LangCode:       s.cfg.TG.LangCode,
		},
	}), nil
}

func getChannel(ctx context.Context, client *tg.Client, channelID int64) (*tg.InputChannel, error) {
	res, err := client.ChannelsGetChannels(ctx, []tg.InputChannelClass{
		&tg.InputChannel{ChannelID: channelID},
	})
	if err != nil {
		return nil, err
	}
	chats := res.GetChats()
	if len(chats) == 0 {
		return nil, fmt.Errorf("channel %d not found", channelID)
	}
	channel, ok := chats[0].(*tg.Channel)
	if !ok {
		return nil, fmt.Errorf("peer %d is not a channel", channelID)
	}
	return channel.AsInput(), nil
}

func mediaFromMessage(msg *tg.Message, convertPhotos bool) (mediaCandidate, bool) {
	switch media := msg.Media.(type) {
	case *tg.MessageMediaDocument:
		doc, ok := media.Document.(*tg.Document)
		if !ok || doc.Size <= 0 {
			return mediaCandidate{}, false
		}
		name := documentName(doc, fmt.Sprintf("document-%d", msg.ID))
		mimeType := nonEmpty(doc.MimeType, detectMimeFromName(name))
		if documentHasVideoAttribute(doc) {
			mimeType = normalizeVideoMime(mimeType)
			name = ensureExtension(name, ".mp4")
		}
		return mediaCandidate{
			OriginalMessageID: msg.ID,
			ImportedMessageID: msg.ID,
			Name:              name,
			MimeType:          mimeType,
			Size:              doc.Size,
			Category:          categoryFor(name, mimeType),
			Kind:              "document",
			Document:          doc,
		}, true
	case *tg.MessageMediaPhoto:
		if !convertPhotos {
			return mediaCandidate{}, false
		}
		photo, ok := media.Photo.(*tg.Photo)
		if !ok {
			return mediaCandidate{}, false
		}
		thumbType, size, ok := bestPhotoSize(photo)
		if !ok {
			return mediaCandidate{}, false
		}
		name := fmt.Sprintf("photo-%d.jpg", msg.ID)
		return mediaCandidate{
			OriginalMessageID: msg.ID,
			Name:              name,
			MimeType:          "image/jpeg",
			Size:              size,
			Category:          "image",
			Kind:              "photo",
			Photo:             photo,
			PhotoThumbType:    thumbType,
			PhotoSize:         size,
		}, true
	default:
		return mediaCandidate{}, false
	}
}

func convertPhotoToDocument(ctx context.Context, client *tg.Client, channel *tg.InputChannel, in mediaCandidate) (mediaCandidate, error) {
	content, err := downloadPhoto(ctx, client, in.Photo, in.PhotoThumbType, in.PhotoSize)
	if err != nil {
		return in, err
	}
	u := uploader.NewUploader(client).WithPartSize(512 * 1024)
	upload, err := u.Upload(ctx, uploader.NewUpload(in.Name, bytes.NewReader(content), int64(len(content))))
	if err != nil {
		return in, err
	}
	doc := message.UploadedDocument(upload).Filename(in.Name).MIME(in.MimeType).ForceFile(true)
	sender := message.NewSender(client)
	target := sender.To(&tg.InputPeerChannel{ChannelID: channel.ChannelID, AccessHash: channel.AccessHash})
	res, err := target.Media(ctx, doc)
	if err != nil {
		return in, err
	}

	msg, err := messageFromUpdates(res)
	if err != nil {
		return in, err
	}
	media, ok := msg.Media.(*tg.MessageMediaDocument)
	if !ok {
		return in, errors.New("converted message is not a document")
	}
	document, ok := media.Document.(*tg.Document)
	if !ok {
		return in, errors.New("converted message has no document")
	}
	in.ImportedMessageID = msg.ID
	in.Document = document
	in.Size = document.Size
	if document.MimeType != "" {
		in.MimeType = document.MimeType
	}
	in.Converted = true
	return in, nil
}

func downloadPhoto(ctx context.Context, client *tg.Client, photo *tg.Photo, thumbType string, size int64) ([]byte, error) {
	location := &tg.InputPhotoFileLocation{
		ID:            photo.ID,
		AccessHash:    photo.AccessHash,
		FileReference: photo.FileReference,
		ThumbSize:     thumbType,
	}
	var buf bytes.Buffer
	const chunk = 512 * 1024
	for offset := int64(0); offset < size; {
		res, err := client.UploadGetFile(ctx, &tg.UploadGetFileRequest{
			Location: location,
			Offset:   offset,
			Limit:    chunk,
		})
		if err != nil {
			return nil, err
		}
		file, ok := res.(*tg.UploadFile)
		if !ok {
			return nil, fmt.Errorf("unexpected upload.getFile response %T", res)
		}
		if len(file.Bytes) == 0 {
			break
		}
		buf.Write(file.Bytes)
		offset += int64(len(file.Bytes))
		if len(file.Bytes) < chunk {
			break
		}
	}
	if buf.Len() == 0 {
		return nil, errors.New("empty photo download")
	}
	return buf.Bytes(), nil
}

func messageFromUpdates(updates tg.UpdatesClass) (*tg.Message, error) {
	switch u := updates.(type) {
	case *tg.Updates:
		for _, update := range u.Updates {
			if channelMsg, ok := update.(*tg.UpdateNewChannelMessage); ok {
				if msg, ok := channelMsg.Message.(*tg.Message); ok {
					return msg, nil
				}
			}
		}
	case *tg.UpdateShortSentMessage:
		return nil, errors.New("short sent message has no channel message payload")
	}
	return nil, fmt.Errorf("new channel message not found in %T", updates)
}

func (s *server) uniqueName(ctx context.Context, parentID string, userID int64, desired string) (string, error) {
	desired = sanitizeName(desired)
	ext := filepath.Ext(desired)
	base := strings.TrimSuffix(desired, ext)
	for i := 0; i < 1000; i++ {
		name := desired
		if i > 0 {
			name = fmt.Sprintf("%s-%d%s", base, i, ext)
		}
		var exists bool
		err := s.db.QueryRow(ctx, `
			select exists (
				select 1
				from teldrive.files
				where parent_id = $1::uuid and user_id = $2 and name = $3 and status = 'active'
			)
		`, parentID, userID, name).Scan(&exists)
		if err != nil {
			return "", err
		}
		if !exists {
			return name, nil
		}
	}
	return "", fmt.Errorf("unable to allocate unique name for %s", desired)
}

func (s *server) createFile(ctx context.Context, userID, channelID int64, parentID string, m mediaCandidate) (string, error) {
	partsJSON, err := json.Marshal([]filePart{{ID: m.ImportedMessageID}})
	if err != nil {
		return "", err
	}
	var fileID string
	err = s.db.QueryRow(ctx, `
		insert into teldrive.files (
			name, parent_id, user_id, mime_type, category, parts,
			size, type, encrypted, updated_at, channel_id, status
		)
		values ($1, $2::uuid, $3, $4, $5, $6::jsonb, $7, 'file', false, timezone('utc'::text, now()), $8, 'active')
		returning id::text
	`, m.Name, parentID, userID, m.MimeType, m.Category, string(partsJSON), m.Size, channelID).Scan(&fileID)
	if err != nil {
		return "", err
	}
	return fileID, nil
}

func (s *server) recordImportedMessage(ctx context.Context, channelID int64, m mediaCandidate, fileID string) error {
	_, err := s.db.Exec(ctx, `
		insert into teldrive_importer.imported_messages (
			channel_id, original_msg_id, imported_msg_id, file_id, name, media_kind, converted
		)
		values ($1, $2, $3, $4::uuid, $5, $6, $7)
		on conflict (channel_id, original_msg_id)
		do update set
			imported_msg_id = excluded.imported_msg_id,
			file_id = excluded.file_id,
			name = excluded.name,
			media_kind = excluded.media_kind,
			converted = excluded.converted
	`, channelID, m.OriginalMessageID, m.ImportedMessageID, fileID, m.Name, m.Kind, m.Converted)
	return err
}

func documentName(doc *tg.Document, fallbackBase string) string {
	for _, attr := range doc.Attributes {
		if filename, ok := attr.(*tg.DocumentAttributeFilename); ok && filename.FileName != "" {
			return sanitizeName(filename.FileName)
		}
	}
	ext := extensionForMime(doc.MimeType)
	return sanitizeName(fallbackBase + ext)
}

func documentHasVideoAttribute(doc *tg.Document) bool {
	for _, attr := range doc.Attributes {
		if _, ok := attr.(*tg.DocumentAttributeVideo); ok {
			return true
		}
	}
	return false
}

func normalizeVideoMime(mimeType string) string {
	if mimeType == "" || strings.EqualFold(mimeType, "application/octet-stream") {
		return "video/mp4"
	}
	return mimeType
}

func ensureExtension(name, ext string) string {
	if filepath.Ext(name) != "" {
		return name
	}
	return sanitizeName(name + ext)
}

func bestPhotoSize(photo *tg.Photo) (string, int64, bool) {
	bestType := ""
	var bestSize int64
	for _, size := range photo.Sizes {
		switch s := size.(type) {
		case *tg.PhotoSize:
			if int64(s.Size) > bestSize && s.Type != "" {
				bestSize = int64(s.Size)
				bestType = s.Type
			}
		case *tg.PhotoSizeProgressive:
			for _, value := range s.Sizes {
				if int64(value) > bestSize && s.Type != "" {
					bestSize = int64(value)
					bestType = s.Type
				}
			}
		}
	}
	return bestType, bestSize, bestType != "" && bestSize > 0
}

func categoryFor(name, mimeType string) string {
	lowerMime := strings.ToLower(mimeType)
	ext := strings.TrimPrefix(strings.ToLower(filepath.Ext(name)), ".")
	if strings.HasPrefix(lowerMime, "image/") || contains([]string{"jpg", "jpeg", "png", "gif", "bmp", "svg", "webp", "heif", "heic"}, ext) {
		return "image"
	}
	if strings.HasPrefix(lowerMime, "video/") || contains([]string{"mp4", "webm", "mov", "avi", "m4v", "flv", "wmv", "mkv", "mpg", "mpeg", "m2v", "mpv"}, ext) {
		return "video"
	}
	if strings.HasPrefix(lowerMime, "audio/") || contains([]string{"mp3", "wav", "ogg", "m4a", "flac", "aac", "wma", "aiff", "ape", "alac", "opus", "pcm"}, ext) {
		return "audio"
	}
	if contains([]string{"zip", "rar", "tar", "gz", "7z", "iso", "dmg", "pkg", "xz", "tgz"}, ext) {
		return "archive"
	}
	if contains([]string{"doc", "docx", "ppt", "pptx", "pps", "ppsx", "odt", "xls", "xlsx", "csv", "pdf", "txt"}, ext) {
		return "document"
	}
	return "other"
}

func extensionForMime(mimeType string) string {
	if mimeType == "" {
		return ""
	}
	exts, err := mime.ExtensionsByType(mimeType)
	if err != nil || len(exts) == 0 {
		return ""
	}
	return exts[0]
}

func detectMimeFromName(name string) string {
	if v := mime.TypeByExtension(filepath.Ext(name)); v != "" {
		return v
	}
	return "application/octet-stream"
}

func sanitizeName(name string) string {
	name = strings.TrimSpace(name)
	name = strings.ReplaceAll(name, "/", "_")
	name = strings.ReplaceAll(name, "\\", "_")
	if name == "" || name == "." || name == ".." {
		return "telegram-file"
	}
	return name
}

func contains(items []string, needle string) bool {
	for _, item := range items {
		if item == needle {
			return true
		}
	}
	return false
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

func nonEmpty(v, fallback string) string {
	if v != "" {
		return v
	}
	return fallback
}
