package main

import (
	"testing"

	"github.com/gotd/td/tg"
)

func TestMediaFromVideoDocumentWithMissingMetadata(t *testing.T) {
	msg := &tg.Message{
		ID: 42,
		Media: &tg.MessageMediaDocument{
			Document: &tg.Document{
				Size:     1234,
				MimeType: "application/octet-stream",
				Attributes: []tg.DocumentAttributeClass{
					&tg.DocumentAttributeFilename{FileName: "82e00fc8cfc8c98ff8fd9d02be34e271"},
					&tg.DocumentAttributeVideo{},
				},
			},
		},
	}

	got, ok := mediaFromMessage(msg, true)
	if !ok {
		t.Fatal("mediaFromMessage returned false")
	}
	if got.Name != "82e00fc8cfc8c98ff8fd9d02be34e271.mp4" {
		t.Fatalf("Name = %q", got.Name)
	}
	if got.MimeType != "video/mp4" {
		t.Fatalf("MimeType = %q", got.MimeType)
	}
	if got.Category != "video" {
		t.Fatalf("Category = %q", got.Category)
	}
}
