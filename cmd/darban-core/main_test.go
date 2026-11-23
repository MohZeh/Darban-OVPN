package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MohZeh/Darban-OVPN/internal/buildinfo"
)

func call(args ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	rc := run(args, &stdout, &stderr)
	return rc, stdout.String(), stderr.String()
}

func TestVersion(t *testing.T) {
	rc, out, _ := call("version")
	if rc != 0 || out != buildinfo.Version+"\n" {
		t.Fatalf("version: %d %q", rc, out)
	}
	if rc, _, _ := call("version", "extra"); rc != 2 {
		t.Fatalf("version with an argument: %d", rc)
	}
}

func TestUsageErrors(t *testing.T) {
	for _, args := range [][]string{{}, {"nonsense"}, {"index"}, {"index", "--pki", "/x"}, {"index", "--pki", "/x", "--view", "crl"},
		{"index", "--pki", "/x", "--view", "list", "--now", "soon"}, {"index", "--pki", "/x", "--view", "list", "extra"}} {
		if rc, out, errText := call(args...); rc != 2 || out != "" || !strings.Contains(errText, "Usage:") {
			t.Errorf("%q: rc %d, out %q", args, rc, out)
		}
	}
}

func TestAnIndexThatCannotBeReadPrintsNoList(t *testing.T) {
	dir := t.TempDir()
	rc, out, errText := call("index", "--pki", dir, "--view", "list")
	if rc != 1 || out != "" || errText != "ERROR: CA database is missing or unreadable: "+dir+"/index.txt\n" {
		t.Fatalf("missing index: %d %q %q", rc, out, errText)
	}
	if err := os.WriteFile(filepath.Join(dir, "index.txt"), []byte("V\t291231235959Z\t\t0A\tunknown\t/CN=a\ngarbage\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rc, out, errText = call("index", "--pki", dir, "--view", "stats")
	if rc != 1 || out != "" || !strings.Contains(errText, "malformed record") {
		t.Fatalf("malformed index: %d %q %q", rc, out, errText)
	}
}

func TestViews(t *testing.T) {
	dir := t.TempDir()
	index := "V\t291231235959Z\t\t0A\tunknown\t/CN=server\nR\t291231235959Z\t261101000000Z\t0B\tunknown\t/CN=gone\n"
	if err := os.WriteFile(filepath.Join(dir, "index.txt"), []byte(index), 0o600); err != nil {
		t.Fatal(err)
	}
	if rc, out, _ := call("index", "--pki", dir, "--view", "stats", "--now", "1795392000", "--server-serial", "0a"); rc != 0 || out != "stats\t0\t1\t0\t0\n" {
		t.Errorf("stats: %d %q", rc, out)
	}
	if rc, out, _ := call("index", "--pki", dir, "--view", "pending", "--now", "1795392000"); rc != 0 || out != "pending\tgone\n" {
		t.Errorf("pending: %d %q", rc, out)
	}
	if rc, out, errText := call("index", "--pki", dir, "--view", "pending", "--crl", filepath.Join(dir, "none.pem")); rc != 1 || out != "" || errText != "" {
		t.Errorf("pending with a CRL that cannot be read: %d %q %q", rc, out, errText)
	}
	if rc, _, errText := call("index", "--pki", dir, "--view", "crl", "--crl", filepath.Join(dir, "none.pem"), "--server-serial", "0A"); rc != 1 || errText != "ERROR: Could not read the serials of the CRL.\n" {
		t.Errorf("crl: %d %q", rc, errText)
	}
	if rc, out, _ := call("index", "--pki", dir, "--view", "list", "--now", "1795392000", "--server-serial", "A"); rc != 0 || out != "hidden\t1\n" {
		t.Errorf("list: %d %q", rc, out)
	}
}
